#!/usr/bin/env python3
"""Annotate a pane's output or Claude's newest reply in plannotator-tui, then hand the notes back.

Bound to two chords in ~/.config/agterm/keymap.conf:

    annotate.py pane      the selection when there is one, else the pane's last LINES lines
    annotate.py replies   Claude's newest reply in this pane; `p` in the viewer picks an older one

Scrolling back, selecting old output and pressing the pane chord is how anything far up the
scrollback gets annotated: the selection is reviewed exactly as made.

Herdr does not need to be installed. plannotator-tui's only route from its Send key to an agent's
prompt is the one it built for the Herdr multiplexer: it runs `$HERDR_BIN_PATH agent prompt ...`.
So this starts the viewer's pane entrypoint (`plannotator-tui herdr pane`) in a blocking agterm
overlay with HERDR_BIN_PATH pointing at plannotator-host.py beside this file, which answers those
calls for agterm. The viewer's Send (`E`, or `S` to send and close) lands in the host script's
outbox, and once the overlay closes this script pastes the last send into the pane the chord came
from. Pane notes arrive unsent, so they can be edited first; reply notes are submitted, but only
while Claude still runs in that pane.

Runs as an agterm custom command: the runner exports AGT_SESSION_ID, AGT_PANE, AGT_SELECTION and
AGT_SOCKET, keeps stdout on /dev/null and starts it with the app's PATH, so progress goes to LOG
and every binary is resolved to an absolute path. Needs Python 3.9 or later, standard library only.
"""

import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

# Lines read from the pane when nothing is selected. The viewer opens a capture at its top and `G`
# does not reach the end of it, so a long one puts the newest output out of sight; a selection is
# the way to reach further back.
LINES = int(os.environ.get("AGTERM_ANNOTATE_LINES") or 50)
# Whether the notes are submitted after the paste, per chord.
SUBMIT = {"pane": False, "replies": True}
# A panel over the session rather than the full pane, so what it asks about stays visible behind
# it, tinted dark enough for the viewer's colors to read.
OVERLAY_PERCENT = 80
OVERLAY_TINT = "#3a2c1e"
# `session paste` returns once agterm has run the paste, while the agent is still reading the
# bytes; a Return sent at once can submit half of a long paste.
SETTLE_SECONDS = 0.4
# Reply notes are submitted only when an argv element of the pane's foreground matches this, the
# same test agent-reset uses. Anything else, a shell left after Claude exited included, gets them
# pasted unsent. Override it for a wrapper launcher, e.g. CLAUDE_FG_MATCH='(^|/)(claude|mywrapper)$'.
CLAUDE_FG_MATCH = re.compile(os.environ.get("CLAUDE_FG_MATCH") or r"(^|/)claude$")

HERE = Path(os.path.realpath(__file__)).parent
HOST = HERE / "plannotator-host.py"
CACHE = Path(os.environ.get("AGTERM_ANNOTATE_DIR") or Path.home() / ".cache" / "agterm-annotate")
TMP = Path(os.environ.get("TMPDIR") or "/tmp")
LOG = Path(os.environ.get("AGTERM_ANNOTATE_LOG") or TMP / "agterm-annotate.log")


def log(message):
    try:
        with LOG.open("a", encoding="utf-8") as fh:
            fh.write(f"{time.strftime('%F %T')}  {message}\n")
    except OSError:
        pass


def first_executable(*candidates):
    for candidate in candidates:
        if candidate and os.access(candidate, os.X_OK):
            return candidate
    return ""


AGTERMCTL = first_executable(
    os.environ.get("AGTERMCTL") or "",
    shutil.which("agtermctl") or "",
    "/usr/local/bin/agtermctl",
    "/opt/homebrew/bin/agtermctl",
    "/Applications/agterm.app/Contents/MacOS/agtermctl",
) or "agtermctl"

PLANNOTATOR_TUI = first_executable(
    os.environ.get("PLANNOTATOR_TUI") or "",
    shutil.which("plannotator-tui") or "",
    "/opt/homebrew/bin/plannotator-tui",
    "/usr/local/bin/plannotator-tui",
    str(Path.home() / ".cargo/bin/plannotator-tui"),
)


