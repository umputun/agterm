#!/usr/bin/env bash
# Bench the two `agtermctl events` transports, one isolated app instance per phase:
#   poll   — `events --json --poll`: events.read every 250 ms per CLI (old transport,
#            served by this build's fast path)
#   stream — `events --json`: events.stream push (new transport)
# Each phase launches a fresh instance, opens WORKSPACES workspaces with SESSIONS_PER_WS
# sessions each, then TYPES one `agtermctl events` listener into every session
# (session.type — the CLI runs inside the pane's shell like a user started it, stdout
# redirected to a per-session file), fires a status+message burst over the socket, and
# samples app CPU and round-trip latency. Listeners are stopped with a typed Ctrl-C before
# the instance is SIGTERM'd by its own pid; the live ~/Applications app is never touched.
# burst cpu is the mean over an 8 s top window covering the burst.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${BENCH_APP:-$PWD/build/DerivedData/Build/Products/Debug/agterm.app}"
CTL="$APP/Contents/MacOS/agtermctl"
STATE="${BENCH_STATE_DIR:-/tmp/agterm-bench-events}"
LISTENERS_DIR=/tmp/agterm-bench-listeners
WORKSPACES="${BENCH_WORKSPACES:-10}"
SESSIONS_PER_WS="${BENCH_SESSIONS_PER_WS:-5}"
STEADY_SECONDS="${BENCH_STEADY_SECONDS:-120}"
OUT="/tmp/agterm-events-bench-$(date -u +%Y%m%dT%H%M%S).md"
INHERIT=(AGTERM_STATE_DIR AGTERM_SOCKET AGTERM_CONTROL_SOCKET GHOSTTY_RESOURCES_DIR CLAUDECODE CLAUDE_CODE_ENTRYPOINT)

[ -x "$CTL" ] || { echo "no CLI at $CTL — build first (scripts/build.sh) or set BENCH_APP"; exit 1; }

APP_PID=""
cleanup() {
    # typed-in-pane listeners: Ctrl-C already sent in phase(); sweep any stragglers by the
    # exact Debug CLI path, which never matches the live app's CLIs
    pkill -f "^$CTL events" 2>/dev/null || true
    if [ -n "$APP_PID" ]; then
        kill -TERM "$APP_PID" 2>/dev/null || true
        for _ in $(seq 1 10); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 1; done
    fi
    [ "${BENCH_KEEP_STATE:-}" = 1 ] || rm -rf "$STATE" "$LISTENERS_DIR"
    if lsappinfo list 2>/dev/null | grep -q agterm.debug; then
        echo "warning: an agterm.debug instance is still registered — check lsappinfo"
    fi
    return 0
}
trap cleanup EXIT

