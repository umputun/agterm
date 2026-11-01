#!/usr/bin/env python3
"""
agtermctl-receiver — the Mac-side half of the container-overlays recipe.

Listens on a local port and runs the real `agtermctl`, streaming its output
back. One connection per call; a call held open by `--block` holds its
connection for as long as the overlay runs, so nothing here times a
subprocess — but when the client side goes away, the child is terminated
and reaped.

Protocol, one JSON object per line:
  argv form:  {"argv": ["session", ...], "env": {"AGTERM_*": "..."}}
  exec form:  {"op": "exec", "container": "dev", "payload_b64": "...",
               "global_flags": ["--json"], "flags": ["--block"],
               "env": {"AGTERM_*": "..."}}
  reply:      {"t": "out"|"err", "b": "<base64 chunk>"} ... {"t": "rc", "rc": N}

The exec form is the only way an overlay COMMAND crosses: the receiver
builds the docker exec line itself, from its own template and the
ingredients above — no caller-written overlay COMMAND reaches the Mac as a
shell line. Every refusal carries an err frame with the reason plus rc 2.

Plainly: this receiver only ever starts its one resolved agtermctl binary
and refuses `--socket`, so a caller can neither smuggle a raw overlay
COMMAND onto the Mac nor point it at another agterm instance — this
receiver's own environment decides which one it drives. Everything else
agtermctl itself can do is still on the wire: anyone who reaches this port
drives your terminal as you, `session new --command` and typing into your
shells included. Bind 127.0.0.1, run it on a single-user machine, stop it
when done.

Only AGTERM_* names from the request environment are honored — the wrapper
sends the session identity so the call targets the container's own session.
Everything else about the child comes from this process's environment.
"""

import argparse
import base64
import json
import os
import re
import select
import shlex
import shutil
import signal
import socket
import socketserver
import subprocess
import sys
import threading
import time
import unittest

MAX_REQUEST_BYTES = 1024 * 1024
CONNECT_TIMEOUT = 30
KILL_GRACE = 5
EOF_POLL = 0.25

# The only names a request may set: the session identity the wrapper
# forwards. Anything else here — a state dir, a socket path — would let a
# caller retarget this receiver's CLI at another agterm instance; argv
# carries the same refusal for --socket.
FORWARDED_ENV = {
    "AGTERM_SESSION_ID", "AGTERM_WINDOW_ID", "AGTERM_WORKSPACE_ID",
    "AGTERM_PANE", "AGTERM_PANE_ID",
}

ROUTE_OPEN = ["session", "overlay", "open"]

# agterm ≥ 0.39.0 `session overlay open` flag surface — this receiver's copy
# of agtermctl.py's inventory; the two move together with the version pin.
VALUE_FLAGS = {
    "--html", "--url", "--cwd", "--size-percent", "--width", "--height",
    "--background-color", "--pane", "--target", "--window", "--socket",
}
BOOL_FLAGS = {
    "--wait", "--block", "--follow", "--navigation", "--js", "--chromeless",
    "--persistent", "--browse", "--companion", "--json",
}

# Route prefix tokens (global_flags) are carried verbatim: agtermctl has no
# root-level flags in 0.39.0, so the host CLI judges anything a caller
# puts there — except --socket, which the token scan refuses everywhere.

# fullmatch, not match: `$` alone also matches before a trailing newline,
# and a name like "alpine\n" would split the docker line under the shell.
CONTAINER_NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")

# The only shell line this receiver ever builds: {ENVFLAGS} {CONTAINER}
# {B64} are replaced. The absolute docker path matters — the overlay
# terminal is spawned by the agterm app, which inherits the app's
# launch-environment PATH, not the reader's shell PATH. Override with
# --exec-template or AGT_OVL_EXEC_TEMPLATE when docker lives elsewhere.
DEFAULT_EXEC_TEMPLATE = (
    "/usr/local/bin/docker exec -it "
    "-e TERM=xterm-ghostty -e COLORTERM=truecolor {ENVFLAGS} {CONTAINER} "
    'sh -c "$(printf %s {B64} | base64 -d)"'
)


