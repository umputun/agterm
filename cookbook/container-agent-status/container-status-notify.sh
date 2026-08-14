#!/usr/bin/env bash
# Runs INSIDE the container. Claude Code's hooks call this in place of the
# installer's agterm-agent-status.sh, which only knows how to reach a
# control socket that does not exist in here. Sends the same state agterm's
# own hooks would set, as JSON over TCP to agterm-remote-receiver.sh on the
# host instead of calling agtermctl directly.
#
# Usage: container-status-notify.sh <active|blocked|completed|idle> [--blink] [--auto-reset]
#
# Requires AGTERM_SESSION_ID and AGTERM_REMOTE_HOST (host:port) in the
# environment; a silent no-op without either, so it is safe to wire into a
# hook that also runs outside this setup.
set -u

[ -n "${AGTERM_SESSION_ID:-}" ] || exit 0
[ -n "${AGTERM_REMOTE_HOST:-}" ] || exit 0

state=$1
shift

case "$AGTERM_REMOTE_HOST" in
  *:*) ;;
  *) exit 0 ;; # without a port the split below silently yields host == port
esac

remote_host=${AGTERM_REMOTE_HOST%:*}
remote_port=${AGTERM_REMOTE_HOST##*:}

json="{\"cmd\":\"session-status\",\"state\":\"$state\",\"session_id\":\"$AGTERM_SESSION_ID\""
[ -n "${AGTERM_PANE:-}" ] && json="$json,\"pane\":\"$AGTERM_PANE\""
[ -n "${AGTERM_PANE_ID:-}" ] && json="$json,\"pane_id\":\"$AGTERM_PANE_ID\""

if [ $# -gt 0 ]; then
  args_json=""
  for arg in "$@"; do
    [ -n "$args_json" ] && args_json="$args_json,"
    args_json="$args_json\"$arg\""
  done
  json="$json,\"args\":[$args_json]"
fi
json="$json}"

printf '%s\n' "$json" | timeout 2 nc "$remote_host" "$remote_port" >/dev/null 2>&1 || true
exit 0
