#!/usr/bin/env bash
# machinery-paint.sh — PreToolUse[Bash] hook: paint the machinery glyph when
# the command about to run is test- or build-shaped, so half an hour of CI
# reads differently from the model thinking. The PostToolUse hook restores the
# pulse when the command returns.
#
# Optional: the recipe works without it, you just do not see machinery until
# the turn ends.
#
# Override AGT_MACHINERY_PATTERN with your own extended regex to match the
# commands you actually wait on.
#
# MUST always exit 0: a non-zero PreToolUse exit blocks the tool call.
set -u
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lights-common.sh
. "$DIR/lights-common.sh"

[ -n "${AGTERM_SESSION_ID:-}" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
# the payload arrives on stdin; run by hand from a terminal there is none, and
# the read below would block forever — which for a PreToolUse hook means a
# wedged tool call, not a missed glyph
[ -t 0 ] && exit 0

AGT_MACHINERY_PATTERN=${AGT_MACHINERY_PATTERN:-'(^|[ /;&|(])(pytest|vitest|jest|playwright|tox |go test|cargo (test|nextest|build)|npm (run )?(test|check|build)|pnpm (run )?(test|check|build)|yarn test|make (test|check|build)|ctest|swift test|xcodebuild|mix test|rspec|bun test|deno test|dotnet test|mvn (test|verify)|gradlew (test|check|build)|just test)'}

cmd=$(jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

if printf '%s' "$cmd" | grep -qiE "$AGT_MACHINERY_PATTERN"; then
  # through the shared builder like every other caller, so blanking a shape or
  # color drops the flag instead of posting an empty value the CLI rejects
  agt_active_args "$AGT_WORK_COLOR" "$AGT_SHAPE_RUNNING"
  "$DIR/set-status.sh" "${AGT_STATUS_ARGS[@]}"
fi
exit 0
