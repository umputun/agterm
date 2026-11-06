#!/usr/bin/env python3
"""Let two agents in one agterm split talk through agterm's pane mailboxes.

`say` puts a message into the other pane's mailbox. A Claude Code receiver picks it up through an
asyncRewake hook (`claude-hook`). A Codex receiver is registered by its SessionStart hook
(`codex-hook`), and agterm's `on message` hook (`agterm-hook`) hands its mail to that thread with
`codex queue`. Nothing is typed into either composer.
"""

from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import fcntl
import json
import os
import stat
import subprocess
import sys
import tempfile
import time
from typing import Any

AGTERMCTL = os.environ.get("AGTERMCTL") or "agtermctl"
STATE_DIR = os.path.join(tempfile.gettempdir(), f"agterm-mailbox-chat-{os.getuid()}")
BODY_LIMIT = 64 * 1024
LABEL = "[peer chat]"
REPLY_LINE = "If you answer, use mailbox-chat.py say; do not reply only to acknowledge."
WAIT_ROUND_SECONDS = 30
WAKE = 2
# codex global options that take a value, skipped to find its subcommand
CODEX_VALUE_FLAGS = frozenset({"-c", "--config", "--enable", "--disable", "--remote", "--remote-auth-token-env",
                               "-i", "--image", "-m", "--model", "--local-provider", "-p", "--profile",
                               "-s", "--sandbox", "-C", "--cd", "--add-dir", "-a", "--ask-for-approval"})


class ChatError(RuntimeError):
    """a refusal or failure reported to the caller as {"error": ...}."""


