#!/usr/bin/env python3
"""drive managed zmx attach clients on ptys of different sizes against one daemon."""
import fcntl
import os
import pty
import re
import select
import shutil
import struct
import subprocess
import sys
import termios
import time

ZMX = sys.argv[1]
ZDIR = "/tmp/zmx-e2e-%d" % os.getpid()
NAME = "e2e"
ROLE = re.compile(rb"\x1b\]2;zmx-role;([A-Za-z0-9-]+):(\w+):(\d+)\x1b\\")


def attach(nonce, rows, cols, claim, name=NAME, argv=("/bin/sh",), reclaim=None):
    pid, fd = pty.fork()
    if pid == 0:
        env = dict(os.environ, ZMX_DIR=ZDIR, ZMX_NO_DETACH_KEY="1", TERM="xterm-256color")
        env.pop("ZMX_SESSION", None)
        env.pop("ZMX_MANAGED", None)
        if nonce:
            env["ZMX_MANAGED"] = nonce
        if claim:
            env["ZMX_MANAGED_CLAIM"] = "1"
        if reclaim:
            env["ZMX_MANAGED_RECLAIM"] = reclaim
        # before exec, so the client's Init reads this size and not the pty default
        fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        os.execve(ZMX, [ZMX, "attach", name, *argv], env)
    return pid, fd


def drain(fd, seconds):
    out = b""
    end = time.time() + seconds
    while time.time() < end:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            try:
                out += os.read(fd, 65536)
            except OSError:
                break
    return out


