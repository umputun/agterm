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

A session attached from another Mac (`zmx attach`, File > Attach Remote...) runs its programs on
that Mac, so Claude's transcript, the Stop hook's record of it and Claude itself are all there. For
such a pane the replies chord runs the viewer on the other Mac over ssh, inside the overlay here,
and this script asks its copy there three things through the modes below. The recipe must be
installed on both Macs at the same path under the home directory (or AGTERM_ANNOTATE_REMOTE names
the path there):

    annotate.py locate DAEMON         which session and pane run in that zmx daemon, as JSON
    annotate.py serve SESSION PANE    the viewer for that pane's newest reply, on this terminal
    annotate.py take SESSION PANE     the last send of that viewer, and whether to submit it

Runs as an agterm custom command: the runner exports AGT_SESSION_ID, AGT_PANE, AGT_SELECTION,
AGT_SESSION_HOST and AGT_SOCKET, keeps stdout on /dev/null and starts it with the app's PATH, so
progress goes to LOG and every binary is resolved to an absolute path. Needs Python 3.9 or later,
standard library only.
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

# An attached pane runs `ssh ... zmx attach agterm-<32 hex>` here; that daemon name is the one key
# the other Mac's `zmx tree` shares with this one.
DAEMON = re.compile(r"\bagterm-[0-9a-f]{32}\b")
SESSION_ID = re.compile(r"^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$")
# The same flags agterm gives its own attach: a password or host-key prompt is a failure, never a
# question nobody can see.
SSH_OPTIONS = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "LogLevel=ERROR"]


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

SSH = first_executable(os.environ.get("AGTERM_ANNOTATE_SSH") or "", "/usr/bin/ssh") or "ssh"


def remote_script():
    """This script's path on the other Mac, as a word its login shell expands: sh and fish alike.

    `$HOME/'rel/path'` is one word in both, so the copy there is found under its own home even when
    the two accounts differ. AGTERM_ANNOTATE_REMOTE overrides it with a path used as given.
    """
    override = os.environ.get("AGTERM_ANNOTATE_REMOTE") or ""
    if override:
        return shlex.quote(override)
    here = Path(os.path.realpath(__file__))
    try:
        return "$HOME/" + shlex.quote(str(here.relative_to(Path.home())))
    except ValueError:
        return shlex.quote(str(here))


class Agt:
    """agtermctl against the instance and session the chord came from."""

    def __init__(self, sid=None, pane=None, socket=None):
        self.socket = (os.environ.get("AGT_SOCKET") or "") if socket is None else socket
        self.sid = (os.environ.get("AGT_SESSION_ID") or "") if sid is None else sid
        self.pane = (os.environ.get("AGT_PANE") or "left") if pane is None else pane

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


def viewer_env(label, foreground, outbox):
    """What every viewer gets, here or on the other Mac."""
    return {
        "HERDR_ENV": "1",
        "HERDR_BIN_PATH": str(HOST),
        "PLANNOTATOR_TUI_DELIVER_TO": label,
        "PLANNOTATOR_TUI_DELIVER_AGENT": os.path.basename(foreground[0]) if foreground else "",
        # The overlay is tinted dark. Naming the theme skips the startup query to the terminal,
        # which swallows a key typed into its window.
        "PLANNOTATOR_TUI_THEME": "dark",
        "AGT_ANNOTATE_OUTBOX": str(outbox),
        # A pane whose agent has exited holds a shell, which would read every quoted "> " line
        # of the notes as a redirect. The host script refuses the send, and the TUI says so and keeps
        # the notes.
        "AGT_ANNOTATE_REFUSE": f"nothing is running in the {label}" if foreground == [] else "",
    }


def replies_env(transcript):
    return {
        "PLANNOTATOR_TUI_HOST": "claude",
        "PLANNOTATOR_TUI_SESSION": transcript,
        "PLANNOTATOR_TUI_NEWEST": "1",
    }


def last_send(outbox):
    """The last send in an outbox, None when the viewer sent nothing, and how many sends it held.

    A review of a pane or a reply resends every note it holds each time, so the last send is the
    whole review; pasting them all would repeat the early notes once per later send.
    """
    try:
        lines = outbox.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return None, 0
    sends = [json.loads(line) for line in lines if line.strip()]
    return (sends[-1] if sends else None), len(sends)


# ---------- a session attached from another Mac ----------


class RemoteError(Exception):
    pass


