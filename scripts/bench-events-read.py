"""Compare events.read polling and events.stream push; CPU is % of one core.

Pass three Debug app bundles: unmodified master (its CLI must poll), the same
revision with only the events.read fast path, and the events-stream-push build.
"""

import argparse
import json
import os
import plistlib
import random
import socket
import statistics
import subprocess
import tempfile
import time
from pathlib import Path


def request(path, cmd, target=None, **args):
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(5)
        sock.connect(str(path))
        payload = {"cmd": cmd, "args": args}
        if target is not None:
            payload["target"] = target
        sock.sendall(json.dumps(payload).encode() + b"\n")
        with sock.makefile("rb") as response:
            reply = json.loads(response.readline())
    if not reply["ok"]:
        raise RuntimeError(reply)
    return reply.get("result")


def check_followers(followers):
    for follower in followers:
        if follower.poll() is not None:
            raise RuntimeError(follower.stderr.read().decode())


def check_stream_connections(followers):
    pids = ",".join(str(follower.pid) for follower in followers)
    for _ in range(2):
        output = subprocess.check_output(["lsof", "-nP", "-a", "-U", "-p", pids, "-Fp"], text=True)
        connected = {line[1:] for line in output.splitlines() if line.startswith("p")}
        if connected != set(pids.split(",")):
            raise RuntimeError(f"Expected persistent stream sockets for {pids}; saw {connected}")
        time.sleep(0.3)


def event_latency(path, state, count, target):
    rng = random.Random(42)
    samples = []
    for index in range(25):
        time.sleep(rng.uniform(0.03, 0.28))
        status = "blocked" if index % 2 == 0 else "completed"
        started = time.time()
        deadline = time.monotonic() + 3
        request(path, "session.status", target=target, status=status)
        pending = set(range(count))
        while pending:
            for follower in tuple(pending):
                text = (state / f"events-{follower}").read_text()
                for line in text.split("\n")[:-1]:
                    event = json.loads(line)
                    if (event["kind"] == "status" and event["ts"] >= started
                            and event["payload"].get("status") == status):
                        samples.append(1000 * (time.time() - event["ts"]))
                        pending.remove(follower)
                        break
            if pending:
                if time.monotonic() >= deadline:
                    raise RuntimeError(f"Missing status {status} on followers {pending}")
                time.sleep(0.002)
    return statistics.median(samples), statistics.quantiles(samples, n=100, method="inclusive")[94]


def app_cpu(pid):
    # cumulative CPU time, including short bursts that a point sample can miss
    text = subprocess.check_output(["ps", "-p", str(pid), "-o", "time="], text=True).strip()
    seconds = 0.0
    for part in text.split(":"):
        seconds = seconds * 60 + float(part)
    return seconds


def sample(pid, seconds):
    start_cpu = app_cpu(pid)
    start = time.monotonic()
    time.sleep(seconds)
    return 100 * (app_cpu(pid) - start_cpu) / (time.monotonic() - start)


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
    process.wait()


def run(app, cli, seconds, count, push):
    with tempfile.TemporaryDirectory(prefix="agtr-bench-", dir="/tmp") as tmp:
        state = Path(tmp)
        (state / "windows").mkdir()
        path = state / "agterm.sock"
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(("AGTERM_", "GHOSTTY_", "CLAUDE", "ZMX_"))}
        env["AGTERM_STATE_DIR"] = tmp
        followers = []
        with (state / "app.log").open("wb") as log:
            process = subprocess.Popen([app / "Contents/MacOS/agterm", "-ApplePersistenceIgnoreState", "YES"], env=env,
                                       stdin=subprocess.DEVNULL, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 15
                while not path.is_socket():
                    if process.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError(f"No isolated socket for PID {process.pid}:\n"
                                           + (state / "app.log").read_text(errors="replace"))
                    time.sleep(0.1)
                request(path, "tree")
                time.sleep(3)
                for index in range(count):
                    with (state / f"events-{index}").open("wb") as output:
                        followers.append(subprocess.Popen([cli, "events", "--json", "--socket", path], env=env,
                                                         stdout=output, stderr=subprocess.PIPE))
                time.sleep(2)
                check_followers(followers)
                request(path, "workspace.new", name="benchmark")
                request(path, "session.new", workspaceName="benchmark", cwd=tmp)
                tree = request(path, "tree")["tree"]
                target, = (session["id"] for workspace in tree["workspaces"] if workspace["name"] == "benchmark"
                           for session in workspace["sessions"])
                time.sleep(3)
                for index in range(count):
                    lines = (state / f"events-{index}").read_text().splitlines()
                    if not any(json.loads(line)["kind"] == "session.created" for line in lines):
                        raise RuntimeError(f"Follower {index + 1} did not receive session.created: {lines}")
                if push:
                    check_stream_connections(followers)
                steady = sample(process.pid, seconds)
                check_followers(followers)
                if push:
                    check_stream_connections(followers)
                latencies = []
                for _ in range(80):
                    start = time.monotonic()
                    request(path, "tree")
                    latencies.append(1000 * (time.monotonic() - start))
                    time.sleep(0.025)
                event_median, event_p95 = event_latency(path, state, count, target)
                for follower in followers:
                    stop(follower)
                time.sleep(2)
                idle = sample(process.pid, min(15, seconds))
                return idle, steady, statistics.median(latencies), sorted(latencies)[75], event_median, event_p95
            finally:
                for follower in followers:
                    stop(follower)
                    follower.stderr.close()
                stop(process)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("master_app", type=Path)
    parser.add_argument("fast_app", type=Path)
    parser.add_argument("stream_app", type=Path)
    parser.add_argument("--seconds", type=int, default=60)
    parser.add_argument("--followers", type=int, default=7)
    parser.add_argument("--pairs", type=int, default=2)
    args = parser.parse_args()
    if min(args.seconds, args.followers, args.pairs) < 1:
        parser.error("seconds, followers, and pairs must be positive")
    builds = [("master", args.master_app.resolve()), ("master + fast path", args.fast_app.resolve()),
              ("branch push", args.stream_app.resolve())]
    for _, app in builds:
        try:
            with (app / "Contents/Info.plist").open("rb") as info:
                bundle_id = plistlib.load(info).get("CFBundleIdentifier")
        except (OSError, plistlib.InvalidFileException) as error:
            parser.error(f"cannot read bundle info for {app}: {error}")
        if bundle_id != "com.umputun.agterm.debug":
            parser.error(f"expected an agterm Debug app: {app}")
    cli = builds[0][1] / "Contents/MacOS/agtermctl"
    stream_cli = builds[2][1] / "Contents/MacOS/agtermctl"
    for executable in [cli, stream_cli, *(app / "Contents/MacOS/agterm" for _, app in builds)]:
        if not os.access(executable, os.X_OK):
            parser.error(f"not executable: {executable}")
    print(f"{args.followers} CLI followers, {args.seconds} s per CPU sample.\n"
          "| Round | Build | Idle CPU % | Subscribed CPU % | Tree p50/p95 ms | Event p50/p95 ms |\n"
          "|---|---|---|---|---|---|", flush=True)
    for pair in range(args.pairs):
        offset = pair % len(builds)
        for label, app in builds[offset:] + builds[:offset]:
            push = label == "branch push"
            idle, steady, median, p95, event_median, event_p95 = run(
                app, stream_cli if push else cli, args.seconds, args.followers, push)
            print(f"| {pair + 1} | {label} | {idle:.3f} | {steady:.3f} | {median:.2f}/{p95:.2f} | "
                  f"{event_median:.2f}/{event_p95:.2f} |", flush=True)


if __name__ == "__main__":
    main()