class Refused(Exception):
    """A request this receiver will not run; the message goes to the client."""


def frame_bytes(kind, data):
    return (json.dumps({"t": kind, "b": base64.b64encode(data).decode()}) + "\n").encode()


def frame_rc(code):
    return (json.dumps({"t": "rc", "rc": code}) + "\n").encode()


def socket_flag(tokens):
    """The first --socket token in tokens, else None (eq form included)."""
    for t in tokens:
        if t == "--socket" or t.startswith("--socket="):
            return t
    return None


def open_tokens(argv):
    """Tokens after a routed `session overlay open`, or None when the call
    does not route there. Mirrors the wrapper's find_route: only flags may
    precede the route."""
    end = argv.index("--") if "--" in argv else len(argv)
    n = len(ROUTE_OPEN)
    for i in range(min(end, len(argv)) - n + 1):
        if argv[i:i + n] == ROUTE_OPEN:
            if all(t.startswith("-") for t in argv[:i]):
                return argv[i + n:]
            return None
    return None


def has_page_flag(tokens):
    return any(
        t in ("--html", "--url") or t.startswith(("--html=", "--url="))
        for t in tokens
    )


def parse_open_command(tokens):
    """Where the COMMAND positional sits in a valid open call: an index,
    None when the call is valid without one (flags only), ValueError when
    the call does not parse. Mirrors agtermctl.py's parser: closed flag
    surface, flags before AND after COMMAND, `--` ends scanning, one
    positional max, no repeated value flags."""
    seen = set()
    command_idx = None
    i = 0
    n = len(tokens)
    while i < n:
        tok = tokens[i]
        if tok == "--":
            i += 1
            break
        if tok.startswith("--"):
            name, eq, _ = tok.partition("=")
            if name in VALUE_FLAGS:
                if name in seen:
                    raise ValueError("repeated flag " + name)
                seen.add(name)
                if not eq:
                    if i + 1 >= n:
                        raise ValueError("missing value for " + name)
                    i += 1
            elif name in BOOL_FLAGS:
                if eq:
                    raise ValueError("boolean flag with value: " + name)
            else:
                raise ValueError("unknown flag " + name)
        elif command_idx is None:
            command_idx = i
        else:
            raise ValueError("second positional")
        i += 1
    while i < n:
        if command_idx is not None:
            raise ValueError("second positional")
        command_idx = i
        i += 1
    return command_idx


def valid_exec_flags(flags):
    """Closed-surface check for an exec request's open flags: known flags
    with their values, nothing else — no positional, no `--`, no
    --html/--url (they contradict the exec COMMAND), no --cwd (container
    cwd belongs in the payload, never on the Mac)."""
    i = 0
    n = len(flags)
    while i < n:
        tok = flags[i]
        name, eq, _ = tok.partition("=")
        if name in VALUE_FLAGS:
            if name in ("--html", "--url", "--cwd"):
                return False
            if eq:
                i += 1
                continue
            if i + 1 >= n:
                return False
            i += 2
            continue
        if name in BOOL_FLAGS and not eq:
            i += 1
            continue
        return False
    return True


def build_exec_line(container, payload_b64, env, template):
    """The only shell line this receiver hands agtermctl. payload_b64 stays
    armored — the b64 alphabet cannot break out of the template's quoting —
    and is only decoded inside the container."""
    env_flags = " ".join(
        f"-e {k}={shlex.quote(v)}"
        for k, v in sorted(env.items())
        if k.startswith("AGTERM_") and v
    )
    return (
        template
        .replace("{ENVFLAGS}", env_flags)
        .replace("{CONTAINER}", container)
        .replace("{B64}", payload_b64)
    )


def forwarded_env(request):
    return {k: v for k, v in (request.get("env") or {}).items()
            if k in FORWARDED_ENV}


def _str_list(value):
    return isinstance(value, list) and all(isinstance(v, str) for v in value)


