#!/usr/bin/env bash
# lights-common.sh — settings and helpers shared by the truthful-agent-lights
# scripts. Sourced, never executed: every value below is a variable you can
# override in the environment of the hooks and of the sweeper, and both sides
# must agree on AGT_LIGHTS_STATE or the sweeper reads no stamps at all.
#
# Colors and shapes are per-call overrides. A per-call override BEATS whatever
# you picked in Settings ▸ Agent Status, so if a shape here collides with your
# own vocabulary, change it here rather than in Settings.

# the CLI that talks to the control socket
AGTERMCTL=${AGTERMCTL:-agtermctl}

# Where the pid notes, turn stamps and heartbeats live. The hooks and the
# sweeper must resolve this to the SAME directory or the sweeper reads no
# stamps at all and reports every session as idle.
#
# XDG_STATE_HOME is ignored deliberately, and this is the reason: the hooks run
# inside your shell, where an XDG_STATE_HOME exported from a shell rc is set,
# while the sweeper runs from launchd, which starts with no such environment.
# Honoring it would put the two halves in two different directories on exactly
# the machines that set it — the hooks writing stamps nobody reads, the sweeper
# concluding that live sessions are dead. A path off $HOME is the same path in
# both. Override AGT_LIGHTS_STATE if you must, and then set it in both places.
AGT_LIGHTS_STATE=${AGT_LIGHTS_STATE:-$HOME/.local/state/agterm-lights}

# the stock status script the hooks package installs. When it is present the
# recipe posts through it, so socket, pane and pane-id handling stay upstream's;
# when it is not, the fallback below calls agtermctl directly.
AGT_STATUS_SCRIPT=${AGT_STATUS_SCRIPT:-$HOME/.config/agterm/agent-status/agterm-agent-status.sh}

# extended regex of agent binaries, matched against the WHOLE command name:
# every alternative is an exact basename, not a prefix. Add yours as its own
# alternative (`claude|codex|my-agent-wrapper`) rather than relying on a prefix
# to cover it — a prefix would also swallow ordinary commands that merely start
# the same way, and a process wrongly read as an agent makes a row claim a
# worker that does not exist.
AGT_AGENT_PATTERN=${AGT_AGENT_PATTERN:-claude|codex|kimi|opencode|pi}

# The work tint, and the silhouette per sub-state. These six take the `${VAR-…}`
# form on purpose, not `${VAR:-…}`: setting one to the empty string is how you
# say "post this state with no override of my own", and a `:-` default would
# quietly hand the default back instead of honoring that.
AGT_WORK_COLOR=${AGT_WORK_COLOR-#4A9EFF}
AGT_STUCK_COLOR=${AGT_STUCK_COLOR-#FF3B30}
AGT_SHAPE_RUNNING=${AGT_SHAPE_RUNNING-square}      # machinery is executing
AGT_SHAPE_MIXED=${AGT_SHAPE_MIXED-diamond}         # executing AND queued
AGT_SHAPE_QUEUED=${AGT_SHAPE_QUEUED-triangle}      # only waiting for a slot
AGT_SHAPE_STUCK=${AGT_SHAPE_STUCK-star}            # claims to run, makes no progress

# timings, all seconds
AGT_HB_FRESH_SECS=${AGT_HB_FRESH_SECS:-300}   # a hook fired this recently: hands off
AGT_HB_STALE_SECS=${AGT_HB_STALE_SECS:-1500}  # no hook this long: the glyph is unbacked
AGT_OWN_LIVE_SECS=${AGT_OWN_LIVE_SECS:-900}   # cap on "my own turn is live" without writes
AGT_STALL_SECS=${AGT_STALL_SECS:-1500}        # running claim, no transcript progress: stuck
AGT_SSH_WORK_SECS=${AGT_SSH_WORK_SECS:-120}   # ssh older than this is a run, not a probe

agt_active_args() { # color shape [extra flags…] -> fills AGT_STATUS_ARGS
  # Blank a color or shape variable to mean "post this state without that
  # override", so the glyph falls back to your Settings ▸ Agent Status choice.
  # The empty value must never reach the CLI: agtermctl rejects `--shape ""`,
  # and the status call swallows its own errors, so it would fail invisibly.
  local color=$1 shape=$2
  shift 2
  AGT_STATUS_ARGS=(active "$@")
  [ -n "$color" ] && AGT_STATUS_ARGS+=(--color "$color")
  [ -n "$shape" ] && AGT_STATUS_ARGS+=(--shape "$shape")
  return 0
}

agt_pid_start() { # pid -> its start time as one normalized line, empty when gone
  ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ *//; s/ *$//'
}

agt_write_pid_note() { # note-path pid — records the pid AND when it started
  # The start time is what makes the note safe to believe later: pids are
  # recycled, and a recycled one can land on another agent process, which no
  # name check can tell apart from the original.
  printf '%s %s\n' "$2" "$(agt_pid_start "$2")" > "$1" 2>/dev/null || true
}

agt_note_pid() { # note-path -> the pid it records, or nothing
  local line
  line=$(cat "$1" 2>/dev/null) || return 1
  [ -n "$line" ] || return 1
  printf '%s' "${line%% *}"
}

agt_note_is_live() { # note-path -> 0 when that exact process is still running
  # pid alive, still an agent binary, and started when the note says it did
  local line pid start
  line=$(cat "$1" 2>/dev/null) || return 1
  pid=${line%% *}
  start=${line#* }
  [ -n "$pid" ] || return 1
  case "$pid" in *[!0-9]*) return 1 ;; esac
  agt_is_agent_name "$(agt_base_name "$(ps -o command= -p "$pid" 2>/dev/null)")" || return 1
  [ "$start" = "$line" ] && return 0    # note predates start-time recording
  [ "$start" = "$(agt_pid_start "$pid")" ]
}

agt_state_dir() { # ensure and echo a state subdirectory
  mkdir -p "$AGT_LIGHTS_STATE/$1" 2>/dev/null || true
  printf '%s\n' "$AGT_LIGHTS_STATE/$1"
}

agt_is_agent_name() { # command name -> 0 when it is an agent binary
  # anchored at both ends: `pi` must not match `ping`, `pip` or `pipx`
  printf '%s' "$1" | grep -qE "^($AGT_AGENT_PATTERN)$"
}

agt_base_name() { # argv string -> bare command name, unwrapping ps's (parens)
  local b=${1%% *}
  b=${b##*/}; b=${b#\(}; b=${b%\)}
  printf '%s' "$b"
}

agt_find_agent_pid() { # walk up from $1 (default $PPID) to the agent process
  local p=${1:-$PPID} cmd
  local _
  for _ in 1 2 3 4 5 6; do
    [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null || break
    cmd=$(ps -o command= -p "$p" 2>/dev/null) || break
    if agt_is_agent_name "$(agt_base_name "$cmd")"; then
      printf '%s\n' "$p"
      return 0
    fi
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  done
  return 1
}
