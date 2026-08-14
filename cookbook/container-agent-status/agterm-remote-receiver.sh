#!/usr/bin/env bash
# Runs on the HOST. Listens on a TCP port for status events sent by
# container-status-notify.sh (inside a container that has no access to the
# host's agterm control socket) and forwards each one to agtermctl.
set -u

AGTERMCTL=${AGTERMCTL:-agtermctl}

PORT=9998
BIND=""
LOG_FILE=""
VERBOSE=false
TARGET_SOCKET="$HOME/Library/Application Support/agterm/agterm.sock"

usage() {
  echo "Usage: $0 [--port PORT] [--bind ADDR] [--log-file FILE] [--socket PATH] [--verbose]"
  echo ""
  echo "  --port PORT       TCP port to listen on (default 9998)"
  echo "  --bind ADDR       Address to bind (default: every interface)"
  echo "  --log-file FILE   Append logs here instead of stdout"
  echo "  --socket PATH     agterm control socket to forward status to"
  echo "                    (default: \$HOME/Library/Application Support/agterm/agterm.sock)"
  echo "  --verbose         Also log the raw JSON received"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --port)
      PORT=$2
      shift 2
      ;;
    --bind)
      BIND=$2
      shift 2
      ;;
    --log-file)
      LOG_FILE=$2
      shift 2
      ;;
    --socket)
      TARGET_SOCKET=$2
      shift 2
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

log() {
  level=$1
  shift
  # socket bytes reach the log verbatim, so strip control characters here: an
  # OSC 52 sequence in a logged line would rewrite the clipboard of whoever
  # has this output on screen, and --log-file replays it on every later cat.
  line="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $(printf '%s' "$*" | tr -d '[:cntrl:]')"
  if [ -n "$LOG_FILE" ]; then
    echo "$line" >>"$LOG_FILE"
  else
    echo "$line"
  fi
}

# Forward one session-status event to agtermctl. Every field but state and
# session_id is optional, so a hand-rolled grep-based parse (no jq
# dependency) is enough for this fixed, single-level shape.
process_event() {
  json=$1

  if [ "$VERBOSE" = true ]; then
    log "DEBUG" "received: $json"
  fi

  cmd=$(printf '%s' "$json" | grep -o '"cmd":"[^"]*"' | head -1 | cut -d'"' -f4)
  state=$(printf '%s' "$json" | grep -o '"state":"[^"]*"' | head -1 | cut -d'"' -f4)
  session_id=$(printf '%s' "$json" | grep -o '"session_id":"[^"]*"' | head -1 | cut -d'"' -f4)
  pane=$(printf '%s' "$json" | grep -o '"pane":"[^"]*"' | head -1 | cut -d'"' -f4)
  pane_id=$(printf '%s' "$json" | grep -o '"pane_id":"[^"]*"' | head -1 | cut -d'"' -f4)

  log "INFO" "event: cmd=$cmd state=$state session_id=$session_id"

  if [ "$cmd" != "session-status" ] || [ -z "$state" ] || [ -z "$session_id" ]; then
    return
  fi

  args=("session" "status" "$state" "--target" "$session_id" "--socket" "$TARGET_SOCKET")
  if [ -n "$pane" ]; then
    args+=("--pane" "$pane")
  fi
  if [ -n "$pane_id" ]; then
    args+=("--pane-id" "$pane_id")
  fi

  # the sender's "args" array carries the hook's own flags; allowlist rather
  # than forward, so a line off the socket cannot pick agtermctl's arguments.
  sent_args=$(printf '%s' "$json" | grep -o '"args":\[[^]]*\]' | head -1)
  for flag in --blink --auto-reset; do
    case "$sent_args" in
      *"\"$flag\""*) args+=("$flag") ;;
    esac
  done

  if [ "$VERBOSE" = true ]; then
    log "DEBUG" "forwarding: $AGTERMCTL ${args[*]}"
  fi

  "$AGTERMCTL" "${args[@]}" >/dev/null 2>&1 || true
}

if ! command -v nc >/dev/null 2>&1; then
  log "ERROR" "nc (netcat) not found"
  exit 1
fi

log "INFO" "listening on ${BIND:-*}:$PORT"

# -k keeps the port bound across connections; a relisten loop would leave it
# closed between events, and a status arriving in that gap is lost silently.
if [ -n "$BIND" ]; then
  nc -k -l "$BIND" "$PORT" 2>/dev/null
else
  nc -k -l "$PORT" 2>/dev/null
fi | while IFS= read -r json_line; do
  [ -z "$json_line" ] && continue
  case "$json_line" in
    "{"*) process_event "$json_line" ;;
    *) log "WARN" "ignoring non-JSON line: $json_line" ;;
  esac
done

log "ERROR" "listener exited"