def build_child(agtermctl, template, request):
    """Validate a parsed request and build (argv, env) for the child.
    Raises Refused with the reason. `op exec` builds the docker-exec
    overlay open itself; the argv form must carry no --socket and no raw
    COMMAND on `session overlay open`."""
    env = dict(os.environ)
    forwarded = forwarded_env(request)
    env.update(forwarded)

    if request.get("op") == "exec":
        container = request.get("container")
        payload_b64 = request.get("payload_b64")
        global_flags = request.get("global_flags", [])
        flags = request.get("flags", [])
        if not isinstance(container, str) or not CONTAINER_NAME_RE.fullmatch(container):
            raise Refused("exec request: container must be a docker container name")
        if not isinstance(payload_b64, str):
            raise Refused("exec request: payload_b64 must be a base64 string")
        try:
            base64.b64decode(payload_b64, validate=True)
        except (ValueError, TypeError):
            raise Refused("exec request: payload_b64 is not valid base64")
        if not _str_list(global_flags):
            raise Refused("exec request: global_flags must be a list of strings")
        if not _str_list(flags):
            raise Refused("exec request: flags must be a list of strings")
        bad = socket_flag(list(global_flags) + list(flags))
        if bad:
            raise Refused(
                f"refused {bad}: this receiver never retargets another agterm instance — "
                "its own environment decides which one it drives"
            )
        if not valid_exec_flags(flags):
            raise Refused(
                "exec request: flags must be plain session overlay open flags — "
                "no COMMAND, no --html/--url, no --cwd"
            )
        line = build_exec_line(container, payload_b64, forwarded, template)
        argv = ([agtermctl] + list(global_flags)
                + ROUTE_OPEN + list(flags) + ["--", line])
        return argv, env

    argv = request.get("argv")
    if not _str_list(argv) or not argv:
        raise Refused("bad request: argv must be a non-empty list of strings")
    bad = socket_flag(argv)
    if bad:
        raise Refused(
            f"refused {bad}: this receiver never retargets another agterm instance — "
            "its own environment decides which one it drives"
        )
    tokens = open_tokens(argv)
    if tokens is not None:
        try:
            command_idx = parse_open_command(tokens)
        except ValueError:
            if not has_page_flag(tokens):
                # fail closed against flag-surface drift: today every
                # unparsable open errors host-side, a newer host may run it
                raise Refused(
                    "refused: unparsable session overlay open with no --html/--url — "
                    "it could carry a raw COMMAND; the container wrapper sends op exec"
                )
            command_idx = None  # unparsable but page-carrying: the host CLI judges
        if command_idx is not None:
            raise Refused(
                "refused: raw COMMAND on session overlay open — no caller-written "
                "shell line crosses; update the container wrapper and receiver "
                "together (see the recipe)"
            )
    return [agtermctl] + argv, env


class Receiver(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, address, handler, agtermctl, exec_template, log):
        super().__init__(address, handler)
        self.agtermctl = agtermctl
        self.exec_template = exec_template
        self.log = log
        self._children = set()
        self._children_lock = threading.Lock()

    def track(self, proc):
        with self._children_lock:
            self._children.add(proc)

    def untrack(self, proc):
        with self._children_lock:
            self._children.discard(proc)

    def terminate_children(self):
        """Terminate and reap every live child — the shutdown path, so an
        abandoned `agtermctl events` never outlives the receiver."""
        with self._children_lock:
            children = list(self._children)
        for proc in children:
            try:
                proc.terminate()
            except OSError:
                pass
        for proc in children:
            try:
                proc.wait(timeout=KILL_GRACE)
            except (subprocess.TimeoutExpired, OSError):
                try:
                    proc.kill()
                    proc.wait()
                except OSError:
                    pass


