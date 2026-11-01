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


def attach(nonce, rows, cols, claim, name=NAME, argv=("/bin/sh",)):
    pid, fd = pty.fork()
    if pid == 0:
        env = dict(os.environ, ZMX_DIR=ZDIR, ZMX_NO_DETACH_KEY="1", TERM="xterm-256color")
        env.pop("ZMX_SESSION", None)
        env.pop("ZMX_MANAGED", None)
        if nonce:
            env["ZMX_MANAGED"] = nonce
        if claim:
            env["ZMX_MANAGED_CLAIM"] = "1"
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


def cli(*args, stdin=None):
    env = dict(os.environ, ZMX_DIR=ZDIR)
    env.pop("ZMX_SESSION", None)
    return subprocess.run([ZMX, *args], env=env, input=stdin, capture_output=True, timeout=10)


def check(label, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + label + (" :: " + detail if detail and not ok else ""))
    return ok


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
                    red + b"ab\x1b[0m  \x1b[0m" + red + b"c\x1b[0m" in replay, repr(replay[-300:]))
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
    finally:
        cli("kill", NAME, "--force")
        for pid in pids:
            try:
                os.kill(pid, 9)
            except ProcessLookupError:
                pass
        shutil.rmtree(ZDIR, ignore_errors=True)
    print("RESULT", "ok" if ok else "FAILED")
    sys.exit(0 if ok else 1)


main()