class Remote:
    """The pane's session as it runs on the Mac it was attached from."""

    def __init__(self, host, session, pane, foreground, transcript):
        self.host, self.session, self.pane = host, session, pane
        self.foreground, self.transcript = foreground, transcript

    @staticmethod
    def ssh_argv(host, words, tty=False):
        return [SSH, *SSH_OPTIONS, *(["-tt"] if tty else []), "--", host, " ".join([remote_script(), *words])]

    @classmethod
    def call(cls, host, *words):
        cmd = cls.ssh_argv(host, words)
        try:
            res = subprocess.run(cmd, capture_output=True, text=True, check=False, timeout=30)
        except (OSError, subprocess.TimeoutExpired) as err:
            raise RemoteError(f"could not reach {host}: {err}") from err
        said = (res.stderr or "").strip()
        if res.returncode == 255:
            raise RemoteError(f"could not reach {host}: {said or 'ssh exited 255'}")
        if res.returncode != 0:
            raise RemoteError(f"annotate.py on {host} failed (exit {res.returncode}): {said or res.stdout.strip()}"
                              " - is the same version of the recipe installed there?")
        try:
            return json.loads(res.stdout)
        except ValueError as err:
            raise RemoteError(f"annotate.py on {host} answered no JSON: {res.stdout.strip()[:200]}") from err

    @classmethod
    def of(cls, agt, host):
        """The remote session behind this pane, or None when the pane runs here (a local split, the scratch)."""
        if host.startswith("-"):
            raise RemoteError(f"refusing an ssh destination that reads as an option: {host}")
        found = DAEMON.search(" ".join(agt.foreground() or []))
        if not found:
            return None
        answer = cls.call(host, "locate", found.group(0))
        session, pane = answer.get("session") or "", answer.get("pane") or ""
        if not SESSION_ID.match(session) or pane not in ("left", "right"):
            raise RemoteError(f"{host} runs no session in {found.group(0)}")
        return cls(host, session, pane, answer.get("foreground"), answer.get("transcript") or "")

    def viewer_command(self):
        return shlex.join(self.ssh_argv(self.host, ["serve", self.session, self.pane], tty=True))

    def take(self):
        return self.call(self.host, "take", self.session, self.pane)


def remote_room(session, pane):
    # Not the room a chord pressed on that Mac uses for the same pane: the two can run at once.
    return TMP / "agterm-annotate" / f"remote-{session}.{pane}"


def checked(session, pane):
    if not SESSION_ID.match(session) or pane not in ("left", "right"):
        raise SystemExit(f"not a session and pane: {session} {pane}")
    return Agt(sid=session, pane=pane, socket="")


def locate(daemon):
    """Run on the Mac a session runs on: which session and pane own the zmx daemon, as JSON."""
    if not DAEMON.fullmatch(daemon):
        raise SystemExit(f"not a daemon name: {daemon}")
    res = Agt(sid="", socket="").run("zmx", "tree", "--json")
    if res.returncode != 0:
        raise SystemExit("agtermctl zmx tree failed: " + (res.stderr or res.stdout).strip())
    remote = json.loads(res.stdout)["result"]["remote"]
    for node in remote.get("sessions", []) if isinstance(remote, dict) else remote:
        for pane in node.get("panes", []):
            if pane.get("daemon") == daemon and pane.get("pane") in ("left", "right"):
                agt = Agt(sid=node["id"], pane=pane["pane"], socket="")
                print(json.dumps({"session": agt.sid, "pane": agt.pane, "foreground": agt.foreground(),
                                  "transcript": transcript_for(agt)}))
                return 0
    print(json.dumps({}))
    return 0


def serve(session, pane):
    """Run on the Mac a session runs on, under the ssh terminal of the overlay on the other one."""
    agt = checked(session, pane)
    transcript = transcript_for(agt)
    if not transcript or not PLANNOTATOR_TUI:
        print("No Claude transcript on record for this pane." if PLANNOTATOR_TUI else "plannotator-tui is not installed here.")
        time.sleep(3)
        return 1
    room = remote_room(session, pane)
    room.mkdir(parents=True, exist_ok=True)
    outbox = room / "outbox.jsonl"
    outbox.unlink(missing_ok=True)
    env = {**os.environ, **viewer_env(f"{pane} pane", agt.foreground(), outbox), **replies_env(transcript)}
    log(f"--- serve session={session} pane={pane}")
    os.execve(PLANNOTATOR_TUI, [PLANNOTATOR_TUI, "herdr", "pane"], env)
    return 1


def take(session, pane):
    """Run on the Mac a session runs on: the viewer's last send, and whether Claude still runs there."""
    agt = checked(session, pane)
    outbox = remote_room(session, pane) / "outbox.jsonl"
    notes, sends = last_send(outbox)
    outbox.unlink(missing_ok=True)
    submit = notes is not None and SUBMIT["replies"] and runs_claude(agt.foreground())
    print(json.dumps({"notes": notes, "sends": sends, "submit": submit}))
    return 0


REMOTE_MODES = {"locate": (locate, 1), "serve": (serve, 2), "take": (take, 2)}


# ---------- the chords ----------