class Handler(socketserver.StreamRequestHandler):
    timeout = CONNECT_TIMEOUT

    def handle(self):
        line = self.rfile.readline(MAX_REQUEST_BYTES)
        if not line:
            return
        # The connect timeout bounded waiting for the request line; from
        # here the socket is fully blocking so a slow client applies TCP
        # backpressure to the pumps, never a write timeout.
        self.connection.settimeout(None)
        try:
            request = json.loads(line)
            if not isinstance(request, dict):
                raise TypeError("request must be a JSON object")
            if not isinstance(request.get("env") or {}, dict) or not all(
                isinstance(k, str) and isinstance(v, str)
                for k, v in (request.get("env") or {}).items()
            ):
                raise ValueError("env must be an object with string values")
        except (ValueError, TypeError) as e:
            self.refuse(f"bad request: {e}")
            return
        try:
            argv, env = build_child(self.server.agtermctl, self.server.exec_template, request)
        except Refused as e:
            self.refuse(str(e))
            return
        if request.get("op") == "exec":
            self.server.log(f"exec {' '.join(argv[1:-1])}")
        else:
            self.server.log(" ".join(argv[1:]))
        code = self.run(argv, env)
        try:
            self.wfile.write(frame_rc(code))
            self.wfile.flush()
        except OSError:
            pass  # client gone mid-reply; the child is already reaped

    def refuse(self, msg):
        try:
            self.wfile.write(frame_bytes("err", msg.encode("utf-8")))
            self.wfile.write(frame_rc(2))
            self.wfile.flush()
        except OSError:
            pass
        self.server.log(msg)

    def run(self, argv, env):
        lock = threading.Lock()
        client_gone = threading.Event()
        child_done = threading.Event()

        def send(data):
            with lock:
                try:
                    self.wfile.write(data)
                    self.wfile.flush()
                    return True
                except OSError:
                    client_gone.set()
                    return False

        # stdin never crosses the wire; DEVNULL keeps the child off this
        # process's own stdin instead of hanging on it.
        proc = subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.server.track(proc)

        def pump(stream, kind):
            while True:
                chunk = stream.read1(65536)
                if not chunk or not send(frame_bytes(kind, chunk)):
                    return

        def watch_eof():
            # The protocol sends exactly one request line and nothing else,
            # so a readable socket means EOF (or a misbehaving client whose
            # bytes MSG_PEEK leaves in place). No settimeout here: it would
            # bound the pump threads' writes too and kill the child on a
            # merely slow client — select keeps sends fully blocking.
            while not (client_gone.is_set() or child_done.is_set()):
                try:
                    readable, _, _ = select.select([self.connection], [], [], EOF_POLL)
                    if not readable:
                        continue
                    if self.connection.recv(1, socket.MSG_PEEK) == b"":
                        break
                except (OSError, ValueError):
                    break
            client_gone.set()

        threads = [threading.Thread(target=pump, args=(proc.stdout, "out"), daemon=True),
                   threading.Thread(target=pump, args=(proc.stderr, "err"), daemon=True),
                   threading.Thread(target=watch_eof, daemon=True)]
        for t in threads:
            t.start()
        code = self.wait_reaping(proc, client_gone)
        child_done.set()
        for t in threads:
            t.join()
        self.server.untrack(proc)
        return code

    @staticmethod
    def wait_reaping(proc, client_gone):
        """Wait for the child; when the client disconnects first, terminate
        and reap it so no abandoned call outlives its connection."""
        while True:
            try:
                return proc.wait(timeout=EOF_POLL)
            except subprocess.TimeoutExpired:
                pass
            if client_gone.is_set():
                proc.terminate()
                try:
                    return proc.wait(timeout=KILL_GRACE)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    return proc.wait()


