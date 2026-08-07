#!/usr/bin/env zsh
# Kiro CLI agent status for zsh and bash — source from ~/.zshrc or ~/.bashrc.
# The shebang names zsh to match the extension and the other .zsh recipes; the body is
# portable to bash, which is why ~/.bashrc is a supported home for it too.
#
# Defines `kiro-cli` (and `kiro`) as a shell FUNCTION shadowing the real binary. The function
# starts kiro-status-detector.sh in the background, runs the real command in the foreground, then
# kills the detector and clears the row the moment that command returns, crash included, since that
# is ordinary job control and not something this file has to arrange. Not covered: a terminal SIGINT,
# which hits the whole foreground group and abandons the rest of this function along with kiro-cli —
# see the Ctrl-C entry in README.md's Limits. A function also catches an ALIAS pointing at
# `kiro-cli`, because alias expansion
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

# Is that pid still our detector? The poller has stop conditions of its own — a hard-killed app
# takes about five seconds of failed reads — so it can be long gone while kiro-cli runs on for hours,
# and the shell reaps it, which frees the number for reuse. Killing a bare remembered pid would then
# signal whatever inherited it. Checked against argv rather than trusted.
#
# Matched on $KIRO_STATUS_DETECTOR, not on the basename this file ships with: that variable is a
# documented override, so a renamed or symlinked poller would fail a basename test and be skipped by
# the teardown below — trading a rare wrong kill for a reliable orphan, which is the worse bug. The
# check is best-effort by nature (`ps` could be missing, and the pid could in principle be reused by
# another session's poller), so it errs toward killing: only a definite mismatch skips teardown.
function _kas_is_detector {
  local cmd
  cmd=$(/bin/ps -o command= -p "$1" 2>/dev/null) || return 0
  [ -z "$cmd" ] && return 1
  case "$cmd" in
    *"$KIRO_STATUS_DETECTOR"*) return 0 ;;
    *) return 1 ;;
  esac
}

function _kas_run {
  local real=$1 pid= rc
  shift
  # Checked rather than just launched, because a detector that lost its executable bit in transit
  # (a copy, a download, an archive) would otherwise fail into >/dev/null and leave no trace at all
  # beyond a session that silently never reports. Warned once per shell, not once per turn.
  if [ -x "$KIRO_STATUS_DETECTOR" ]; then
    # No `active` report here. `kiro-cli chat` is a REPL: this function spans the whole session, so a
    # status set at entry would sit on the row between turns too. Per-turn state is the poller's job.
    "$KIRO_STATUS_DETECTOR" >/dev/null 2>&1 &
    pid=$!
    disown %+ 2>/dev/null || true   # %+ (most recent job) works in both bash and zsh; suppresses the interactive "[N] terminated" notice this kill would otherwise print
  elif [ -z "${_kas_warned:-}" ]; then
    _kas_warned=1
    printf 'kiro-agent-status: %s is not executable, so status reporting is off (chmod +x it).\n' \
      "$KIRO_STATUS_DETECTOR" >&2
  fi
  # `&& ... || ...` rather than a bare call: under `set -e`/ERR_EXIT a nonzero kiro-cli would exit
  # the shell here and skip the idle report below, stranding whatever the poller last set. Note
  # `if ! cmd` would also survive errexit but loses the code — in the branch $? is the negation's 0.
  command "$real" "$@" && rc=0 || rc=$?
  if [ -n "$pid" ] && _kas_is_detector "$pid"; then
    kill "$pid" 2>/dev/null || true
    # No `wait`: the job was disowned, so neither shell can reap it here (zsh says so and returns
    # 127, bash silently returns 0 having reaped nothing) — and a killed, disowned child leaves no
    # zombie to collect anyway. The sleep is what matters, and it is not cosmetic: killing the poller
    # does not cancel a status write it had already spawned, and that grandchild would otherwise land
    # after the idle below and leave the row showing a turn that is over. A tick of the poll interval
    # is longer than that one agtermctl call has left to run.
    sleep "${KIRO_STATUS_INTERVAL:-0.5}" 2>/dev/null || true
  fi
  # The session is over, so nothing about it is worth flagging: `idle` clears the row unconditionally,
  # where a `completed` left to --auto-reset would outlive the thing it describes. The poller cannot do
  # this itself — by here it is dead either way, killed above or already self-exited. Runs even when no
  # poller started, since some earlier session may have left a status on the row.
  "$AGTERM_STATUS_WRAPPER" idle >/dev/null 2>&1 || true
  return $rc
}

# `function name { }`, not `name() { }`: an existing alias called kiro-cli or kiro expands in the
# name position of the latter and makes sourcing this file a syntax error, which would break every
# new shell — and an alias pointing at kiro-cli is exactly what this recipe sets out to support.
function kiro-cli { _kas_run kiro-cli "$@"; }
function kiro     { _kas_run kiro "$@"; }
