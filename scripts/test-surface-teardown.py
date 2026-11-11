#!/usr/bin/env python3
"""Close busy and idle surfaces in disposable application instances."""

import argparse
import json
import os
import shlex
import signal
import subprocess
import tempfile
import time
from pathlib import Path

# a hang limit, not a latency bound: a loaded runner answers late; the patch's Zig tests pin the finite drain
HANG_LIMIT = 60
SNAPSHOT_LIMIT = 10


def app_pids():
    result = subprocess.run(["pgrep", "-x", "agterm"], capture_output=True, text=True, check=False)
    if result.returncode not in (0, 1):
        raise RuntimeError(result.stderr)
    return {int(pid) for pid in result.stdout.split()}


def stop_test_app(pid):
    result = subprocess.check_output(["ps", "-axo", "pid=,ppid="], text=True)
    children = {}
    for line in result.splitlines():
        child, parent = map(int, line.split())
        children.setdefault(parent, []).append(child)

    def stop_tree(parent):
        for child in children.get(parent, []):
            stop_tree(child)
        try:
            os.kill(parent, signal.SIGKILL)
        except ProcessLookupError:
            pass

    stop_tree(pid)


def snapshot(app_pid, case_dir, suffix):
    """Process, thread and load state at a hang, from probes that need no task port. Returns probe failures."""
    probes = {
        "ps": ["ps", "-axo", "pid,ppid,stat,pcpu,etime,comm"],
        "threads": ["ps", "-M", "-p", str(app_pid)],
        "loadavg": ["sysctl", "-n", "vm.loadavg"],
    }
    failures = {}
    for label, argv in probes.items():
        try:
            with (case_dir / f"{label}-{suffix}.txt").open("w") as out:
                subprocess.run(argv, stdout=out, stderr=subprocess.STDOUT, timeout=SNAPSHOT_LIMIT, check=False)
        except (subprocess.SubprocessError, OSError) as exc:
            failures[label] = str(exc)
    return failures


def wait_for(condition, what):
    deadline = time.monotonic() + HANG_LIMIT
    while not condition():
        if time.monotonic() >= deadline:
            raise RuntimeError(f"{what} within {HANG_LIMIT} s")
        time.sleep(0.1)


def run_case(app, evidence, count, busy):
    name = f"{'spam' if busy else 'idle'}-{count}"
    case_dir = evidence / name
    case_dir.mkdir(parents=True, exist_ok=True)
    state = Path(tempfile.mkdtemp(prefix="agclose-", dir="/tmp"))
    (state / "windows").mkdir()
    (state / "settings.json").write_text(json.dumps({"restoreMode": "none"}))
    # both commands outlive any setup delay, so the close always meets a running producer or sleeper
    producer = state / "producer.py"
    producer.write_text(
        "import sys\n"
        "while True:\n"
        " sys.stdout.write('\\x1b]0;title\\x07')\n"
        " sys.stdout.flush()\n"
    )
    origin = time.monotonic()
    result = {"status": "running", "timeline": {}, "calls": []}
    snapshot_taken = False

    def since(moment):
        return round(moment - origin, 3)

    def save():
        (case_dir / "result.json").write_text(json.dumps(result))

    before = app_pids()
    subprocess.run(
        ["open", "-n", "-a", str(app), "--env", f"AGTERM_STATE_DIR={state}"],
        check=True,
    )
    result["timeline"]["opened"] = since(time.monotonic())
    created = set()

    def launched():
        nonlocal created
        created = app_pids() - before
        return bool(created)

    wait_for(launched, "the isolated app did not start")
    if len(created) != 1:
        raise RuntimeError(f"Cannot identify isolated app: {created}")
    pid = created.pop()
    result["timeline"]["pid"] = since(time.monotonic())
    ctl = app / "Contents/MacOS/agtermctl"

    def call(op, *args):
        nonlocal snapshot_taken
        entry = {"op": op, "start": since(time.monotonic())}
        result["calls"].append(entry)
        begin = time.monotonic()
        proc = subprocess.Popen(
            [str(ctl), *args, "--socket", str(state / "agterm.sock"), "--json"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        try:
            out, err = proc.communicate(timeout=HANG_LIMIT)
        except subprocess.TimeoutExpired:
            entry.update(elapsed=round(time.monotonic() - begin, 3), outcome="timeout")
            snapshot_taken = True
            failures = snapshot(pid, case_dir, f"{len(result['calls']) - 1:02d}-{op}")
            if failures:
                entry["snapshot_errors"] = failures
            # reap without draining: a descendant holding the pipes would block EOF, as in subprocess.run
            proc.kill()
            proc.wait()
            proc.stdout.close()
            proc.stderr.close()
            raise subprocess.TimeoutExpired(proc.args, HANG_LIMIT) from None
        entry.update(elapsed=round(time.monotonic() - begin, 3), outcome="error" if proc.returncode else "ok")
        if proc.returncode:
            raise RuntimeError(err)
        return json.loads(out)["result"]

    def timings():
        return " ".join(f"{c['op']}={c.get('elapsed', '?')}" for c in result["calls"])

    try:
        wait_for((state / "agterm.sock").exists, "the control socket did not appear")
        result["timeline"]["socket"] = since(time.monotonic())
        result["version"] = call("version", "version")
        ids = []
        command = f"/usr/bin/python3 {shlex.quote(str(producer))}" if busy else "/bin/sleep 3600"
        for index in range(count):
            ids.append(call(f"new-{index}", "session", "new", "--name", f"{name}-{index}", "--command", command,
                            "--no-select")["id"])

        def realized():
            tree = call("tree", "tree")["tree"]
            sessions = [session for workspace in tree["workspaces"] for session in workspace["sessions"]]
            return all(any(s["id"] == sid and s.get("realized") for s in sessions) for sid in ids)

        wait_for(realized, "the test surfaces did not realize")
        result["timeline"]["realized"] = since(time.monotonic())
        time.sleep(1)
        call("close", "session", "close", "--target", ids[0])
        call("version-after", "version")
        result["status"] = "passed"
        print(f"PASS {name}: {timings()}", flush=True)
    except Exception as exc:
        result.update(status="failed", error=str(exc))
        if not snapshot_taken:
            failures = snapshot(pid, case_dir, "failure")
            if failures:
                result["snapshot_errors"] = failures
        print(f"calls {name}: {timings()}", flush=True)
        raise
    finally:
        save()
        stop_test_app(pid)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=True)
    failed = []
    for count, busy in [(1, True), (8, False)]:
        try:
            run_case(args.app.resolve(), args.evidence.resolve(), count, busy)
        except (subprocess.SubprocessError, OSError, RuntimeError, ValueError, LookupError) as exc:
            failed.append(str(exc))
            print(f"FAIL {'spam' if busy else 'idle'}-{count}: {exc}", flush=True)
    if failed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
