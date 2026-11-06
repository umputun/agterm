#!/usr/bin/env bash
# subagent-pick.sh SESSION_ID - pick one of the session's subagents and page its transcript over the session.
# The keymap passes {AGT_SESSION_ID}, the session the chord fired in.
set -u
[ -n "${1:-}" ] || { echo "usage: $0 SESSION_ID" >&2; exit 2; }
export AGTERM_SESSION_ID=$1
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=subagent-common.sh
. "$script_dir/subagent-common.sh"

# no subagents is an answer, not a failure: say so over the session and exit 0, or agterm reports a failed command
nothing_to_pick() {
  "$AGTERMCTL" session hud "No subagents in this conversation" --hide-after 3 --target "$AGTERM_SESSION_ID" \
    >/dev/null 2>&1
  exit 0
}

conversation=$(current_conversation)
dir=$(conversation_dir "$conversation")
[ -n "$conversation" ] && [ -d "$dir" ] || nothing_to_pick

# a session has one overlay slot, and a live viewer.pid marks it as a transcript this picker opened;
# viewer.agent names whose, so the list leaves out the one already on screen unless it is the only one. A HUD
# saying there is nothing else is refused over the running viewer, so a one-item picker is the answer instead
viewer_pid_file=$session_dir/viewer.pid
viewer_agent_file=$session_dir/viewer.agent
viewer_pid=$(read_file "$viewer_pid_file")
shown=
if [ -n "$viewer_pid" ] && kill -0 "$viewer_pid" 2>/dev/null; then
  shown=$(read_file "$viewer_agent_file")
  others=0
  for status_file in "$dir"/*.status; do
    [ -f "$status_file" ] && [ "$status_file" != "$dir/$shown.status" ] && others=$((others + 1))
  done
  [ "$others" -gt 0 ] || shown=
else
  viewer_pid=
fi

json_string() {
  local s=${1//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$(printf '%s' "$s" | tr -d '\000-\037')"
}

# Claude writes what the subagent was asked to do beside its transcript, a moment after the start
description_of() {
  plutil -extract description raw -o - "${1%.jsonl}.meta.json" 2>/dev/null
}

items=
for status_file in "$dir"/*.status; do
  [ -f "$status_file" ] || continue
  id=${status_file##*/}
  id=${id%.status}
  [ "$id" = "$shown" ] && continue
  status=$(status_of "$dir/$id")
  transcript=$(read_file "$dir/$id.transcript")
  label=$(description_of "$transcript")
  label=${label:-$id}
  if [ "$status" = running ]; then
    glyph=active
    subtitle=$(read_file "$dir/$id.activity")
  else
    glyph=completed
    subtitle='done'
  fi
  items+="${items:+,}{\"id\":$(json_string "$id"),\"label\":$(json_string "$label"),"
  items+="\"subtitle\":$(json_string "${subtitle:-starting}"),\"status\":\"$glyph\"}"
done
[ -n "$items" ] || nothing_to_pick

result=$(printf '[%s]' "$items" | "$AGTERMCTL" pick --prompt "Subagent transcript") || exit 0
id=$(plutil -extract id raw -o - - <<<"$result" 2>/dev/null)
[ -n "$id" ] || exit 0

transcript=$(read_file "$dir/$id.transcript")
title=$(description_of "$transcript")
follow=
[ "$(status_of "$dir/$id")" = running ] && follow=--follow
# replace a transcript this picker opened, never another program's overlay
[ -n "$viewer_pid" ] && "$AGTERMCTL" session overlay close --target "$AGTERM_SESSION_ID" >/dev/null 2>&1
write_file "$viewer_agent_file" "$id"
command=$(printf 'AGT_SUBAGENT_VIEWER_PID_FILE=%q %q %q %q %s' "$viewer_pid_file" "$script_dir/transcript-view.sh" \
  "$transcript" "${title:-$id}" "$follow")
"$AGTERMCTL" session overlay open "$command" --target "$AGTERM_SESSION_ID"
