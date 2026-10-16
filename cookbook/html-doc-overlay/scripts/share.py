#!/usr/bin/env python3
"""share.py publishes an approved snapshot of an HTML page at an unguessable path on a named tunnel.

usage: share.py [--ttl 90m|24h|2d] FILE.html | list | stop FILE|URL|all | --test
"""

from __future__ import annotations

import contextlib
import fcntl
import hashlib
import json
import os
import re
import secrets
import shutil
import signal
import subprocess
import sys
import time
from collections.abc import Callable, Iterator
from pathlib import Path

SELF = Path(__file__).resolve()
SHOW = SELF.parent / "show.sh"
# physical path, so it matches the file path agterm reports for an overlay
ROOT = Path("/tmp").resolve() / "agdoc-share"
CLOUDFLARED = os.environ.get("CLOUDFLARED", "/opt/homebrew/opt/cloudflared/bin/cloudflared")
AGTERMCTL = os.environ.get("AGTERMCTL", "agtermctl")
CREDENTIALS = str(Path.home() / ".cloudflared" / "agdoc-share.json")
APPROVAL_WAIT = 600
WATCH_INTERVAL = 30
TUNNEL_WAIT = 60
PORT_RE = re.compile(r" port (\d+) ")
TTL_RE = re.compile(r"^([1-9][0-9]*)([smhd])$")
Result = subprocess.CompletedProcess


class Runner:
    """Runner starts and signals the external processes a share depends on."""

    def run(self, argv: list[str], stdin: str | None = None) -> Result[str]:
        return subprocess.run(argv, input=stdin, capture_output=True, text=True, check=False)

    def spawn(self, argv: list[str], log: Path) -> int:
        # a new session survives the agent command runner's process-group cleanup
        with open(log, "w") as out:
            proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT,
                                    start_new_session=True)
        return proc.pid

    def signal(self, pid: int, sig: int) -> None:
        os.kill(pid, sig)

    def alive(self, pid: int) -> bool:
        try:
            os.kill(pid, 0)
        except OSError:
            return False
        return True


class Clock:
    """Clock reads and waits on the wall clock."""

    def now(self) -> float:
        return time.time()

    def sleep(self, seconds: float) -> None:
        time.sleep(seconds)


def ttl_seconds(text: str) -> int | None:
    m = TTL_RE.match(text)
    if not m:
        return None
    return int(m.group(1)) * {"s": 1, "m": 60, "h": 3600, "d": 86400}[m.group(2)]


def share_key(file: str) -> str:
    """share_key resolves the parent but keeps the final name, so a symlinked page keeps its own share."""
    p = os.path.abspath(file)
    return os.path.join(os.path.realpath(os.path.dirname(p)), os.path.basename(p))


def err(msg: str) -> None:
    print(msg, file=sys.stderr)


def utc(ts: int) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))


class Approval:
    """Approval shows a staged page in this session's overlay and asks the user over it whether to publish."""

    def __init__(self, runner: Runner, clock: Clock, env: dict[str, str]) -> None:
        self.runner, self.clock = runner, clock
        self.session = env.get("AGTERM_SESSION_ID", "")
        self.socket = ["--socket", env["AGTERM_SOCKET"]] if env.get("AGTERM_SOCKET") else []
        self.window = ["--window", env["AGTERM_WINDOW_ID"]] if env.get("AGTERM_WINDOW_ID") else []

    def ctl(self, *args: str) -> Result[str]:
        return self.runner.run([AGTERMCTL, *args, *self.socket])

    def overlay_file(self) -> str:
        r = self.ctl("tree", "--json", *self.window)
        try:
            tree = json.loads(r.stdout)
        except json.JSONDecodeError:
            return ""
        node = next((n for n in walk(tree) if n.get("id") == self.session), {})
        overlays = node.get("htmlOverlays")
        pages = [p for p in overlays if isinstance(p, dict) and p.get("pane") is None] if isinstance(overlays, list) else []
        return str(pages[0].get("file") or "") if pages else ""

    def approve(self, stage: Path, name: str, title: str, access: str) -> bool:
        prev = self.overlay_file()
        pending = ""
        answer = ""
        try:
            if self.runner.run([str(SHOW), str(stage)]).returncode != 0:
                err("could not show the page for review")
                return False
            data = stage.read_bytes()
            msg = (f"{name} as shown, {len(data)} bytes, sha256 {hashlib.sha256(data).hexdigest()[:12]}. "
                   f"Anyone with the link can read it {access}.")
            r = self.ctl("ask", "open", title, "--style", "gui", "--target", self.session, *self.window,
                         "--no-block", "--message", msg, "--button", "publish=Publish",
                         "--button", "cancel=Cancel", "--default", "cancel")
            pending = str(parse_json(r.stdout).get("id") or "")
            if not pending:
                reason = (r.stderr or r.stdout).strip().removeprefix("error: ")
                hint = "; switch to this session and share again" if "session not visible" in reason else ""
                err(f"could not open the approval question: {reason or 'no answer from agterm'}{hint}")
                return False
            deadline = self.clock.now() + APPROVAL_WAIT
            while self.clock.now() < deadline:
                res = parse_json(self.ctl("ask", "result", pending, *self.window).stdout)
                # a malformed or failed poll keeps the question pending, so cleanup still cancels it
                if res.get("result") in ("answered", "escaped", "cancelled"):
                    pending = ""
                    answer = str(res.get("id") or "") if res.get("result") == "answered" else ""
                    break
                self.clock.sleep(1)
            return answer == "publish"
        finally:
            if pending:
                try:
                    self.ctl("ask", "cancel", pending, *self.window)
                except Exception as e:  # noqa: BLE001
                    err(f"could not cancel the approval question: {e}")
            try:
                self.restore(stage, prev)
            except Exception as e:  # noqa: BLE001
                err(f"could not restore the overlay: {e}")

    def restore(self, stage: Path, prev: str) -> None:
        # the staged copy is renamed or deleted next; put back what was open so reload keeps working.
        # agterm reports the path it was given, /tmp for a stage under /private/tmp, so compare resolved
        shown = self.overlay_file()
        if not shown or Path(shown).resolve() != stage.resolve():
            return
        if prev and Path(prev).resolve() != stage.resolve() and Path(prev).is_file():
            self.runner.run([str(SHOW), prev])
            return
        self.ctl("session", "overlay", "close", "--target", self.session)


