#!/usr/bin/env bash
# subagent-hook.sh MODE - Claude Code hook that keeps the session's info line on its subagents and holds
# the row's completed while one still runs. The payload comes on stdin. Never fails a hook.
#   conversation  SessionStart        start showing this conversation's subagents
#   start         SubagentStart
#   activity      PreToolUse          only a subagent's own tool calls carry agent_id
#   stop          SubagentStop
#   prompt        UserPromptSubmit
#   turn-end      Stop                replaces the stock Stop entry
#   end           SessionEnd
set -u
[ -n "${AGTERM_SESSION_ID:-}" ] || exit 0
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=subagent-common.sh
. "$script_dir/subagent-common.sh"

mode=${1:-}
payload=$(cat)
# plutil reads JSON on every supported macOS, where jq is not guaranteed
field() { plutil -extract "$1" raw -o - - <<<"$payload" 2>/dev/null; }
agent=$(field agent_id)
conversation=$(field session_id)
case "$mode" in start | activity | stop) [ -n "$agent" ] || exit 0 ;; esac

# The first agent above this hook is the claude that fired it; its pid tells the refresher when to give up.
# A second agent above that one spawned it as a worker (`claude -p` from a tool call), which inherits the
# session's AGTERM_SESSION_ID and must not take over its line. A run of one name counts once, for a launcher
# that does not exec, and an unreadable tree counts as the pane's own agent, as in the stock adapter.
is_agent() {
  case "$1" in claude | codex | kimi | opencode | pi | gemini | cursor-agent | aider | crush | goose) return 0 ;; esac
  return 1
}
agent_pid=
previous=
p=$PPID
for _ in 1 2 3 4 5 6 7 8; do
  line=$(ps -o ppid=,command= -p "$p" 2>/dev/null) || break
  line=${line#"${line%%[![:space:]]*}"}
  [ -n "$line" ] || break
  command=${line#* }
  name=${command%% *}
  name=${name##*/}
  # an npm-installed claude runs as `node .../claude`, so a runtime's first argument names the agent
  case "$name" in
    node | bun | deno)
      hosted=${command#* }
      hosted=${hosted%% *}
      is_agent "${hosted##*/}" && name=${hosted##*/}
      ;;
  esac
  if is_agent "$name"; then
    if [ "$name" != "$previous" ]; then
      [ -n "$agent_pid" ] && exit 0
      agent_pid=$p
    fi
    previous=$name
  else
    previous=
  fi
  p=${line%% *}
  [ "$p" -gt 1 ] 2>/dev/null || break
done

mkdir -p "$session_dir" 2>/dev/null && chmod 700 "$AGT_SUBAGENT_STATE" 2>/dev/null
touch "$session_dir/heartbeat" 2>/dev/null
[ -n "$conversation" ] && [ -z "$(current_conversation)" ] && write_file "$session_dir/current" "$conversation"
conversation=${conversation:-$(current_conversation)}
[ -n "$conversation" ] || exit 0
dir=$(conversation_dir "$conversation")
mkdir -p "$dir" 2>/dev/null

record_agent_pid() { [ -z "$agent_pid" ] || write_file "$session_dir/agent.pid" "$agent_pid"; }

refresher_alive() {
  local pid
  pid=$(read_file "$session_dir/refresher.pid")
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# keeps the line from expiring while a subagent runs, and gives up when the agent is gone, so a killed
# claude leaves no line behind
refresh_loop() {
  local conv pid beat
  while sleep "$AGT_SUBAGENT_REFRESH"; do
    conv=$(current_conversation)
    [ -n "$conv" ] || break
    pid=$(read_file "$session_dir/agent.pid")
    if [ -n "$pid" ]; then
      kill -0 "$pid" 2>/dev/null || break
    else
      beat=$(stat -f %m "$session_dir/heartbeat" 2>/dev/null || echo 0)
      [ $(($(date +%s) - beat)) -lt 1800 ] || break
    fi
    if [ "$(count_status "$(conversation_dir "$conv")" running)" -eq 0 ]; then
      set_line "$(conversation_dir "$conv")" "$AGT_SUBAGENT_LINGER"
      rm -f "$session_dir/refresher.pid"
      return
    fi
    set_line "$(conversation_dir "$conv")" "$AGT_SUBAGENT_HIDE_AFTER"
  done
  "$AGTERMCTL" session info --clear --target "$AGTERM_SESSION_ID" >/dev/null 2>&1
  rm -f "$session_dir/refresher.pid"
}

# one refresher per session; a start racing a refresher on its way out loses only one tick of the line,
# because every start and stop also sets the line itself
ensure_refresher() {
  refresher_alive && return
  refresh_loop </dev/null >/dev/null 2>&1 &
  write_file "$session_dir/refresher.pid" "$!"
}

# the parent's completed was held back while subagents ran; post it once the last one is done
release_completed() {
  [ -f "$dir/turn-ended" ] && [ "$(count_status "$dir" running)" -eq 0 ] || return 0
  rm -f "$dir/turn-ended"
  post_status completed --auto-reset
}

case "$mode" in
  conversation)
    # state untouched for a month belongs to sessions closed long ago and conversations nobody resumes
    find "$AGT_SUBAGENT_STATE" -mindepth 2 -maxdepth 2 -name heartbeat -mtime +30 2>/dev/null |
      while IFS= read -r beat; do rm -rf "${beat%/heartbeat}"; done
    find "$AGT_SUBAGENT_STATE/conversations" -mindepth 1 -maxdepth 1 -type d -mtime +30 ! -name "$conversation" \
      -exec rm -rf {} + 2>/dev/null
    write_file "$session_dir/current" "$conversation"
    record_agent_pid
    set_line "$dir" "$AGT_SUBAGENT_LINGER"
    ;;
  start)
    record_agent_pid
    [ -n "$agent_pid" ] && write_file "$dir/$agent.pid" "$agent_pid"
    write_file "$dir/$agent.status" running
    parent=$(field transcript_path)
    [ -n "$parent" ] && write_file "$dir/$agent.transcript" "${parent%.jsonl}/subagents/agent-$agent.jsonl"
    set_line "$dir" "$AGT_SUBAGENT_HIDE_AFTER"
    ensure_refresher
    ;;
  activity)
    # Claude Code's own helper agents call tools and stop without ever starting; only a started id counts
    [ -f "$dir/$agent.status" ] || exit 0
    tool=$(field tool_name)
    detail=$(field tool_input.description || field tool_input.command || field tool_input.file_path \
      || field tool_input.pattern)
    write_file "$dir/$agent.activity" "${tool}${detail:+: $detail}"
    write_file "$dir/$agent.status" running
    ensure_refresher
    ;;
  stop)
    [ -f "$dir/$agent.status" ] || exit 0
    write_file "$dir/$agent.status" completed
    transcript=$(field agent_transcript_path)
    [ -n "$transcript" ] && write_file "$dir/$agent.transcript" "$transcript"
    rm -f "$dir/$agent.activity"
    set_line "$dir" "$AGT_SUBAGENT_LINGER"
    release_completed
    ;;
  prompt)
    rm -f "$dir/turn-ended"
    ;;
  turn-end)
    if [ "$(count_status "$dir" running)" -gt 0 ]; then
      touch "$dir/turn-ended"
    else
      post_status completed --auto-reset
    fi
    ;;
  end)
    rm -f "$session_dir/current" "$session_dir/agent.pid"
    "$AGTERMCTL" session info --clear --target "$AGTERM_SESSION_ID" >/dev/null 2>&1
    ;;
esac
exit 0