ctl() { # ctl <json> — one control round-trip, prints the reply
    python3 - "$1" <<'PY'
import os, socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(10)
s.connect(os.environ["BENCH_SOCK"])
try:
    s.sendall((sys.argv[1] + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = s.recv(1 << 20)
        if not chunk:
            break
        buf += chunk
    print(buf.decode())
finally:
    s.close()
PY
}

avg_cpu() { # avg_cpu <samples> <interval-seconds> — mean app CPU% via top; top rejects fractional
    # intervals (exit 1, which set -e would treat as fatal), so keep the interval integral
    top -l "$1" -s "$2" -pid "$APP_PID" -stats pid,cpu 2>/dev/null \
        | awk -v pid="$APP_PID" '$1 == pid { v += $2; n++ } END { if (n) printf "%.1f", v / n; else print "n/a" }'
}

latency() { # latency <n> — tree round-trip "p50/p95" ms
    python3 - "$1" <<'PY'
import os, socket, sys, time
lat = []
for _ in range(int(sys.argv[1])):
    t = time.perf_counter()
    s = socket.socket(socket.AF_UNIX); s.settimeout(5)
    s.connect(os.environ["BENCH_SOCK"])
    try:
        s.sendall(b'{"cmd":"tree"}\n')
        while True:
            chunk = s.recv(1 << 20)
            if not chunk or chunk.endswith(b"\n"):
                break
    finally:
        s.close()
    lat.append((time.perf_counter() - t) * 1000)
lat.sort()
print(f"{lat[len(lat)//2]:.1f}/{lat[int(len(lat)*0.95)]:.1f}")
PY
}

setup_tree() { # workspaces + sessions, wait for realization, write ids/paneIDs files
    mkdir -p "$STATE/workspaces"
    for i in $(seq 1 "$WORKSPACES"); do
        local name dir
        name=$(printf "bench-w%02d" "$i")
        dir="$STATE/workspaces/ws$(printf "%02d" "$i")"
        mkdir -p "$dir"
        grep -q '"ok":true' < <(ctl "{\"cmd\":\"workspace.new\",\"args\":{\"name\":\"$name\"}}") \
            || { echo "workspace.new $name failed"; exit 1; }
        for _ in $(seq 1 "$SESSIONS_PER_WS"); do
            grep -q '"ok":true' \
                < <(ctl "{\"cmd\":\"session.new\",\"args\":{\"workspaceName\":\"$name\",\"cwd\":\"$dir\"}}") \
                || { echo "session.new in $name failed"; exit 1; }
        done
    done
    python3 - "$WORKSPACES" "$SESSIONS_PER_WS" <<'PY'
import json, os, socket, sys, time
want = int(sys.argv[1]) * int(sys.argv[2])
deadline = time.time() + 90
rows = []
while time.time() < deadline:
    s = socket.socket(socket.AF_UNIX); s.settimeout(10)
    s.connect(os.environ["BENCH_SOCK"])
    s.sendall(b'{"cmd":"tree"}\n')
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = s.recv(1 << 20)
        if not chunk:
            break
        buf += chunk
    s.close()
    tree = json.loads(buf)["result"]["tree"]
    rows = [(w["name"], sess) for w in tree["workspaces"] if w["name"].startswith("bench-")
            for sess in w["sessions"]]
    if len(rows) == want and all(s.get("surfaces") and s["surfaces"][0].get("paneID") for _, s in rows):
        break
    time.sleep(1)
else:
    sys.exit("sessions did not realize in 90s")
with open(os.environ["BENCH_IDS"], "w") as f:
    f.write("\n".join(sess["id"] for _, sess in rows))
with open(os.environ["BENCH_PANES"], "w") as f:
    f.write("\n".join(f"{sess['id']}:{sess['surfaces'][0]['paneID']}" for _, sess in rows))
print(f"  {len(rows)} sessions realized across {sys.argv[1]} workspaces")
PY
}

burst() { # 2 status flips + 1 message per session; prints "duration_s req_p50/p95 events failures stalls"
    python3 - <<'PY'
import json, os, random, signal, socket, subprocess, time
app_pid = int(os.environ["BENCH_APP_PID"])
ids = open(os.environ["BENCH_IDS"]).read().split()
panes = dict(line.split(":") for line in open(os.environ["BENCH_PANES"]).read().splitlines())
random.seed(7)
requests = []
for sid in ids:
    # two distinct status values: the pane's auto status can equal the first, but never both,
    # so each session is guaranteed at least one status event; msg.send always delivers
    requests += [
        {"cmd": "session.status", "target": sid, "args": {"status": "blocked"}},
        {"cmd": "msg.send", "target": sid,
         "args": {"body": "bench", "recipients": [f"{sid}:{panes[sid]}"]}},
        {"cmd": "session.status", "target": sid, "args": {"status": "completed"}},
    ]
random.shuffle(requests)


def app_alive():
    try:
        os.kill(app_pid, 0)
        return True
    except OSError:
        return False


lat, failures, stalls, t0 = [], 0, 0, time.perf_counter()
for payload in requests:
    t = time.perf_counter()
    s = socket.socket(socket.AF_UNIX); s.settimeout(5)
    try:
        for attempt in range(25):
            try:
                s.connect(os.environ["BENCH_SOCK"])
                break
            except ConnectionRefusedError:
                stalls += 1
                if stalls == 1:
                    subprocess.run(["sample", str(app_pid), "2", "-file", "/tmp/agterm-bench-stall.sample"],
                                   capture_output=True)
                if not app_alive():
                    print(f"APP DIED mid-burst on payload {json.dumps(payload)[:80]}")
                    raise
                time.sleep(0.2)
        s.sendall((json.dumps(payload) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = s.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        if b'"ok":true' not in buf.replace(b" ", b""):
            failures += 1
    finally:
        s.close()
    lat.append((time.perf_counter() - t) * 1000)
lat.sort()
print(f"{time.perf_counter() - t0:.2f} {lat[len(lat)//2]:.1f}/{lat[int(len(lat)*0.95)]:.1f} "
      f"{len(requests)} {failures} {stalls}")
PY
}

delivery() { # every listener saw the burst? prints "complete/total frames"
    python3 - <<'PY'
import glob, os, time
want_status = len(open(os.environ["BENCH_IDS"]).read().split())      # >= 1 per session
want_message = len(open(os.environ["BENCH_IDS"]).read().split())     # exactly 1 per session
files = sorted(glob.glob("/tmp/agterm-bench-listeners/*.out"))
deadline = time.time() + 30
while time.time() < deadline:
    ok, frames = 0, 0
    for path in files:
        text = open(path, errors="replace").read()
        if text.count('"kind":"status"') >= want_status \
                and text.count('"kind":"message"') >= want_message:
            ok += 1
        frames += text.count('"kind":')
    if ok == len(files):
        break
    time.sleep(1)
print(f"{ok}/{len(files)} {frames}")
PY
}

type_into_session() { # type_into_session <session-id> <text-with-trailing-newline>
    python3 - "$1" "$2" <<'PY'
import json, os, socket, sys
payload = {"cmd": "session.type", "target": sys.argv[1], "args": {"text": sys.argv[2]}}
s = socket.socket(socket.AF_UNIX); s.settimeout(10)
s.connect(os.environ["BENCH_SOCK"])
try:
    s.sendall((json.dumps(payload) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = s.recv(1 << 20)
        if not chunk:
            break
        buf += chunk
    if b'"ok":true' not in buf.replace(b" ", b""):
        sys.exit("session.type failed: " + buf.decode(errors="replace"))
finally:
    s.close()
PY
}

listener_count() { pgrep -f "^$CTL events" | wc -l | tr -d ' '; }

phase() { # phase <poll|stream> <label>
    local transport="$1" label="$2" flag=""
    [ "$transport" = poll ] && flag="--poll"
    export BENCH_SOCK="$STATE/agterm.sock" BENCH_IDS="$STATE/ids.txt" BENCH_PANES="$STATE/panes.txt"

    rm -rf "$STATE" && mkdir -p "$STATE/windows"
    echo "phase [$label]: launching $APP"
    env $(printf -- "-u %s " "${INHERIT[@]}") open -n --env AGTERM_STATE_DIR="$STATE" "$APP"
    local waited=0
    until [ -S "$STATE/agterm.sock" ]; do
        if [ $waited -ge 15 ]; then echo "control socket never appeared"; exit 1; fi
        sleep 1; waited=$((waited + 1))
    done
    # the pid whose environment names THIS state dir — never a stale debug instance; `ps eww`
    # with no selector sees only this terminal's processes, so walk the pgrep candidates
    local candidate
    for candidate in $(pgrep -f "^$APP/Contents/MacOS/agterm$" || true); do
        if ps eww -p "$candidate" -o command= | grep -q "AGTERM_STATE_DIR=$STATE"; then
            APP_PID=$candidate
            break
        fi
    done
    [ -n "$APP_PID" ] || { echo "could not find the app pid for $STATE"; exit 1; }
    echo "  app pid $APP_PID"
    export BENCH_APP_PID="$APP_PID"

    setup_tree

    local idle steady lat_steady burst_stats stats_file burst_pid burst_cpu del
    echo "  sampling idle cpu..."
    idle=$(avg_cpu 5 1)

    rm -rf "$LISTENERS_DIR" && mkdir -p "$LISTENERS_DIR"
    echo "  typing one listener into each of the sessions ($transport)..."
    local i=0
    for sid in $(cat "$BENCH_IDS"); do
        i=$((i + 1))
        type_into_session "$sid" \
            "$CTL events --json $flag --socket $BENCH_SOCK > $LISTENERS_DIR/l$i.out 2>&1"$'\n'
    done
    waited=0
    until [ "$(listener_count)" -ge "$((i))" ]; do
        if [ $waited -ge 30 ]; then
            echo "only $(listener_count)/$i listeners started"; exit 1
        fi
        sleep 1; waited=$((waited + 1))
    done
    sleep 2
    echo "  steady window: ${STEADY_SECONDS}s with listeners attached..."
    steady=$(avg_cpu "$STEADY_SECONDS" 1)
    lat_steady=$(latency 20)

    echo "  firing burst (status + message per session)..."
    stats_file=$(mktemp)
    burst > "$stats_file" &
    burst_pid=$!
    burst_cpu=$(avg_cpu 8 1)
    wait "$burst_pid"
    burst_stats=$(cat "$stats_file")

    del=$(delivery)

    local dur reqs events failures stalls
    dur=$(echo "$burst_stats" | awk '{print $1}')
    reqs=$(echo "$burst_stats" | awk '{print $2}')
    events=$(echo "$burst_stats" | awk '{print $3}')
    failures=$(echo "$burst_stats" | awk '{print $4}')
    stalls=$(echo "$burst_stats" | awk '{print $5}')
    printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
        "$label" "$idle" "$steady" "$burst_cpu" "$lat_steady" "$reqs" "$dur" "$events" \
        "$failures" "$stalls" "$del" >> "$OUT"
    echo "  row appended to $OUT"

    # Ctrl-C every pane's listener, then sweep any stragglers by the exact CLI path
    for sid in $(cat "$BENCH_IDS"); do type_into_session "$sid" $'\u0003' || true; done
    waited=0
    until [ "$(listener_count)" -eq 0 ]; do
        if [ $waited -ge 10 ]; then pkill -f "^$CTL events" 2>/dev/null || true; break; fi
        sleep 1; waited=$((waited + 1))
    done
    local dying="$APP_PID"
    kill -TERM "$dying"; APP_PID=""
    for _ in $(seq 1 10); do kill -0 "$dying" 2>/dev/null || break; sleep 1; done
}

{
    echo "# agterm events transport bench — $(date -u +%Y-%m-%d)"
    echo
    echo "- build: \`$APP\` — macOS $(sw_vers -productVersion)"
    echo "- $WORKSPACES workspaces × $SESSIONS_PER_WS sessions, one \`agtermctl events --json\` listener typed into every session ($((WORKSPACES * SESSIONS_PER_WS)) total); steady window ${STEADY_SECONDS}s"
    echo "- poll = old transport (events.read every 250 ms per CLI, served by this build's fast path);"
    echo "  stream = new transport (events.stream push). Both phases run the same build."
    echo
    echo "| transport | idle cpu % | steady cpu % | burst cpu % | tree p50/p95 ms | burst req p50/p95 ms | burst s | events | failed reqs | refused stalls | listeners complete / frames |"
    echo "|---|---|---|---|---|---|---|---|---|---|---|"
} > "$OUT"

phase poll "poll (old transport)"
phase stream "stream (new transport)"

echo
echo "results saved to $OUT"
cat "$OUT"
