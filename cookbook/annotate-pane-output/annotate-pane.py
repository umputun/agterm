#!/usr/bin/env python3
"""Annotate what the pane just printed and hand the notes back to it as an unsent paste.

Runs as an agterm keymap custom command, so the runner exports $AGT_* and the app spawns it with a
PATH of its own choosing and stdout on /dev/null.

    text selected    -> that selection is what you annotate
    nothing selected -> the pane's last CAPTURE_LINES lines

The text goes into a scratch file, revdiff opens on it in a blocking overlay, and every annotation
comes back as the line it was attached to plus what was written about it. That pair is the whole
point: a note like "why this one?" is unreadable on its own once the pane has scrolled on.

The reply is delivered through the CLIPBOARD, saved and restored around the paste. This is not a
convenience - `session type` sends real keystrokes, so a multi-line reply submits itself one line at
a time whatever is reading, while `session paste` is the only bracketed-paste path agterm exposes
and it reads the system clipboard. Measured against a pty with DECSET 2004 on: type produced bare
lines, paste produced one `^[[200~...^[[201~` block, so the reply lands whole and unsent. 2004 is
the PROGRAM's mode, not a property of the route: against one with it off the newlines submit, the
same as any manual paste. There is no way to ask over the control API which it is.

`session paste` takes no --pane and always runs on the session's main surface, so from a split's
right pane or the scratch it would deliver to the wrong prompt. Those panes keep the notes on the
clipboard and say so instead.

Usage: annotate-pane.py [--print]
    --print  write the reply to stdout instead of pasting it, for checking the formatting
"""

from __future__ import annotations

import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# how much of the pane to offer when nothing is selected. `session text --lines N` reads the whole
# screen buffer, scrollback included, so raising this reaches back past the visible pane
CAPTURE_LINES = 50

# a floating panel rather than the full pane, so the session it asks about stays visible behind it,
# tinted dark enough that revdiff's syntax colors still read against it
OVERLAY_PERCENT = 80
OVERLAY_TINT = "#3a2c1e"

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
    """Resolve revdiff absolutely: a custom command gets the app's PATH, not a shell's.

    Nothing a profile adds is on it, so a revdiff installed anywhere but Homebrew's prefix or
    `go install`'s needs REVDIFF set to its full path.
    """
    for candidate in (os.environ.get("REVDIFF") or "", shutil.which("revdiff") or "",
                      "/opt/homebrew/bin/revdiff", str(Path.home() / "go/bin/revdiff")):
        if candidate and os.access(candidate, os.X_OK):
            return candidate
    return ""


def find_agtermctl() -> str:
    """Resolve the CLI, falling back to the install target when the bare name does not resolve.

    Before 0.22.0 a custom command ran with launchd's bare `/usr/bin:/bin:/usr/sbin:/sbin`, which
    does not contain the `/usr/local/bin` that Help > Install Command Line Tool writes to, so a bare
    `agtermctl` exited 127 before anything happened. From 0.22.0 the app widens PATH and the lookup
    above succeeds. Returning the bare name last keeps the failure legible rather than silent.
    """
    for candidate in (os.environ.get("AGTERMCTL") or "", shutil.which("agtermctl") or "",
                      "/usr/local/bin/agtermctl"):
        if candidate and os.access(candidate, os.X_OK):
            return candidate
    return "agtermctl"


AGTERMCTL = find_agtermctl()


def cli_error(res: subprocess.CompletedProcess[str]) -> str:
    """Pull agtermctl's own sentence out of a failed call, falling back to the exit status."""
    for stream in (res.stderr, res.stdout):
        line = (stream or "").strip().splitlines()
        if line:
            return line[-1]
    return f"agtermctl exited {res.returncode}"


def copy_clipboard(text: str) -> None:
    """Put text on the system clipboard, which is what `session paste` reads."""
    subprocess.run(["pbcopy"], input=text, text=True, check=False)


