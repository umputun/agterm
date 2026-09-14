#!/bin/sh
# agst - run a command under an agterm session status indicator.
#
# Sets the current agterm session's status to `active` while the command runs,
# then `completed --auto-reset` on success or `blocked --auto-reset` on any
# non-zero exit. When $AGTERM_SESSION_ID is unset, just runs the command.
#
# Flags --blink, --sound, --shape, and --socket are parsed off the front;
# --blink and --sound apply to the end states only (completed/blocked),
# --shape and --socket apply to every status call including active.
# Everything after them is the command.
#
# Usage:
#   agst [--blink] [--sound <sound>] [--shape <shape>] [--socket <socket>] <command...>
#
# Environment:
#   AGTERM_SESSION_ID  the session to update (set by agterm).
#   AGTERMCTL          override the agtermctl binary (default: agtermctl).

set -u

AGTERMCTL=${AGTERMCTL:-agtermctl}

usage() {
  echo "usage: ${0##*/} [--blink] [--sound <sound>] [--shape <shape>] [--socket <socket>] <command...>" >&2
}

# Collect our own flags off the front; the rest is the command.
# end_opts (--blink, --sound) apply to completed/blocked only.
# all_opts (--shape, --socket) also apply to active.
end_opts=
all_opts=
while [ $# -gt 0 ]; do
  case "$1" in
    --blink) end_opts="$end_opts --blink"; shift ;;
    --sound)
      [ $# -ge 2 ] || { usage; exit 2; }
      end_opts="$end_opts --sound $2"; shift 2 ;;
    --shape)
      [ $# -ge 2 ] || { usage; exit 2; }
      all_opts="$all_opts --shape $2"; shift 2 ;;
    --socket)
      [ $# -ge 2 ] || { usage; exit 2; }
      all_opts="$all_opts --socket $2"; shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

if [ $# -eq 0 ]; then
  usage
  exit 2
fi

# Not inside agterm: exec the command directly, no status calls.
if [ -z "${AGTERM_SESSION_ID:-}" ]; then
  exec "$@"
fi

status() {
  "$AGTERMCTL" session status "$@" --target "$AGTERM_SESSION_ID" >/dev/null 2>&1 || :
}

# set -u: $all_opts and $end_opts are always defined (initialized above), so
# unquoted expansion is safe even when empty.
status active $all_opts

# Capture the exit code without -e so the status still gets set on failure.
rc=0
"$@" || rc=$?

if [ "$rc" -eq 0 ]; then
  status completed --auto-reset $all_opts $end_opts
else
  status blocked --auto-reset $all_opts $end_opts
fi

exit "$rc"