def walk(node: object) -> list[dict[str, object]]:
    out: list[dict[str, object]] = []
    if isinstance(node, dict):
        out.append(node)
        for v in node.values():
            out.extend(walk(v))
    elif isinstance(node, list):
        for v in node:
            out.extend(walk(v))
    return out


def parse_json(text: str) -> dict[str, object]:
    try:
        v = json.loads(text)
    except json.JSONDecodeError:
        return {}
    return v if isinstance(v, dict) else {}


class Shares:
    """Shares manages share directories under root, each an approved snapshot and an expiry watcher,
    and the hub beside root: one server and one named tunnel serving every live share at its token path."""

    def __init__(self, runner: Runner, clock: Clock, root: Path, env: dict[str, str]) -> None:
        self.runner, self.clock, self.root, self.env = runner, clock, root, env
        self.approval = Approval(runner, clock, env)
        self.hub = root.with_name(f"{root.name}-hub")
        self.host = env.get("AGDOC_SHARE_HOST", "")
        self.credentials = Path(env.get("AGDOC_SHARE_CREDENTIALS", CREDENTIALS))

    def dir_for(self, file: str) -> Path:
        return self.root / hashlib.sha256(share_key(file).encode()).hexdigest()

    # the start time keeps a recycled pid running the same command from passing as ours
    def identity(self, pid: int) -> str:
        r = self.runner.run(["ps", "-ww", "-p", str(pid), "-o", "lstart=", "-o", "command="])
        return r.stdout.strip() if r.returncode == 0 else ""

    def running(self, d: Path, name: str) -> bool:
        pid_file, ident_file = d / f"{name}.pid", d / f"{name}.identity"
        if not pid_file.is_file() or not ident_file.is_file():
            return False
        current = self.identity(int(pid_file.read_text()))
        return bool(current) and current == ident_file.read_text().strip()

    def live(self, d: Path) -> bool:
        token = read(d / "token")
        return (bool(token) and self.running(d, "expiry") and self.hub_live()
                and (self.hub / "public" / token).is_symlink())

    # a creator still approving or starting the tunnel owns its share until the expiry watcher is up
    def in_progress(self, d: Path) -> bool:
        return not self.live(d) and self.running(d, "owner")

    def hub_live(self) -> bool:
        return self.running(self.hub, "server") and self.running(self.hub, "tunnel")

    # flock serializes the start-or-reuse and stop-if-idle decisions of concurrent shares and watchers
    @contextlib.contextmanager
    def hub_lock(self) -> Iterator[None]:
        with open(self.hub.with_name(f"{self.hub.name}.lock"), "a") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            yield

    def tunnel_id(self) -> str:
        try:
            v = json.loads(self.credentials.read_text())
        except (OSError, json.JSONDecodeError):
            return ""
        return str(v.get("TunnelID") or "") if isinstance(v, dict) else ""

    def hub_up(self, tunnel_id: str) -> bool:
        with self.hub_lock():
            if self.hub_live():
                return True
            stopped = [self.stop_proc(self.hub, n) for n in ("tunnel", "server")]
            if not all(stopped):
                return False
            # public/ keeps the links of shares still live, so a restart after a crashed process serves them again
            public = self.hub / "public"
            public.mkdir(parents=True, mode=0o700, exist_ok=True)
            # a registration line left by the previous tunnel would pass the readiness check
            (self.hub / "tunnel.log").unlink(missing_ok=True)
            # an empty root index keeps http.server from listing the live tokens at /
            (public / "index.html").write_text("")
            # an explicit empty config keeps any ingress in ~/.cloudflared/config.yml out of the hub
            (self.hub / "config.yml").write_text("")
            try:
                # port 0 lets the server pick its own free port, avoiding a probe-then-bind race
                self.start(self.hub, "server", [sys.executable, "-u", "-m", "http.server", "0", "--bind",
                                                "127.0.0.1", "--directory", str(public)])
                port = self.server_port(self.hub)
                if port:
                    self.start(self.hub, "tunnel", [
                        CLOUDFLARED, "tunnel", "--config", str(self.hub / "config.yml"), "--no-autoupdate",
                        "--output", "json", "--logfile", str(self.hub / "tunnel.log"), "--grace-period", "1s",
                        "--url", f"http://127.0.0.1:{port}",
                        "run", "--credentials-file", str(self.credentials), tunnel_id])
                    if self.tunnel_ready():
                        return True
                err("share server or tunnel did not start")
            except RuntimeError as e:
                err(str(e))
            for log in ("server.out", "tunnel.log", "tunnel.out"):
                if (self.hub / log).is_file():
                    err("\n".join((self.hub / log).read_text().splitlines()[-12:]))
            for n in ("tunnel", "server"):
                self.stop_proc(self.hub, n)
            return False

    def hub_down_if_idle(self) -> bool:
        with self.hub_lock():
            dirs = [p for p in self.root.iterdir() if p.is_dir()] if self.root.is_dir() else []
            if any(self.live(p) or self.in_progress(p) for p in dirs):
                return True
            stopped = [self.stop_proc(self.hub, n) for n in ("tunnel", "server")]
            if not all(stopped):
                return False
            shutil.rmtree(self.hub, ignore_errors=True)
            return True

    def tunnel_ready(self) -> bool:
        deadline = self.clock.now() + TUNNEL_WAIT
        log = self.hub / "tunnel.log"
        while self.clock.now() < deadline and self.hub_live():
            registered = "Registered tunnel connection" in (log.read_text() if log.is_file() else "")
            if registered and self.reachable(f"https://{self.host}/"):
                return True
            self.clock.sleep(1)
        return False

    def start(self, d: Path, name: str, argv: list[str]) -> None:
        pid = self.runner.spawn(argv, d / f"{name}.out")
        try:
            (d / f"{name}.pid").write_text(f"{pid}\n")
            # interpreter launchers re-exec, so wait for the final command line before recording it
            for _ in range(50):
                self.clock.sleep(0.1)
                current = self.identity(pid)
                if not current:
                    break
                if f"{d}/" in current:
                    (d / f"{name}.identity").write_text(current + "\n")
                    return
            raise RuntimeError(f"could not identify {name} process {pid}")
        except BaseException:
            # without an identity record stop_proc treats the pid as foreign, so the child we just
            # spawned is stopped here or it outlives its deleted share
            try:
                self.runner.signal(pid, signal.SIGKILL)
            except OSError:
                pass
            raise

    def stop_proc(self, d: Path, name: str) -> bool:
        pid_file = d / f"{name}.pid"
        if not pid_file.is_file():
            return True
        pid = int(pid_file.read_text())
        if pid == os.getpid():  # the expiry watcher stopping its own share
            return True
        if not self.running(d, name):
            if self.runner.alive(pid):
                err(f"leaving PID {pid} alone: no longer the recorded process")
            return True
        for sig, tries in ((signal.SIGTERM, 50), (signal.SIGKILL, 20)):
            try:
                self.runner.signal(pid, sig)
            except OSError:
                pass
            for _ in range(tries):
                if not self.running(d, name):
                    return True
                self.clock.sleep(0.1)
        err(f"could not stop PID {pid}; keeping state in {d}")
        return False

    def stop_share(self, d: Path) -> bool:
        if not self.stop_proc(d, "expiry"):
            return False
        token = read(d / "token")
        if token:
            (self.hub / "public" / token).unlink(missing_ok=True)
        shutil.rmtree(d, ignore_errors=True)
        return self.hub_down_if_idle()

    # -f fails on the 530/1033 answer Cloudflare gives while no connector is registered
    def reachable(self, url: str) -> bool:
        curl = self.runner.run(["curl", "-fsS", "--max-time", "10", "-o", "/dev/null", url])
        return curl.returncode == 0

    def hand_out(self, d: Path, wait: int) -> int:
        url = (d / "url").read_text().strip()
        deadline = self.clock.now() + wait
        while self.clock.now() < deadline:
            if self.reachable(url):
                print(url)
                if self.runner.run(["pbcopy"], stdin=url).returncode != 0:
                    err("could not copy URL to clipboard")
                return 0
            self.clock.sleep(1)
        err(f"share is running but {url} is not reachable; stop it and share again for a new URL")
        return 1

    def share(self, file: str, ttl_text: str) -> int:
        ttl = ttl_seconds(ttl_text)
        if ttl is None or not Path(file).is_file() or Path(file).suffix.lower() not in (".html", ".htm"):
            return usage()
        if self.env.get("AGTERM_ENABLED") != "1" or not self.env.get("AGTERM_SESSION_ID"):
            err("sharing needs agterm: the page is approved in this session's overlay before it is published")
            return 1
        if not self.host:
            err("set AGDOC_SHARE_HOST to the hostname routed to the tunnel")
            return 1
        src = Path(share_key(file))
        d = self.dir_for(file)
        if d.is_dir():
            if self.live(d) and (d / "url").is_file() and self.clock.now() < self.expires(d):
                return self.update(src, d)
            if self.in_progress(d):
                err(f"{src} is already being shared from another session")
                return 1
            if not self.stop_share(d):
                return 1
        return self.create(src, d, ttl, ttl_text)

    def expires(self, d: Path) -> int:
        return int((d / "expires").read_text())

    def update(self, src: Path, d: Path) -> int:
        # per process, so overlapping shares of one page each publish only what their own Publish approved
        index, stage = d / "web" / "index.html", d / f"stage-{os.getpid()}.html"
        if src.read_bytes() != index.read_bytes():
            # staged beside web/, never inside it, so the unapproved copy is not reachable through the tunnel
            shutil.copyfile(src, stage)
            try:
                until = time.strftime("%b %d %H:%M", time.localtime(self.expires(d)))
                if not self.approval.approve(stage, src.name, "Publish update?", f"until {until}"):
                    err("not approved; the shared page is unchanged")
                    return 1
                if self.clock.now() >= self.expires(d):
                    err("the share expired while waiting for approval")
                    return 1
                os.replace(stage, index)
            finally:
                stage.unlink(missing_ok=True)
        # a live share still has to answer publicly before its URL is handed out again
        return self.hand_out(d, 30)

    def create(self, src: Path, d: Path, ttl: int, ttl_text: str) -> int:
        if not os.access(CLOUDFLARED, os.X_OK):
            err(f"cloudflared not found at {CLOUDFLARED}")
            return 1
        tunnel_id = self.tunnel_id()
        if not tunnel_id:
            err(f"no tunnel credentials at {self.credentials}; run the one-time tunnel setup first")
            return 1
        web, stage = d / "web", d / f"stage-{os.getpid()}.html"
        web.mkdir(parents=True, mode=0o700)
        (d / "file").write_text(f"{src}\n")
        (d / "owner.pid").write_text(f"{os.getpid()}\n")
        (d / "owner.identity").write_text(self.identity(os.getpid()) + "\n")
        done = False
        try:
            shutil.copyfile(src, stage)
            if not self.approval.approve(stage, src.name, "Publish this page?", f"for {ttl_text}"):
                err("not approved; nothing was published")
                return 1
            # the clock starts at approval, so a slow review cannot publish an already expired share
            (d / "expires").write_text(f"{int(self.clock.now()) + ttl}\n")
            os.replace(stage, web / "index.html")
            (d / "started").write_text(utc(int(self.clock.now())) + "\n")
            # random, never derived from the file path: the path is the only thing keeping a share private
            token = secrets.token_urlsafe(16)
            (d / "token").write_text(f"{token}\n")
            if not self.hub_up(tunnel_id):
                return 1
            # the watcher starts only after publication, so a short ttl cannot delete the share mid-startup
            if self.clock.now() >= self.expires(d):
                err("the share expired while the tunnel was starting")
                return 1
            (self.hub / "public" / token).symlink_to(web)
            (d / "url").write_text(f"https://{self.host}/{token}/\n")
            self.start(d, "expiry", [sys.executable, str(SELF), "watch", f"{d}/"])
            done = True
            return self.hand_out(d, 30)
        except (RuntimeError, OSError) as e:
            err(str(e))
            return 1
        finally:
            stage.unlink(missing_ok=True)
            if not done:
                self.stop_share(d)

    def server_port(self, d: Path) -> str:
        for _ in range(50):
            out = d / "server.out"
            m = PORT_RE.search(out.read_text()) if out.is_file() else None
            if m:
                return m.group(1)
            if not self.running(d, "server"):
                return ""
            self.clock.sleep(0.1)
        return ""

    def watch(self, d: Path) -> int:
        # polls the wall clock, so a sleeping Mac delays the stop by at most one interval after wake
        while True:
            try:
                deadline = self.expires(d)
            except (OSError, ValueError):
                return 0
            if self.clock.now() >= deadline:
                break
            self.clock.sleep(WATCH_INTERVAL)
        return 0 if self.stop_share(d) else 1

    def list(self) -> int:
        dirs = sorted(p for p in self.root.iterdir() if p.is_dir()) if self.root.is_dir() else []
        for d in dirs:
            if self.in_progress(d):
                print("\t".join([read(d / "file"), "pending", "-", "-", "pending"]))
                continue
            alive = self.live(d)
            expires = read(d / "expires")
            print("\t".join([
                read(d / "file"), read(d / "url") or "pending", read(d / "started") or "-",
                utc(int(expires)) if expires else "-", "alive" if alive else "dead"]))
            if not alive:
                self.stop_share(d)
        if not dirs:
            print("no shares")
        return 0

    def stop(self, target: str) -> int:
        key = target.rstrip("/") if target == "all" or target.startswith("https://") else str(self.dir_for(target))
        found, failed = False, False
        dirs = sorted(p for p in self.root.iterdir() if p.is_dir()) if self.root.is_dir() else []
        for d in dirs:
            if key in ("all", str(d), read(d / "url").rstrip("/")):
                found = True
                if self.stop_share(d):
                    print(f"stopped: {d}")
                else:
                    failed = True
        if not found:
            print("no matching shares")
        return 1 if failed else 0