def run(args: list[str], timeout: float = 30, stdin: str | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(args, input=stdin, capture_output=True, text=True, timeout=timeout, check=False)


def ctl_args(*args: str) -> list[str]:
    cmd = [AGTERMCTL, *args]
    socket = os.environ.get("AGTERM_SOCKET", "")
    if socket:
        cmd += ["--socket", socket]
    return cmd


def agtermctl(*args: str, stdin: str | None = None) -> Any:
    res = run(ctl_args(*args), stdin=stdin)
    if res.returncode != 0:
        raise ChatError("agtermctl {} failed: {}".format(" ".join(args[:2]), (res.stderr or res.stdout).strip()))
    return json.loads(res.stdout) if "--json" in args else res.stdout


def state_path(name: str) -> str:
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    return os.path.join(STATE_DIR, name)


def read_json(path: str) -> dict[str, Any] | None:
    try:
        with open(path, encoding="utf-8") as f:
            value = json.load(f)
    except (OSError, ValueError):
        return None
    return value if isinstance(value, dict) else None


def write_json(path: str, value: dict[str, Any]) -> None:
    # atomic replace: hooks in both panes read these files while they are rewritten
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp-")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(value, f)
    os.replace(tmp, path)


def remove(path: str) -> None:
    try:
        os.remove(path)
    except FileNotFoundError:
        pass


def pid_alive(pid: Any) -> bool:
    if not isinstance(pid, int) or pid <= 1:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def render(message: dict[str, Any]) -> str:
    """the text an agent receives: chat mail as sent, any other mail marked with its bus sender."""
    body = str(message.get("body", "")).rstrip()
    if body.startswith(LABEL):
        return body
    return "[agterm mailbox, not a peer chat message] from {}:\n{}".format(
        message.get("from") or "outside agterm", body)


def compose(text: str) -> str:
    body = text.strip()
    if body.startswith(LABEL):
        body = body[len(LABEL):].lstrip()
    if body.endswith(REPLY_LINE):
        body = body[:-len(REPLY_LINE)].rstrip()
    if not body:
        raise ChatError("message is empty")
    message = f"{LABEL} {body}\n\n{REPLY_LINE}"
    size = len(message.encode("utf-8"))
    if size > BODY_LIMIT:
        raise ChatError(f"message is {size} bytes, over agterm's {BODY_LIMIT}-byte limit; put the long part in a file "
                        "and name its path")
    return message


def read_message_file(path: str) -> str:
    """the message text in `path`, which must be a regular file within agterm's body limit."""
    # codex's allow rule runs this outside its sandbox, so a fifo or device path must neither block nor flood it
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise ChatError(f"{path} is not a regular file")
    with os.fdopen(fd, "rb") as f:
        data = f.read(BODY_LIMIT + 1)
    if len(data) > BODY_LIMIT:
        raise ChatError(f"{path} is over agterm's {BODY_LIMIT}-byte limit; put the long part in another file "
                        "and name its path")
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        raise ChatError(f"{path} is not utf-8 text") from None


def find_node(tree: Any, sid: str) -> dict[str, Any] | None:
    if isinstance(tree, dict):
        if tree.get("id") == sid and "surfaces" in tree:
            return tree
        children: Any = tree.values()
    elif isinstance(tree, list):
        children = tree
    else:
        return None
    for child in children:
        hit = find_node(child, sid)
        if hit is not None:
            return hit
    return None


def session_node(sid: str) -> dict[str, Any] | None:
    """the tree node of session `sid` in whichever open window holds it."""
    # tree reads one window, the frontmost unless named, and the session may have moved since launch
    window = os.environ.get("AGTERM_WINDOW_ID", "")
    node = find_node(agtermctl("tree", "--json", *(["--window", window] if window else [])), sid)
    if node is not None:
        return node
    windows = (agtermctl("window", "list", "--json").get("result") or {}).get("windows") or []
    for w in windows:
        if isinstance(w, dict) and w.get("open") and w.get("id") and w.get("id") != window:
            node = find_node(agtermctl("tree", "--json", "--window", str(w["id"])), sid)
            if node is not None:
                return node
    return None


def other_pane(sid: str, pane: str) -> str:
    """the pane id across the split from `pane` in session `sid`."""
    node = session_node(sid)
    if node is None:
        raise ChatError(f"session {sid} is not in any open agterm window")
    panes = {s.get("kind"): s.get("paneID") for s in node.get("surfaces") or []
             if isinstance(s, dict) and s.get("kind") in ("left", "right")}
    if pane not in panes.values():
        raise ChatError(f"pane {pane} is not the left or right pane of session {sid}")
    peer = panes.get("right") if panes.get("left") == pane else panes.get("left")
    if not peer:
        raise ChatError("this session has no split; open one with `agtermctl session split on`")
    return peer


def own_identity() -> tuple[str, str]:
    sid = os.environ.get("AGTERM_SESSION_ID", "")
    pane = os.environ.get("AGTERM_PANE_ID", "")
    if not sid or not pane:
        raise ChatError("AGTERM_SESSION_ID and AGTERM_PANE_ID are unset: not inside an agterm pane, "
                        "or the agent strips them from its tool commands (see Setup)")
    return sid, pane


class Waiter:
    """the Claude Code receiver for one pane, run by an asyncRewake hook.

    It exits 2 with the mail on stderr, which starts a Claude turn, and 0 in every other case, errors
    included. Mail is taken only between turns: UserPromptSubmit sets the busy mark, Stop and a
    non-compact SessionStart clear it. Esc fires no Stop, so mail after an interrupted turn waits for
    the next turn's end.
    """

    BUSY_POLL_SECONDS = 1.0
    READ_ATTEMPTS = 3
    RETRY_SECONDS = 1.0
    LOCK_POLL_SECONDS = 1.0
    # a waiter whose Claude Code exited notices after its current read round, then frees the lock
    TAKEOVER_SECONDS = WAIT_ROUND_SECONDS + 15

    def __init__(self, sid: str, pane: str) -> None:
        self.sid = sid
        self.pane = pane
        self.parent = os.getppid()
        self.lock_path = state_path(f"claude-{pane}.lock")
        self.busy_path = state_path(f"claude-{pane}.busy")
        self.claude_path = state_path(f"claude-{pane}.json")
        self.waiter_path = state_path(f"claude-{pane}.waiter")
        self.log_path = state_path(f"claude-{pane}.log")

    def listening(self) -> bool:
        """whether the Claude Code that last ran this pane's hook is alive, waiter running or not."""
        return pid_alive((read_json(self.claude_path) or {}).get("pid"))

    def busy(self) -> bool:
        return os.path.exists(self.busy_path)

    def mark_busy(self) -> None:
        with open(self.busy_path, "w"):
            pass

    def run(self, event: str, source: str) -> int:
        try:
            write_json(self.claude_path, {"pid": self.parent})
            if event == "UserPromptSubmit":
                self.mark_busy()
                return 0
            # auto-compaction fires SessionStart in the middle of a turn
            if not (event == "SessionStart" and source == "compact"):
                remove(self.busy_path)
            return self.serve()
        except Exception as e:  # noqa: BLE001 - any failure must exit 0, never wake Claude
            self.log(f"error: {e}")
            return 0

    def log(self, msg: str) -> None:
        try:
            with open(self.log_path, "a", encoding="utf-8") as f:
                f.write("{} pid={} {}\n".format(time.strftime("%Y-%m-%d %H:%M:%S"), os.getpid(), msg))
        except OSError:
            pass

    def serve(self) -> int:
        with open(self.lock_path, "a") as lock:
            if not self.take_lock(lock):
                return 0
            write_json(self.waiter_path, {"pid": os.getpid(), "parent": self.parent})
            try:
                return self.loop()
            finally:
                remove(self.waiter_path)

    def take_lock(self, lock: Any) -> bool:
        """the pane's waiter lock; False when a waiter for this same Claude Code already holds it."""
        deadline = time.monotonic() + self.TAKEOVER_SECONDS
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return True
            except OSError:
                if (read_json(self.waiter_path) or {}).get("parent") == self.parent:
                    return False
                if time.monotonic() >= deadline:
                    return False
                time.sleep(self.LOCK_POLL_SECONDS)

    def loop(self) -> int:
        while os.getppid() == self.parent:
            messages = self.peek()
            # the wait can outlive the Claude Code that started it; mail taken then reaches nobody
            if not messages or os.getppid() != self.parent:
                continue
            if self.busy():
                time.sleep(self.BUSY_POLL_SECONDS)
                continue
            # write before the ack: a pipe Claude closed fails here and leaves the mail in the mailbox
            sys.stderr.write("\n\n".join(render(m) for m in messages) + "\n")
            sys.stderr.flush()
            agtermctl("msg", "ack", "--as", self.identity(), *[m["id"] for m in messages])
            # the turn this starts is Stop-hook feedback, which fires no UserPromptSubmit
            self.mark_busy()
            return WAKE
        return 0

    def identity(self) -> str:
        return f"{self.sid}:{self.pane}"

    def peek(self) -> list[dict[str, Any]]:
        args = ctl_args("msg", "read", "--wait", "--timeout", str(WAIT_ROUND_SECONDS), "--json", "--as",
                        self.identity())
        res = None
        for attempt in range(self.READ_ATTEMPTS):
            if attempt:
                time.sleep(self.RETRY_SECONDS)
            res = run(args, timeout=WAIT_ROUND_SECONDS + 15)
            if res.returncode == 124:
                return []
            if res.returncode == 0:
                return (json.loads(res.stdout).get("result") or {}).get("messages") or []
        detail = (res.stderr or res.stdout).strip() if res else ""
        raise ChatError(f"msg read failed {self.READ_ATTEMPTS} times: {detail}")


class Courier:
    """the Codex receiver for one pane: hands its mail to the registered thread with `codex queue`.

    A message is acked only after codex accepted it, so a failed hand-over leaves it in the mailbox.
    """

    LOCK_SECONDS = 30

    def __init__(self, sid: str, pane: str) -> None:
        self.sid = sid
        self.pane = pane
        self.path = state_path(f"codex-{pane}.json")

    def registration(self) -> dict[str, Any] | None:
        """the thread a live codex registered in this pane; None when there is none or its codex is gone."""
        reg = read_json(self.path)
        if not reg or reg.get("session") != self.sid or not reg.get("thread"):
            return None
        # codex queue accepts mail for a thread nobody runs, so it would be acked and lost
        return reg if pid_alive(reg.get("pid")) else None

    def register(self, thread: str, pid: int, executable: str | None) -> None:
        reg: dict[str, Any] = {"session": self.sid, "thread": thread, "pid": pid}
        if executable:
            reg["codex"] = executable
        write_json(self.path, reg)

    def deliver(self) -> int:
        reg = self.registration()
        if reg is None:
            raise ChatError(f"no running codex has registered pane {self.pane}")
        with open(state_path(f"codex-{self.pane}.lock"), "a") as lock:
            self.take_lock(lock)
            # the codex may have exited or been replaced while another delivery held the lock
            reg = self.registration()
            if reg is None:
                raise ChatError(f"the codex in pane {self.pane} exited before delivery")
            return self.drain(reg)

    def take_lock(self, lock: Any) -> None:
        deadline = time.monotonic() + self.LOCK_SECONDS
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return
            except OSError:
                if time.monotonic() >= deadline:
                    raise ChatError(f"another delivery held the lock for {self.LOCK_SECONDS}s") from None
                time.sleep(0.2)

    def drain(self, reg: dict[str, Any]) -> int:
        identity = f"{self.sid}:{self.pane}"
        # agterm's event hook runs with the app's PATH, which rarely holds an npm or nvm codex
        codex = str(reg.get("codex") or "codex")
        delivered = 0
        while True:
            out = agtermctl("msg", "read", "--json", "--as", identity)
            messages = (out.get("result") or {}).get("messages") or []
            if not messages:
                return delivered
            for m in messages:
                if not pid_alive(reg.get("pid")):
                    raise ChatError(f"the codex in pane {self.pane} exited after {delivered} delivered; "
                                    "the rest stays in the mailbox")
                res = run([codex, "queue", "--thread", str(reg["thread"]), "--message", render(m)], timeout=60)
                if res.returncode != 0:
                    detail = (res.stderr or res.stdout).strip()
                    raise ChatError(f"codex queue failed after {delivered} delivered: {detail}")
                agtermctl("msg", "ack", "--as", identity, m["id"])
                delivered += 1


def receiver(sid: str, pane: str) -> str:
    """which receiver serves a pane now: codex, claude, or none."""
    if Courier(sid, pane).registration() is not None:
        return "codex"
    if Waiter(sid, pane).listening():
        return "claude"
    return "none"


def say(text: str) -> dict[str, Any]:
    sid, pane = own_identity()
    message = compose(text)
    peer = other_pane(sid, pane)
    # delivery to codex is the agterm event hook's job: codex queue fails inside a codex tool sandbox
    agtermctl("msg", "send", "--stdin", "--to", f"{sid}:{peer}", "--json", stdin=message)
    result: dict[str, Any] = {"sent": len(message.encode("utf-8")), "receiver": receiver(sid, peer)}
    if result["receiver"] == "claude":
        result["peerBusy"] = Waiter(sid, peer).busy()
    return result


def status() -> dict[str, Any]:
    sid, pane = own_identity()
    peer = other_pane(sid, pane)
    result: dict[str, Any] = {"pane": pane, "peerPane": peer, "receiver": receiver(sid, peer)}
    if result["receiver"] == "claude":
        result["peerBusy"] = Waiter(sid, peer).busy()
    return result


def find_codex_pid(start: int) -> int | None:
    """the nearest ancestor of `start`, itself included, whose command is codex."""
    pid = start
    for _ in range(6):
        res = run(["ps", "-o", "ppid=,comm=", "-p", str(pid)], timeout=5)
        parts = res.stdout.split(None, 1)
        if res.returncode != 0 or len(parts) < 2:
            return None
        if os.path.basename(parts[1].strip()) == "codex":
            return pid
        pid = int(parts[0])
        if pid <= 1:
            return None
    return None


def process_argv(pid: int) -> list[str] | None:
    """the process's argv with its real boundaries, from macOS KERN_PROCARGS2; ps joins them."""
    libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
    mib = (ctypes.c_int * 3)(1, 49, pid)  # CTL_KERN, KERN_PROCARGS2
    size = ctypes.c_size_t(0)
    if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0:
        return None
    buf = ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib, 3, buf, ctypes.byref(size), None, 0) != 0 or size.value < 4:
        return None
    raw = buf.raw[:size.value]
    argc = int.from_bytes(raw[:4], sys.byteorder)
    # argc, the executable path, NUL padding, then argc NUL-terminated strings
    rest = raw[4:]
    rest = rest[rest.find(b"\0"):].lstrip(b"\0")
    args = rest.split(b"\0")[:argc]
    return [a.decode("utf-8", "replace") for a in args] if len(args) == argc else None


