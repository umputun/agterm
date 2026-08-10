#!/usr/bin/env python3
"""Annotate what the pane just printed and hand the notes back to it as an unsent paste.

Runs as an agterm keymap custom command, so the runner exports $AGT_* and the app spawns it with
launchd's PATH and stdout on /dev/null.

    text selected    -> that selection is what you annotate
    nothing selected -> the pane's last CAPTURE_LINES lines

The text goes into a scratch file, revdiff opens on it in a blocking overlay, and every annotation
comes back as the line it was attached to plus what was written about it. That pair is the whole
point: a note like "why this one?" is unreadable on its own once the pane has scrolled on.

The reply is delivered through the CLIPBOARD, saved and restored around the paste. This is not a
convenience - `session type` sends real keystrokes, so a multi-line reply submits itself one line at
a time, while `session paste` is the only bracketed-paste path agterm exposes and it reads the
system clipboard. Measured against a pty with DECSET 2004 on: type produced bare lines, paste
produced one `^[[200~...^[[201~` block. So the reply lands whole and unsent, for you to read and
send.

Usage: annotate-pane.py [--print]
    --print  write the reply to stdout instead of pasting it, for checking the formatting
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# how much of the pane to offer when nothing is selected. The pane's visible screen is the ceiling
# anyway - `session text` without --all does not reach into scrollback
CAPTURE_LINES = 50

# a floating panel rather than the full pane, so the session it asks about stays visible behind it,
# tinted dark enough that revdiff's syntax colors still read against it
OVERLAY_PERCENT = 80
OVERLAY_TINT = "#3a2c1e"

AGTERMCTL = os.environ.get("AGTERMCTL") or "agtermctl"
LOG = Path(os.environ.get("ANNOTATE_LOG") or (Path(tempfile.gettempdir()) / "agterm-annotate.log"))

# `## path:line (type)` and `## path:line-end (type)`, the record header revdiff writes. The path is
# non-greedy so a colon inside it cannot eat the line number
HEADER_RE = re.compile(r"^##\s+(?P<path>.+?):(?P<start>\d+)(?:-(?P<end>\d+))?\s+\((?P<kind>[^)]*)\)\s*$")
# the file-level form carries no line at all, so it quotes nothing
FILE_HEADER_RE = re.compile(r"^##\s+(?P<path>.+?)\s+\((?P<kind>[^)]*)\)\s*$")


def log(message: str) -> None:
    """Append a line to the run log; a keybinding has no stdout anyone reads."""
    try:
        with LOG.open("a") as fh:
            fh.write(f"{time.strftime('%F %T')}  {message}\n")
    except OSError:
        pass


def fail(message: str, agt: Agt | None = None) -> None:
    """Report through the only channels a keybinding has, then exit."""
    log(message)
    print(f"annotate-pane: {message}", file=sys.stderr)
    if agt:
        agt.notify(message)
    sys.exit(1)


def find_revdiff() -> str:
    """Resolve revdiff absolutely: a custom command gets launchd's PATH, not a shell's.

    That PATH is /usr/local/bin plus the system directories, so a revdiff installed by Homebrew or
    `go install` is not on it. Set REVDIFF to its full path when neither fallback below matches.
    """
    for candidate in (os.environ.get("REVDIFF") or "", shutil.which("revdiff") or "",
                      "/opt/homebrew/bin/revdiff", str(Path.home() / "go/bin/revdiff")):
        if candidate and os.access(candidate, os.X_OK):
            return candidate
    return ""


class Agt:
    """The agterm control channel: agtermctl plus this session's addressing."""

    def __init__(self) -> None:
        self.socket = os.environ.get("AGT_SOCKET") or ""
        self.sid = os.environ.get("AGT_SESSION_ID") or ""
        self.pane = os.environ.get("AGT_PANE") or ""

    def run(self, *args: str) -> subprocess.CompletedProcess[str]:
        """Invoke agtermctl against the instance the chord came from, never raising on a nonzero exit."""
        cmd = [AGTERMCTL, *args]
        if self.socket:
            cmd += ["--socket", self.socket]
        return subprocess.run(cmd, capture_output=True, text=True, check=False)

    def notify(self, message: str) -> None:
        """Post a desktop banner, the one channel a keybinding has when it cannot paste."""
        self.run("notify", message, "--title", "annotate")

    def pane_text(self) -> str:
        """Read the pane the chord fired from, not whichever pane happens to be focused.

        --pane is passed explicitly because the two can differ: a chord fired in a split's right pane
        while focus sits left would otherwise capture the wrong half.
        """
        args = ["session", "text", "--target", self.sid, "--lines", str(CAPTURE_LINES)]
        if self.pane in ("left", "right", "scratch"):
            args += ["--pane", self.pane]
        res = self.run(*args)
        return res.stdout if res.returncode == 0 else ""

    def review(self, revdiff: str, src: Path, out: Path) -> int:
        """Open revdiff over this session and block, returning its exit status.

        10 means annotations were written, 0 that the review was quit without any.
        """
        command = f"{revdiff} --only={src} -o {out} --exit-code-on-annotations --wrap"
        return self.run("session", "overlay", "open", command, "--block",
                        "--size-percent", str(OVERLAY_PERCENT),
                        "--background-color", OVERLAY_TINT,
                        "--target", self.sid).returncode

    def paste(self, text: str) -> bool:
        """Deliver text as one bracketed paste, leaving the clipboard as it was found.

        The save-and-restore is what makes the clipboard route free: without it, using this command
        would silently cost whatever you were carrying.
        """
        saved = subprocess.run(["pbpaste"], capture_output=True, text=True, check=False).stdout
        try:
            subprocess.run(["pbcopy"], input=text, text=True, check=False)
            return self.run("session", "paste", "--target", self.sid).returncode == 0
        finally:
            subprocess.run(["pbcopy"], input=saved, text=True, check=False)


