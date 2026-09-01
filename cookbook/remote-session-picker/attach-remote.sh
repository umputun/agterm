#!/bin/sh
# pick a session running on another Mac and attach it here, marked remote in the sidebar.
#
# takes the host as its first argument, or from $AGT_REMOTE_HOST when it runs as a keymap
# custom command, where the runner exports the window and socket as $AGT_* variables.
#
# each row shows the far side's window and workspace, the session's own note of what it is
# for, its working directory, and whatever its panes are running.
set -eu

AGTERMCTL=${AGTERMCTL:-agtermctl}
HOST=${1:-${AGT_REMOTE_HOST:-}}
LIMIT=1000

# carry the socket when the session names one, so this also works in a second instance
agt() {
    if [ -n "${AGT_SOCKET:-}" ]; then
        "$AGTERMCTL" "$@" --socket "$AGT_SOCKET"
    else
        "$AGTERMCTL" "$@"
    fi
}

# a keybinding runs with stdout and stderr on /dev/null, so anything the reader must see is a banner
fail() {
    agt notify "$1" --title "Attach Remote" >/dev/null 2>&1 || true
    exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is not on PATH"
[ -n "$HOST" ] || fail "no host. Pass one, or set AGT_REMOTE_HOST in the custom command"

# the local agterm runs the ssh, so a failure here is the far side's or the network's
TREE=$(agt zmx tree "$HOST" --json 2>&1) || fail "$HOST: $(printf '%s' "$TREE" | tail -1)"

ERR=$(printf '%s' "$TREE" | jq -r 'if .ok then empty else .error end' 2>/dev/null) \
    || fail "unreadable answer from $HOST"
[ -z "$ERR" ] || fail "$HOST: $ERR"

# id addresses the row; the subtitle is where it lives on the far side, then what it is doing.
# names, not ids: the ids are for grouping and neither window nor workspace name is unique.
ITEMS=$(printf '%s' "$TREE" | jq -c '
    [.result.remote.sessions[]
     | {id, label: .name,
        subtitle: ([ (.windowName + "/" + .workspaceName),
                     .context,
                     .cwd,
                     ([.panes[].foreground // empty | .[0] | split("/") | last] | join(" | "))
                   ] | map(select(. != null and . != "")) | join("  ·  "))}]') \
    || fail "unreadable session list from $HOST"

COUNT=$(printf '%s' "$ITEMS" | jq 'length') || fail "unreadable session list from $HOST"
# an empty list does not diagnose the mode: it reads the same whether the far side is not in Live
# sessions mode or is and has nothing eligible. `agtermctl zmx list` on that machine says which.
[ "$COUNT" -gt 0 ] || fail "nothing to attach on $HOST"
# the picker refuses a longer list outright, so count first and explain rather than fail opaquely
[ "$COUNT" -le "$LIMIT" ] || fail "$COUNT sessions is over the picker's $LIMIT-item limit"

set +e
CHOICE=$(printf '%s' "$ITEMS" | agt pick --prompt "attach from $HOST" --window "${AGT_WINDOW_ID:-active}")
rc=$?
set -e
case $rc in
    0) ;;
    2) exit 0 ;;  # cancelled at the picker, which is a normal way out
    *) fail "picker failed (exit $rc)" ;;
esac

ID=$(printf '%s' "$CHOICE" | jq -r 'select(.result == "picked") | .id') \
    || fail "unreadable answer from the picker"
[ -n "$ID" ] || exit 0

# the remote is resolved again by the attach itself, so a session that has gone since the
# listing fails here rather than handing back a fresh shell wearing its name
OUT=$(agt zmx attach "$HOST" "$ID" 2>&1) || fail "attach failed: $(printf '%s' "$OUT" | tail -1)"
