#!/bin/bash
# Recreate sessions from a snapshot.sh JSON in the frontmost agterm window.
# Usage: restore.sh [--dry-run] SNAPSHOT.json SESSION_ID...
#        restore.sh [--dry-run] SNAPSHOT.json --workspace WORKSPACE_ID
# A session that is still open, or was already restored from this snapshot, is selected instead of duplicated;
# one whose conversation a running Claude already holds is skipped.
set -eu
AGTERMCTL=${AGTERMCTL:-agtermctl}
dry=
if [ "${1:-}" = --dry-run ]; then dry=1; shift; fi
snap=${1:?usage: restore.sh [--dry-run] SNAPSHOT.json SESSION_ID... | --workspace WS_ID}
shift
[ -f "$snap" ] || { echo "no such snapshot: $snap" >&2; exit 1; }
if [ "${1:-}" = --workspace ]; then
  ids=$(jq -r --arg w "${2:?workspace id}" '.sessions[] | select(.workspaceId == $w) | .id' "$snap")
else
  ids="$*"
fi
[ -n "$ids" ] || { echo "nothing to restore" >&2; exit 1; }
exec 3>&1  # dry-run lines bypass the /dev/null redirects below
run() { if [ -n "$dry" ]; then echo "  would run: ${*%$'\n'}" >&3; else "$@"; fi; }

open_ids=$("$AGTERMCTL" window list --json | jq -r '.result.windows[] | select(.open) | .id' | while read -r w; do
  "$AGTERMCTL" tree --window "$w" --json | jq -r '.result.tree.workspaces[].sessions[].id'
done)

# a restored session gets a new id, so the snapshot id -> new id pairs are kept beside the snapshot
umask 077
restored=${snap%.json}.restored.tsv
restored_ids=$(cat "$restored" 2>/dev/null || true)

# conversations a running Claude holds right now; resuming one again interleaves its history
live_sids=$(for j in "$HOME"/.claude/sessions/*.json; do
  [ -f "$j" ] || continue
  p=$(jq -r '.pid // empty' "$j")
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then jq -r '.sessionId // empty' "$j"; fi
done)

# session type sends each byte as a keystroke, and a control byte (^U, ^C, a newline) acts in the line editor
# whatever the shell quoting around it; a backslash escapes inside fish single quotes, so POSIX quoting breaks there
typeable() { [[ ! $1 =~ [[:cntrl:]] && $1 != *\\* ]]; }
resumed() { sed -n 's/.*claude --resume \([0-9a-fA-F-]\{36\}\).*/\1/p' <<< "$1"; }

for id in $ids; do
  s=$(jq -c --arg id "$id" '.sessions[] | select(.id == $id)' "$snap")
  [ -n "$s" ] || { echo "not in snapshot: $id"; continue; }
  ws=$(jq -r .workspace <<< "$s")
  name=$(jq -r .name <<< "$s")
  if grep -qix "$id" <<< "$open_ids"; then
    run "$AGTERMCTL" session select --target "$id" > /dev/null 2>&1 || true
    echo "${dry:+[dry-run] }still open, selected: $ws / $name"
    continue
  fi
  prev=$(awk -F '\t' -v id="$id" 'toupper($1) == toupper(id) { print $2 }' <<< "$restored_ids" | tail -1)
  if [ -n "$prev" ] && grep -qix "$prev" <<< "$open_ids"; then
    run "$AGTERMCTL" session select --target "$prev" > /dev/null 2>&1 || true
    echo "${dry:+[dry-run] }already restored, selected: $ws / $name"
    continue
  fi
  cwd=$(jq -r .cwd <<< "$s")
  line=$(jq -r '.restore // empty' <<< "$s")
  has_split=$(jq -r '.split != null' <<< "$s")
  sline=$(jq -r '.split.restore // empty' <<< "$s")
  # only a conversation a line actually resumes can collide with a running Claude
  main_sid=$(resumed "$line")
  split_sid=$(resumed "$sline")
  busy=
  for sid in $main_sid $split_sid; do
    if grep -qix "$sid" <<< "$live_sids"; then busy=$sid; fi
  done
  if [ -n "$busy" ]; then
    echo "skipped: $ws / $name, conversation $busy is already running in another Claude"
    continue
  fi
  if [ -n "$split_sid" ] && [ "$split_sid" = "$main_sid" ]; then
    echo "  split resumes the main pane's conversation, not typed: $sline"
    sline=
  fi
  if [ -n "$line" ] && ! typeable "$line"; then
    echo "  not typed, it holds control characters or a backslash; run it by hand in bash or zsh: $line"
    line=
  fi
  if [ -n "$sline" ] && ! typeable "$sline"; then
    echo "  split line not typed, it holds control characters or a backslash; run it by hand in bash or zsh: $sline"
    sline=
  fi
  if [ -n "$dry" ]; then
    new=NEW_SESSION
    echo "  would run: $AGTERMCTL session new --workspace-name '$ws' --create-workspace --name '$name' --cwd '$cwd'"
  else
    new=$("$AGTERMCTL" session new --workspace-name "$ws" --create-workspace --name "$name" --cwd "$cwd" --json |
          jq -r .result.id)
  fi
  [ -z "$line" ] || run "$AGTERMCTL" session type --target "$new" "$line"$'\n' > /dev/null
  if [ "$has_split" = true ]; then
    run "$AGTERMCTL" session split on --target "$new" > /dev/null
    if [ -n "$sline" ]; then
      # the new pane's shell needs a moment before it takes input
      [ -n "$dry" ] || sleep 1
      run "$AGTERMCTL" session type --target "$new" --pane right "$sline"$'\n' > /dev/null ||
        { echo "  split pane not ready, run by hand: $sline"; sline=; }
    fi
  fi
  # recorded once the panes are set up, so a run that died halfway restores the session again on retry
  [ -n "$dry" ] || printf '%s\t%s\n' "$id" "$new" >> "$restored"
  live_sids=$(printf '%s\n%s\n%s' "$live_sids" "$(resumed "$line")" "$(resumed "$sline")")
  echo "${dry:+[dry-run] }restored: $ws / $name${line:+  ($line)}"
done