def main():
    if os.environ.get("AGT_OVL_SELFTEST") == "1":
        suite = unittest.TestLoader().loadTestsFromTestCase(RT)
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        sys.exit(0 if result.wasSuccessful() else 1)

    parser = argparse.ArgumentParser(description="run agtermctl for container-side wrappers")
    parser.add_argument("--port", type=int, default=59998, help="port to listen on (default 59998)")
    parser.add_argument("--bind", default="127.0.0.1",
                        help="address to bind (default 127.0.0.1; containers reach it via host.docker.internal)")
    parser.add_argument("--agtermctl", default=None,
                        help="path to the real agtermctl (default: $AGTERMCTL, else the first on PATH)")
    parser.add_argument("--exec-template", default=None,
                        help="docker exec template for overlay COMMANDs; must contain {ENVFLAGS}, "
                             "{CONTAINER} and {B64} (default: $AGT_OVL_EXEC_TEMPLATE, else docker "
                             "desktop's path)")
    args = parser.parse_args()

    agtermctl = args.agtermctl or os.environ.get("AGTERMCTL") or shutil.which("agtermctl")
    if not agtermctl:
        sys.exit("agtermctl-receiver: no agtermctl found — pass --agtermctl /path/to/agtermctl or set AGTERMCTL")

    template = args.exec_template or os.environ.get("AGT_OVL_EXEC_TEMPLATE") or DEFAULT_EXEC_TEMPLATE
    missing = [p for p in ("{ENVFLAGS}", "{CONTAINER}", "{B64}") if p not in template]
    if missing:
        sys.exit(f"agtermctl-receiver: exec template is missing {', '.join(missing)}")

    def log(msg):
        print(f"agtermctl-receiver: {msg}", file=sys.stderr, flush=True)

    receiver = Receiver((args.bind, args.port), Handler, agtermctl, template, log)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    log(f"serving {agtermctl} on {args.bind}:{args.port}")
    try:
        receiver.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        receiver.terminate_children()


# --- Selftest (AGT_OVL_SELFTEST=1 agtermctl-receiver) ------------------------

