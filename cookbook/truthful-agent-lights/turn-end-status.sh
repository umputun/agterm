#!/usr/bin/env bash
# turn-end-status.sh — Stop hook: end the turn on the glyph the session
# deserves, instead of an unconditional completed.
#
#   turn-end-status.sh completed --auto-reset
#
# The arguments are the fallback: they are used only when the scan proves
# nothing is left running. Otherwise:
#
#   a dispatched worker or subagent still alive  -> active --blink
#   machinery running AND something queued       -> active, work color, mixed shape
#   machinery running                            -> active, work color, running shape
#   only wait-shaped subtrees (locks, monitors)  -> active, work color, queued shape
#   the scan failed while an agent pid is known  -> active --blink
#
# The last line is deliberate: an unknown state must never read as done. A
# stale "something is running" costs you a glance; a false green costs you the
# work you thought had finished.
#
# Always exits 0 and prints nothing.
set -u
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lights-common.sh
. "$DIR/lights-common.sh"

[ -n "${AGTERM_SESSION_ID:-}" ] || exit 0

# stamp the turn end: the sweeper compares this against the turn-start stamp to
# tell a session that is producing from one that is merely holding a wait
touch "$(agt_state_dir turnend)/$AGTERM_SESSION_ID" 2>/dev/null || true

# find the agent process: walk up from the hook shell, fall back to the note
agent_pid=$(agt_find_agent_pid "$PPID" || true)
note="$AGT_LIGHTS_STATE/pid/$AGTERM_SESSION_ID"
if [ -z "$agent_pid" ] && [ -f "$note" ] && agt_note_is_live "$note"; then
  # the note is believed only when that exact process — same pid, same start
  # time, still an agent — is running; a recycled pid would classify a stranger
  agent_pid=$(agt_note_pid "$note")
fi

agents=""; machinery=""; waiting=""; remote=""; watch=""
if [ -n "$agent_pid" ]; then
  scan=$("$DIR/work-scan.sh" "$agent_pid" "$$" 2>/dev/null | head -1)
  case "$scan" in
    agents=*machinery=*waiting=*remote=*watch=*)
      agents=${scan#agents=};       agents=${agents%% *}
      machinery=${scan#*machinery=}; machinery=${machinery%% *}
      waiting=${scan#*waiting=};     waiting=${waiting%% *}
      remote=${scan#*remote=};       remote=${remote%% *}
      watch=${scan#*watch=};         watch=${watch%% *}
      ;;
  esac
  case "$agents$machinery$waiting$remote$watch" in
    ''|*[!0-9]*)
      # the scan said nothing usable while an agent pid is known: keep the
      # pulse and let the sweeper sort it out on its next pass
      exec "$DIR/set-status.sh" active --blink
      ;;
  esac
else
  agents=0; machinery=0; waiting=0; remote=0; watch=0
fi

running=$((machinery + remote))

if [ "$agents" -gt 0 ]; then
  exec "$DIR/set-status.sh" active --blink
fi
if [ "$running" -gt 0 ] && [ "$waiting" -gt 0 ]; then
  agt_active_args "$AGT_WORK_COLOR" "$AGT_SHAPE_MIXED"
  exec "$DIR/set-status.sh" "${AGT_STATUS_ARGS[@]}"
fi
if [ "$running" -gt 0 ]; then
  agt_active_args "$AGT_WORK_COLOR" "$AGT_SHAPE_RUNNING"
  exec "$DIR/set-status.sh" "${AGT_STATUS_ARGS[@]}"
fi
if [ $((waiting + watch)) -gt 0 ]; then
  agt_active_args "$AGT_WORK_COLOR" "$AGT_SHAPE_QUEUED"
  exec "$DIR/set-status.sh" "${AGT_STATUS_ARGS[@]}"
fi
exec "$DIR/set-status.sh" "$@"
