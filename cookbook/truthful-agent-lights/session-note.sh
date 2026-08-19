#!/usr/bin/env bash
# session-note.sh — SessionStart / UserPromptSubmit hook: note what the rest of
# the recipe needs to know about this session.
#
# Writes, under the state directory:
#   pid/<session-id>         the agent process id and its start time, so the
#                            classifier and the sweeper know which process tree
#                            to scan and can tell a recycled pid from the
#                            original
#   transcript/<session-id>  the transcript path from the hook payload, so the
#                            sweeper can measure progress
#   turnstart/<session-id>   touched on UserPromptSubmit only: a turn began
#
# $PPID is not reliably the agent — a hook can be invoked through an extra
# `zsh -c` layer — so this walks up until it finds an agent binary.
#
# Always exits 0, and prints nothing: Claude Code injects a hook's stdout into
# the prompt context.
set -u
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lights-common.sh
. "$DIR/lights-common.sh"

[ -n "${AGTERM_SESSION_ID:-}" ] || exit 0

# the hook payload arrives as JSON on stdin: transcript_path binds this session
# to its transcript file (the agent does not hold it open, so nothing else can
# find it), hook_event_name tells a prompt from a session start
# Read the payload WHOLE. A cap here is not a safety measure: a payload longer
# than the cap parses as truncated JSON, jq returns nothing, and the turn-start
# stamp is never written — which makes the sweeper believe no turn is running
# and hand the row the false `completed` this recipe exists to prevent. A large
# prompt or a long transcript path is enough to reach that.
tp=""; ev=""
if [ ! -t 0 ] && command -v jq >/dev/null 2>&1; then
  hj=$(cat)
  tp=$(printf '%s' "$hj" | jq -r '.transcript_path // empty' 2>/dev/null)
  ev=$(printf '%s' "$hj" | jq -r '.hook_event_name // empty' 2>/dev/null)
fi

agent_pid=$(agt_find_agent_pid "$PPID") || exit 0
[ -n "$agent_pid" ] || exit 0

agt_write_pid_note "$(agt_state_dir pid)/$AGTERM_SESSION_ID" "$agent_pid"
if [ -n "$tp" ]; then
  printf '%s\n' "$tp" > "$(agt_state_dir transcript)/$AGTERM_SESSION_ID" 2>/dev/null || true
fi
if [ "$ev" = "UserPromptSubmit" ]; then
  touch "$(agt_state_dir turnstart)/$AGTERM_SESSION_ID" 2>/dev/null || true
fi
exit 0