class Agt:
    """agtermctl against the instance and session the chord came from."""

    def __init__(self):
        self.socket = os.environ.get("AGT_SOCKET") or ""
        self.sid = os.environ.get("AGT_SESSION_ID") or ""
        self.pane = os.environ.get("AGT_PANE") or "left"

    def run(self, *args, stdin=None):
        cmd = [AGTERMCTL, *args]
        if self.socket:
            cmd += ["--socket", self.socket]
        try:
            return subprocess.run(cmd, input=stdin, capture_output=True, text=True, check=False)
        except OSError as err:
            return subprocess.CompletedProcess(cmd, 127, "", f"{AGTERMCTL}: {err}")

    def notify(self, message):
        self.run("notify", message, "--title", "Annotate", "--target", self.sid)

    def foreground(self):
        """The argv running in this pane: a list, [] when a shell holds it, None when unknown.

        No read-back exposes a scratch pane's foreground, so it is unknown and treated as live, as
        is a pane whose process macOS will not show (agterm then omits both fields).
        """
        key = {"left": "foreground", "right": "splitForeground"}.get(self.pane)
        res = self.run("tree", "--json")
        if key is None or res.returncode != 0:
            return None
        try:
            tree = json.loads(res.stdout)["result"]["tree"]
        except (ValueError, KeyError):
            return None
        for workspace in tree.get("workspaces", []):
            for node in workspace.get("sessions", []):
                if node.get("id") != self.sid:
                    continue
                if node.get(key):
                    return node[key]
                return [] if node.get(key + "Shell") else None
        return None


def runs_claude(foreground):
    """Whether the foreground argv is Claude Code; an unknown foreground (None) is not."""
    return bool(foreground) and any(CLAUDE_FG_MATCH.search(arg) for arg in foreground)


def fail(agt, message):
    log(message)
    agt.notify(message)
    return 1


def capture_pane(agt, room):
    """Write the selection, else the pane's last LINES lines, to a file; "" when there is nothing."""
    selection = os.environ.get("AGT_SELECTION") or ""
    if selection.strip():
        text = selection
    else:
        res = agt.run("session", "text", "--target", agt.sid, "--pane", agt.pane, "--lines", str(LINES))
        if res.returncode != 0:
            raise RuntimeError("could not read the pane: " + (res.stderr or res.stdout).strip())
        text = res.stdout
    if not text.strip():
        return ""
    path = room / "capture.txt"
    path.write_text(text, encoding="utf-8")
    return str(path)


def transcript_for(agt):
    """The Claude transcript the Stop hook (save-transcript-path.py) recorded for this pane."""
    pointer = CACHE / f"{agt.sid}.{agt.pane}.json"
    try:
        path = json.loads(pointer.read_text(encoding="utf-8")).get("transcript_path") or ""
    except (OSError, ValueError):
        return ""
    return path if os.path.isfile(path) else ""


def deliver(agt, text, submit):
    """Paste through the clipboard, the one bracketed-paste route agterm has, and put it back."""
    held = subprocess.run(["pbpaste"], capture_output=True, text=True, check=False).stdout
    try:
        subprocess.run(["pbcopy"], input=text, text=True, check=True)
        res = agt.run("session", "paste", "--target", agt.sid, "--pane", agt.pane)
    finally:
        subprocess.run(["pbcopy"], input=held, text=True, check=False)
    if res.returncode != 0:
        return (res.stderr or res.stdout).strip() or f"agtermctl exited {res.returncode}"
    if submit:
        time.sleep(SETTLE_SECONDS)
        agt.run("session", "type", "--stdin", "--target", agt.sid, "--pane", agt.pane, stdin="\n")
    return ""


def main(argv):
    mode = argv[0] if argv else ""
    agt = Agt()
    log(f"--- mode={mode} session={agt.sid} pane={agt.pane}")
    if mode not in SUBMIT:
        return fail(agt, "usage: annotate.py pane|replies")
    if not agt.sid:
        return fail(agt, "no AGT_SESSION_ID: run this as an agterm custom command")
    if not PLANNOTATOR_TUI:
        return fail(agt, "plannotator-tui is not installed: brew install plannotator/tap/plannotator-tui")

    room = TMP / "agterm-annotate" / f"{agt.sid}.{agt.pane}"
    room.mkdir(parents=True, exist_ok=True)
    lock = room / "lock"
    try:
        # One review per pane: a second press while the viewer is open is dropped.
        lock.mkdir()
    except FileExistsError:
        log(f"already open for this pane: {lock}")
        # A viewer killed with SIGKILL leaves the lock behind, and then every press lands here.
        agt.notify(f"An annotate viewer is already open for this pane. If none is, remove {lock}.")
        return 0
    # SIGTERM unwinds through the finally below, so the lock goes with the script.
    signal.signal(signal.SIGTERM, lambda signum, _frame: sys.exit(128 + signum))
    try:
        return review(agt, mode, room)
    finally:
        for leftover in ("capture.txt", "outbox.jsonl"):
            (room / leftover).unlink(missing_ok=True)
        lock.rmdir()


