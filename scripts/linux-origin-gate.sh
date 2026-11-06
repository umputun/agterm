#!/usr/bin/env bash
# mac-to-linux attach gate; docs/remote-linux-gate.md says what each step checks.
#
# usage: AGTERM_STATE_DIR=/tmp/agg scripts/linux-origin-gate.sh HOST [SESSION]
#   HOST     an ssh destination the user's own ssh resolves with key auth (ssh://user@127.0.0.1:2222 works)
#   SESSION  the origin session id from `zmx tree HOST`; the first one listed when omitted
#   AGTERM_GATE_APP  the Debug bundle, default build/DerivedData/Build/Products/Debug/agterm.app
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${AGTERM_GATE_APP:-$ROOT/build/DerivedData/Build/Products/Debug/agterm.app}"
DEADLINE=15
CALL_LIMIT=20
FAILED=0
APP_PID=""
COMPANION=""
PAGE=""
BG_PID=""
FINISH_STATUS=0

die() { echo "linux-origin-gate: $*" >&2; exit 2; }

# a state dir that is not a short throwaway under /tmp could be the live terminal's, whose socket this script
# would then drive
check_state_dir() {
  local dir="${AGTERM_STATE_DIR:-}"
  [[ -n "$dir" ]] || die "AGTERM_STATE_DIR is unset; export a short /tmp directory"
  dir="${dir%/}"
  case "$dir" in
    "$HOME/Library/Application Support/agterm" | "$HOME/Library/Application Support/agterm-debug")
      die "AGTERM_STATE_DIR names a shared state dir ($dir)" ;;
    /tmp/* | /private/tmp/*) ;;
    *) die "AGTERM_STATE_DIR must be under /tmp, got $dir" ;;
  esac
  # unix socket paths cap near 104 bytes; a longer one launches the app with no control socket
  (( ${#dir} + 12 <= 100 )) || die "AGTERM_STATE_DIR is too long for a control socket: $dir"
  STATE="$dir"
  SOCK="$STATE/agterm.sock"
  RESULTS="$STATE/gate-results.txt"
}

check_state_dir
[[ $# -ge 1 && $# -le 2 ]] || die "usage: AGTERM_STATE_DIR=/tmp/agg $0 HOST [SESSION]"
HOST="$1"
SESSION="${2:-}"
[[ "$HOST" != -* ]] || die "HOST must not start with '-'"
[[ -x "$APP/Contents/MacOS/agtermctl" ]] || die "no Debug build at $APP; run make build or set AGTERM_GATE_APP"
CTL="$APP/Contents/MacOS/agtermctl"
SSH=(ssh -T -o BatchMode=yes -o ConnectTimeout=5 "$HOST")
"${SSH[@]}" true </dev/null || die "ssh to $HOST failed with key auth"

# a fresh state dir reads as a first launch and opens the welcome alert; the marker skips it
mkdir -p "$STATE/windows"
: >"$RESULTS"

record() {
  local verdict="$1" step="$2" detail="${3:-}"
  printf '%-8s %-22s %s\n' "$verdict" "$step" "$detail" | tee -a "$RESULTS"
  [[ "$verdict" != FAIL ]] || FAILED=1
}

ctl() { "$CTL" "$@" --socket "$SOCK"; }

exited_within() {
  local pid="$1" end=$((SECONDS + $2))
  while kill -0 "$pid" 2>/dev/null; do
    (( SECONDS < end )) || return 1
    sleep 1
  done
}

# the origin reads the line through `/bin/sh -s`, so its login shell, fish or zsh, never parses the arguments
remote_line() {
  local line="PATH=\"\$PATH:/usr/local/bin:/opt/homebrew/bin:\$HOME/.local/bin\"; exec" arg
  for arg in "$@"; do line+=" $(printf '%q' "$arg")"; done
  printf '%s\n' "$line"
}

# ssh must be a direct child of this shell, not of a subshell or pipeline, for wait to return its exit status
start_remote() {
  local out="$1" line="$2"
  "${SSH[@]}" /bin/sh -s <<<"$line" >"$out" 2>&1 &
  BG_PID=$!
}

# ConnectTimeout bounds only the connection setup, so a stalled remote command needs its own limit
rctl_shell() {
  local out status=0
  out="$(mktemp "$STATE/rctl.XXXXXX")"
  start_remote "$out" "$1"
  if ! exited_within "$BG_PID" "$CALL_LIMIT"; then
    kill "$BG_PID" 2>/dev/null || true
    echo "linux-origin-gate: origin call timed out: $1" >&2
  fi
  wait "$BG_PID" || status=$?
  cat "$out"
  rm -f "$out"
  return "$status"
}

rctl() { rctl_shell "$(remote_line agtermctl "$@")"; }

node() { ctl tree --json | jq -c --arg s "$1" '[.. | objects | select(.id? == $s)][0] // empty'; }

origin_node() { rctl tree --json | jq -c --arg s "$SESSION" '[.. | objects | select(.id? == $s)][0] // {}'; }

wait_for() {
  local id="$1" predicate="$2" end=$((SECONDS + DEADLINE)) current=""
  while (( SECONDS < end )); do
    current="$(node "$id" || true)"
    if [[ -n "$current" ]] && jq -e "$predicate" >/dev/null 2>&1 <<<"$current"; then
      printf '%s\n' "$current"
      return 0
    fi
    sleep 1
  done
  printf '%s\n' "${current:-null}"
  return 1
}

check() {
  local step="$1" id="$2" predicate="$3" got
  if got="$(wait_for "$id" "$predicate")"; then
    record PASS "$step" "$predicate"
  else
    record FAIL "$step" "$predicate; last node: $got"
  fi
}

app_pids() { ps -axo pid=,command= | awk -v bin="$APP/Contents/MacOS/agterm" '$2 == bin {print $1}'; }

# only a pid that did not exist before this launch and runs on this state dir is ours: a reused dir can have
# an owner, and the new instance then exits on the state lock while the owner stays running
launch() {
  [[ ! -S "$SOCK" ]] || ! ctl tree --json >/dev/null 2>&1 || die "another instance already serves $SOCK"
  local before vars pid end=$((SECONDS + 10))
  before=" $(app_pids | tr '\n' ' ') "
  vars="$(env | sed -n 's/^\(\(CLAUDE\|AGTERM_\|GHOSTTY_\)[A-Za-z0-9_]*\)=.*/\1/p' | sed 's/^/-u /' | tr '\n' ' ')"
  # shellcheck disable=SC2086 # vars is a list of `-u NAME` words
  env $vars open -n --env "AGTERM_STATE_DIR=$STATE" "$APP"
  while [[ -z "$APP_PID" ]] && (( SECONDS < end )); do
    for pid in $(app_pids); do
      [[ "$before" != *" $pid "* ]] || continue
      ps eww -o command= -p "$pid" | grep -qE "(^| )AGTERM_STATE_DIR=$STATE( |$)" && APP_PID="$pid"
    done
    [[ -n "$APP_PID" ]] || sleep 1
  done
  [[ -n "$APP_PID" ]] || die "no new instance on $STATE appeared; nothing was stopped"
  # the socket binds from the window scene, which a launch that cannot take focus never renders until activated;
  # a stopped instance leaves its socket file, so only an answer counts
  local activated=""
  until ctl tree --json >/dev/null 2>&1; do
    if (( SECONDS >= end )) && [[ -z "$activated" ]]; then
      # shellcheck disable=SC2086
      env $vars open --env "AGTERM_STATE_DIR=$STATE" "$APP" 2>/dev/null
      activated=1
      end=$((SECONDS + 10))
    fi
    (( SECONDS < end )) || die "no answering control socket at $SOCK 10s after activating the instance"
    sleep 1
  done
}

