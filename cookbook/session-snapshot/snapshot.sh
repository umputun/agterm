#!/bin/bash
# Snapshot every open agterm window into $AGT_SNAP_DIR/<stamp>.{json,html} and point latest.html at it.
# Usage: snapshot.sh [--open]
set -eu
AGTERMCTL=${AGTERMCTL:-agtermctl}
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
dir=${AGT_SNAP_DIR:-$HOME/agterm-snapshots}

umask 077
mkdir -p "$dir" && chmod 700 "$dir"
stamp=$(date +%Y-%m-%d-%H%M%S)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

"$AGTERMCTL" window list --json > "$work/windows.json"
jq -r '.result.windows[] | select(.open) | .id' "$work/windows.json" | while read -r w; do
  "$AGTERMCTL" tree --window "$w" --json > "$work/tree-$w.json"
  jq -r '.result.tree.workspaces[].sessions[].id' "$work/tree-$w.json" | while read -r s; do
    "$AGTERMCTL" session text --target "$s" --window "$w" --pane left --lines 60 > "$work/screen-$s.txt" 2>/dev/null || true
  done
done

# live Claude Code sessions -> the agterm session and pane they run in, from Claude's own registry rather
# than by process name: an npm install runs as `node`, an SDK host under its own path.
# Every surface of a session shares AGTERM_SESSION_ID; AGTERM_PANE and AGTERM_PANE_ID tell them apart.
# A headless `claude -p` or SDK child started by a Claude inherits its pane's environment and registers too,
# so an entry with another registered Claude among its ancestors is not the pane's own conversation.
: > "$work/claude.tsv"
pids=" "
for j in "$HOME"/.claude/sessions/*.json; do
  [ -f "$j" ] || continue
  p=$(jq -r '.pid // empty' "$j")
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then pids="$pids$p "; fi
done
for j in "$HOME"/.claude/sessions/*.json; do
  [ -f "$j" ] || continue
  p=$(jq -r '.pid // empty' "$j")
  case $pids in *" $p "*) ;; *) continue ;; esac
  a=$p nested=
  while a=$(ps -o ppid= -p "$a" | tr -d ' ') && [ -n "$a" ] && [ "$a" -gt 1 ]; do
    case $pids in *" $a "*) nested=1; break ;; esac
  done
  [ -z "$nested" ] || continue
  env=$(ps eww -p "$p" -o command= | tr ' ' '\n')
  asid=$(sed -n 's/^AGTERM_SESSION_ID=//p' <<< "$env")
  pane=$(sed -n 's/^AGTERM_PANE=//p' <<< "$env")
  pane_id=$(sed -n 's/^AGTERM_PANE_ID=//p' <<< "$env")
  if [ -n "$asid" ]; then
    printf '%s\t%s\t%s\t%s\n' "$asid" "$pane" "$pane_id" "$(jq -r .sessionId "$j")" >> "$work/claude.tsv"
  fi
done

python3 "$here/render.py" "$work" "$dir" "$stamp" "$here/restore.sh"
if [ "${1:-}" = --open ]; then open "$dir/latest.html"; fi