class Agt:
    """The agterm control channel: agtermctl plus this session's addressing."""

    def __init__(self) -> None:
        self.socket = os.environ.get("AGT_SOCKET") or ""
        self.sid = os.environ.get("AGT_SESSION_ID") or ""
        self.pane = os.environ.get("AGT_PANE") or ""

    def run(self, *args: str) -> subprocess.CompletedProcess[str]:
        """Invoke agtermctl against the instance the chord came from, never raising on a nonzero exit.

        An unresolvable binary is turned into a 127 rather than a FileNotFoundError: the traceback
        would go to a stdout the runner pins to /dev/null, and the chord would appear to do nothing.
        """
        cmd = [AGTERMCTL, *args]
        if self.socket:
            cmd += ["--socket", self.socket]
        try:
            return subprocess.run(cmd, capture_output=True, text=True, check=False)
        except OSError as err:
            return subprocess.CompletedProcess(cmd, 127, "", f"{AGTERMCTL}: {err}")

    def notify(self, message: str) -> None:
        """Post a desktop banner, the one channel a keybinding has when it cannot paste."""
        self.run("notify", message, "--title", "annotate")

    def pane_text(self) -> tuple[str, str]:
        """Read the pane the chord fired from, returning (text, error). A blank pane is not an error.

        --pane is passed explicitly because the pane the chord fired from and the focused pane can
        differ: a chord pressed in a split's right half while focus sits left would otherwise capture
        the wrong side. The error is kept apart from an empty read so a refused call is not
        diagnosed as an empty screen.
        """
        args = ["session", "text", "--target", self.sid, "--lines", str(CAPTURE_LINES)]
        if self.pane in ("left", "right", "scratch"):
            args += ["--pane", self.pane]
        res = self.run(*args)
        if res.returncode != 0:
            return "", cli_error(res)
        return res.stdout, ""

    def review(self, revdiff: str, src: Path, out: Path) -> tuple[int, str]:
        """Open revdiff over this session and block, returning (exit status, agtermctl error).

        10 means annotations were written, 0 that the review was quit without any. A nonzero status
        is ambiguous on its own: agtermctl can refuse before revdiff ever runs, "overlay already
        open" being the one a second press produces, so its own message is carried out with it.
        """
        # the overlay runs this string through a shell, so a REVDIFF path with a space in it would
        # otherwise split into two words
        command = (f"{shlex.quote(revdiff)} --only={shlex.quote(str(src))} -o {shlex.quote(str(out))}"
                   " --exit-code-on-annotations --wrap")
        res = self.run("session", "overlay", "open", command, "--block",
                       "--size-percent", str(OVERLAY_PERCENT),
                       "--background-color", OVERLAY_TINT,
                       "--target", self.sid)
        return res.returncode, cli_error(res)

    def deliver(self, text: str) -> str:
        """Put the notes where the chord came from, returning "" on success or what went wrong.

        Only the main pane can be pasted into: `session paste` takes no --pane and runs on the
        session's main surface, so pasting from a split's right pane or the scratch would drop the
        notes at another prompt. Those panes keep the text on the clipboard for a manual paste,
        which is why the restore below is skipped for them.
        """
        if self.pane in ("right", "scratch"):
            copy_clipboard(text)
            self.notify(f"notes copied to the clipboard - paste them into the {self.pane} pane")
            return ""
        saved = subprocess.run(["pbpaste"], capture_output=True, text=True, check=False).stdout
        try:
            copy_clipboard(text)
            res = self.run("session", "paste", "--target", self.sid)
            return "" if res.returncode == 0 else cli_error(res)
        finally:
            copy_clipboard(saved)


def captured(selection: str, pane: str) -> str:
    """Pick what gets reviewed: the selection when there is one, else the pane text.

    Whitespace does not count as a selection - a stray drag leaves one, and reviewing it would show
    an empty buffer instead of the screen you meant.

    The pane's trailing newline is dropped so revdiff does not open on an empty last line; `--lines`
    has already trimmed blank grid rows server-side. Newlines ONLY - a bare rstrip would eat trailing
    spaces off the last line of a prompt or an ASCII layout, changing what is annotated. A selection
    is taken exactly as made, and leading blanks stay: dropping them would shift every line number a
    note comes back with.
    """
    if selection.strip():
        return selection
    return "\n".join(pane.splitlines()).rstrip("\n")


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

    selection = os.environ.get("AGT_SELECTION") or ""
    pane, err = agt.pane_text()
    if err and not selection.strip():
        fail(f"could not read the pane: {err}", agt)
    text = captured(selection, pane)
    if not text.strip():
        fail("nothing to annotate: no selection and the pane read empty", agt)

    room = Path(tempfile.mkdtemp(prefix="agterm-annotate-"))
    src, out = room / "session.txt", room / "notes.md"
    src.write_text(text)
    try:
        code, err = agt.review(revdiff, src, out)
        if code not in (0, 10):
            fail(err or f"revdiff exited {code}", agt)
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
    if failure := agt.deliver(reply):
        fail(f"could not deliver the notes: {failure}", agt)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(130)