stop_app() {
  [[ -n "$APP_PID" ]] || return 0
  kill -TERM "$APP_PID" 2>/dev/null || true
  exited_within "$APP_PID" 10 || echo "linux-origin-gate: Debug pid $APP_PID still running" >&2
  APP_PID=""
}

# shellcheck disable=SC2329 # runs from the EXIT trap
cleanup() {
  local pid leftovers
  for pid in $(jobs -p); do kill "$pid" 2>/dev/null || true; done
  [[ -z "$COMPANION" ]] || rctl session close --target "$COMPANION" >/dev/null 2>&1 || true
  [[ -z "$PAGE" ]] || rctl session overlay close --target "$SESSION" >/dev/null 2>&1 || true
  [[ -z "$PAGE" ]] || rctl_shell "rm -f $PAGE" >/dev/null 2>&1 || true
  stop_app
  leftovers="$(lsappinfo list 2>/dev/null | grep -A4 'agterm.debug' || true)"
  [[ -z "$leftovers" ]] || printf 'linux-origin-gate: lsappinfo still lists agterm.debug:\n%s\n' "$leftovers" >&2
}
trap cleanup EXIT

attach() {
  local reply member
  reply="$(ctl zmx attach "$HOST" "$SESSION" --companions --json)" || { record FAIL attach "$reply"; return 1; }
  LOCAL="$(jq -r '.result.id // empty' <<<"$reply")"
  [[ -n "$LOCAL" ]] || { record FAIL attach "no local id in $reply"; return 1; }
  check attach "$LOCAL" '.presentation.state == "connected"'
  member="$(jq -r --arg c "$COMPANION" \
    '.result.remoteGroup.companions[]? | select(.origin == $c) | .id // empty' <<<"$reply")"
  if [[ -n "$member" ]]; then
    check group "$member" '.presentation.state == "connected"'
  else
    record FAIL group "companion $COMPANION missing from $(jq -c '.result.remoteGroup // {}' <<<"$reply")"
  fi
}

