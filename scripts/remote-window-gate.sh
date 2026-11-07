#!/usr/bin/env bash
# remote window gate against scripts/server-container.sh: a 20-session catalog under stock sshd (MaxSessions 10),
# reconnect after dropped masters, an ended row, a promoted split, a shell exit, and an unreachable server.
# docs/remote-linux-gate.md says what each step checks.
#
# usage: AGTERM_STATE_DIR=/tmp/agw scripts/remote-window-gate.sh [COUNT]
#   COUNT            sessions created on the server, default 20
#   AGTERM_GATE_APP  the Debug bundle, default build/DerivedData/Build/Products/Debug/agterm.app
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${AGTERM_GATE_APP:-$ROOT/build/DerivedData/Build/Products/Debug/agterm.app}"
COUNT="${1:-20}"
CONTAINER=agterm-server-test
KEYS="$ROOT/build/server-container"
HOST="ssh://agterm@127.0.0.1:${AGTERM_SERVER_CONTAINER_PORT:-2222}"
DEADLINE=60
FAILED=0
APP_PID=""
PAUSED=""

die() { echo "remote-window-gate: $*" >&2; exit 2; }

dir="${AGTERM_STATE_DIR:-}"
[[ -n "$dir" ]] || die "AGTERM_STATE_DIR is unset; export a short /tmp directory"
dir="${dir%/}"
case "$dir" in
  /tmp/* | /private/tmp/*) ;;
  *) die "AGTERM_STATE_DIR must be under /tmp, got $dir" ;;
esac
(( ${#dir} + 12 <= 100 )) || die "AGTERM_STATE_DIR is too long for a control socket: $dir"
STATE="$dir"
SOCK="$STATE/agterm.sock"
RESULTS="$STATE/gate-results.txt"
[[ -x "$APP/Contents/MacOS/agtermctl" ]] || die "no Debug build at $APP; run make build or set AGTERM_GATE_APP"
CTL="$APP/Contents/MacOS/agtermctl"
[[ -f "$KEYS/id_ed25519" ]] || die "no container keys under $KEYS; run scripts/server-container.sh build"
docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true \
  || die "the $CONTAINER container is not running; run scripts/server-container.sh start"

# the app's ssh resolves through PATH, so a wrapper ahead of it gives every invocation the container's key and
# host key, and logs each call for the master count
mkdir -p "$STATE/bin" "$STATE/windows"
cat >"$STATE/ssh_config" <<EOF
Host 127.0.0.1
  IdentityFile $KEYS/id_ed25519
  IdentitiesOnly yes
  UserKnownHostsFile $KEYS/known_hosts
  StrictHostKeyChecking yes
EOF
cat >"$STATE/bin/ssh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$STATE/ssh-calls.log"
exec /usr/bin/ssh -F "$STATE/ssh_config" "\$@"
EOF
chmod +x "$STATE/bin/ssh"
: >"$STATE/ssh-calls.log"
: >"$RESULTS"

record() {
  local verdict="$1" step="$2" detail="${3:-}"
  printf '%-8s %-20s %s\n' "$verdict" "$step" "$detail" | tee -a "$RESULTS"
  [[ "$verdict" != FAIL ]] || FAILED=1
}

ctl() { "$CTL" "$@" --socket "$SOCK"; }
remote() { "$STATE/bin/ssh" -T -o BatchMode=yes -o ConnectTimeout=5 "$HOST" "export PATH=\$PATH:\$HOME/.local/bin; $1"; }
zmx_list() { remote "ZMX_DIR=\$(agtermctl zmx tree --json | jq -r .result.remote.endpoint.socketDirectory) ~/.local/lib/agterm-server/zmx list"; }
starts() { grep -c -- '-f -N -M' "$STATE/ssh-calls.log" || true; }
# the pool directory is shared by every remote window of this user, so only the paths this run's ssh used are its own
own_paths() { grep -o 'ControlPath=[^ ]*' "$STATE/ssh-calls.log" | sed 's/^ControlPath=//' | sort -u; }
master_pid() { /usr/bin/ssh -O check -o ControlPath="$1" "$HOST" 2>&1 | sed -n 's/.*pid=\([0-9]*\).*/\1/p'; }

