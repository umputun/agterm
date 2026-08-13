#!/usr/bin/env bash
# Runs on the HOST. Listens on a TCP port for status events sent by
# container-status-notify.sh (inside a container that has no access to the
# host's agterm control socket) and forwards each one to agtermctl.
set -u

AGTERMCTL=${AGTERMCTL:-agtermctl}

PORT=9998
LOG_FILE=""
VERBOSE=false
TARGET_SOCKET="$HOME/Library/Application Support/agterm/agterm.sock"

usage() {
  echo "Usage: $0 [--port PORT] [--log-file FILE] [--socket PATH] [--verbose]"
  echo ""
  echo "  --port PORT       TCP port to listen on (default 9998)"
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
  line="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
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

  log "INFO" "event: cmd=$cmd state=$state session_id=$session_id"

  if [ "$cmd" != "session-status" ] || [ -z "$state" ] || [ -z "$session_id" ]; then
    return
  fi

  args=("session" "status" "$state" "--target" "$session_id" "--socket" "$TARGET_SOCKET")
  if [ -n "$pane" ]; then
    args+=("--pane" "$pane")
  fi

  if [ "$VERBOSE" = true ]; then
    log "DEBUG" "forwarding: $AGTERMCTL ${args[*]}"
  fi

  "$AGTERMCTL" "${args[@]}" >/dev/null 2>&1 || true
}

if ! command -v nc >/dev/null 2>&1; then
  log "ERROR" "nc (netcat) not found"
  exit 1
fi

log "INFO" "listening on port $PORT"

while true; do
  nc -l "$PORT" 2>/dev/null | while IFS= read -r json_line; do
    [ -z "$json_line" ] && continue
    case "$json_line" in
      "{"*) process_event "$json_line" ;;
      *) log "WARN" "ignoring non-JSON line: $json_line" ;;
    esac
  done
  log "WARN" "connection closed, relistening..."
  sleep 1
done