def read(p: Path) -> str:
    return p.read_text().strip() if p.is_file() else ""


def usage() -> int:
    err("usage: share.py [--ttl 90m|24h|2d] FILE.html | list | stop FILE|URL|all")
    return 2


def main(argv: list[str]) -> int:
    if argv == ["--test"]:
        return run_tests()
    os.umask(0o077)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    shares = Shares(Runner(), Clock(), ROOT, dict(os.environ))
    if Runner().run(["ps", "-p", str(os.getpid())]).returncode != 0:
        err("process inspection unavailable; cannot manage shares safely")
        return 1
    try:
        if argv == ["list"]:
            return shares.list()
        if len(argv) == 2 and argv[0] == "stop":
            return shares.stop(argv[1])
        if len(argv) == 2 and argv[0] == "watch":
            return shares.watch(Path(argv[1]))
        if len(argv) == 3 and argv[0] == "--ttl":
            return shares.share(argv[2], argv[1])
        if len(argv) == 1 and not argv[0].startswith("-"):
            return shares.share(argv[0], "24h")
        return usage()
    except KeyboardInterrupt:
        return 130


def run_tests() -> int:
    import contextlib
    import io
    import tempfile
    import unittest
    import unittest.mock

    class FakeClock(Clock):
        def __init__(self) -> None:
            self.t = 1_800_000_000.0
            self.on_sleep: Callable[[], None] | None = None

        def now(self) -> float:
            return self.t

        def sleep(self, seconds: float) -> None:
            self.t += seconds
            if self.on_sleep:
                self.on_sleep()

    class FakeRunner(Runner):
        def __init__(self) -> None:
            self.procs: dict[int, list[str]] = {}
            self.dead: set[int] = set()
            self.next_pid = 90000
            self.overlay = ""
            self.answers: list[str] = []
            self.on_pending: Callable[[], None] | None = None
            self.calls: list[list[str]] = []
            self.clipboard = ""
            self.show_rc = 0
            self.cancel_raises = False
            self.hide_identity = False
            self.alias: tuple[str, str] | None = None
            self.registers = True
            self.ask_error = ""
            self.self_pid = os.getpid()

        def spawn(self, argv: list[str], log: Path) -> int:
            self.next_pid += 1
            self.procs[self.next_pid] = argv
            if "http.server" in argv:
                log.write_text("Serving HTTP on 127.0.0.1 port 5555 (http://127.0.0.1:5555/) ...\n")
            if "tunnel" in argv and "--logfile" in argv and self.registers:
                Path(argv[argv.index("--logfile") + 1]).write_text('{"message":"Registered tunnel connection"}\n')
            return self.next_pid

        def signal(self, pid: int, sig: int) -> None:
            assert pid in self.procs, f"signal to a pid the fake never started: {pid}"
            self.dead.add(pid)

        def alive(self, pid: int) -> bool:
            return pid in self.procs and pid not in self.dead

        def run(self, argv: list[str], stdin: str | None = None) -> Result[str]:
            self.calls.append(argv)
            out, rc = "", 0
            if argv[0] == "ps":
                pid = int(argv[3])
                if pid in self.procs and pid not in self.dead:
                    shown = ["python3", "unrelated"] if self.hide_identity else self.procs[pid]
                    out = "Mon Sep 28 10:00:00 2026 " + " ".join(shown)
                elif pid == self.self_pid:
                    out = "Mon Sep 28 09:00:00 2026 python3 share.py"
                else:
                    rc = 1
            elif argv[0] == "pbcopy":
                self.clipboard = stdin or ""
            elif argv[0] == str(SHOW):
                rc = self.show_rc
                if rc == 0:
                    self.overlay = argv[1]
            elif argv[0] == AGTERMCTL:
                if argv[1:3] == ["ask", "open"] and self.ask_error:
                    return Result(argv, 1, "", f"error: {self.ask_error}\n")
                out, rc = self.ctl(argv[1:])
            return Result(argv, rc, out, "")

        def ctl(self, args: list[str]) -> tuple[str, int]:
            if args[:2] == ["tree", "--json"]:
                shown = self.overlay.replace(*self.alias, 1) if self.alias else self.overlay
                pages = [{"file": shown, "state": "loaded"}] if shown else []
                return json.dumps({"windows": [{"sessions": [{"id": "S1", "htmlOverlays": pages}]}]}), 0
            if args[:3] == ["session", "overlay", "close"]:
                self.overlay = ""
                return "ok", 0
            if args[:2] == ["ask", "open"]:
                return '{"id":"ask-1"}', 0
            if args[:2] == ["ask", "result"]:
                answer = self.answers.pop(0) if self.answers else "pending"
                if answer == "pending":
                    if self.on_pending:
                        hook, self.on_pending = self.on_pending, None
                        hook()
                    return '{"result":"pending"}', 1
                if answer == "garbage":
                    return "unknown ask: ask-1", 1
                return json.dumps({"result": "answered", "id": answer}), 0
            if args[:2] == ["ask", "cancel"]:
                if self.cancel_raises:
                    raise OSError("socket gone")
                return "ok", 0
            return "", 0

        def cancelled(self) -> bool:
            return any(c[1:3] == ["ask", "cancel"] for c in self.calls if c[0] == AGTERMCTL)

        def asked(self) -> bool:
            return any(c[1:3] == ["ask", "open"] for c in self.calls if c[0] == AGTERMCTL)

    class ShareTest(unittest.TestCase):
        def setUp(self) -> None:
            self.tmp = tempfile.TemporaryDirectory()
            base = Path(self.tmp.name).resolve()
            self.page = base / "page.html"
            self.page.write_text("<p>v1</p>")
            self.runner, self.clock = FakeRunner(), FakeClock()
            self.runner.overlay = str(self.page)
            self.creds = base / "tunnel.json"
            self.creds.write_text('{"AccountTag":"a","TunnelID":"tid-1","TunnelSecret":"s"}')
            env = {"AGTERM_ENABLED": "1", "AGTERM_SESSION_ID": "S1", "AGDOC_SHARE_CREDENTIALS": str(self.creds),
                   "AGDOC_SHARE_HOST": "share.example.com"}
            self.shares = Shares(self.runner, self.clock, base / "root", env)
            self.hub = self.shares.hub
            self.d = self.shares.dir_for(str(self.page))
            self.cloudflared = contextlib.ExitStack()
            self.cloudflared.enter_context(unittest.mock.patch.object(os, "access", return_value=True))

        def tearDown(self) -> None:
            self.cloudflared.close()
            self.tmp.cleanup()

        def share(self, ttl: str = "24h") -> tuple[int, str]:
            out = io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
                rc = self.shares.share(str(self.page), ttl)
            return rc, out.getvalue().strip()

        def publish(self) -> str:
            self.runner.answers = ["publish"]
            rc, url = self.share()
            self.assertEqual(0, rc)
            return url

        def hub_pids(self) -> list[int]:
            return [int((self.hub / f"{n}.pid").read_text()) for n in ("server", "tunnel")]

        def tunnels(self) -> list[list[str]]:
            return [argv for argv in self.runner.procs.values() if "tunnel" in argv]

        def test_outside_agterm_refused(self) -> None:
            self.shares.env = {}
            self.assertEqual(1, self.share()[0])
            self.assertFalse(self.d.exists())
            self.assertFalse(self.runner.asked())

        def test_new_share_cancelled_leaves_nothing(self) -> None:
            self.runner.answers = ["cancel"]
            self.assertEqual(1, self.share()[0])
            self.assertFalse(self.d.exists())
            self.assertEqual(str(self.page), self.runner.overlay)
            self.assertFalse(self.runner.cancelled())

        def test_pending_approval_publishes_nothing(self) -> None:
            seen: dict[str, object] = {}

            def inspect() -> None:
                seen["overlay"] = self.runner.overlay
                seen["web"] = sorted(p.name for p in (self.d / "web").iterdir())
                seen["stage"] = (self.d / f"stage-{os.getpid()}.html").is_file()
                seen["tunnel"] = (self.hub / "tunnel.pid").exists()

            self.runner.on_pending = inspect
            self.runner.answers = ["pending", "publish"]
            rc, url = self.share()
            self.assertEqual(0, rc)
            self.assertEqual({"overlay": str(self.d / f"stage-{os.getpid()}.html"), "web": [], "stage": True, "tunnel": False}, seen)
            self.assertEqual(f"https://share.example.com/{(self.d / 'token').read_text().strip()}/", url)
            self.assertEqual(url, self.runner.clipboard)

        def test_publish_serves_snapshot_and_restores_overlay(self) -> None:
            self.publish()
            index = self.d / "web" / "index.html"
            self.assertFalse(index.is_symlink())
            self.assertEqual("<p>v1</p>", index.read_text())
            self.assertFalse((self.d / f"stage-{os.getpid()}.html").exists())
            self.assertEqual(str(self.page), self.runner.overlay)
            self.assertTrue(self.shares.live(self.d))
            self.assertEqual(int(self.clock.now()) // 10, (self.shares.expires(self.d) - 86400) // 10)

        def test_publish_restores_overlay_reported_through_symlink(self) -> None:
            # agterm reported /tmp/... for a stage under /private/tmp/..., so the dead stage stayed shown
            link = Path(self.tmp.name).resolve().parent / f"{Path(self.tmp.name).name}-alias"
            link.symlink_to(Path(self.tmp.name).resolve())
            self.addCleanup(link.unlink)
            self.runner.alias = (str(Path(self.tmp.name).resolve()), str(link))
            self.publish()
            self.assertEqual(self.page, Path(self.runner.overlay).resolve())

        def test_source_edit_after_publish_not_served(self) -> None:
            self.publish()
            self.page.write_text("<p>v2</p>")
            self.assertEqual("<p>v1</p>", (self.d / "web" / "index.html").read_text())

        def test_interrupt_while_pending_cancels_and_cleans(self) -> None:
            def interrupt() -> None:
                raise KeyboardInterrupt

            self.runner.on_pending = interrupt
            with self.assertRaises(KeyboardInterrupt):
                self.share()
            self.assertTrue(self.runner.cancelled())
            self.assertFalse(self.d.exists())
            self.assertEqual(str(self.page), self.runner.overlay)

        def test_poll_error_keeps_question_pending_until_cancel(self) -> None:
            def interrupt() -> None:
                raise KeyboardInterrupt

            self.runner.answers = ["garbage", "pending"]
            self.runner.on_pending = interrupt
            with self.assertRaises(KeyboardInterrupt):
                self.share()
            self.assertTrue(self.runner.cancelled())

        def test_cleanup_continues_when_cancel_fails(self) -> None:
            self.runner.cancel_raises = True
            self.runner.answers = []
            self.assertEqual(1, self.share()[0])
            self.assertEqual(str(self.page), self.runner.overlay)
            self.assertFalse(self.d.exists())

        def test_approval_timeout_cancels_question(self) -> None:
            start = self.clock.now()
            self.assertEqual(1, self.share()[0])
            self.assertTrue(self.runner.cancelled())
            self.assertGreaterEqual(self.clock.now() - start, APPROVAL_WAIT)
            self.assertFalse(self.d.exists())

        def test_preview_failure_is_not_approval(self) -> None:
            self.runner.show_rc = 1
            self.assertEqual(1, self.share()[0])
            self.assertFalse(self.runner.asked())
            self.assertFalse(self.d.exists())

        def test_update_cancel_keeps_old_bytes_and_processes(self) -> None:
            self.publish()
            self.page.write_text("<p>v2</p>")
            self.runner.answers = ["cancel"]
            self.assertEqual(1, self.share()[0])
            self.assertEqual("<p>v1</p>", (self.d / "web" / "index.html").read_text())
            self.assertFalse((self.d / f"stage-{os.getpid()}.html").exists())
            self.assertTrue(self.shares.live(self.d))

        def test_update_pending_stage_outside_web(self) -> None:
            self.publish()
            self.page.write_text("<p>v2</p>")
            seen: list[str] = []
            self.runner.on_pending = lambda: seen.extend(sorted(p.name for p in (self.d / "web").iterdir()))
            self.runner.answers = ["pending", "cancel"]
            self.share()
            self.assertEqual(["index.html"], seen)

        def test_update_publish_keeps_url_and_expiry(self) -> None:
            url = self.publish()
            expires = self.shares.expires(self.d)
            self.page.write_text("<p>v2</p>")
            self.clock.sleep(60)
            self.runner.answers = ["publish"]
            rc, again = self.share()
            self.assertEqual((0, url), (rc, again))
            self.assertEqual(expires, self.shares.expires(self.d))
            self.assertEqual("<p>v2</p>", (self.d / "web" / "index.html").read_text())

        def test_update_rechecks_deadline_before_rename(self) -> None:
            self.runner.answers = ["publish"]
            self.assertEqual(0, self.share("60s")[0])
            self.page.write_text("<p>v2</p>")
            self.runner.on_pending = lambda: self.clock.sleep(61)
            self.runner.answers = ["pending", "publish"]
            self.assertEqual(1, self.share()[0])
            self.assertTrue(self.runner.asked())
            self.assertEqual("<p>v1</p>", (self.d / "web" / "index.html").read_text())

        def test_identical_bytes_reuse_without_asking(self) -> None:
            url = self.publish()
            self.runner.calls.clear()
            self.assertEqual((0, url), self.share())
            self.assertFalse(self.runner.asked())

        def test_expired_share_is_not_reused(self) -> None:
            self.publish()
            old = [*self.hub_pids(), int((self.d / "expiry.pid").read_text())]
            (self.d / "expires").write_text("1\n")
            self.runner.answers = ["cancel"]
            self.assertEqual(1, self.share()[0])
            self.assertTrue(self.runner.asked())
            self.assertTrue(all(p in self.runner.dead for p in old))
            self.assertFalse(self.d.exists())
            self.assertFalse(self.hub.exists())

        def test_watch_stops_share_at_deadline(self) -> None:
            self.publish()
            pids = self.hub_pids()
            (self.d / "expiry.pid").write_text(f"{os.getpid()}\n")
            start = self.clock.now()
            self.assertEqual(0, self.shares.watch(self.d))
            self.assertGreaterEqual(self.clock.now(), start + 86400 - 1)
            self.assertLess(self.clock.now(), start + 86400 + WATCH_INTERVAL + 1)
            self.assertTrue(all(p in self.runner.dead for p in pids))
            self.assertFalse(self.d.exists())
            self.assertFalse(self.hub.exists())

        def test_short_ttl_counts_from_approval(self) -> None:
            self.runner.on_pending = lambda: self.clock.sleep(300)
            self.runner.answers = ["pending", "publish"]
            self.assertEqual(0, self.share("60s")[0])
            self.assertEqual(int(self.clock.now()) // 10, (self.shares.expires(self.d) - 60) // 10)

        def test_share_key_keeps_symlinked_name(self) -> None:
            link = self.page.parent / "link.html"
            link.symlink_to(self.page)
            self.assertEqual(str(link), share_key(str(link)))
            self.assertNotEqual(self.shares.dir_for(str(link)), self.d)

        def test_interrupt_during_startup_stops_unrecorded_process(self) -> None:
            # an interrupt before the identity was recorded left the tunnel running with its state deleted
            def interrupt() -> None:
                if any("tunnel" in argv for argv in self.runner.procs.values()):
                    self.clock.on_sleep = None
                    raise SystemExit(143)

            self.runner.answers = ["publish"]
            self.clock.on_sleep = interrupt
            with self.assertRaises(SystemExit):
                self.share()
            self.assertEqual(set(self.runner.procs), self.runner.dead)
            self.assertFalse(self.d.exists())

        def test_unidentified_process_is_stopped(self) -> None:
            self.runner.answers = ["publish"]
            self.runner.hide_identity = True
            self.assertEqual(1, self.share()[0])
            self.assertEqual(set(self.runner.procs), self.runner.dead)
            self.assertFalse(self.d.exists())

        def test_missing_credentials_refused_before_asking(self) -> None:
            self.creds.unlink()
            self.runner.answers = ["publish"]
            self.assertEqual(1, self.share()[0])
            self.assertFalse(self.runner.asked())
            self.assertFalse(self.d.exists())

        def test_missing_host_refused_before_asking(self) -> None:
            self.shares.host = ""
            self.runner.answers = ["publish"]
            self.assertEqual(1, self.share()[0])
            self.assertFalse(self.runner.asked())
            self.assertFalse(self.d.exists())

        def test_update_without_host_refused_before_asking(self) -> None:
            self.publish()
            self.page.write_text("<p>v2</p>")
            asks = len(self.runner.calls)
            self.shares.host = ""
            self.runner.answers = ["publish"]
            self.assertEqual(1, self.share()[0])
            self.assertFalse(any(c[1:3] == ["ask", "open"] for c in self.runner.calls[asks:] if c[0] == AGTERMCTL))
            self.assertEqual("<p>v1</p>", (self.d / "web" / "index.html").read_text())

        def test_list_keeps_share_awaiting_approval(self) -> None:
            seen: dict[str, object] = {}

            def list_while_pending() -> None:
                with contextlib.redirect_stdout(io.StringIO()) as out:
                    self.shares.list()
                seen["listed"] = out.getvalue()
                seen["stage"] = (self.d / f"stage-{os.getpid()}.html").is_file()

            self.runner.on_pending = list_while_pending
            self.runner.answers = ["pending", "publish"]
            self.assertEqual(0, self.share()[0])
            self.assertTrue(seen["stage"])
            self.assertIn("pending", str(seen["listed"]))

        def list_quietly(self) -> str:
            with contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(io.StringIO()):
                self.shares.list()
            return out.getvalue()

        def test_list_keeps_share_while_tunnel_starts(self) -> None:
            listed: list[str] = []
            hub_up = self.shares.hub_up

            def list_then_start(tunnel_id: str) -> bool:
                listed.append(self.list_quietly())
                return hub_up(tunnel_id)

            self.runner.answers = ["publish"]
            with unittest.mock.patch.object(self.shares, "hub_up", side_effect=list_then_start):
                rc, url = self.share()
            self.assertEqual(0, rc)
            self.assertTrue(url.startswith("https://share.example.com/"))
            self.assertIn("pending", listed[0])
            self.assertTrue(self.shares.live(self.d))

        def test_list_keeps_share_before_watcher_starts(self) -> None:
            listed: list[str] = []
            start = self.shares.start

            def list_then_watch(d: Path, name: str, argv: list[str]) -> None:
                if name == "expiry":
                    self.assertTrue((d / "url").is_file())
                    listed.append(self.list_quietly())
                start(d, name, argv)

            self.runner.answers = ["publish"]
            with unittest.mock.patch.object(self.shares, "start", side_effect=list_then_watch):
                self.assertEqual(0, self.share()[0])
            self.assertIn("pending", listed[0])
            self.assertTrue(self.shares.live(self.d))

        def test_list_cleans_pending_share_whose_owner_died(self) -> None:
            self.d.mkdir(parents=True)
            (self.d / "file").write_text(f"{self.page}\n")
            (self.d / "stage-424242.html").write_text("<p>v1</p>")
            (self.d / "owner.pid").write_text("424242\n")
            (self.d / "owner.identity").write_text("Mon Sep 28 08:00:00 2026 python3 share.py\n")
            self.list_quietly()
            self.assertFalse(self.d.exists())

        def test_dead_pending_share_does_not_keep_hub_up(self) -> None:
            self.publish()
            pids = self.hub_pids()
            orphan = self.shares.dir_for(str(self.page.parent / "orphan.html"))
            orphan.mkdir(parents=True)
            (orphan / "owner.pid").write_text("424242\n")
            (orphan / "owner.identity").write_text("Mon Sep 28 08:00:00 2026 python3 share.py\n")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(0, self.shares.stop(str(self.page)))
            self.assertTrue(all(p in self.runner.dead for p in pids))

        def test_second_share_refused_while_first_awaits_approval(self) -> None:
            seen: dict[str, int] = {}

            def share_from_other_session() -> None:
                with unittest.mock.patch.object(os, "getpid", return_value=424242):
                    seen["rc"] = self.share()[0]

            self.runner.on_pending = share_from_other_session
            self.runner.answers = ["pending", "publish"]
            self.assertEqual(0, self.share()[0])
            self.assertEqual(1, seen["rc"])
            self.assertTrue(self.shares.live(self.d))

        def test_overlapping_updates_serve_only_approved_bytes(self) -> None:
            self.publish()
            self.page.write_text("<p>v2</p>")
            seen: dict[str, int] = {}

            def update_from_other_session() -> None:
                self.page.write_text("<p>v3</p>")
                with unittest.mock.patch.object(os, "getpid", return_value=424242):
                    seen["rc"] = self.share()[0]

            self.runner.on_pending = update_from_other_session
            self.runner.answers = ["pending", "publish", "publish"]
            self.assertEqual(0, self.share()[0])
            self.assertEqual(0, seen["rc"])
            self.assertEqual("<p>v2</p>", (self.d / "web" / "index.html").read_text())

        def test_hidden_session_explains_approval_failure(self) -> None:
            self.runner.ask_error = "session not visible"
            out = io.StringIO()
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(out):
                self.assertEqual(1, self.shares.share(str(self.page), "24h"))
            self.assertIn("session not visible", out.getvalue())
            self.assertIn("switch to this session", out.getvalue())
            self.assertFalse(self.d.exists())

        def test_stop_works_without_host(self) -> None:
            self.publish()
            self.shares.host = ""
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(0, self.shares.stop(str(self.page)))
            self.assertFalse(self.d.exists())

        def test_tunnel_runs_named_tunnel_with_credentials(self) -> None:
            self.publish()
            argv = self.tunnels()[0]
            self.assertEqual(["run", "--credentials-file", str(self.creds), "tid-1"], argv[-4:])
            self.assertIn(str(self.hub / "config.yml"), argv)
            self.assertEqual("", (self.hub / "config.yml").read_text())

        def test_token_path_serves_snapshot_and_root_lists_nothing(self) -> None:
            url = self.publish()
            token = (self.d / "token").read_text().strip()
            self.assertGreaterEqual(len(token), 22)
            self.assertNotIn(self.d.name, url)
            self.assertEqual("<p>v1</p>", (self.hub / "public" / token / "index.html").read_text())
            self.assertEqual("", (self.hub / "public" / "index.html").read_text())
            self.assertEqual(url, self.runner.clipboard)

        def test_second_share_reuses_hub(self) -> None:
            first = self.publish()
            other = self.page.parent / "other.html"
            other.write_text("<p>other</p>")
            self.runner.answers = ["publish"]
            with contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(0, self.shares.share(str(other), "24h"))
            self.assertEqual(1, len(self.tunnels()))
            self.assertNotEqual(first, out.getvalue().strip())

        def test_hub_stops_only_after_last_share(self) -> None:
            self.publish()
            other = self.page.parent / "other.html"
            other.write_text("<p>other</p>")
            self.runner.answers = ["publish"]
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(0, self.shares.share(str(other), "24h"))
                token = (self.d / "token").read_text().strip()
                pids = self.hub_pids()
                self.assertEqual(0, self.shares.stop(str(self.page)))
                self.assertFalse((self.hub / "public" / token).exists())
                self.assertFalse(any(p in self.runner.dead for p in pids))
                self.assertTrue(self.shares.live(self.shares.dir_for(str(other))))
                self.assertEqual(0, self.shares.stop(str(other)))
            self.assertTrue(all(p in self.runner.dead for p in pids))
            self.assertFalse(self.hub.exists())

        def test_stop_by_url_without_trailing_slash(self) -> None:
            url = self.publish()
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(0, self.shares.stop(url.rstrip("/")))
            self.assertFalse(self.d.exists())

        def test_unregistered_tunnel_fails_and_cleans(self) -> None:
            self.runner.registers = False
            self.runner.answers = ["publish"]
            self.assertEqual(1, self.share()[0])
            self.assertEqual(set(self.runner.procs), self.runner.dead)
            self.assertFalse(self.d.exists())
            self.assertFalse(self.hub.exists())

        def test_hub_restart_keeps_links_of_live_shares(self) -> None:
            self.publish()
            token = (self.d / "token").read_text().strip()
            self.runner.dead.add(self.hub_pids()[1])
            other = self.page.parent / "other.html"
            other.write_text("<p>other</p>")
            self.runner.answers = ["publish"]
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(0, self.shares.share(str(other), "24h"))
            self.assertEqual(2, len(self.tunnels()))
            self.assertTrue((self.hub / "public" / token).is_symlink())
            self.assertTrue(self.shares.live(self.d))

        def test_hub_restart_ignores_previous_tunnel_log(self) -> None:
            self.publish()
            self.runner.dead.add(self.hub_pids()[1])
            self.runner.registers = False
            other = self.page.parent / "other.html"
            other.write_text("<p>other</p>")
            self.runner.answers = ["publish"]
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(1, self.shares.share(str(other), "24h"))
            self.assertFalse(self.shares.dir_for(str(other)).exists())
            self.assertTrue((self.hub / "public" / (self.d / "token").read_text().strip()).is_symlink())

        def test_share_expiring_during_hub_start_is_not_published(self) -> None:
            def slow_tunnel() -> None:
                if self.tunnels():
                    self.clock.on_sleep = None
                    self.clock.t += 5

            self.runner.answers = ["publish"]
            self.clock.on_sleep = slow_tunnel
            self.assertEqual(1, self.share("2s")[0])
            self.assertFalse(self.d.exists())
            self.assertFalse(self.hub.exists())
            self.assertFalse(any(self.hub.parent.glob(f"{self.hub.name}/public/*")))

        def test_non_html_file_refused(self) -> None:
            for name in ("notes.md", "page", "report.pdf"):
                f = self.page.parent / name
                f.write_text("x")
                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(2, self.shares.share(str(f), "24h"))
            self.assertFalse(self.runner.asked())
            self.assertFalse(self.shares.root.exists())

        def test_htm_file_accepted(self) -> None:
            self.page = self.page.with_name("page.htm")
            self.page.write_text("<p>v1</p>")
            self.runner.overlay = str(self.page)
            self.d = self.shares.dir_for(str(self.page))
            self.publish()

        def test_ttl_parsing(self) -> None:
            self.assertEqual([90, 5400, 86400, 172800, None, None, None],
                             [ttl_seconds(t) for t in ("90s", "90m", "24h", "2d", "0h", "5", "1w")])

    suite = unittest.TestLoader().loadTestsFromTestCase(ShareTest)
    return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
