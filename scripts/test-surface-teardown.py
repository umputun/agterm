#!/usr/bin/env python3
"""Close busy and idle surfaces in disposable application instances."""

import argparse
import json
import os
import shlex
import signal
import subprocess
import tempfile
import threading
import time
from pathlib import Path

CALL_LIMIT = 5
SLOW_CALL = 3
SAMPLE_LIMIT = 20
SPINDUMP_LIMIT = 15


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


class Collector:
    """A stack collector run in the background, stopped `limit` seconds after it starts and reaped by finish."""

    def __init__(self, label, argv, path, limit, privileged=False):
        self.label, self.limit, self.privileged = label, limit, privileged
        self.error = None
        self.expired = False
        self.leftover = None
        self.cleaned = threading.Event()
        self.stderr = Path(f"{path}.err")
        try:
            with self.stderr.open("w") as err:
                # its own process group, so a hard stop reaches a child sudo started, not only sudo itself
                self.proc = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=err, start_new_session=True)
        except OSError as exc:
            self.proc, self.error = None, str(exc)
            return
        self.timer = threading.Timer(limit, self.expire)
        self.timer.daemon = True
        self.timer.start()

    def expire(self):
        if self.proc.poll() is not None:
            return
        self.expired = True
        try:
            self.stop()
        finally:
            self.cleaned.set()

    def stop(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        group = self.proc.pid
        if self.privileged:
            subprocess.run(["sudo", "-n", "kill", "-KILL", "--", f"-{group}"], capture_output=True, timeout=5, check=False)
        else:
            try:
                os.killpg(group, signal.SIGKILL)
            except ProcessLookupError:
                pass
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        alive = subprocess.run(["pgrep", "-g", str(group)], capture_output=True, text=True, check=False).stdout.split()
        if alive:
            self.leftover = f"group {group} still has {', '.join(alive)}"

    def finish(self):
        """Reap the collector; returns its failure, or None when it wrote its file."""
        if self.proc is None:
            return self.error
        try:
            self.proc.wait(timeout=self.limit + 20)
        except subprocess.TimeoutExpired:
            pass
        self.timer.cancel()
        # a TERM can end the launcher while expire is still killing the group, so wait for its cleanup too
        cleaned = self.cleaned.wait(timeout=20) if self.expired else True
        detail = self.stderr.read_text().strip()
        self.stderr.unlink()
        if not cleaned:
            return f"{self.label} timed out after {self.limit} seconds; cleanup did not finish within 20 s"
        if self.proc.poll() is None:
            return f"{self.label} still running as pid {self.proc.pid} after cleanup"
        if self.expired:
            suffix = f"; {self.leftover}" if self.leftover else ""
            return f"{self.label} timed out after {self.limit} seconds{suffix}"
        if self.proc.returncode:
            return f"{self.label} exit {self.proc.returncode}: {detail}"
        return None


def sampler(pid, path):
    return Collector("sample", ["sample", str(pid), "2", "-file", str(path)], path, SAMPLE_LIMIT)


def spindump(app_pid, cli_pid, path):
    """Both processes in one passive snapshot; `sample` has timed out on a stalled app in CI."""
    argv = ["sudo", "-n", "/usr/sbin/spindump", str(app_pid), "1", "10", "-onlyTarget", "-proc", str(cli_pid),
            "-noProcessingWhileSampling", "-timelimit", "10", "-o", str(path)]
    return Collector("spindump", argv, path, SPINDUMP_LIMIT, privileged=True)


def check_spindump(evidence):
    """Runs the stall collector once against two throwaway processes, so a stall's missing report can be told
    apart from a collector that never works on this runner."""
    path = evidence / "spindump-check.txt"
    first = subprocess.Popen(["/bin/sleep", "30"])
    second = subprocess.Popen(["/bin/sleep", "30"])
    try:
        failure = spindump(first.pid, second.pid, path).finish()
    finally:
        for proc in (first, second):
            proc.kill()
            proc.wait()
    try:
        report = path.read_text(errors="replace")
    except OSError as exc:
        report, failure = "", failure or f"report unreadable: {exc}"
    if not failure and str(first.pid) not in report:
        failure = "report is empty" if not report else "report does not name the target process"
    (evidence / "spindump-check.json").write_text(json.dumps({"error": failure, "report_bytes": len(report)}))
    print(f"spindump check: {failure or f'{len(report)} bytes'}", flush=True)


def run_case(app, evidence, count, busy):
    name = f"{'spam' if busy else 'idle'}-{count}"
    case_dir = evidence / name
    case_dir.mkdir(parents=True, exist_ok=True)
    state = Path(tempfile.mkdtemp(prefix="agclose-", dir="/tmp"))
    (state / "windows").mkdir()
    (state / "settings.json").write_text(json.dumps({"restoreMode": "none"}))
    producer = state / "producer.py"
    producer.write_text(
        "import sys,time\n"
        "end=time.monotonic()+30\n"
        "while time.monotonic()<end:\n"
        " sys.stdout.write('\\x1b]0;title\\x07')\n"
        " sys.stdout.flush()\n"
    )
    origin = time.monotonic()
    result = {"status": "running", "timeline": {}, "calls": []}
    samplers = []

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
    deadline = time.monotonic() + 5
    created = set()
    while time.monotonic() < deadline:
        created = app_pids() - before
        if created:
            break
        time.sleep(0.1)
    if len(created) != 1:
        raise RuntimeError(f"Cannot identify isolated app: {created}")
    pid = created.pop()
    result["timeline"]["pid"] = since(time.monotonic())
    ctl = app / "Contents/MacOS/agtermctl"

    def call(op, *args):
        entry = {"op": op, "start": since(time.monotonic())}
        result["calls"].append(entry)
        spawn = time.monotonic()
        proc = subprocess.Popen(
            [str(ctl), *args, "--socket", str(state / "agterm.sock"), "--json"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        begin = time.monotonic()
        entry["spawn"] = round(begin - spawn, 3)
        try:
            out, err = proc.communicate(timeout=SLOW_CALL)
        except subprocess.TimeoutExpired:
            # both sides, so a stall in the app reads apart from a client stuck before or after its request
            entry["sampled"] = True
            index = len(result["calls"]) - 1
            for side, target in (("app", pid), ("cli", proc.pid)):
                samplers.append((entry, side, sampler(target, case_dir / f"sample-{index:02d}-{op}-{side}.txt")))
            samplers.append((entry, "spindump", spindump(pid, proc.pid, case_dir / f"spindump-{index:02d}-{op}.txt")))
            try:
                out, err = proc.communicate(timeout=max(0, begin + CALL_LIMIT - time.monotonic()))
            except subprocess.TimeoutExpired:
                entry.update(elapsed=round(time.monotonic() - begin, 3), outcome="timeout")
                # reap without draining: a descendant holding the pipes would block EOF, as in subprocess.run
                proc.kill()
                proc.wait()
                proc.stdout.close()
                proc.stderr.close()
                raise subprocess.TimeoutExpired(proc.args, CALL_LIMIT) from None
        entry.update(elapsed=round(time.monotonic() - begin, 3), outcome="error" if proc.returncode else "ok")
        if proc.returncode:
            raise RuntimeError(err)
        return json.loads(out)["result"]

    try:
        deadline = time.monotonic() + 12
        while not (state / "agterm.sock").exists() and time.monotonic() < deadline:
            time.sleep(0.1)
        result["timeline"]["socket"] = since(time.monotonic())
        result["version"] = call("version", "version")
        ids = []
        command = f"/usr/bin/python3 {shlex.quote(str(producer))}" if busy else "/bin/sleep 30"
        for index in range(count):
            ids.append(call(f"new-{index}", "session", "new", "--name", f"{name}-{index}", "--command", command,
                            "--no-select")["id"])
        deadline = time.monotonic() + 5
        while True:
            tree = call("tree", "tree")["tree"]
            sessions = [session for workspace in tree["workspaces"] for session in workspace["sessions"]]
            if all(any(s["id"] == sid and s.get("realized") for s in sessions) for sid in ids):
                break
            if time.monotonic() >= deadline:
                raise RuntimeError("Test surfaces did not realize")
            time.sleep(0.1)
        result["timeline"]["realized"] = since(time.monotonic())
        time.sleep(1)
        call("close", "session", "close", "--target", ids[0])
        call("version-after", "version")
        result["status"] = "passed"
        save()
        print(f"PASS {name}", flush=True)
    except Exception as exc:
        result.update(status="failed", error=str(exc))
        save()
        last = result["calls"][-1] if result["calls"] else {}
        if not (last.get("sampled") and last.get("outcome") != "ok"):
            samplers.append((result, "app", sampler(pid, case_dir / "sample.txt")))
        raise
    finally:
        for owner, side, collector in samplers:
            failure = collector.finish()
            if failure:
                owner.setdefault("sample_errors", {})[side] = failure
        if samplers:
            save()
        stop_test_app(pid)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=True)
    check_spindump(args.evidence.resolve())
    failed = []
    for count, busy in [(1, True), (8, True), (8, False)]:
        try:
            run_case(args.app.resolve(), args.evidence.resolve(), count, busy)
        except (subprocess.SubprocessError, OSError, RuntimeError, ValueError, LookupError) as exc:
            failed.append(str(exc))
            print(f"FAIL {'spam' if busy else 'idle'}-{count}: {exc}", flush=True)
    if failed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
