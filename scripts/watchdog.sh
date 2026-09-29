#!/usr/bin/env bash
# run a command; past WATCHDOG_SECONDS, save its process tree's diagnostics and kill it (exit 124).
set -uo pipefail

deadline=${WATCHDOG_SECONDS:-600}
budget=${WATCHDOG_DIAG_SECONDS:-120}
out=${DIAG_DIR:-watchdog-diagnostics}

"$@" &
pid=$!

descendants() {
  local child
  for child in $(pgrep -P "$1"); do
    echo "$child"
    descendants "$child"
  done
}

# the tree is listed once, before any signal: a parent that exits first would hide its children from pgrep
kill_tree() {
  # shellcheck disable=SC2086 # the pid list is meant to split into words
  kill -TERM $1 2>/dev/null
  sleep 5
  # shellcheck disable=SC2086
  kill -KILL $1 2>/dev/null
}

# a cancelled job must not leave the tree running
trap 'kill_tree "$(echo "$pid"; descendants "$pid")"; exit 143' TERM INT

diag_end=0

# sample's duration omits symbolication, so diagnostic calls need a wall-clock cap
capped() {
  local limit=$1 file=$2 left=$((diag_end - SECONDS))
  shift 2
  ((left > 0)) || return 1
  ((limit < left)) || limit=$left
  perl -e 'alarm shift; exec @ARGV' "$limit" "$@" > "$file" 2>&1
  echo "exit $?" >> "$file"
}

diagnose() {
  local tree=$1 p
  diag_end=$((SECONDS + budget))
  mkdir -p "$out"
  ps -axo pid,ppid,pgid,stat,etime,command > "$out/ps-all.txt"
  # the test runner first: it holds the stuck test's stack
  for p in $(pgrep -f swiftpm-testing); do
    capped 20 "$out/sample-$p.log" sample "$p" 2 -file "$out/sample-$p.txt" || return
  done
  for p in $tree; do
    ps -o pid,ppid,pgid,stat,etime,command -p "$p" > "$out/proc-$p.txt" 2>&1
    capped 10 "$out/lsof-$p.txt" lsof -nP -b -p "$p" || return
  done
  for p in $tree; do
    [ -e "$out/sample-$p.log" ] && continue
    capped 20 "$out/sample-$p.log" sample "$p" 2 -file "$out/sample-$p.txt" || return
  done
}

elapsed=0
while kill -0 "$pid" 2>/dev/null; do
  if ((elapsed >= deadline)); then
    echo "watchdog: '$*' still running after ${deadline}s, writing diagnostics to $out" >&2
    tree=$(echo "$pid"; descendants "$pid")
    diagnose "$tree"
    kill_tree "$tree"
    exit 124
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done
wait "$pid"