# a predicate over the remote window's tree, polled until it holds or the deadline passes
wait_tree() {
  local predicate="$1" limit="${2:-$DEADLINE}" end current=""
  end=$((SECONDS + limit))
  while (( SECONDS < end )); do
    current="$(ctl tree --window "$WINDOW" --json 2>/dev/null | jq -c '.result.tree' || true)"
    if [[ -n "$current" ]] && jq -e "$predicate" >/dev/null 2>&1 <<<"$current"; then return 0; fi
    sleep 1
  done
  printf '%s\n' "$current" | jq -c '{remote, sessions: [.workspaces[].sessions[] | {id, ended, hasSplit, presentation}]}' 2>/dev/null >&2 || true
  return 1
}

check() {
  local step="$1" predicate="$2"
  if wait_tree "$predicate" "${3:-$DEADLINE}"; then record PASS "$step" "$predicate"; else record FAIL "$step" "$predicate"; fi
}

rows='[.workspaces[].sessions[]]'
all_up="(.remote.state == \"connected\") and ($rows | length) == \$n and ($rows | all(.presentation.state == \"connected\"))"

launch() {
  [[ ! -S "$SOCK" ]] || ! ctl tree --json >/dev/null 2>&1 || die "another instance already serves $SOCK"
  local vars pid activated="" end=$((SECONDS + 10))
  vars="$(env | sed -n 's/^\(\(CLAUDE\|AGTERM_\|GHOSTTY_\)[A-Za-z0-9_]*\)=.*/\1/p' | sed 's/^/-u /' | tr '\n' ' ')"
  # shellcheck disable=SC2086 # vars is a list of `-u NAME` words
  env $vars open -n --env "AGTERM_STATE_DIR=$STATE" --env "PATH=$STATE/bin:$PATH" "$APP"
  for _ in $(seq 10); do
    for pid in $(ps -axo pid=,command= | awk -v bin="$APP/Contents/MacOS/agterm" '$2 == bin {print $1}'); do
      ps eww -o command= -p "$pid" | grep -qE "(^| )AGTERM_STATE_DIR=$STATE( |$)" && APP_PID="$pid"
    done
    [[ -z "$APP_PID" ]] || break
    sleep 1
  done
  [[ -n "$APP_PID" ]] || die "no instance on $STATE appeared"
  # the socket binds from the window scene, which a launch that cannot take focus never renders until activated
  until ctl tree --json >/dev/null 2>&1; do
    if (( SECONDS >= end )) && [[ -z "$activated" ]]; then
      # shellcheck disable=SC2086
      env $vars open --env "AGTERM_STATE_DIR=$STATE" --env "PATH=$STATE/bin:$PATH" "$APP" 2>/dev/null
      activated=1
      end=$((SECONDS + 10))
    fi
    (( SECONDS < end )) || die "no answering control socket at $SOCK 10s after activating the instance"
    sleep 1
  done
}

# shellcheck disable=SC2329 # runs from the EXIT trap
cleanup() {
  [[ -z "$PAUSED" ]] || docker unpause "$CONTAINER" >/dev/null 2>&1 || true
  if [[ -n "$APP_PID" ]]; then
    kill -TERM "$APP_PID" 2>/dev/null || true
    for _ in $(seq 10); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 1; done
    kill -0 "$APP_PID" 2>/dev/null && echo "remote-window-gate: Debug pid $APP_PID still running" >&2
  fi
  echo "results: $RESULTS"
}
trap cleanup EXIT

# --- server: COUNT sessions, one of them split, plus one to end and one to exit
existing="$(remote 'agtermctl tree --json' | jq '[.result.tree.workspaces[].sessions[]] | length')"
for _ in $(seq $((COUNT - existing))); do remote 'agtermctl session new --json' >/dev/null; done
ids=()
while IFS= read -r id; do ids+=("$id"); done < <(remote 'agtermctl tree --json' | jq -r '.result.tree.workspaces[].sessions[].id')
SPLIT="${ids[0]}" ENDS="${ids[1]}" EXITS="${ids[2]}"
remote "agtermctl session split on --target $SPLIT" >/dev/null
record RECORDED server "$COUNT sessions; split $SPLIT, ends $ENDS, exits $EXITS"