def captured(selection: str, pane: str) -> str:
    """Pick what gets reviewed: the selection when there is one, else the pane text.

    Whitespace does not count as a selection - a stray drag leaves one, and reviewing it would show
    an empty buffer instead of the screen you meant.

    Blank tail lines are dropped from the PANE only. `session text` returns the whole screen, so a
    pane holding a few lines hands over a screenful of padding, and revdiff opens on the emptiness
    below the content rather than on the content. A selection is taken exactly as made. Only the tail
    is trimmed: dropping leading blanks would shift every line number an annotation comes back with.
    """
    if selection.strip():
        return selection
    return "\n".join(pane.splitlines()).rstrip()


def parse_annotations(text: str) -> list[tuple[int, int, str]]:
    """Read revdiff's output into (start, end, note) triples, 0 for file-level.

    A body line beginning with `## ` arrives space-prefixed, revdiff's own guard against a comment
    being read as the next record; that space is taken back off here.
    """
    found: list[tuple[int, int, str]] = []
    start = end = 0
    body: list[str] = []
    open_record = False

    def flush() -> None:
        note = "\n".join(body).strip()
        if open_record and note:
            found.append((start, end, note))

    for line in text.splitlines():
        header = HEADER_RE.match(line)
        if not header and line.startswith("## "):
            header = FILE_HEADER_RE.match(line)
        if header:
            flush()
            groups = header.groupdict()
            start = int(groups.get("start") or 0)
            end = int(groups.get("end") or 0) or start
            body, open_record = [], True
            continue
        if open_record:
            body.append(line[1:] if line.startswith(" ## ") else line)
    flush()
    return found


def reply_text(lines: list[str], annotations: list[tuple[int, int, str]]) -> str:
    """Render each annotation as the line it hangs on, quoted, then the note.

    Line numbers are 1-based into the captured text. One out of range quotes nothing rather than
    dropping the note: a question is still worth asking without its referent.
    """
    blocks = []
    for start, end, note in annotations:
        quoted = [f"> {lines[n - 1]}" for n in range(start, end + 1) if 1 <= n <= len(lines)]
        blocks.append("\n".join(quoted + ["", note]) if quoted else note)
    return "\n\n".join(blocks)


def main(argv: list[str]) -> int:
    """Capture, review, and paste the notes back into the session."""
    agt = Agt()
    if not agt.sid:
        fail("no $AGT_SESSION_ID: run this as an agterm custom command")
    revdiff = find_revdiff()
    if not revdiff:
        fail("revdiff not found: set REVDIFF to its full path", agt)

    text = captured(os.environ.get("AGT_SELECTION") or "", agt.pane_text())
    if not text.strip():
        fail("nothing to annotate: no selection and the pane read empty", agt)

    room = Path(tempfile.mkdtemp(prefix="agterm-annotate-"))
    src, out = room / "session.txt", room / "notes.md"
    src.write_text(text)
    try:
        code = agt.review(revdiff, src, out)
        if code not in (0, 10):
            fail(f"revdiff exited {code}", agt)
        if code == 0 or not out.exists():
            log("quit without annotations")
            return 0
        annotations = parse_annotations(out.read_text())
    finally:
        shutil.rmtree(room, ignore_errors=True)

    if not annotations:
        return 0
    reply = reply_text(text.splitlines(), annotations)
    if "--print" in argv:
        print(reply)
        return 0
    if not agt.paste(reply):
        fail("could not paste the reply into the session", agt)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(130)
