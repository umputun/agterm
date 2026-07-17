#!/usr/bin/env bash
# agterm-agent-status — set the current agterm session's agent-status indicator.
#
#   agterm-agent-status.sh active            # agent is busy
#   agterm-agent-status.sh completed         # agent finished a turn
#   agterm-agent-status.sh blocked  --blink  # agent is waiting on you (pulse for attention)
#   agterm-agent-status.sh idle              # clear the indicator
#
# States: idle | active | completed | blocked. An optional --blink / --auto-reset
# (and any further args) is forwarded verbatim to `agtermctl session status`.
#
# Outside agterm this is a silent no-op, so it is safe to call from any hook.
#
# As a hook it must never interfere with the agent: stdout/stderr are suppressed
# (Claude Code injects a UserPromptSubmit/SessionStart hook's stdout into the
# prompt context) and it always exits 0 (a non-zero exit can block the turn).
#
# agtermctl resolution order (the binary that talks to the control socket):
#   1. $AGTERMCTL — an explicit override the caller set.
#   2. the absolute bundled-binary path the installer bakes in: the installer
#      rewrites the AGTERMCTL default below to agterm.app's Contents/MacOS/agtermctl,
#      so the hook fires even when the CLI was never symlinked into PATH.
#   3. `agtermctl` on PATH — the fallback when nothing above resolved.
set -u

[ -n "${AGTERM_SESSION_ID:-}" ] || exit 0   # not inside agterm: nothing to do

# --socket is a SUBCOMMAND option, so it must come AFTER `session status`, not before
# it. Pass it only when AGTERM_SOCKET is set (the app injects it alongside the id).
state=$1
shift

# forward the pane discriminators when the app injected them: each session surface
# (main/split/scratch) sets its own AGTERM_PANE (the role) plus AGTERM_PANE_ID (a stable
# per-surface token). the role can go stale — a split survivor promoted into the main pane
# keeps its baked `right` — so we also forward the token as --pane-id, which the app resolves
# to the surface's CURRENT slot and lets override the stale role (#199). both are validated
# agtermctl-side, so pass them through verbatim. the ${arr[@]+..} guard keeps the empty-array
# expansion safe under `set -u` on bash 3.2.
pane_args=()
[ -n "${AGTERM_PANE:-}" ] && pane_args+=(--pane "$AGTERM_PANE")
[ -n "${AGTERM_PANE_ID:-}" ] && pane_args+=(--pane-id "$AGTERM_PANE_ID")

if [ -n "${AGTERM_SOCKET:-}" ]; then
  "${AGTERMCTL:-agtermctl}" session status "$state" \
    --target "$AGTERM_SESSION_ID" --socket "$AGTERM_SOCKET" \
    "${pane_args[@]+"${pane_args[@]}"}" "$@" >/dev/null 2>&1 || true
else
  "${AGTERMCTL:-agtermctl}" session status "$state" \
    --target "$AGTERM_SESSION_ID" "${pane_args[@]+"${pane_args[@]}"}" "$@" >/dev/null 2>&1 || true
fi
exit 0
