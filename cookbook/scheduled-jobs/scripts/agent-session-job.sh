#!/bin/sh
# cronn job: open a background agterm session that starts a coding agent on a prompt, in a named
# workspace, and badge it so the run is waiting in the sidebar when you come back.
# cronn runs this under sh -c with the launchd agent's PATH and no AGTERM_* variables.
set -u

AGTERMCTL="${AGTERMCTL:-agtermctl}"
JQ="${JQ:-jq}"
JOB_NAME="${JOB_NAME:-scheduled}"
JOB_WORKSPACE="${JOB_WORKSPACE:-scheduled}"
JOB_CWD="${JOB_CWD:-$HOME}"
JOB_AGENT="${JOB_AGENT:-claude}"
JOB_PROMPT="${JOB_PROMPT:-}"
JOB_CONTEXT="${JOB_CONTEXT:-$JOB_NAME: scheduled run}"
# a --command session starts with agterm's GUI PATH, which has neither Homebrew nor ~/.local/bin
SPAWN_PATH="${SPAWN_PATH:-$PATH:$HOME/.local/bin}"

notify_fail() {
    /usr/bin/osascript - "$JOB_NAME job failed" "$1" <<'AS' >/dev/null 2>&1 || true
on run argv
    display notification (item 2 of argv) with title (item 1 of argv)
end run
AS
}

die() {
    echo "$JOB_NAME: $*" >&2
    notify_fail "$*"
    exit 1
}

sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

[ -n "$JOB_PROMPT" ] || die "JOB_PROMPT is empty"
[ -d "$JOB_CWD" ] || die "JOB_CWD $JOB_CWD is not a directory"
windows=$("$AGTERMCTL" window list --json 2>/dev/null) || die "agterm is not running or $AGTERMCTL cannot reach it"

# every agtermctl call defaults to the frontmost window, and workspaces are per window
window=""
for id in $(printf '%s' "$windows" | "$JQ" -r '.result.windows[] | select(.open) | .id'); do
    if "$AGTERMCTL" tree --json --window "$id" |
        WS="$JOB_WORKSPACE" "$JQ" -e 'any(.result.tree.workspaces[]; .name == env.WS)' >/dev/null; then
        window="$id"
        break
    fi
done

# --command is split into argv by libghostty, not by a shell, so the quoted agent line goes into a
# one-shot launcher that /bin/sh parses and the session command stays a plain two-word line
launcher=$(mktemp "${TMPDIR:-/tmp}/agent-session-job.XXXXXX") || die "cannot create a launcher file"
{
    echo "rm -f \"\$0\""
    echo "exec /usr/bin/env PATH=$(sq "$SPAWN_PATH") $(sq "$JOB_AGENT") $(sq "$JOB_PROMPT")"
} > "$launcher"
name="$JOB_NAME-$(date +%m%d)"

sid=$("$AGTERMCTL" session new --workspace-name "$JOB_WORKSPACE" --create-workspace --no-select --wait \
    --cwd "$JOB_CWD" --name "$name" --command "/bin/sh $launcher" --json ${window:+--window "$window"} |
    "$JQ" -r '.result.id // empty')
if [ -z "$sid" ]; then
    rm -f "$launcher"
    die "cannot open an agterm session in workspace $JOB_WORKSPACE"
fi

"$AGTERMCTL" session context "$JOB_CONTEXT" --target "$sid" ${window:+--window "$window"} >/dev/null ||
    echo "session context not set"
"$AGTERMCTL" notify "$JOB_NAME is waiting" --title "scheduled job" --target "$sid" >/dev/null ||
    echo "notify failed"
echo "session $sid ($name) opened in workspace $JOB_WORKSPACE"