def reaped(pid, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        done, status = os.waitpid(pid, os.WNOHANG)
        if done == pid:
            return status
        time.sleep(0.02)
    return None


def cli(*args, stdin=None, extra=None, executable=ZMX):
    env = dict(os.environ, ZMX_DIR=ZDIR)
    env.pop("ZMX_SESSION", None)
    env.update(extra or {})
    return subprocess.run([executable, *args], env=env, input=stdin or b"", capture_output=True, timeout=10)


def listed(name):
    return name.encode() in cli("list", "--short").stdout.split()


def legacy_ipc(executable):
    """legacy_ipc is true for a zmx before 1.0, against whose daemon the new client refuses run, tail and write."""
    found = re.search(rb"zmx\s+(\d+)\.", cli("version", executable=executable).stdout)
    return found is not None and int(found.group(1)) < 1


def written(path, content):
    """written waits up to 5 s for path to hold content: `zmx write` has the session's shell write it."""
    deadline = time.time() + 5
    while time.time() < deadline:
        try:
            with open(path, "rb") as f:
                if f.read() == content:
                    return True
        except OSError:
            pass
        time.sleep(0.1)
    return False


def tail_prints(name, typed, marker):
    """tail_prints reports whether `zmx tail` on name prints marker after typed reaches the session, within 5 s."""
    env = dict(os.environ, ZMX_DIR=ZDIR)
    env.pop("ZMX_SESSION", None)
    proc = subprocess.Popen([ZMX, "tail", name], env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL)
    try:
        time.sleep(0.5)
        cli("type", name, stdin=typed)
        seen, deadline = b"", time.time() + 5
        while marker not in seen and time.time() < deadline:
            ready, _, _ = select.select([proc.stdout], [], [], 0.2)
            if ready:
                chunk = os.read(proc.stdout.fileno(), 4096)
                if not chunk:
                    break
                seen += chunk
        return marker in seen
    finally:
        proc.kill()
        proc.wait()


def check(label, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + label + (" :: " + detail if detail and not ok else ""))
    return ok


QUERY_PROBE = r"""
import os, re, select, sys, time, tty
size = os.get_terminal_size(0)
open(sys.argv[1], "w").close()
tty.setraw(0)
os.write(1, b"SIZE=%d,%d\r\n" % (size.lines, size.columns))
os.write(1, b"\x1b[6n\x1b]10;?\x1b\\\x1b]11;?\x1b\\")
want = [rb"\x1b\[\d+;\d+R", rb"\x1b\]10;rgb:[0-9a-f/]+\x1b\\", rb"\x1b\]11;rgb:[0-9a-f/]+\x1b\\"]
got, end = b"", time.time() + 3
while time.time() < end and not all(re.search(w, got) for w in want):
    if select.select([0], [], [], 0.1)[0]:
        got += os.read(0, 256)
os.write(1, b"REPLIES-OK\r\n" if all(re.search(w, got) for w in want) else b"REPLIES-MISSING\r\n")
time.sleep(0.5)
"""
QUERIES = (b"\x1b[6n", b"\x1b]10;?\x1b\\", b"\x1b]11;?\x1b\\")


def check_hold():
    ok = True
    marker = os.path.join(ZDIR, "held-ran")
    created = cli("attach", "--detached", "held", "/usr/bin/python3", "-c", QUERY_PROBE, marker,
                  extra={"ZMX_HOLD_UNTIL_ATTACH": "10"})
    time.sleep(1.0)
    ok &= check("a held create starts the daemon but not its command",
                created.returncode == 0 and listed("held") and not os.path.exists(marker), repr(created.stderr))
    pid, fd = attach("held-1", 30, 83, claim=False, name="held")
    try:
        out, end = b"", time.time() + 5
        while time.time() < end and not all(q in out for q in QUERIES):
            out += drain(fd, 0.1)
        queried = all(q in out for q in QUERIES)
        if queried:
            os.write(fd, b"\x1b[1;1R\x1b]10;rgb:ffff/ffff/ffff\x1b\\\x1b]11;rgb:3030/3030/3030\x1b\\")
        out += drain(fd, 2.0)
        ok &= check("the first attach releases it at its own size and answers the queries it writes at exec",
                    os.path.exists(marker) and queried and b"SIZE=30,83" in out and b"REPLIES-OK" in out,
                    repr(out[-300:]))
    finally:
        os.close(fd)
        os.kill(pid, 9)
        os.waitpid(pid, 0)

    timed = os.path.join(ZDIR, "timed-ran")
    cli("attach", "--detached", "timed", "/bin/sh", "-c", "touch %s; sleep 30" % timed,
        extra={"ZMX_HOLD_UNTIL_ATTACH": "1"})
    time.sleep(2.0)
    ok &= check("a hold nobody attaches to releases at its bound", os.path.exists(timed))

    killed = os.path.join(ZDIR, "held-killed-ran")
    created = cli("attach", "--detached", "held-killed", "/bin/sh", "-c", "touch %s" % killed,
                  extra={"ZMX_HOLD_UNTIL_ATTACH": "1"})
    was_listed = listed("held-killed")
    stopped = cli("kill", "held-killed", "--force")
    time.sleep(1.5)
    ok &= check("a kill while held ends the session before its command runs",
                created.returncode == 0 and was_listed and stopped.returncode == 0
                and not listed("held-killed") and not os.path.exists(killed),
                repr((created.stderr, stopped.stderr)))

    bad = cli("attach", "--detached", "held-bad", "/bin/sh", extra={"ZMX_HOLD_UNTIL_ATTACH": "0"})
    ok &= check("a hold of zero seconds is refused", bad.returncode != 0 and not listed("held-bad"), repr(bad.stderr))
    return ok


def check_upgrade(previous):
    name = "upgrade"
    created = cli("attach", "--detached", name, "/bin/sh", executable=previous)
    if not check("the previous zmx starts a detached daemon", created.returncode == 0, repr(created.stderr)):
        return False

    attached = []
    try:
        ok = check("the new zmx lists the previous daemon", listed(name))
        held = attach("upgrade-held", 32, 88, claim=True, name=name)
        attached.append(held)
        roles = ROLE.findall(drain(held[1], 2.0))
        ok &= check("the new client claims leadership on the previous daemon",
                    bool(roles) and roles[-1][:2] == (b"upgrade-held", b"leader"), repr(roles))
        back = attach("upgrade-back", 30, 90, claim=False, name=name, reclaim="upgrade-held")
        attached.append(back)
        roles = ROLE.findall(drain(back[1], 2.0))
        ok &= check("a reconnect takes back the lead its dropped attach holds on the previous daemon",
                    bool(roles) and roles[-1][:2] == (b"upgrade-back", b"leader"), repr(roles))
        marker = b"OLD-DAEMON-OUTPUT"
        typed = cli("type", name, stdin=b"printf 'OLD-%s-OUTPUT\\n' DAEMON\r")
        ok &= check("the new client types into the previous daemon",
                    typed.returncode == 0 and marker in drain(back[1], 1.0), repr(typed.stderr))
        screen = cli("screen", name)
        ok &= check("the new client reads the previous daemon's grid and screen",
                    screen.stdout.split(b"\n", 1)[0].split()[1:3] == [b"90", b"30"]
                    and marker in screen.stdout, repr(screen.stdout))
        printed = cli("print", name, stdin=b"OLD-DAEMON-PRINT")
        ok &= check("the new client prints to the previous daemon's clients",
                    printed.returncode == 0 and b"OLD-DAEMON-PRINT" in drain(back[1], 1.0), repr(printed.stderr))
        target = os.path.join(ZDIR, "upgrade-write")
        if legacy_ipc(previous):
            ran, tailed = cli("run", name, "true"), cli("tail", name)
            ok &= check("the new client refuses to run or tail through the previous daemon",
                        ran.returncode != 0 and b"does not support run" in ran.stderr
                        and tailed.returncode != 0 and b"does not support tail" in tailed.stderr,
                        repr((ran.stderr, tailed.stderr)))
            wrote = cli("write", name, target, stdin=b"OLD-DAEMON-WRITE")
            ok &= check("the new client refuses to write through the previous daemon",
                        wrote.returncode != 0 and b"does not support write" in wrote.stderr, repr(wrote.stderr))
        else:
            ran = cli("run", name, "sh", "-c", "exit 7")
            ok &= check("the new client runs a task through the previous daemon and gets its code",
                        ran.returncode == 7, repr((ran.returncode, ran.stderr)))
            followed = tail_prints(name, b"printf 'OLD-%s-TAIL\\n' DAEMON\r", b"OLD-DAEMON-TAIL")
            ok &= check("the new client tails the previous daemon's new output", followed)
            wrote = cli("write", name, target, stdin=b"OLD-DAEMON-WRITE")
            ok &= check("the new client writes through the previous daemon",
                        wrote.returncode == 0 and written(target, b"OLD-DAEMON-WRITE"), repr(wrote.stderr))
        killed = cli("kill", name)
        ok &= check("the new client kills the previous daemon",
                    killed.returncode == 0 and b"name=" + name.encode() not in cli("list").stdout, repr(killed.stderr))
        return ok
    finally:
        cli("kill", name, executable=previous)
        for pid, fd in attached:
            os.close(fd)
            try:
                os.kill(pid, 9)
            except ProcessLookupError:
                pass
            os.waitpid(pid, 0)

def main():
    os.makedirs(ZDIR, mode=0o700)
    ok = True
    pids = []
    try:
        p1, f1 = attach("origin-1", 30, 83, claim=False)
        pids.append(p1)
        out1 = drain(f1, 2.0)
        roles1 = ROLE.findall(out1)
        ok &= check("first attach is told it leads", bool(roles1) and roles1[-1][:2] == (b"origin-1", b"leader"), repr(roles1))

        screen = cli("screen", NAME).stdout.split(b"\n", 1)[0].split()
        ok &= check("pty has the first client's grid", screen[1:3] == [b"83", b"30"], repr(screen))

        p2, f2 = attach("viewer-2", 40, 120, claim=True)
        pids.append(p2)
        out2 = drain(f2, 2.0)
        roles2 = ROLE.findall(out2)
        ok &= check("claiming attach is told it leads", bool(roles2) and roles2[-1][:2] == (b"viewer-2", b"leader"), repr(roles2))
        demoted = ROLE.findall(drain(f1, 1.0))
        ok &= check("the old leader is told it follows", bool(demoted) and demoted[-1][:2] == (b"origin-1", b"follower"), repr(demoted))

        screen = cli("screen", NAME).stdout.split(b"\n", 1)[0].split()
        ok &= check("pty took the claimer's grid", screen[1:3] == [b"120", b"40"], repr(screen))

        os.write(f1, b"echo FROM-FOLLOWER\r")
        time.sleep(0.7)
        text = cli("screen", NAME).stdout
        ok &= check("a follower's typing is dropped", b"FROM-FOLLOWER" not in text, repr(text[-200:]))
        screen = text.split(b"\n", 1)[0].split()
        ok &= check("and does not take the grid back", screen[1:3] == [b"120", b"40"], repr(screen))

        typed = cli("type", NAME, stdin=b"echo VIA-TYPE\r")
        time.sleep(0.7)
        text = cli("screen", NAME).stdout
        ok &= check("type is accepted and runs", typed.returncode == 0 and text.count(b"VIA-TYPE") >= 2, repr(text[-200:]))
        header = text.split(b"\n", 1)[0].split()
        ok &= check("screen header carries six fields", len(header) == 6, repr(header))
        nl = cli("type", NAME, stdin=b"\r")
        ok &= check("a bare carriage return is accepted", nl.returncode == 0, repr(nl.stderr))
        empty = cli("type", NAME, stdin=b"")
        ok &= check("empty input is refused", empty.returncode != 0)

        env_leak = cli("type", NAME, stdin=b"echo M=[$ZMX_MANAGED]\r")
        time.sleep(0.7)
        text = cli("screen", NAME).stdout
        ok &= check("the opt-in variable does not reach the shell", env_leak.returncode == 0 and b"M=[]" in text, repr(text[-200:]))

        os.kill(p2, 15)
        time.sleep(1.0)
        orphaned = ROLE.findall(drain(f1, 1.0))
        ok &= check("the leader leaving reports unowned", bool(orphaned) and orphaned[-1][1] == b"unowned", repr(orphaned))

        def role_of(fd, nonce):
            found = [r for r in ROLE.findall(drain(fd, 1.5)) if r[0] == nonce.encode()]
            return found[-1][1] if found else None

        def joined(nonce, claim=False, reclaim=None):
            pid, fd = attach(nonce, 30, 83, claim=claim, name="reclaim", reclaim=reclaim)
            pids.append(pid)
            return pid, fd

        _, o1 = joined("rc-origin")
        role_of(o1, "rc-origin")
        dropped, _ = joined("rc-v1", claim=True)
        time.sleep(1.0)
        _, v2 = joined("rc-v2", reclaim="rc-v1")
        ok &= check("a reconnect takes back the lead its dropped attach holds", role_of(v2, "rc-v2") == b"leader")
        _, stranger = joined("rc-x", reclaim="rc-nobody")
        ok &= check("naming another attach takes nothing", role_of(stranger, "rc-x") == b"follower")

        for pid in (dropped, pids[-2]):
            os.kill(pid, 15)
        time.sleep(1.0)
        _, fallback = joined("rc-origin-2")
        ok &= check("a vacant pane goes to the next attach", role_of(fallback, "rc-origin-2") == b"leader")
        _, v3 = joined("rc-v3", reclaim="rc-v2")
        ok &= check("a reconnect takes back a lead an unused attach filled", role_of(v3, "rc-v3") == b"leader")

        os.kill(pids[-1], 15)
        time.sleep(1.0)
        _, used = joined("rc-origin-3")
        ok &= check("the pane is vacant again for the next attach", role_of(used, "rc-origin-3") == b"leader")
        os.write(used, b"\x03")
        time.sleep(0.7)
        _, v4 = joined("rc-v4", reclaim="rc-v3")
        ok &= check("an attach that only got a Ctrl-C keeps the lead", role_of(v4, "rc-v4") == b"follower")

        missing = cli("screen", "no-such-session")
        ok &= check("screen on a missing session fails", missing.returncode != 0)

        # a re-attach replayed a cursor-skipped gap under the previous cell's style
        cli("type", NAME, stdin=b"clear; printf '\\033[41mab\\033[5Gc\\033[0m\\n\\033[41mab  c\\033[0m\\n'\r")
        time.sleep(0.7)
        p3, f3 = attach("viewer-3", 40, 120, claim=False)
        pids.append(p3)
        replay = drain(f3, 2.0)
        red = b"\x1b[48;5;1m"
        ok &= check("a replayed gap the program skipped is unstyled and the run resumes after it",
                    red + b"ab\x1b[2Cc\x1b[0m" in replay, repr(replay[-300:]))
        ok &= check("replayed spaces the program wrote keep their style",
                    red + b"ab  c\x1b[0m" in replay, repr(replay[-300:]))

        ending = ("/bin/sh", "-c", "sleep 0.5; printf '\\033[?1000hEXIT-MARK\\n'; sleep 0.5")
        p4, f4 = attach("exit-4", 30, 83, claim=False, name="exit-managed", argv=ending)
        pids.append(p4)
        tail = drain(f4, 3.0).rpartition(b"EXIT-MARK")[2]
        ok &= check("a managed client whose session ends leaves the screen and turns reporting off",
                    b"\x1bc" not in tail and b"\x1b[?9l" in tail and b"\x1b[?1000l" in tail, repr(tail))
        p5, f5 = attach(None, 30, 83, claim=False, name="exit-plain", argv=ending)
        pids.append(p5)
        tail = drain(f5, 3.0).rpartition(b"EXIT-MARK")[2]
        ok &= check("an unmanaged client whose session ends still resets the terminal", b"\x1bc" in tail, repr(tail))

        record = os.path.join(ZDIR, "exit-record")
        created = cli("attach", "--detached", "detached", "/bin/sh", "-c", "sleep 0.5; exit 7",
                      extra={"ZMX_EXIT_FILE": record})
        ok &= check("a detached create needs no tty", created.returncode == 0 and listed("detached"), repr(created.stderr))
        again = cli("attach", "--detached", "detached", "/bin/sh")
        ok &= check("a detached create of a live session is refused", again.returncode == 1, repr(again.stderr))
        gone_without_record = False
        deadline = time.time() + 5
        while time.time() < deadline:
            present = listed("detached")
            if not present and not os.path.exists(record):
                gone_without_record = True
            if not present:
                break
            time.sleep(0.02)
        ok &= check("a session that exited is never gone before its record", not gone_without_record)
        status = open(record).read().strip() if os.path.exists(record) else None
        ok &= check("the record marks an exit", status == "exited", repr(status))

        worker_pid = os.path.join(ZDIR, "worker-pid")
        spawn = ("trap '' HUP; (trap '' HUP; exec sleep 300) </dev/null >/dev/null 2>&1 & "
                 "echo $! > %s; sleep 0.3; exit 0" % worker_pid)
        cli("attach", "--detached", "worker", "/bin/sh", "-c", spawn,
            extra={"ZMX_EXIT_FILE": os.path.join(ZDIR, "worker-record")})
        deadline = time.time() + 5
        while time.time() < deadline and listed("worker"):
            time.sleep(0.05)
        time.sleep(1.0)
        pid = int(open(worker_pid).read()) if os.path.exists(worker_pid) else None
        alive = False
        if pid:
            try:
                os.kill(pid, 0)
                alive = True
            except ProcessLookupError:
                pass
        ok &= check("an exited shell's hangup-ignoring background worker is ended with the session",
                    pid is not None and not alive and os.path.exists(os.path.join(ZDIR, "worker-record")), repr(pid))

        cli("attach", "--detached", "env-probe", "/bin/sh", "-c", "printf 'E=[%s]' \"$ZMX_EXIT_FILE\"; sleep 30",
            extra={"ZMX_EXIT_FILE": os.path.join(ZDIR, "env-record")})
        time.sleep(0.7)
        text = cli("screen", "env-probe").stdout
        ok &= check("the record path does not reach the shell", b"E=[]" in text, repr(text[-200:]))
        ok &= check_hold()

        killed_record = os.path.join(ZDIR, "killed-record")
        cli("attach", "--detached", "killed", "/bin/sh", "-c", "sleep 30", extra={"ZMX_EXIT_FILE": killed_record})
        cli("kill", "killed", "--force")
        time.sleep(1.0)
        ok &= check("a killed session writes no record", not listed("killed") and not os.path.exists(killed_record))
        cli("attach", "--detached", "busy", "yes")
        time.sleep(0.5)
        probes = [(listed("busy"), cli("screen", "busy").returncode) for _ in range(5)]
        ok &= check("a session streaming output is listed and answers", all(p == (True, 0) for p in probes), repr(probes))
        # zmx 0.8.1 misreads a busy session's stream, so the upgrade case must not share a directory with it
        cli("kill", "busy", "--force")
        ran = cli("run", "task", "sh", "-c", "echo TASK-OUT; exit 3")
        env = dict(os.environ, ZMX_DIR=ZDIR)
        env.pop("ZMX_SESSION", None)
        tailer = subprocess.Popen([ZMX, "tail", "task"], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(0.3)
        cli("run", "task", "echo", "TAIL-OUT")
        try:
            tailed, _ = tailer.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            tailer.kill()
            tailed, _ = tailer.communicate()
        ok &= check("run returns a task's code and output and tail follows it on a current daemon",
                    ran.returncode == 3 and b"TASK-OUT" in ran.stdout and tailer.returncode == 0 and b"TAIL-OUT" in tailed,
                    repr((ran.returncode, ran.stdout[-120:], ran.stderr[-120:], tailer.returncode, tailed[-120:])))
        term_pid, term_fd = attach("sigterm", 24, 80, claim=True, name="sigterm")
        pids.append(term_pid)
        roles = ROLE.findall(drain(term_fd, 1.0))
        printed = cli("print", "sigterm", stdin=b"x" * 200)
        time.sleep(0.3)
        os.kill(term_pid, 15)
        status = reaped(term_pid, 2)
        ok &= check("a SIGTERMed client exits while nobody reads its terminal",
                    bool(roles) and roles[-1][:2] == (b"sigterm", b"leader") and printed.returncode == 0
                    and status is not None and os.WIFSIGNALED(status) and os.WTERMSIG(status) == 15,
                    repr((roles[-1:], printed.returncode, status)))
        os.close(term_fd)
        if status is not None or reaped(term_pid, 2) is not None:
            pids.remove(term_pid)
        if len(sys.argv) > 2:
            ok &= check_upgrade(sys.argv[2])
    finally:
        cli("kill", NAME, "reclaim", "detached", "killed", "env-probe", "sigterm", "busy", "task", "held", "timed",
            "held-killed", "--force")
        for pid in pids:
            try:
                os.kill(pid, 9)
            except ProcessLookupError:
                pass
        shutil.rmtree(ZDIR, ignore_errors=True)
    print("RESULT", "ok" if ok else "FAILED")
    sys.exit(0 if ok else 1)


main()
