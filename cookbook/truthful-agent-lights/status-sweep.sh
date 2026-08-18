#!/usr/bin/env bash
# status-sweep.sh — make the sidebar tell the truth in both directions, on a
# timer. A status is pushed and then trusted forever, so a killed agent leaves
# its last glyph pulsing and a session that quietly started working after its
# turn ended shows nothing at all.
#
# Run it from a LaunchAgent every couple of minutes (see the recipe's Setup).
# The invariant it maintains: no glyph means idle with nothing running, and a
# glyph that claims work is backed by a live process.
#
#   claims active, agent dead, hooks long dark   -> idle
#   claims active, agent alive, nothing running  -> completed, or idle when the
#                                                   hooks have gone dark
#   claims active while a worker subtree lives   -> active --blink
#   claims active while machinery or a queue runs-> active, work color + shape
#   claims active, no subtree, no progress       -> active, stuck color + shape
#   idle or completed while work is running      -> re-lit to match the work
#   blocked                                      -> left alone while anything
#                                                   backs it; a dead agent with
#                                                   dark hooks clears it
#
# Reads only; the only thing it changes is the glyph.
set -u
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lights-common.sh
. "$DIR/lights-common.sh"

AGT_LIGHTS_LOG=${AGT_LIGHTS_LOG:-$AGT_LIGHTS_STATE/sweep.log}
mkdir -p "$AGT_LIGHTS_STATE" 2>/dev/null || true
LOCK="$AGT_LIGHTS_STATE/sweep.lock"

log() { printf '%s %s\n' "$(date '+%m-%d %H:%M:%S')" "$*" >> "$AGT_LIGHTS_LOG"; }

# A scheduled job runs under launchd's PATH, not yours, so a Homebrew jq or an
# agtermctl that was never symlinked is simply absent here. Say so in the log:
# a sweeper that exits silently every two minutes looks exactly like a sweeper
# that has nothing to do.
if ! command -v "$AGTERMCTL" >/dev/null 2>&1 && [ ! -x "$AGTERMCTL" ]; then
  log "no agtermctl on PATH as '$AGTERMCTL' (PATH=$PATH) — nothing done"
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  log "no jq on PATH (PATH=$PATH) — nothing done"
  exit 0
fi

# single-flight; break a lock older than ten minutes
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
    rmdir "$LOCK" 2>/dev/null || true
    mkdir "$LOCK" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
MAP=$(mktemp "$AGT_LIGHTS_STATE/agent-map.XXXXXX") || { rmdir "$LOCK" 2>/dev/null; exit 0; }
trap 'rm -f "$MAP"; rmdir "$LOCK" 2>/dev/null' EXIT

if [ -f "$AGT_LIGHTS_LOG" ] && [ "$(wc -l < "$AGT_LIGHTS_LOG")" -gt 200 ]; then
  tail -n 100 "$AGT_LIGHTS_LOG" > "$AGT_LIGHTS_LOG.tmp" && mv "$AGT_LIGHTS_LOG.tmp" "$AGT_LIGHTS_LOG"
fi

# Keep the state directory from growing without end: one file per session per
# kind, and sessions come and go. Stale state already fails closed — a dead
# pid note, a week-old heartbeat and an ancient turn stamp all read as "no
# information" — so this prunes for tidiness rather than for correctness, and
# it also collects the agent-map temporaries a SIGKILLed sweep leaves behind
# before its trap can fire.
for sub in pid hb turnstart turnend transcript; do
  [ -d "$AGT_LIGHTS_STATE/$sub" ] &&
    find "$AGT_LIGHTS_STATE/$sub" -type f -mtime +7 -delete 2>/dev/null
done
find "$AGT_LIGHTS_STATE" -maxdepth 1 -type f -name 'agent-map.*' -mtime +1 -delete 2>/dev/null

now=$(date +%s)