# --- open
launch
reply="$(ctl window remote open "$HOST" --json)"
WINDOW="$(jq -r '.result.id // empty' <<<"$reply")"
[[ -n "$WINDOW" ]] || die "window remote open failed: $reply"
check open "$(sed "s/\\\$n/$COUNT/" <<<"$all_up")" 120
masters=0
for path in $(own_paths); do [[ -z "$(master_pid "$path")" ]] || masters=$((masters + 1)); done
attached="$(zmx_list | grep -c 'clients=1' || true)"
record RECORDED masters "$masters live masters, $(starts) starts, $attached daemons with one client"
(( attached == COUNT + 1 )) && record PASS attached "every pane has its client" || record FAIL attached "$attached of $((COUNT + 1))"

# --- drop every master as a network loss would, then expect one start per master and every pane back
before="$(starts)"
for path in $(own_paths); do
  pid="$(master_pid "$path")"
  [[ -z "$pid" ]] || kill -9 "$pid" 2>/dev/null || true
done
sleep 5
check reconnect "$(sed "s/\\\$n/$COUNT/" <<<"$all_up")" 120
after="$(starts)"
attached="$(zmx_list | grep -c 'clients=1' || true)"
# reconnect probes hold counted leases too, so a full pool may open new slots; each path still starts once
twice="$(grep -- '-f -N -M' "$STATE/ssh-calls.log" | tail -n +$((before + 1)) | sed -E 's/.*ControlPath=([^ ]+).*/\1/' \
  | sort | uniq -d | wc -l | tr -d ' ')"
record RECORDED restarts "$((after - before)) starts after the drop for $masters masters, $attached daemons with one client"
(( twice == 0 )) && record PASS one-start-each "no connection started twice" || record FAIL one-start-each "$twice started twice"
(( attached == COUNT + 1 )) && record PASS reattached "every pane has its client" || record FAIL reattached "$attached of $((COUNT + 1))"

# --- a killed daemon ends its row, which keeps its screen
daemon="$(remote 'agtermctl zmx tree --json' | jq -r --arg s "$ENDS" '.result.remote.sessions[] | select(.id == $s) | .panes[0].daemon')"
remote "ZMX_DIR=\$(agtermctl zmx tree --json | jq -r .result.remote.endpoint.socketDirectory) ~/.local/lib/agterm-server/zmx kill $daemon" >/dev/null
check ended "$rows | map(select(.id == \"$ENDS\")) | .[0] | (.ended == true and .realized == true)"

# --- a killed primary with a live split promotes the split
primary="$(remote 'agtermctl zmx tree --json' | jq -r --arg s "$SPLIT" '.result.remote.sessions[] | select(.id == $s) | .panes[] | select(.pane == "left") | .daemon')"
remote "ZMX_DIR=\$(agtermctl zmx tree --json | jq -r .result.remote.endpoint.socketDirectory) ~/.local/lib/agterm-server/zmx kill $primary" >/dev/null
check promoted "$rows | map(select(.id == \"$SPLIT\")) | .[0] | (. != null and (.hasSplit // false) == false and (.ended // false) == false)"

# --- a shell that exits removes its row
check exit-row-shown "$rows | map(select(.id == \"$EXITS\")) | length == 1"
remote "agtermctl session type --target $EXITS 'exit
'" >/dev/null
check shell-exit "$rows | map(select(.id == \"$EXITS\")) | length == 0"

# --- an unreachable server leaves the window Disconnected with its rows, and comes back
rows_before="$(ctl tree --window "$WINDOW" --json | jq "[.result.tree.workspaces[].sessions[]] | length")"
(( rows_before > 0 )) || record FAIL unreachable "the window shows no rows to keep"
docker pause "$CONTAINER" >/dev/null
PAUSED=1
check unreachable "(.remote.state == \"disconnected\") and ($rows | length) == $rows_before" 90
docker unpause "$CONTAINER" >/dev/null
PAUSED=""
check back "(.remote.state == \"connected\")" 120

# a start keeps its argv whether it became its path's master or, finding the path taken, a plain session that never
# exits; only the second is a stray
stray=0
while read -r pid path; do
  [[ "$(master_pid "$path")" == "$pid" ]] || stray=$((stray + 1))
done < <(ps -axo pid=,command= | grep -- "-F $STATE/ssh_config -f -N -M" | grep -v grep \
  | sed -E 's/^ *([0-9]+) .*ControlPath=([^ ]+).*/\1 \2/')
(( stray == 0 )) && record PASS no-stray-ssh "every running start is its path's master" \
  || record FAIL no-stray-ssh "$stray starts running as plain sessions"

exit "$FAILED"
