#!/usr/bin/env bash
# Claude Code status adapter installed by agterm's Help ▸ Install Agent Status Hooks command.
# agent-owner.sh keeps a worker agent's hooks off the spawner's row. The argv reaches the shared
# wrapper unchanged except for the two payload rewrites at the end.
set -u

[ -n "${AGTERM_SESSION_ID:-}" ] || exit 0

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
status_wrapper=${AGTERM_STATUS_WRAPPER:-"$script_dir/agterm-agent-status.sh"}

. "$script_dir/agent-owner.sh"
spawned_by_agent && exit 0

# the completed->active rewrite drops the caller's flags: a carried --auto-reset would idle the row on the
# next visit while a background agent still runs. stdin is read only when it is not a terminal, and briefly,
# so an inherited open pipe never hangs a hook; bash 3.2's read returns 1 at EOF and on timeout alike, so
# the payload is tested, not the status.
payload=
[ -t 0 ] || IFS= read -r -d '' -t 2 payload || true

# the platform picks the parser: a Linux /usr/bin/plutil may be GNUstep's, which has no `-extract raw`
field() { # key path value, array length for an array, empty when absent or unparseable
  if [[ $OSTYPE == darwin* ]]; then
    if v=$(printf '%s' "$payload" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null); then printf '%s' "$v"; fi
  elif command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq -r --arg p "$1" \
      'getpath($p | split(".") | map(tonumber? // .)) | if type == "array" then length else . // empty end' 2>/dev/null
  fi
}

running_agent() {
  n=$(field background_tasks)
  case "$n" in '' | *[!0-9]*) return 1 ;; esac
  i=0
  while [ "$i" -lt "$n" ]; do
    if [ "$(field "background_tasks.$i.status")" = running ]; then
      case "$(field "background_tasks.$i.type")" in
        subagent | workflow) return 0 ;;
        shell) [ "${AGTERM_CLAUDE_IGNORE_SHELLS:-}" = 1 ] || return 0 ;;
      esac
    fi
    i=$((i + 1))
  done
  return 1
}

if [ -n "$payload" ]; then
  if [ -n "$(field agent_id)" ]; then
    [ "${1:-}" = active ] && set -- "$@" --if-idle
  elif [ "${1:-}" = completed ] && [ "$(field hook_event_name)" = Stop ] && running_agent; then
    set -- active --blink
  fi
fi

exec "$status_wrapper" "$@"
