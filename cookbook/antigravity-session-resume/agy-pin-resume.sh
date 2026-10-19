#!/usr/bin/env bash
# Antigravity CLI (agy) SessionStart hook: pin this agterm pane's restore
# command to `agy --conversation <conversationId>` so restarting agterm
# reopens the pane's own conversation.

set -u

payload=$(cat)
printf '{}\n'

[ -n "${AGTERM_SESSION_ID:-}" ] || exit 0
[ -n "${AGTERM_PANE_ID:-}" ] || exit 0
[ -n "${AGTERM_SOCKET:-}" ] || exit 0

# An agy worker spawned inside a Claude Code session shares the pane with its
# parent. The pane's restore pin belongs to the outer session, not the child.
{ [ -z "${CLAUDECODE:-}" ] && [ -z "${CLAUDE_CODE_SESSION_ID:-}" ]; } || exit 0

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

cid_re='"conversationId"[[:space:]]*:[[:space:]]*"([^"]*)"'
[[ $payload =~ $cid_re ]] || exit 0
conversation_id=${BASH_REMATCH[1]}

# The id lands in shell code (the pinned restore line), so reject anything
# outside a strict safe character set instead of quoting it in.
case "$conversation_id" in
  ""|-*|*[!A-Za-z0-9_-]*) exit 0 ;;
esac

agtermctl_bin=${AGTERMCTL:-agtermctl}
if ! command -v "$agtermctl_bin" >/dev/null 2>&1; then
  if [ -z "${AGTERMCTL:-}" ] && [ -x "${HOME:-}/Applications/agterm.app/Contents/MacOS/agtermctl" ]; then
    agtermctl_bin="${HOME:-}/Applications/agterm.app/Contents/MacOS/agtermctl"
  elif [ -z "${AGTERMCTL:-}" ] && [ -x /Applications/agterm.app/Contents/MacOS/agtermctl ]; then
    agtermctl_bin=/Applications/agterm.app/Contents/MacOS/agtermctl
  else
    exit 0
  fi
fi

"$agtermctl_bin" session restore "agy --conversation $conversation_id" \
  --target "$AGTERM_SESSION_ID" \
  --pane-id "$AGTERM_PANE_ID" \
  --socket "$AGTERM_SOCKET" >/dev/null 2>&1 || true

exit 0
