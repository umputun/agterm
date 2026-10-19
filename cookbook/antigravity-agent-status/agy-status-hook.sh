#!/usr/bin/env bash
# Antigravity CLI (agy) lifecycle hook adapter for agterm agent status.
# Reads the hook payload from stdin, prints the JSON response agy requires on
# stdout, and forwards the state transition to agterm-agent-status.sh.

set -u

action=${1:-}
payload=""

case "$action" in
  invocation|tool-done)
    cat >/dev/null
    printf '{}\n'
    ;;
  ask)
    cat >/dev/null
    printf '{"decision":"allow"}\n'
    ;;
  stop)
    payload=$(cat)
    printf '{"decision":"stop"}\n'
    ;;
  *)
    cat >/dev/null
    printf '{}\n'
    exit 0
    ;;
esac

[ -n "${AGTERM_SESSION_ID:-}" ] || exit 0
{ [ -z "${CLAUDECODE:-}" ] && [ -z "${CLAUDE_CODE_SESSION_ID:-}" ]; } || exit 0

status_script=${AGTERM_STATUS_WRAPPER:-${AGTERM_STATUS_SCRIPT:-${HOME:-}/.config/agterm/agent-status/agterm-agent-status.sh}}
[ -x "$status_script" ] || exit 0

is_headless_agy() {
  local pid=$$ parent_cmd found_agy token
  local -a tokens=()
  for _ in 1 2 3 4 5 6; do
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    { [ -n "$pid" ] && [ "$pid" -gt 1 ]; } 2>/dev/null || break
    parent_cmd=$(ps -o command= -p "$pid" 2>/dev/null) || break
    case "$parent_cmd" in
      sh\ -c\ *|*/sh\ -c\ *|bash\ -c\ *|*/bash\ -c\ *|zsh\ -c\ *|*/zsh\ -c\ *)
        continue
        ;;
    esac
    read -r -a tokens <<< "$parent_cmd"
    found_agy=0
    for token in "${tokens[@]+"${tokens[@]}"}"; do
      if [ "$found_agy" -eq 0 ]; then
        case "$token" in
          agy|*/agy) found_agy=1 ;;
        esac
      else
        case "$token" in
          -p|--print|--prompt|--print=*|--prompt=*) return 0 ;;
        esac
      fi
    done
    [ "$found_agy" -eq 1 ] && return 1
  done
  return 1
}

is_headless_agy && exit 0

case "$action" in
  invocation|tool-done)
    "$status_script" active --blink >/dev/null 2>&1 || true
    ;;
  ask)
    "$status_script" blocked >/dev/null 2>&1 || true
    ;;
  stop)
    idle_false_re='"fullyIdle"[[:space:]]*:[[:space:]]*false'
    if [[ $payload =~ $idle_false_re ]]; then
      exit 0
    fi
    "$status_script" completed --auto-reset >/dev/null 2>&1 || true
    ;;
esac

exit 0
