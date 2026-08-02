#!/bin/sh
# pick a project in agterm's native picker and open a new session in it, creating the
# project's workspace when it does not exist yet. With a command configured, typing a
# prompt after the project's name hands it to that command as its first argument.
#
# takes no arguments: it runs as a keymap custom command, and the runner exports the
# window and socket as $AGT_* environment variables.
#
# project roots come from $AGT_PROJECT_ROOTS (colon-separated, default $HOME/src); every
# direct subdirectory of a root is a project. $AGT_PROJECT_COMMAND, when set, is a shell
# line run in the new session in place of your login shell.
set -eu

AGTERMCTL=${AGTERMCTL:-agtermctl}
ROOTS=${AGT_PROJECT_ROOTS:-$HOME/src}
CMD=${AGT_PROJECT_COMMAND:-}
LIMIT=1000
tilde='~'  # shortens $HOME in a row subtitle; a display string, never expanded as a path

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
    agt notify "$1" --title "Launch Project" >/dev/null 2>&1 || true
    exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is not on PATH"

# the command line is spliced into a single-quoted token below, where a single quote
# would end the token early and run the rest outside it
case $CMD in *\'*) fail "AGT_PROJECT_COMMAND must not contain single quotes" ;; esac

# one TSV line per project: the directory the picker returns, the name the row shows,
# and the path as the row's second line
candidates() {
    old_ifs=$IFS
    IFS=:
    # shellcheck disable=SC2086  # deliberate split of the colon-separated root list
    set -- $ROOTS
    IFS=$old_ifs
    for root in "$@"; do
        root=${root%/}  # a trailing slash in the roots list would double up in every path
        [ -d "$root" ] || continue
        for dir in "$root"/*/; do
            [ -d "$dir" ] || continue
            dir=${dir%/}
            case $dir in
                "$HOME"/*) printf '%s\t%s\t%s/%s\n' "$dir" "${dir##*/}" "$tilde" "${dir#"$HOME"/}" ;;
                *) printf '%s\t%s\t%s\n' "$dir" "${dir##*/}" "$dir" ;;
            esac
        done
    done
}

LIST=$(candidates)
[ -n "$LIST" ] || fail "no projects under $ROOTS. Set AGT_PROJECT_ROOTS"

# the picker rejects a list longer than its limit, so count first and explain rather than fail opaquely
COUNT=$(printf '%s\n' "$LIST" | wc -l | tr -d ' ')
if [ "$COUNT" -gt "$LIMIT" ]; then
    fail "$COUNT projects is over the picker's $LIMIT-item limit. Narrow AGT_PROJECT_ROOTS"
fi

ITEMS=$(printf '%s\n' "$LIST" |
    jq -R -s 'split("\n") | map(select(length > 0) | split("\t")) |
              map({id: .[0], label: .[1], subtitle: .[2]})')

set +e
CHOICE=$(printf '%s' "$ITEMS" | agt pick --prompt "project — or project + prompt" \
    --allow-custom --window "${AGT_WINDOW_ID:-active}")
rc=$?
set -e
case $rc in
    0) ;;
    2) exit 0 ;;  # cancelled at the picker, which is a normal way out
    *) fail "picker failed (exit $rc)" ;;
esac

# a picked row is a project alone; a free-text answer splits into a project word and a
# prompt. The free-text row only exists while the query matches no row — which a line
# with prompt words after the project usually is, but not always: see Limits in the README.
PROMPT=''
RESULT=$(printf '%s' "$CHOICE" | jq -r '.result' 2>/dev/null) || exit 0
case $RESULT in
    picked)
        DIR=$(printf '%s' "$CHOICE" | jq -r '.id')
        ;;
    custom)
        QUERY=$(printf '%s' "$CHOICE" | jq -r '.query')
        word=$(printf '%s\n' "$QUERY" | awk '{print $1}')
        word=${word%:}  # "api: ga" forces the prompt path when "api ga" would still match a row
        PROMPT=$(printf '%s\n' "$QUERY" | sed 's/^[[:space:]]*[^[:space:]]*[[:space:]]*//')
        [ -n "$word" ] || exit 0
        # resolve the word against the project names: exact, then prefix, then substring,
        # unique at each tier. Ambiguity prints the contenders and refuses.
        set +e
        MATCH=$(printf '%s\n' "$LIST" | awk -F'\t' -v w="$word" '
            BEGIN { w = tolower(w) }
            { n = tolower($2)
              if (n == w)              { er[++ne] = $0; en[ne] = $2 }
              else if (index(n, w) == 1) { pr[++np] = $0; pn[np] = $2 }
              else if (index(n, w) > 1)  { sr[++ns] = $0; sn[ns] = $2 } }
            END {
                if (ne == 1) { print er[1]; exit }
                if (ne > 1)  { for (i = 1; i <= ne; i++) printf "%s%s", (i > 1 ? ", " : ""), en[i]; exit 3 }
                if (np == 1) { print pr[1]; exit }
                if (np > 1)  { for (i = 1; i <= np; i++) printf "%s%s", (i > 1 ? ", " : ""), pn[i]; exit 3 }
                if (ns == 1) { print sr[1]; exit }
                if (ns > 1)  { for (i = 1; i <= ns; i++) printf "%s%s", (i > 1 ? ", " : ""), sn[i]; exit 3 }
                exit 4 }')
        mrc=$?
        set -e
        case $mrc in
            0) DIR=$(printf '%s\n' "$MATCH" | cut -f1) ;;
            3) fail "\"$word\" is ambiguous: $MATCH" ;;
            *) fail "no project matches \"$word\"" ;;
        esac
        ;;
    *) exit 0 ;;
esac

[ -n "$DIR" ] || exit 0
WS=${DIR##*/}

# a prompt with nothing to receive it would vanish silently; say so, then open plain
if [ -n "$PROMPT" ] && [ -z "$CMD" ]; then
    agt notify "AGT_PROJECT_COMMAND is not set, so the prompt went nowhere" \
        --title "Launch Project" >/dev/null 2>&1 || true
    PROMPT=''
fi

# the command runs through a login shell so it resolves from your normal PATH. A prompt
# travels by temp file: --command is tokenized argv-style with no shell, so splicing
# arbitrary text into it is a quoting problem, while a file the session's own shell
# reads and deletes carries any text.
launch=''
if [ -n "$CMD" ]; then
    if [ -n "$PROMPT" ]; then
        PF=$(mktemp "${TMPDIR:-/tmp}/agt-launch-prompt.XXXXXX") || fail "mktemp failed"
        printf '%s' "$PROMPT" > "$PF"
        launch="zsh -lc 'p=\$(cat \"$PF\"); rm -f \"$PF\"; $CMD \"\$p\"'"
    else
        launch="zsh -lc '$CMD'"
    fi
fi

# --window twice over: the session must land in the window the picker showed in, and the
# workspace-name lookup itself is scoped to the target window's store, so an unpinned call
# matches (or creates) against whatever window happens to be frontmost by then.
if [ -n "$launch" ]; then
    out=$(agt session new --window "${AGT_WINDOW_ID:-active}" --workspace-name "$WS" \
        --create-workspace --cwd "$DIR" --command "$launch" 2>&1) \
        || { [ -n "$PROMPT" ] && rm -f "$PF"; fail "session new failed: $out"; }
else
    out=$(agt session new --window "${AGT_WINDOW_ID:-active}" --workspace-name "$WS" \
        --create-workspace --cwd "$DIR" 2>&1) || fail "session new failed: $out"
fi