def executable_path(pid: int) -> str | None:
    """the absolute path of the process's executable, from macOS proc_pidpath."""
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
    buf = ctypes.create_string_buffer(4096)
    if libproc.proc_pidpath(pid, buf, ctypes.sizeof(buf)) <= 0:
        return None
    return buf.value.decode("utf-8", "replace")


def codex_subcommand(argv: list[str]) -> str:
    """the first argument after codex's global options and their values."""
    i = 1
    while i < len(argv) and argv[i].startswith("-"):
        i += 2 if argv[i] in CODEX_VALUE_FLAGS else 1
    return argv[i] if i < len(argv) else ""


def is_codex_exec(pid: int) -> bool:
    """whether codex is a headless `codex exec` run; an unreadable argv counts as one."""
    argv = process_argv(pid)
    return argv is None or codex_subcommand(argv) in ("exec", "e")


def hook_event() -> dict[str, Any]:
    try:
        value = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        return {}
    return value if isinstance(value, dict) else {}


def claude_hook() -> int:
    sid = os.environ.get("AGTERM_SESSION_ID", "")
    pane = os.environ.get("AGTERM_PANE_ID", "")
    # a `claude -p` started from an agterm pane inherits its AGTERM_* and must not take the pane's mail
    if not sid or not pane or os.environ.get("CLAUDE_CODE_ENTRYPOINT") != "cli":
        return 0
    event = hook_event()
    return Waiter(sid, pane).run(str(event.get("hook_event_name", "")), str(event.get("source", "")))


