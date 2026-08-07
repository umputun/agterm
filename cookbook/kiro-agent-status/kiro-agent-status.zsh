#!/usr/bin/env bash
# Kiro CLI agent status for zsh and bash — source from ~/.zshrc or ~/.bashrc.
#
# Defines `kiro-cli` (and `kiro`) as a shell FUNCTION shadowing the real binary. The function
# starts kiro-status-detector.sh in the background, runs the real command in the foreground, then
# kills the detector and clears the row the moment that command returns — for any reason, including
# a crash or a Ctrl-C, since that is ordinary job control and not something this file has to
# arrange. A function also catches an ALIAS pointing at `kiro-cli`, because alias expansion
# resolves to the function before the shell looks up a binary; a preexec hook matching the typed
# text would miss that.
#
# The poller owns all three per-turn states (active, blocked, completed); this file owns only its
# lifetime and the final `idle`. Alternative to agterm's shipped shell/integration.sh, whose default
# AGTERM_AGENT_RE does not list kiro — do not add kiro to that regex on top of this, since for a REPL
# it pins one `active` across the whole session, which is what this recipe exists to avoid.
#
# Fish users want kiro-agent-status.fish instead.

[ -n "${AGTERM_SESSION_ID:-}" ] || return 0 2>/dev/null

# Locate kiro-status-detector.sh and the stock status script relative to this file.
if [ -n "${ZSH_VERSION:-}" ]; then
  _kas_self="${(%):-%x}"
  _kas_dir="${_kas_self:A:h}"
else
  _kas_self="${BASH_SOURCE[0]}"
  _kas_dir="$(cd "$(dirname "$_kas_self")" >/dev/null 2>&1 && pwd)"
fi
: "${KIRO_STATUS_DETECTOR:=$_kas_dir/kiro-status-detector.sh}"
: "${AGTERM_STATUS_WRAPPER:=$HOME/.config/agterm/agent-status/agterm-agent-status.sh}"

function _kas_run {
  local real=$1 pid rc
  shift
  # No `active` report here. `kiro-cli chat` is a REPL: this function spans the whole session, so a
  # status set at entry would sit on the row between turns too. Per-turn state is the poller's job.
  "$KIRO_STATUS_DETECTOR" >/dev/null 2>&1 &
  pid=$!
  disown %+ 2>/dev/null || true   # %+ (most recent job) works in both bash and zsh; suppresses the interactive "[N] terminated" notice this kill would otherwise print
  # `&& ... || ...` rather than a bare call: under `set -e`/ERR_EXIT a nonzero kiro-cli would exit
  # the shell here and skip the idle report below, stranding whatever the poller last set. Note
  # `if ! cmd` would also survive errexit but loses the code — in the branch $? is the negation's 0.
  command "$real" "$@" && rc=0 || rc=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  # `wait` reaps the poller but not a status write it had already spawned, which would otherwise land
  # after the idle below and leave the row showing a turn that is over. A tick of the poll interval is
  # longer than that one agtermctl call has left to run.
  sleep "${KIRO_STATUS_INTERVAL:-0.5}" 2>/dev/null || true
  # The session is over, so nothing about it is worth flagging: `idle` clears the row unconditionally,
  # where a `completed` left to --auto-reset would outlive the thing it describes. The poller already
  # reported completed for the last turn, and it cannot do this itself — it is killed a line above.
  "$AGTERM_STATUS_WRAPPER" idle >/dev/null 2>&1 || true
  return $rc
}

# `function name { }`, not `name() { }`: an existing alias called kiro-cli or kiro expands in the
# name position of the latter and makes sourcing this file a syntax error, which would break every
# new shell — and an alias pointing at kiro-cli is exactly what this recipe sets out to support.
function kiro-cli { _kas_run kiro-cli "$@"; }
function kiro     { _kas_run kiro "$@"; }