def main(argv):
    mode = argv[0] if argv else ""
    if mode in REMOTE_MODES:
        handler, count = REMOTE_MODES[mode]
        if len(argv) != count + 1:
            raise SystemExit(f"usage: annotate.py {mode} with {count} argument(s)")
        return handler(*argv[1:])
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
    # A viewer that outlived its script, after a SIGTERM or a SIGKILL and a removed lock, can still
    # write the outbox. Read as this review's send, it would paste old notes, and the replies chord
    # would submit them.
    for leftover in ("capture.txt", "outbox.jsonl"):
        (room / leftover).unlink(missing_ok=True)
    # SIGTERM unwinds through the finally below, so the lock goes with the script.
    signal.signal(signal.SIGTERM, lambda signum, _frame: sys.exit(128 + signum))
    try:
        return review(agt, mode, room)
    finally:
        for leftover in ("capture.txt", "outbox.jsonl"):
            (room / leftover).unlink(missing_ok=True)
        lock.rmdir()


def review(agt, mode, room):
    host = os.environ.get("AGT_SESSION_HOST") or ""
    try:
        remote = Remote.of(agt, host) if host else None
    except RemoteError as err:
        return fail(agt, str(err))
    # The agent of an attached pane runs on the other Mac; here the pane only runs the ssh to it.
    foreground = remote.foreground if remote else agt.foreground()
    label = f"{agt.pane} pane"
    outbox = room / "outbox.jsonl"
    env = viewer_env(label, foreground, outbox)
    if mode == "pane":
        # What the pane printed is on this Mac's screen too, so a pane review stays here.
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
    elif remote:
        if not remote.transcript:
            log(f"no transcript on record for this pane on {host}")
            agt.notify(f"This pane has no Claude transcript on record on {host} yet. It registers when Claude finishes a reply.")
            return 0
    else:
        transcript = transcript_for(agt)
        if not transcript:
            log("no transcript on record for this pane")
            agt.notify("This pane has no Claude transcript on record yet. It registers when Claude finishes a reply.")
            return 0
        env.update(replies_env(transcript))

    if mode == "replies" and remote:
        command = remote.viewer_command()
    else:
        assignments = " ".join(f"{key}={shlex.quote(value)}" for key, value in env.items())
        command = f"env {assignments} {shlex.quote(PLANNOTATOR_TUI)} herdr pane"
    res = agt.run(
        "session", "overlay", "open", command, "--block",
        "--size-percent", str(OVERLAY_PERCENT),
        "--background-color", OVERLAY_TINT,
        "--target", agt.sid,
    )
    log(f"viewer exit={res.returncode} {(res.stderr or res.stdout).strip()}")
    said = (res.stderr or res.stdout).strip()
    if res.returncode != 0:
        if "overlay already open" in said:
            return fail(agt, "This session already has an overlay open. Close it, then press the chord again.")
        if "not realized" in said or "no such session" in said:
            return fail(agt, "This session is not on screen yet. Visit it once, then press the chord again.")

    if mode == "replies" and remote:
        if res.returncode == 255:
            return fail(agt, f"The viewer could not reach {host} (ssh exit 255). See {LOG}.")
        try:
            taken = remote.take()
        except RemoteError as err:
            return fail(agt, str(err))
        notes, sends = taken.get("notes"), taken.get("sends") or 0
        # Read again on that Mac after the viewer closed: Claude may have exited meanwhile.
        submit = bool(taken.get("submit"))
    else:
        # ⌘W on the overlay kills the viewer before it reports anything; that is a dismissal.
        if res.returncode != 0 and not outbox.exists() and "no overlay result" not in said:
            return fail(agt, f"The viewer did not run (exit {res.returncode}). See {LOG}.")
        notes, sends = last_send(outbox)
        # Read again: the viewer can stay open for minutes, and Claude may have exited meanwhile. A
        # Return sent to the shell left behind would run the notes, and their quoted "> " lines would
        # truncate files.
        submit = notes is not None and SUBMIT[mode] and runs_claude(agt.foreground())

    if notes is None:
        log("closed without sending")
        return 0
    CACHE.mkdir(parents=True, exist_ok=True)
    # A blind paste can be swallowed when the agent's focus is elsewhere; keep a recovery copy.
    (CACHE / "last-notes.md").write_text(notes, encoding="utf-8")
    # An attached pane takes the paste here and its ssh carries it to the other Mac.
    failure = deliver(agt, notes, submit)
    if failure:
        return fail(agt, f"Could not paste the notes ({failure}). They are in {CACHE / 'last-notes.md'}.")
    if SUBMIT[mode] and not submit:
        agt.notify(f"Could not confirm Claude runs in the {label}, so the notes were pasted unsent.")
    log(f"delivered {sends} send(s), {len(notes)} chars, submit={submit}" + (f", from {host}" if remote else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