class RT(unittest.TestCase):
    TEMPLATE = "DOCKER {ENVFLAGS} {CONTAINER} {B64}"

    def make_server(self, agtermctl="/bin/sh"):
        server = Receiver(("127.0.0.1", 0), Handler, agtermctl, self.TEMPLATE,
                          lambda msg: None)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.terminate_children)
        self.addCleanup(server.shutdown)
        self.addCleanup(server.server_close)
        return server

    @staticmethod
    def call(addr, request):
        with socket.create_connection(addr, timeout=15) as sock:
            sock.sendall((json.dumps(request) + "\n").encode())
            frames = []
            for line in sock.makefile("rb"):
                frames.append(json.loads(line))
            return frames

    @staticmethod
    def frame_bytes(frames, kind):
        return b"".join(base64.b64decode(f["b"]) for f in frames if f["t"] == kind)

    def test_valid_exec_flags(self):
        for flags in ([], ["--block"], ["--size-percent", "60"], ["--target", "X"],
                      ["--target=X"], ["--wait", "--follow"], ["--json"]):
            self.assertTrue(valid_exec_flags(flags), flags)
        for flags in (["htop"], ["--"], ["--html", "f"], ["--url=x"], ["--nope"],
                      ["--cwd", "/x"], ["--cwd=/x"], ["--block=1"], ["--target"]):
            self.assertFalse(valid_exec_flags(flags), flags)

    def test_parse_open_command(self):
        self.assertIsNone(parse_open_command([]))
        self.assertIsNone(parse_open_command(["--html", "f"]))
        self.assertEqual(parse_open_command(["htop"]), 0)
        self.assertEqual(parse_open_command(["--block", "--", "htop"]), 2)
        self.assertEqual(parse_open_command(["htop", "--block"]), 0)
        for bad in (["htop", "extra"], ["--nope", "v"], ["--html", "a", "--html=b"],
                    ["--block=1"], ["--html"], ["--", "htop", "extra"]):
            with self.assertRaises(ValueError, msg=str(bad)):
                parse_open_command(bad)

    def test_socket_flag(self):
        self.assertIsNone(socket_flag(["session", "status"]))
        self.assertEqual(socket_flag(["--socket", "/x"]), "--socket")
        self.assertEqual(socket_flag(["session", "--socket=/x"]), "--socket=/x")

    def test_open_tokens(self):
        self.assertIsNone(open_tokens(["session", "status", "active"]))
        self.assertIsNone(open_tokens(["tree", "session", "overlay", "open"]))
        self.assertEqual(open_tokens(["session", "overlay", "open", "--block"]),
                         ["--block"])
        self.assertEqual(open_tokens(["session", "overlay", "open", "--", "htop"]),
                         ["--", "htop"])
        self.assertEqual(open_tokens(["--json", "session", "overlay", "open",
                                      "--html", "f"]), ["--html", "f"])

    def test_build_exec_line(self):
        line = build_exec_line("dev-box", "Q0Q=",
                               {"AGTERM_SESSION_ID": "S", "HOME": "/root"},
                               "D {ENVFLAGS} {CONTAINER} {B64}")
        self.assertEqual(line, "D -e AGTERM_SESSION_ID=S dev-box Q0Q=")
        quoted = build_exec_line("c", "Q=", {"AGTERM_PANE": "a b"},
                                 "E {ENVFLAGS}|{CONTAINER}|{B64}")
        self.assertIn("-e AGTERM_PANE='a b'|", quoted)

    def test_build_child_exec(self):
        request = {"op": "exec", "container": "dev", "payload_b64": "Q0Q=",
                   "global_flags": ["--json"], "flags": ["--block"],
                   "env": {"AGTERM_SESSION_ID": "S", "HOME": "/root"}}
        argv, env = build_child("/agtermctl", "D {CONTAINER} {B64} {ENVFLAGS}", request)
        self.assertEqual(argv, ["/agtermctl", "--json", "session", "overlay",
                                "open", "--block", "--",
                                "D dev Q0Q= -e AGTERM_SESSION_ID=S"])
        self.assertEqual(env.get("AGTERM_SESSION_ID"), "S")
        # agtermctl has no root-level flags: prefix tokens ride verbatim
        # for the host CLI to judge (--socket stays refused by the scan).
        request2 = dict(request, global_flags=["--future-flag"])
        argv2, _ = build_child("/agtermctl", "D {CONTAINER} {B64}", request2)
        self.assertEqual(argv2[1], "--future-flag")

    def test_build_child_refusals(self):
        cases = [
            {"op": "exec", "container": "dev; rm -rf", "payload_b64": "Q0Q="},
            {"op": "exec", "container": "dev\n", "payload_b64": "Q0Q="},
            {"op": "exec", "container": "alpine\nrm -rf /", "payload_b64": "Q0Q="},
            {"op": "exec", "container": "dev", "payload_b64": "not b64!"},
            {"op": "exec", "container": "dev", "payload_b64": "Q0Q=",
             "global_flags": ["--socket", "/x"]},
            {"op": "exec", "container": "dev", "payload_b64": "Q0Q=", "flags": ["htop"]},
            {"op": "exec", "container": "dev", "payload_b64": "Q0Q=",
             "flags": ["--html", "f"]},
            {"op": "exec", "container": "dev", "payload_b64": "Q0Q=",
             "flags": ["--cwd", "/x"]},
            {"op": "exec", "container": "dev", "payload_b64": "Q0Q=", "flags": ["--"]},
            {"op": "exec", "container": "dev", "payload_b64": "Q0Q=",
             "flags": ["--socket", "/tmp/other.sock"]},
            {"argv": []},
            {"argv": ["session", "status", "--socket", "/x"]},
            {"argv": ["--socket=/x", "session", "status"]},
            {"argv": ["session", "overlay", "open", "--", "htop"]},
            {"argv": ["session", "overlay", "open", "htop", "--block"]},
            {"argv": ["session", "overlay", "open", "htop", "--nope"]},
        ]
        for request in cases:
            request["env"] = {}
            with self.assertRaises(Refused, msg=str(request)):
                build_child("/bin/sh", DEFAULT_EXEC_TEMPLATE, request)

    def test_build_child_passthrough(self):
        for request in (
            {"argv": ["session", "overlay", "open"]},
            {"argv": ["session", "overlay", "open", "--html", "/srv/p.html"], "env": {}},
            {"argv": ["session", "overlay", "open", "--nope", "--html", "f"], "env": {}},
            {"argv": ["session", "status", "active"], "env": {}},
        ):
            argv, _ = build_child("/agtermctl", DEFAULT_EXEC_TEMPLATE, request)
            self.assertEqual(argv[0], "/agtermctl")

    def test_roundtrip_out_err_rc(self):
        server = self.make_server()
        frames = self.call(server.server_address,
                           {"argv": ["-c", "echo hi; echo bad >&2; exit 7"], "env": {}})
        self.assertEqual(frames[-1], {"t": "rc", "rc": 7})
        self.assertEqual(self.frame_bytes(frames, "out"), b"hi\n")
        self.assertEqual(self.frame_bytes(frames, "err"), b"bad\n")

    def test_bare_open_runs_instead_of_refusing(self):
        server = self.make_server()
        frames = self.call(server.server_address,
                           {"argv": ["session", "overlay", "open"], "env": {}})
        self.assertEqual(frames[-1]["t"], "rc")
        self.assertNotIn(b"refused", self.frame_bytes(frames, "err"))

    def test_refusals_over_socket(self):
        server = self.make_server()
        for request in (
            {"argv": ["session", "overlay", "open", "--", "htop"], "env": {}},
            {"argv": ["session", "overlay", "open", "htop"], "env": {}},
            {"argv": ["session", "status", "--socket", "/tmp/x.sock"], "env": {}},
        ):
            frames = self.call(server.server_address, request)
            self.assertEqual(frames[-1], {"t": "rc", "rc": 2}, request)
            self.assertIn(b"refused", self.frame_bytes(frames, "err"))

    def test_exec_over_socket(self):
        server = self.make_server(agtermctl="/bin/echo")
        frames = self.call(server.server_address,
                           {"op": "exec", "container": "dev", "payload_b64": "Q0Q=",
                            "global_flags": ["--json"], "flags": ["--block"], "env": {}})
        out = self.frame_bytes(frames, "out").decode()
        self.assertIn("--json session overlay open --block --", out)
        self.assertIn("dev Q0Q=", out)
        self.assertEqual(frames[-1]["rc"], 0)

    def test_child_stdin_is_closed(self):
        """stdin does not cross the wire; the child sees EOF immediately
        instead of reading (and hanging on) the receiver's own stdin."""
        server = self.make_server()
        frames = self.call(server.server_address,
                           {"argv": ["-c", "cat; echo done"], "env": {}})
        self.assertEqual(frames[-1], {"t": "rc", "rc": 0})
        self.assertEqual(self.frame_bytes(frames, "out"), b"done\n")

    def test_client_disconnect_reaps_child(self):
        server = self.make_server()
        with socket.create_connection(server.server_address, timeout=15) as sock:
            sock.sendall((json.dumps({"argv": ["-c", "echo $$; exec sleep 30"],
                                      "env": {}}) + "\n").encode())
            frame = json.loads(sock.makefile("rb").readline())
            pid = int(base64.b64decode(frame["b"]))
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            probe = subprocess.run(["ps", "-p", str(pid), "-o", "pid="],
                                   capture_output=True, text=True, check=False)
            if probe.returncode != 0:
                return  # gone from the table: terminated AND reaped
            time.sleep(0.2)
        self.fail(f"child {pid} still alive after the client disconnected")

    def test_slow_reader_gets_backpressure_not_kill(self):
        """A client that stalls reading without closing must get TCP
        backpressure, never a write-timeout kill: the child survives and
        the full output plus rc arrive once it drains."""
        server = self.make_server()
        total = 8 * 1024 * 1024
        sock = socket.create_connection(server.server_address, timeout=15)
        sock.sendall((json.dumps(
            {"argv": ["-c", f"head -c {total} /dev/zero | tr '\\0' 'x'"],
             "env": {}}) + "\n").encode())
        time.sleep(2)  # stall: the send buffer fills while nothing is read
        frames = []
        for line in sock.makefile("rb"):
            frames.append(json.loads(line))
            if frames[-1].get("t") == "rc":
                break
        sock.close()
        self.assertEqual(frames[-1], {"t": "rc", "rc": 0})
        self.assertEqual(len(self.frame_bytes(frames, "out")), total)


if __name__ == "__main__":
    main()