def review(agt, mode, room):
    foreground = agt.foreground()
    agent = os.path.basename(foreground[0]) if foreground else ""
    label = f"{agt.pane} pane"
    outbox = room / "outbox.jsonl"
    env = {
        "HERDR_ENV": "1",
        "HERDR_BIN_PATH": str(HOST),
        "PLANNOTATOR_TUI_DELIVER_TO": label,
        "PLANNOTATOR_TUI_DELIVER_AGENT": agent,
        # The overlay is tinted dark. Naming the theme skips the startup query to the terminal,
        # which swallows a key typed into its window.
        "PLANNOTATOR_TUI_THEME": "dark",
        "AGT_ANNOTATE_OUTBOX": str(outbox),
        # A pane whose agent has exited holds a shell, which would read every quoted "> " line
        # of the notes as a redirect. The host script refuses the send, and the TUI says so and keeps
        # the notes.
        "AGT_ANNOTATE_REFUSE": f"nothing is running in the {label}" if foreground == [] else "",
    }
    if mode == "pane":
        try:
            capture = capture_pane(agt, room)
        except RuntimeError as err:
            return fail(agt, str(err))
        if not capture:
            return fail(agt, "nothing to annotate: no selection and the pane read empty")
        env.update({
            "AGT_ANNOTATE_CAPTURE": capture,
            "PLANNOTATOR_TUI_TERMINAL_PANE": label,
            "PLANNOTATOR_TUI_TERMINAL_LINES": str(LINES),
        })
    else:
        transcript = transcript_for(agt)
        if not transcript:
            log("no transcript on record for this pane")
            agt.notify("This pane has no Claude transcript on record yet. It registers when Claude finishes a reply.")
            return 0
        env.update({
            "PLANNOTATOR_TUI_HOST": "claude",
            "PLANNOTATOR_TUI_SESSION": transcript,
            "PLANNOTATOR_TUI_NEWEST": "1",
        })

    assignments = " ".join(f"{key}={shlex.quote(value)}" for key, value in env.items())
    command = f"env {assignments} {shlex.quote(PLANNOTATOR_TUI)} herdr pane"
    res = agt.run(
        "session", "overlay", "open", command, "--block",
        "--size-percent", str(OVERLAY_PERCENT),
        "--background-color", OVERLAY_TINT,
        "--target", agt.sid,
    )
    log(f"viewer exit={res.returncode} {(res.stderr or res.stdout).strip()}")
    if res.returncode != 0:
        said = (res.stderr or res.stdout).strip()
        if "overlay already open" in said:
            return fail(agt, "This session already has an overlay open. Close it, then press the chord again.")
        if "not realized" in said or "no such session" in said:
            return fail(agt, "This session is not on screen yet. Visit it once, then press the chord again.")
        # ⌘W on the overlay kills the viewer before it reports anything; that is a dismissal.
        if not outbox.exists() and "no overlay result" not in said:
            return fail(agt, f"The viewer did not run (exit {res.returncode}). See {LOG}.")

    if not outbox.exists():
        log("closed without sending")
        return 0
    sends = [json.loads(line) for line in outbox.read_text(encoding="utf-8").splitlines() if line.strip()]
    # A review of a pane or a reply resends every note it holds each time, so the last send is the
    # whole review; pasting them all would repeat the early notes once per later send.
    notes = sends[-1]
    CACHE.mkdir(parents=True, exist_ok=True)
    # A blind paste can be swallowed when the agent's focus is elsewhere; keep a recovery copy.
    (CACHE / "last-notes.md").write_text(notes, encoding="utf-8")
    # Read again: the viewer can stay open for minutes, and Claude may have exited meanwhile. A
    # Return sent to the shell left behind would run the notes, and their quoted "> " lines would
    # truncate files.
    submit = SUBMIT[mode] and runs_claude(agt.foreground())
    failure = deliver(agt, notes, submit)
    if failure:
        return fail(agt, f"Could not paste the notes ({failure}). They are in {CACHE / 'last-notes.md'}.")
    if SUBMIT[mode] and not submit:
        agt.notify(f"Claude is not running in the {label}, so the notes were pasted unsent.")
    log(f"delivered {len(sends)} send(s), {len(notes)} chars, submit={submit}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