# ---- discovery: session id -> agent pid, for every pane-attached agent ----
# Every agent started inside a session carries AGTERM_SESSION_ID in its
# environment, so this covers sessions that predate the hooks and repairs a pid
# note that was written by something else.
# the pattern travels through the environment, not through -v: awk interprets
# escapes in a -v value, so a reader's escaped metacharacter would compile
# differently here than it does in the grep that reads the same variable
ps -axo pid=,tty=,command= |
  AGT_AGENT_PATTERN="$AGT_AGENT_PATTERN" awk '
    BEGIN { re = "^(" ENVIRON["AGT_AGENT_PATTERN"] ")$" }
    { b = $3; sub(/.*\//, "", b); sub(/^\(/, "", b); sub(/\)$/, "", b)
      if (b ~ re && $2 != "??") print $1 }' |
  sort -n |
  while read -r cand; do
    # pgrep cannot read another process's environment; `ps eww` is the only
    # way to ask which session a running agent belongs to
    # shellcheck disable=SC2009
    sid=$(ps eww "$cand" 2>/dev/null | grep -o 'AGTERM_SESSION_ID=[A-Za-z0-9-]*' | head -1)
    [ -n "$sid" ] && printf '%s %s\n' "${sid#AGTERM_SESSION_ID=}" "$cand"
    # candidates arrive lowest pid first, so when two processes claim one
    # session the older one — the pane's own agent, which existed before it
    # spawned anything — wins the dedupe below
  done | awk '!seen[$1]++' > "$MAP"

pid_dir=$(agt_state_dir pid)
while read -r msid mpid; do
  [ -n "$msid" ] && agt_write_pid_note "$pid_dir/$msid" "$mpid"
done < "$MAP"

set_status() { # session-id pane args…
  local sid=$1 pane=$2
  shift 2
  if [ -n "$pane" ]; then
    "$AGTERMCTL" session status "$@" --target "$sid" --pane "$pane" >/dev/null 2>&1 || true
  else
    "$AGTERMCTL" session status "$@" --target "$sid" >/dev/null 2>&1 || true
  fi
}

file_age() { # path -> seconds since mtime, or a huge number when unreadable
  local m
  m=$(stat -f %m "$1" 2>/dev/null) || { echo 999999; return; }
  echo $((now - m))
}

hb_age() { file_age "$AGT_LIGHTS_STATE/hb/$1"; }

pid_is_agent() { # pid -> 0 when alive and still an agent binary (pids get reused)
  local c
  c=$(ps -o command= -p "$1" 2>/dev/null) || return 1
  agt_is_agent_name "$(agt_base_name "$c")"
}

own_turn_live() { # session-id -> 0 when a turn started after the last turn end
  # Transcript mtime alone cannot decide this: the harness keeps appending
  # after a turn ends, which held a false "still working" glyph for minutes.
  # The stamps decide, and the transcript only caps the claim, so an
  # interrupted turn that never fired Stop cannot hold it once writes stop.
  local ts="$AGT_LIGHTS_STATE/turnstart/$1" te="$AGT_LIGHTS_STATE/turnend/$1"
  local tf="$AGT_LIGHTS_STATE/transcript/$1"
  local sm em tp tm
  [ -f "$ts" ] || return 1
  sm=$(stat -f %m "$ts" 2>/dev/null) || return 1
  em=0
  [ -f "$te" ] && { em=$(stat -f %m "$te" 2>/dev/null) || em=0; }
  [ "$sm" -gt "$em" ] || return 1
  tp=""
  [ -f "$tf" ] && tp=$(cat "$tf" 2>/dev/null)
  if [ -n "$tp" ] && [ -f "$tp" ]; then
    tm=$(stat -f %m "$tp" 2>/dev/null) || return 1
    [ $((now - tm)) -lt "$AGT_OWN_LIVE_SECS" ]
  else
    [ $((now - sm)) -lt "$AGT_OWN_LIVE_SECS" ]
  fi
}

transcript_stalled() { # session-id -> 0 when the transcript is known and cold
  local tf="$AGT_LIGHTS_STATE/transcript/$1" tp
  [ -f "$tf" ] || return 1
  tp=$(cat "$tf" 2>/dev/null)
  [ -n "$tp" ] && [ -f "$tp" ] || return 1
  [ "$(file_age "$tp")" -ge "$AGT_STALL_SECS" ]
}

scan_counts() { # agent pid -> fills SC_*, returns 1 when the scan is unusable
  local out counts line
  out=$(AGT_SCAN_PIDS=1 "$DIR/work-scan.sh" "$1" "$$" 2>/dev/null)
  counts=${out%%$'\n'*}
  case "$counts" in agents=*machinery=*waiting=*remote=*watch=*) ;; *) return 1 ;; esac
  SC_AGENTS=${counts#agents=};        SC_AGENTS=${SC_AGENTS%% *}
  SC_MACHINERY=${counts#*machinery=}; SC_MACHINERY=${SC_MACHINERY%% *}
  SC_WAITING=${counts#*waiting=};     SC_WAITING=${SC_WAITING%% *}
  SC_REMOTE=${counts#*remote=};       SC_REMOTE=${SC_REMOTE%% *}
  SC_WATCH=${counts#*watch=};         SC_WATCH=${SC_WATCH%% *}
  case "$SC_AGENTS$SC_MACHINERY$SC_WAITING$SC_REMOTE$SC_WATCH" in *[!0-9]*) return 1 ;; esac
  SC_PIDS=""
  while IFS= read -r line; do
    case "$line" in pids=*) SC_PIDS=${line#pids=} ;; esac
  done <<<"$out"
  return 0
}

cpu_centis() { # pid list -> summed cpu time in centiseconds
  local list
  list=$(printf '%s' "$1" | tr ' ' ',' | sed 's/^,*//; s/,*$//')
  [ -n "$list" ] || { echo 0; return; }
  ps -o cputime= -p "$list" 2>/dev/null | awk '
    { n = split($1, t, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + t[i]; total += s }
    END { printf "%d", total * 100 }'
}

subtree_busy() { # -> 0 when the machinery subtrees are actually computing
  [ -n "$SC_PIDS" ] || return 1
  local t1 t2
  t1=$(cpu_centis "$SC_PIDS")
  sleep 1.5
  t2=$(cpu_centis "$SC_PIDS")
  [ $((t2 - t1)) -ge 15 ]   # 0.15s of cpu over 1.5s is work, not a poll loop
  # SC_PIDS holds only the machinery subtrees, which is exactly what this
  # gates: a watcher burning cpu elsewhere must not vouch for idle machinery
}

work_state() { # -> running | mixed | queued for the scanned counts, or nothing
  # A remote run counts as running on sight; local machinery has to prove it
  # burns cpu, because a subtree can look busy while it only waits.
  # The state, not the shape: a reader who blanks a shape variable to fall back
  # on their Settings silhouette must still get the state recognized.
  local run=$SC_REMOTE
  if [ "$SC_MACHINERY" -gt 0 ] && subtree_busy; then run=$((run + SC_MACHINERY)); fi
  if [ "$run" -gt 0 ] && [ "$SC_WAITING" -gt 0 ]; then printf mixed
  elif [ "$run" -gt 0 ]; then printf running
  elif [ $((SC_WAITING + SC_WATCH)) -gt 0 ]; then printf queued
  fi
}

shape_for() { # work state -> the shape configured for it, empty when blanked
  case "$1" in
    running) printf '%s' "$AGT_SHAPE_RUNNING" ;;
    mixed)   printf '%s' "$AGT_SHAPE_MIXED" ;;
    queued)  printf '%s' "$AGT_SHAPE_QUEUED" ;;
  esac
}

windows=$("$AGTERMCTL" window list --json 2>/dev/null | jq -r '.result.windows[]? | select(.open) | .id') || exit 0

for w in $windows; do
  "$AGTERMCTL" tree --window "$w" --json 2>/dev/null | jq -c '
    .result.tree.workspaces[]?.sessions[]? |
    {id, status: (.status // "idle"),
     pane: (.statusPane // ""),
     blink: (.statusBlink // false),
     shape: (.statusShape // ""),
     color: (.statusColor // ""),
     fg: ((.foreground // [])[0] // ""),
     sfg: ((.splitForeground // [])[0] // "")}' |
  while IFS= read -r row; do
    sid=$(jq -r .id <<<"$row")
    status=$(jq -r .status <<<"$row")
    pane=$(jq -r .pane <<<"$row")
    blink=$(jq -r .blink <<<"$row")
    shape_now=$(jq -r .shape <<<"$row")
    color_now=$(jq -r .color <<<"$row")
    fg=$(jq -r .fg <<<"$row")
    sfg=$(jq -r .sfg <<<"$row")
    [ -n "$sid" ] || continue

    # a pid straight from discovery is live by construction; one read back from
    # a note has to prove it is still the same process, not a recycled pid that
    # happens to be another agent
    pid=$(awk -v s="$sid" '$1 == s { print $2; exit }' "$MAP")
    alive=0; knew_pid=0
    if [ -n "$pid" ]; then
      knew_pid=1
      pid_is_agent "$pid" && alive=1
    elif [ -f "$AGT_LIGHTS_STATE/pid/$sid" ]; then
      # this session had an agent once; whether it still does is the question
      knew_pid=1
      if agt_note_is_live "$AGT_LIGHTS_STATE/pid/$sid"; then
        pid=$(agt_note_pid "$AGT_LIGHTS_STATE/pid/$sid")
        alive=1
      fi
    fi

    case "$status" in
      blocked)
        # blocked means a human was asked something: leave it alone while
        # anything backs it, and clear it only once the agent is gone and the
        # hooks have been silent for a long time
        if [ "$knew_pid" -eq 1 ] && [ "$alive" -eq 0 ] && [ "$(hb_age "$sid")" -gt "$AGT_HB_STALE_SECS" ]; then
          set_status "$sid" "$pane" idle
          log "dead blocked $sid -> idle"
        fi
        ;;
      active)
        if [ "$alive" -eq 1 ] && scan_counts "$pid"; then
          state=""; shape=""
          if [ "$SC_AGENTS" -eq 0 ]; then state=$(work_state); shape=$(shape_for "$state"); fi
          total=$((SC_AGENTS + SC_MACHINERY + SC_WAITING + SC_REMOTE + SC_WATCH))
          if [ "$SC_AGENTS" -gt 0 ]; then
            if [ "$shape_now" = "$AGT_SHAPE_STUCK" ]; then
              set_status "$sid" "$pane" active --blink
              log "worker progress $sid -> pulse"
            fi
          elif own_turn_live "$sid"; then
            if [ "$blink" != "true" ] || [ "$shape_now" = "$AGT_SHAPE_STUCK" ]; then
              set_status "$sid" "$pane" active --blink
              log "own turn live $sid -> pulse"
            fi
          elif [ -n "$state" ]; then
            # only post when the row is not already showing exactly this. A
            # repaint is not free: it would also clear a pulse the row is
            # carrying, so a blinking row is repainted even when the shape and
            # tint already match.
            if [ "$shape_now" = "$shape" ] && [ "$color_now" = "$AGT_WORK_COLOR" ] &&
               [ "$blink" != "true" ]; then
              : # already honest; leave it alone
            else
              agt_active_args "$AGT_WORK_COLOR" "$shape"
              set_status "$sid" "$pane" "${AGT_STATUS_ARGS[@]}"
              log "work $sid (m=$SC_MACHINERY r=$SC_REMOTE q=$SC_WAITING w=$SC_WATCH) -> $state"
            fi
          elif [ "$blink" = "true" ] && [ "$total" -eq 0 ] && transcript_stalled "$sid"; then
            # it claims to be working, nothing is running under it, and the
            # transcript has not moved: wedged, and worth summoning you
            if [ "$shape_now" != "$AGT_SHAPE_STUCK" ] || [ "$color_now" != "$AGT_STUCK_COLOR" ]; then
              agt_active_args "$AGT_STUCK_COLOR" "$AGT_SHAPE_STUCK" --blink
              set_status "$sid" "$pane" "${AGT_STATUS_ARGS[@]}"
              log "stuck $sid (running claim, no progress) -> stuck glyph"
            fi
          elif [ -f "$AGT_LIGHTS_STATE/turnstart/$sid" ] && [ -f "$AGT_LIGHTS_STATE/turnend/$sid" ] &&
               [ "$(stat -f %m "$AGT_LIGHTS_STATE/turnend/$sid" 2>/dev/null || echo 0)" -gt \
                 "$(stat -f %m "$AGT_LIGHTS_STATE/turnstart/$sid" 2>/dev/null || echo 1)" ]; then
            # the stamps prove no turn is running and the scan found nothing:
            # the background work this glyph stood for has drained
            set_status "$sid" "$pane" completed --auto-reset
            log "work drained $sid -> completed"
          elif [ "$(hb_age "$sid")" -gt "$AGT_HB_STALE_SECS" ]; then
            set_status "$sid" "$pane" idle
            log "idle at prompt $sid -> idle"
          fi
        elif [ "$alive" -eq 0 ]; then
          age=$(hb_age "$sid")
          if [ "$age" -lt "$AGT_HB_FRESH_SECS" ]; then
            : # a hook fired moments ago: an agent we cannot see yet is alive
          elif agt_is_agent_name "$(agt_base_name "$fg")" ||
               agt_is_agent_name "$(agt_base_name "$sfg")"; then
            : # an agent is visibly in the pane; its own hooks will take over
          elif [ "$age" -gt "$AGT_HB_STALE_SECS" ]; then
            set_status "$sid" "$pane" idle
            log "unbacked active $sid (dark ${age}s) -> idle"
          fi
        fi
        ;;
      idle|completed)
        # the other direction: work is running but the row shows done, or nothing
        if [ "$alive" -eq 1 ] && scan_counts "$pid"; then
          state=""; shape=""
          if [ "$SC_AGENTS" -eq 0 ]; then state=$(work_state); shape=$(shape_for "$state"); fi
          if [ "$SC_AGENTS" -gt 0 ]; then
            set_status "$sid" "$pane" active --blink
            log "silent workers $sid (agents=$SC_AGENTS) -> pulse"
          elif [ -n "$state" ]; then
            agt_active_args "$AGT_WORK_COLOR" "$shape"
            set_status "$sid" "$pane" "${AGT_STATUS_ARGS[@]}"
            log "silent work $sid (m=$SC_MACHINERY r=$SC_REMOTE q=$SC_WAITING w=$SC_WATCH) -> $state"
          fi
        fi
        ;;
    esac
  done
done
exit 0
