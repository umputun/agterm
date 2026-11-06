#!/usr/bin/env bash
# Sourced by subagent-hook.sh and subagent-pick.sh, never run.
#
# State, one small file per fact, so two subagents finishing at once never rewrite the same file. A
# conversation is kept apart from the agterm session, because --resume can bring it back in another one:
#   $AGT_SUBAGENT_STATE/<agterm session>/current                   the conversation the session shows
#   $AGT_SUBAGENT_STATE/<agterm session>/agent.pid                 the claude process, the refresher's stop condition
#   $AGT_SUBAGENT_STATE/conversations/<conversation>/<id>.status   running | completed
#   ...                                             /<id>.pid      the claude process that started it
#   ...                                             /<id>.activity the tool call it ran last
#   ...                                             /<id>.transcript its JSONL
#   ...                                             /turn-ended    the parent's turn ended with subagents still running

AGTERMCTL=${AGTERMCTL:-agtermctl}
AGT_SUBAGENT_STATE=${AGT_SUBAGENT_STATE:-$HOME/.local/state/agterm-subagents}
AGT_SUBAGENT_REFRESH=${AGT_SUBAGENT_REFRESH:-10}
AGT_SUBAGENT_HIDE_AFTER=${AGT_SUBAGENT_HIDE_AFTER:-30}
AGT_SUBAGENT_LINGER=${AGT_SUBAGENT_LINGER:-60}
if [ -z "${AGT_STATUS_SCRIPT:-}" ]; then
  AGT_STATUS_SCRIPT=$HOME/.config/agterm/agent-status/agterm-claude-status.sh
  [ -x "$AGT_STATUS_SCRIPT" ] || AGT_STATUS_SCRIPT=$HOME/.config/agterm/agent-status/agterm-agent-status.sh
fi

session_dir=$AGT_SUBAGENT_STATE/${AGTERM_SESSION_ID:-none}

write_file() { printf '%s\n' "$2" > "$1.$$" && mv -f "$1.$$" "$1"; }
read_file() { [ -r "$1" ] && head -n 1 "$1"; }

current_conversation() { read_file "$session_dir/current"; }
conversation_dir() { printf '%s/conversations/%s' "$AGT_SUBAGENT_STATE" "$1"; }

# post a status through the hooks package, or straight to agtermctl without it
post_status() {
  if [ -x "$AGT_STATUS_SCRIPT" ]; then
    "$AGT_STATUS_SCRIPT" "$@" </dev/null >/dev/null 2>&1
  else
    "$AGTERMCTL" session status "$@" --target "$AGTERM_SESSION_ID" >/dev/null 2>&1
  fi
}

# status_of DIR/ID prints a subagent's status. A claude killed mid-run never sends its SubagentStop, so a
# running subagent whose claude is gone counts as finished
status_of() {
  local status pid
  status=$(read_file "$1.status")
  if [ "$status" = running ]; then
    pid=$(read_file "$1.pid")
    [ -z "$pid" ] || kill -0 "$pid" 2>/dev/null || status=completed
  fi
  printf '%s' "$status"
}

# count_status DIR STATUS
count_status() {
  local n=0 f
  for f in "$1"/*.status; do
    [ -f "$f" ] && [ "$(status_of "${f%.status}")" = "$2" ] && n=$((n + 1))
  done
  printf '%s' "$n"
}

# the activity of the subagent that reported one last, empty when none is running
latest_activity() {
  local newest=
  for f in "$1"/*.activity; do
    [ -f "$f" ] || continue
    [ "$(status_of "${f%.activity}")" = running ] || continue
    [ -z "$newest" ] || [ "$f" -nt "$newest" ] && newest=$f
  done
  [ -n "$newest" ] && read_file "$newest"
}

# summary_line RUNNING FINISHED ACTIVITY prints the sidebar line as session info markdown, at most 512 bytes
summary_line() {
  local running=$1 finished=$2 activity line quote="'"
  if [ "$running" -eq 0 ]; then
    [ "$finished" -eq 1 ] && line="1 subagent done" || line="$finished subagents done"
    printf '^[%s](dim: true)' "$line"
    return
  fi
  [ "$running" -eq 1 ] && line="**1** subagent" || line="**$running** subagents"
  line+=' ^[running](color: "green")'
  [ "$finished" -gt 0 ] && line+=" · ^[$finished done](dim: true)"
  # the agent's text goes in a code span so its own markup stays literal; iconv drops a character the
  # cut split, which would otherwise make the whole line invalid UTF-8
  activity=$(printf '%s' "${3//\`/$quote}" | cut -c 1-80 | iconv -c -f UTF-8 -t UTF-8 2>/dev/null)
  [ -n "$activity" ] && line+=" · \`$activity\`"
  printf '%s' "$line"
}

# set_line DIR HIDE_AFTER sets the session's info line from DIR's subagents, or clears it when there are none
set_line() {
  local running finished
  running=$(count_status "$1" running)
  finished=$(count_status "$1" completed)
  if [ "$running" -eq 0 ] && [ "$finished" -eq 0 ]; then
    "$AGTERMCTL" session info --clear --target "$AGTERM_SESSION_ID" >/dev/null 2>&1
    return
  fi
  "$AGTERMCTL" session info --markdown --hide-after "$2" --target "$AGTERM_SESSION_ID" \
    "$(summary_line "$running" "$finished" "$(latest_activity "$1")")" >/dev/null 2>&1
}
