#!/usr/bin/env bash
# set-status.sh — post one agent status for the current session, and leave a
# heartbeat behind so the sweeper can tell a live session from an abandoned
# glyph.
#
#   set-status.sh active --blink
#   set-status.sh active --color '#4A9EFF' --shape square
#   set-status.sh completed --auto-reset
#
# Every argument is forwarded verbatim to `agtermctl session status`. Outside
# agterm this is a silent no-op, and it always exits 0: a hook that fails must
# never block the agent's turn.
set -u
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lights-common.sh
. "$DIR/lights-common.sh"

[ -n "${AGTERM_SESSION_ID:-}" ] || exit 0
[ "$#" -gt 0 ] || exit 0

# heartbeat: every status post marks this session as alive
hb=$(agt_state_dir hb)
touch "$hb/$AGTERM_SESSION_ID" 2>/dev/null || true

# prefer the stock script the hooks package installs — socket, pane and
# pane-id handling then stay upstream's, and extra flags pass through
if [ -x "$AGT_STATUS_SCRIPT" ]; then
  "$AGT_STATUS_SCRIPT" "$@" >/dev/null 2>&1 || true
  exit 0
fi

state=$1
shift
args=()
[ -n "${AGTERM_PANE:-}" ] && args+=(--pane "$AGTERM_PANE")
[ -n "${AGTERM_PANE_ID:-}" ] && args+=(--pane-id "$AGTERM_PANE_ID")
[ -n "${AGTERM_SOCKET:-}" ] && args+=(--socket "$AGTERM_SOCKET")

"$AGTERMCTL" session status "$state" --target "$AGTERM_SESSION_ID" \
  "${args[@]+"${args[@]}"}" "$@" >/dev/null 2>&1 || true
exit 0
