#!/usr/bin/env bash
# GitHub Copilot CLI status adapter installed by agterm's Help ▸ Install Agent Status Hooks command.
# Copilot parses a hook's stdout as JSON (agentStop's "block" forces another turn), so this prints
# nothing and the wrapper's output never reaches it. A question (elicitation_dialog) is not mapped:
# Autopilot answers its own and reports it only after the answer (measured on 1.0.116), so it would
# read as blocked through the rest of the turn.
set -u

action=${1:-}

# drained on every action, so Copilot never writes into a closed pipe; bash 3.2's read returns 1 at
# EOF and on timeout alike, so the payload is tested, not the status
payload=
[ -t 0 ] || IFS= read -r -d '' -t 2 payload || true

[ -n "${AGTERM_SESSION_ID:-}" ] || exit 0

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
status_wrapper=${AGTERM_STATUS_WRAPPER:-"$script_dir/agterm-agent-status.sh"}

. "$script_dir/agent-owner.sh"
spawned_by_agent && exit 0

# the platform picks the parser: a Linux /usr/bin/plutil may be GNUstep's, which has no `-extract raw`
field() { # key path value, empty when absent or unparseable
  if [[ $OSTYPE == darwin* ]]; then
    if v=$(printf '%s' "$payload" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null); then printf '%s' "$v"; fi
  elif command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq -r --arg p "$1" \
      'getpath($p | split(".") | map(tonumber? // .)) | . // empty' 2>/dev/null
  fi
}

# a subagent's hooks carry its agentId: its tool must not clear the main agent's pending permission
# prompt, and it fires its own agentStop while the main turn goes on (measured on 1.0.116)
subagent=
[ -n "$(field agentId)" ] && subagent=1

case "$action" in
  work)
    set -- active --blink
    [ -n "$subagent" ] && set -- active --blink --if-idle
    ;;
  ask) set -- blocked ;;
  stop)
    [ -n "$subagent" ] && exit 0
    set -- completed --auto-reset
    ;;
  end)
    [ -n "$subagent" ] && exit 0
    # a `copilot -p` run ends with reason "complete" right after its agentStop; idle would erase it
    [ "$(field reason)" = complete ] && exit 0
    set -- idle
    ;;
  *) exit 0 ;;
esac

"$status_wrapper" "$@" >/dev/null 2>&1 || true