def codex_hook() -> int:
    sid = os.environ.get("AGTERM_SESSION_ID", "")
    pane = os.environ.get("AGTERM_PANE_ID", "")
    if not sid or not pane:
        return 0
    try:
        event = hook_event()
        thread = event.get("session_id")
        # codex's background memory session starts with no transcript, and codex queue cannot reach it
        if not thread or not event.get("transcript_path"):
            return 0
        pid = find_codex_pid(os.getppid())
        # a nested `codex exec` fires SessionStart too and would take over the pane's thread
        if pid is None or is_codex_exec(pid):
            return 0
        Courier(sid, pane).register(str(thread), pid, executable_path(pid))
        # detached, so codex's startup never waits on queue calls into its own thread
        with open(state_path(f"codex-{pane}.log"), "a") as log:
            subprocess.Popen([sys.executable, os.path.abspath(__file__), "deliver"], stdin=subprocess.DEVNULL,
                             stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    except Exception:  # noqa: BLE001 - a hook failure must not disturb codex's start
        return 0
    return 0


def agterm_hook() -> int:
    """the agterm `on message` hook: hand new mail for a registered codex pane to its thread."""
    event = hook_event()
    payload = event.get("payload")
    sid = str(event.get("session") or "")
    pane = str(payload.get("paneID") or "") if isinstance(payload, dict) else ""
    if not sid or not pane:
        return 0
    courier = Courier(sid, pane)
    if courier.registration() is None:
        return 0
    socket = os.environ.get("AGT_SOCKET", "")
    if not socket:
        sys.stderr.write("AGT_SOCKET is unset; refusing to guess which agterm to read mail from\n")
        return 1
    # the app's own socket wins over any AGTERM_SOCKET inherited from where agterm was started
    os.environ["AGTERM_SOCKET"] = socket
    try:
        courier.deliver()
    except (ChatError, OSError, ValueError, subprocess.SubprocessError) as e:
        sys.stderr.write(f"delivery to codex in pane {pane} failed: {e}\n")
        return 1
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="mailbox-chat.py")
    sub = parser.add_subparsers(dest="cmd", required=True)
    say_cmd = sub.add_parser("say", help="send a message to the agent in the other pane")
    say_input = say_cmd.add_mutually_exclusive_group(required=True)
    say_input.add_argument("--stdin", action="store_true", help="read the message from stdin")
    say_input.add_argument("--file", metavar="PATH", help="read the message from a file, which is kept")
    sub.add_parser("status", help="the other pane and which receiver serves it")
    deliver_cmd = sub.add_parser("deliver", help="hand a codex pane's waiting mail to its thread")
    deliver_cmd.add_argument("--pane", help="pane id, default: this pane")
    sub.add_parser("claude-hook", help="Claude Code hook: deliver this pane's mail")
    sub.add_parser("codex-hook", help="Codex SessionStart hook: register this pane's thread")
    sub.add_parser("agterm-hook", help="agterm `on message` hook: hand new mail to a registered codex")
    args = parser.parse_args(argv)
    if args.cmd == "claude-hook":
        return claude_hook()
    if args.cmd == "codex-hook":
        return codex_hook()
    if args.cmd == "agterm-hook":
        return agterm_hook()
    try:
        if args.cmd == "say":
            result = say(read_message_file(args.file) if args.file is not None else sys.stdin.read())
        elif args.cmd == "status":
            result = status()
        else:
            sid, pane = own_identity()
            result = {"delivered": Courier(sid, args.pane or pane).deliver()}
    except (ChatError, OSError, ValueError, subprocess.SubprocessError) as e:
        print(json.dumps({"error": str(e)}))
        return 1
    print(json.dumps(result))
    return 1 if "error" in result else 0


if __name__ == "__main__":
    sys.exit(main())
