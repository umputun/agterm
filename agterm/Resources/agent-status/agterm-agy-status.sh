#!/usr/bin/env bash
# Antigravity CLI (agy) status adapter installed by agterm's Help ▸ Install Agent Status Hooks command.
# agy parses every hook's stdout as one JSON object and requires a decision from PreToolUse and Stop,
# so the reply is printed before anything can exit, and the status wrapper's output never reaches it.
# PreToolUse's "allow" leaves the tool to agy's own permission check (measured on 1.5.16). Only the two
# prompt tools route here: PreToolUse fires before that check, so any other tool would read as blocked.
set -u

action=${1:-}
case "$action" in
  ask) printf '{"decision":"allow"}\n' ;;
  stop) printf '{"decision":"stop"}\n' ;;
  *) printf '{}\n' ;;
esac

# drained on every action, so agy never writes into a closed pipe; bash 3.2's read returns 1 at EOF and
# on timeout alike, so the payload is tested, not the status
payload=
[ -t 0 ] || IFS= read -r -d '' -t 2 payload || true

[ -n "${AGTERM_SESSION_ID:-}" ] || exit 0

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
status_wrapper=${AGTERM_STATUS_WRAPPER:-"$script_dir/agterm-agent-status.sh"}

. "$script_dir/agent-owner.sh"
spawned_by_agent && exit 0

case "$action" in
  invocation) set -- active --blink ;;
  ask) set -- blocked ;;
  stop)
    # fullyIdle is false while a background command, subagent or timer still runs; agy wakes the agent
    # when it finishes, and that turn's Stop completes. A quote inside a JSON string is escaped, so the
    # pattern cannot match text the user typed.
    still_running='"fullyIdle"[[:space:]]*:[[:space:]]*false'
    if [[ $payload =~ $still_running ]] && [ "${AGTERM_AGY_IGNORE_BACKGROUND:-}" != 1 ]; then
      set -- active --blink
    else
      set -- completed --auto-reset
    fi
    ;;
  *) exit 0 ;;
esac

"$status_wrapper" "$@" >/dev/null 2>&1 || true
