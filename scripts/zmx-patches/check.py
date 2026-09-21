#!/usr/bin/env python3
"""drive two managed zmx attach clients on ptys of different sizes against one daemon."""
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


def attach(nonce, rows, cols, claim):
    pid, fd = pty.fork()
    if pid == 0:
        env = dict(os.environ, ZMX_DIR=ZDIR, ZMX_MANAGED=nonce, ZMX_NO_DETACH_KEY="1", TERM="xterm-256color")
        env.pop("ZMX_SESSION", None)
        if claim:
            env["ZMX_MANAGED_CLAIM"] = "1"
        # before exec, so the client's Init reads this size and not the pty default
        fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        os.execve(ZMX, [ZMX, "attach", NAME, "/bin/sh"], env)
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