finish() {
  local name="$1" pid="$2"
  shift 2
  FINISH_STATUS=0
  if ! exited_within "$pid" "$DEADLINE"; then
    record RECORDED "$name" "still pending after ${DEADLINE}s"
    [[ $# -eq 0 ]] || rctl "$@" >/dev/null 2>&1 || true
    exited_within "$pid" 5 || kill "$pid" 2>/dev/null || true
  fi
  wait "$pid" || FINISH_STATUS=$?
  record RECORDED "$name" "exit $FINISH_STATUS: $(tr '\n' ' ' <"$STATE/$name.out")"
}

expect_exit() {
  if [[ "$FINISH_STATUS" -eq "$2" ]]; then
    record PASS "$1" "exit $2"
  else
    record FAIL "$1" "expected exit $2, got $FINISH_STATUS"
  fi
}

# a detach experiment only means something when the interaction was showing before the detach
detach_during() {
  local name="$1" predicate="$2" got
  if got="$(wait_for "$LOCAL" "$predicate")"; then
    record PASS "$name-shown" "$predicate"
    detach_and_reattach "$name"
  else
    record FAIL "$name-shown" "$predicate never held, detach not run; last node: $got"
  fi
}

detach_and_reattach() {
  local name="$1"
  ctl session close --target "$LOCAL" >/dev/null
  sleep 2
  record RECORDED "$name-origin" "$(origin_node | jq -c '{ask, overlay, htmlOverlays, remoteOverlays, presenters}')"
  attach
  record RECORDED "$name-after" "$(node "$LOCAL" | jq -c '{ask, overlay, htmlOverlays, presentation}')"
}

launch
if [[ -z "$SESSION" ]]; then
  SESSION="$(ctl zmx tree "$HOST" --json | jq -r '.result.remote.sessions[0].id // empty')"
  [[ -n "$SESSION" ]] || die "$HOST lists no attachable session"
fi
# group attach is only verified with a member to attach, so the gate makes one and ends it afterwards
COMPANION="$(rctl session new --parent "$SESSION" --json | jq -r '.result.id // empty')"
[[ -n "$COMPANION" ]] || die "could not create a companion of $SESSION on $HOST"
attach || exit 1

rctl session status active --target "$SESSION" >/dev/null
check status "$LOCAL" '.status == "active"'

nonce="gate-$RANDOM"
rctl session context "$nonce" --target "$SESSION" >/dev/null
check context "$LOCAL" ".context == \"$nonce\""

rctl session hud "gate hud" --target "$SESSION" >/dev/null
check hud-open "$LOCAL" '.hud != null'
rctl session hud close --target "$SESSION" >/dev/null
check hud-close "$LOCAL" '.hud == null'

start_remote "$STATE/ask.out" "$(remote_line agtermctl ask "gate ask" --button ok=OK --target "$SESSION")"
ask_pid=$BG_PID
ask_id=""
if got="$(wait_for "$LOCAL" '.ask.replica == true')"; then
  record PASS ask-shown '.ask.replica == true'
  ask_id="$(jq -r '.ask.id' <<<"$got")"
  rctl ask cancel "$ask_id" >/dev/null
  check ask-cancelled "$LOCAL" '.ask == null'
else
  record FAIL ask-shown "last node: $got"
fi
finish ask "$ask_pid" ask cancel "${ask_id:-none}"
expect_exit ask-outcome 2

start_remote "$STATE/overlay.out" \
  "$(remote_line agtermctl session overlay open --block --target "$SESSION" 'sleep 3; exit 7')"
overlay_pid=$BG_PID
check overlay-shown "$LOCAL" '.overlay == true'
finish overlay "$overlay_pid" session overlay close --target "$SESSION"
expect_exit overlay-outcome 7
check overlay-closed "$LOCAL" '.overlay == false'

PAGE="/tmp/agterm-gate-$RANDOM.html"
rctl_shell "printf '<h1>gate</h1>\\n' > $PAGE" >/dev/null
rctl session overlay open --html "$PAGE" --target "$SESSION" >/dev/null
# a replica runs under a page id of the presenting Mac's own, so it is matched by the origin's file
detach_during detach-page "[.htmlOverlays[]? | select(.replica == true and .file == \"$PAGE\")] | length == 1"
rctl session overlay close --target "$SESSION" >/dev/null 2>&1 || true

start_remote "$STATE/detach-ask.out" "$(remote_line agtermctl ask "gate detach ask" --button ok=OK --target "$SESSION")"
ask_pid=$BG_PID
detach_during detach-ask '.ask.replica == true'
finish detach-ask "$ask_pid" ask cancel "$(origin_node | jq -r '.ask.id // "none"')"

start_remote "$STATE/detach-program.out" \
  "$(remote_line agtermctl session overlay open --block --target "$SESSION" 'sleep 60')"
overlay_pid=$BG_PID
detach_during detach-program '.overlay == true'
finish detach-program "$overlay_pid" session overlay close --target "$SESSION"

stop_app
launch
record RECORDED relaunch "$(ctl tree --json | jq -c --arg h "$HOST" '[.. | objects | select(.remoteHost? == $h) | .id]')"

echo "results: $RESULTS"
exit "$FAILED"
