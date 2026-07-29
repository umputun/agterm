#!/bin/sh
# pick a directory with agterm's native picker and type its path into the session that asked for it.
#
# takes no arguments: it runs as a keymap custom command, and the runner exports the session, window,
# pane and socket as $AGT_* environment variables and starts the process in the session's directory.
#
# search roots come from $AGT_PICK_ROOTS (colon-separated, default: the session's own directory) and
# the depth below each root from $AGT_PICK_DEPTH.
set -eu

AGTERMCTL=${AGTERMCTL:-agtermctl}
ROOTS=${AGT_PICK_ROOTS:-$PWD}
DEPTH=${AGT_PICK_DEPTH:-4}
LIMIT=1000
tilde='~'  # shortens $HOME in a row label; a display string, never expanded as a path

# carry the socket when the session names one, so the recipe also works in a second instance
agt() {
    if [ -n "${AGT_SOCKET:-}" ]; then
        "$AGTERMCTL" "$@" --socket "$AGT_SOCKET"
    else
        "$AGTERMCTL" "$@"
    fi
}

# a keybinding runs with stdout and stderr on /dev/null, so anything the reader must see is a banner
fail() {
    agt notify "$1" --title "Pick Directory" >/dev/null 2>&1 || true
    exit 1
}

command -v fd >/dev/null 2>&1 || fail "fd is not on PATH"
command -v jq >/dev/null 2>&1 || fail "jq is not on PATH"

# one TSV line per directory: the full path the picker returns, and the label the row shows
candidates() {
    old_ifs=$IFS
    IFS=:
    # shellcheck disable=SC2086  # deliberate split of the colon-separated root list
    set -- $ROOTS
    IFS=$old_ifs
    for root in "$@"; do
        [ -d "$root" ] || continue
        fd --type d --max-depth "$DEPTH" . "$root" |
            while IFS= read -r dir; do
                case $dir in
                    "$HOME"/*) printf '%s\t%s/%s\n' "$dir" "$tilde" "${dir#"$HOME"/}" ;;
                    *) printf '%s\t%s\n' "$dir" "$dir" ;;
                esac
            done
    done
}

LIST=$(candidates)
[ -n "$LIST" ] || fail "no directories under $ROOTS"

# the picker rejects a list longer than its limit, so count first and explain rather than fail opaquely
COUNT=$(printf '%s\n' "$LIST" | wc -l | tr -d ' ')
if [ "$COUNT" -gt "$LIMIT" ]; then
    fail "$COUNT directories is over the picker's $LIMIT-item limit. Narrow AGT_PICK_ROOTS or lower AGT_PICK_DEPTH"
fi

ITEMS=$(printf '%s\n' "$LIST" |
    jq -R -s 'split("\n") | map(select(length > 0) | split("\t")) | map({id: .[0], label: .[1]})')

set +e
CHOICE=$(printf '%s' "$ITEMS" | agt pick --prompt "directory" --window "${AGT_WINDOW_ID:-active}")
rc=$?
set -e
case $rc in
    0) ;;
    2) exit 0 ;;  # cancelled at the picker, which is a normal way out
    *) fail "picker failed (exit $rc)" ;;
esac

DIR=$(printf '%s' "$CHOICE" | jq -r 'select(.result == "picked") | .id' 2>/dev/null || true)
[ -n "$DIR" ] || exit 0
case $DIR in
    */) ;;
    *) DIR="$DIR/" ;;
esac

agt session type "$DIR" --target "${AGT_SESSION_ID:-active}" --pane "${AGT_PANE:-left}" >/dev/null
