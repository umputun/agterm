#!/usr/bin/env bash
# agterm-claude-resume — pin `claude --resume <id>` as the pane's restore command.
#
# Run by the Claude adapter (`agterm-claude-status.sh resume`) from Claude Code's SessionStart and
# SessionEnd hooks, after its worker guard, so only the pane's own agent pins. Under Re-run commands
# the next launch then reopens this conversation whether Claude Code was quit by hand or agterm exited
# around it; a plain `claude` capture would start a new one. SessionStart keeps the pin on the LIVE id
# through /clear, /resume and compaction. The pin persists until something replaces it:
# `agtermctl session restore --clear` drops it, and AGTERM_CLAUDE_RESUME=0 turns this script off.
#
# Like the status wrapper it never interferes with the agent: silent, and always exit 0.
set -u

[ -n "${AGTERM_SESSION_ID:-}" ] || exit 0
[ "${AGTERM_CLAUDE_RESUME:-1}" = 0 ] && exit 0

# the id goes into persisted shell code, so only a UUID-shaped value may reach it.
sid=$(/usr/bin/plutil -extract session_id raw -o - - 2>/dev/null) || exit 0
[[ $sid =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || exit 0

args=(--target "$AGTERM_SESSION_ID")
[ -n "${AGTERM_PANE:-}" ] && args+=(--pane "$AGTERM_PANE")
[ -n "${AGTERM_PANE_ID:-}" ] && args+=(--pane-id "$AGTERM_PANE_ID")
[ -n "${AGTERM_SOCKET:-}" ] && args+=(--socket "$AGTERM_SOCKET")

"${AGTERMCTL:-agtermctl}" session restore "claude --resume $sid" "${args[@]}" >/dev/null 2>&1 || true
exit 0
