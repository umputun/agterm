#!/usr/bin/env bash
# Stage and capture the site and README screenshots with real agents (agtermUITests/ScreenshotUITests).
# Usage: scripts/screenshots.sh [test-method ...]   (default: every method in the class)
# Captures are copied to build/screenshots. XCUITest drives the screen and keyboard while it runs.
set -euo pipefail
cd "$(dirname "$0")/.."

shots="$HOME/Library/Containers/com.umputun.agtermUITests.xctrunner/Data/tmp/agterm-shots"
out=build/screenshots
helper="$PWD/build/DerivedData/Build/Products/Debug/agterm.app/Contents/MacOS/agterm-session-host"
domain="gui/$(id -u)"

# each test's session host outlives the app and has no idle exit; stop only a host this run's tests
# recorded: the Debug helper on that namespace, through the launchd job owning its pid, or by pid when it
# was spawned directly (`host <namespace>` alone). A namespace still holding a daemon socket keeps its
# host and its record, since the host roots that daemon and the record is all that names it.
retire_hosts() {
  [ -f "$shots/zmx-namespaces" ] || return 0
  local failed=0 namespace socket pid exe verb ns key label extra job_pid
  while read -r namespace; do
    [ -n "$namespace" ] || continue
    for socket in "$namespace"/agterm-*; do
      [ -S "$socket" ] || continue
      echo "$namespace still holds zmx daemon ${socket##*/}; its session host is left running" >&2
      failed=1
      continue 2
    done
    while read -r pid exe verb ns key label extra; do
      [ "$exe" = "$helper" ] && [ "$verb" = host ] && [ "$ns" = "$namespace" ] && [ -z "$extra" ] || continue
      if [ -z "$key" ]; then
        kill -TERM "$pid" || { echo "failed to stop session host $pid" >&2; failed=1; }
        continue
      fi
      [ -n "$label" ] || continue
      job_pid=$(launchctl print "$domain/$label" 2>/dev/null | awk '$1 == "pid" {print $3; exit}')
      if [ "$job_pid" != "$pid" ]; then
        echo "session host $pid is not launchd job $label; left running" >&2
        failed=1
        continue
      fi
      launchctl bootout "$domain/$label" || { echo "failed to stop session host $label" >&2; failed=1; }
    done < <(ps -axo pid=,command=)
  done < "$shots/zmx-namespaces"
  return "$failed"
}
# the keymap shot's config directory: its path shows in the editor's status line, so it is short
keymap_dir=""
cleanup() {
  [ -z "$keymap_dir" ] || rm -rf "$keymap_dir"
  retire_hosts || status=1
}
on_exit() {
  local rc=$?
  cleanup
  [ "$rc" -ne 0 ] && exit "$rc"
  exit "${status:-1}"
}
trap on_exit EXIT
trap 'status=130; exit' INT
trap 'status=143; exit' TERM

only=()
if [ $# -eq 0 ]; then
  only=(-only-testing:agtermUITests/ScreenshotUITests)
else
  for method in "$@"; do only+=("-only-testing:agtermUITests/ScreenshotUITests/$method"); done
fi

if ! retire_hosts; then
  echo "previous screenshot namespaces could not be retired; records kept in $shots" >&2
  trap - EXIT
  exit 1
fi
rm -rf "$shots"
keymap_dir=$(mktemp -d /tmp/agterm.XXXX)
./scripts/setup.sh
xcodegen generate
# the shots below tail a real agtermCore run or state its passed total;
# the log is kept only from a passing run, so a cached file never carries a failure
core_log=build/screenshots-input/agtermcore-test.log
core_tests=0
needs_core=$(( $# == 0 ))
for t in "$@"; do
  case $t in testPairClaudeCodex|testStatusBar|testDashboard|testAgentAsk|testHUDSpinner|testGatePicker|testNotifications|testCompactDensity|testSidebarShowcase|testDiffPage|testSourceAndLog|testMainWindow|testCommandPalette|testPairClaudeAgy) needs_core=1 ;; esac
done
if [ "$needs_core" -eq 1 ]; then
  if [ ! -s "$core_log" ]; then
    mkdir -p "$(dirname "$core_log")"
    (cd agtermCore && swift test) > "$core_log.partial" 2>&1 || { echo "agtermCore tests failed, see $core_log.partial" >&2; exit 1; }
    mv "$core_log.partial" "$core_log"
  fi
  core_tests=$(sed -n 's/^. Test run with \([0-9]*\) tests.* passed .*/\1/p' "$core_log" | awk '{s += $1} END {print s + 0}')
  [ "$core_tests" -gt 0 ] || { echo "no passing test run in $core_log" >&2; exit 1; }
fi

status=0
TEST_RUNNER_AGTERM_SCREENSHOTS=1 TEST_RUNNER_AGTERM_CORE_TESTS="$core_tests" TEST_RUNNER_AGTERM_KEYMAP_DIR="$keymap_dir" \
  xcodebuild test \
  -project agterm.xcodeproj \
  -scheme agterm \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData \
  "${only[@]}" || status=$?

mkdir -p "$out"
shopt -s nullglob
copied=0
for png in "$shots"/*.png; do
  cp "$png" "$out/" || { echo "failed to copy $png" >&2; status=1; continue; }
  echo "$out/$(basename "$png")"
  copied=$((copied + 1))
done
[ "$copied" -gt 0 ] || { echo "no screenshots were captured" >&2; status=1; }
