#!/usr/bin/env bash
# run a command while the Release helpers build alongside it; the app build's helper phase stays authoritative
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
log=build/helper-prebuild.log

# keep the two helper commands in their own process group
set -m
(swift build --package-path agtermCore -c release --product agtermctl &&
  swift build --package-path agtermCore -c release --product agterm-session-host) >"$log" 2>&1 &
helpers=$!
set +m
prebuilt=

stop_helpers() {
  [ -z "$prebuilt" ] || return 0
  if kill -0 -- "-$helpers" 2>/dev/null; then
    kill -- "-$helpers" 2>/dev/null || true
    wait "$helpers" 2>/dev/null || true
  fi
  # swift build starts each compiler job in a group of its own and leaves it running when signalled
  pkill -f -- "$PWD/agtermCore/.build/" 2>/dev/null || true
}
trap stop_helpers EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

"$@" && status=0 || status=$?
if [ "$status" -ne 0 ]; then
  stop_helpers
  echo "helper prebuild log:"
  tail -n 40 "$log" || true
  exit "$status"
fi
if wait "$helpers"; then
  prebuilt=1
else
  echo "helper prebuild failed; the app build's helper phase built them itself:"
  tail -n 40 "$log"
fi
