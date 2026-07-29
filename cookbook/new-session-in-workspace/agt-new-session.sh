#!/bin/sh
# agt-new-session.sh — start a session in a workspace picked from a searchable list.
#
# usage: agt-new-session.sh          open the picker over the current session
#        agt-new-session.sh --pick   internal: the picker itself, run inside the overlay's pty
#
# Bound to a chord in keymap.conf, the script opens an agterm overlay over the session the key was
# pressed in and re-invokes itself there in --pick mode, where it has the real tty that fzf needs.

set -u

AGTERMCTL="${AGTERMCTL:-agtermctl}"

# fzf, and a homebrew jq, are not on the app's launchd PATH — which a custom command and an overlay
# both inherit. Both standard homebrew prefixes are prepended; set AGT_BIN_PATH to a colon-separated
# list of your own if the binaries live elsewhere.
#
# Resolved into a variable rather than used inline, because the launcher has to hand both this and
# AGTERMCTL to the overlay explicitly — see the prefix on the overlay command at the bottom.
AGT_BIN_PATH="${AGT_BIN_PATH:-/opt/homebrew/bin:/usr/local/bin}"
PATH="$AGT_BIN_PATH:$PATH"
export PATH

# agtermctl resolves its socket from --socket, else AGTERM_STATE_DIR, else the app-support default.
# It does NOT read AGTERM_SOCKET. agterm hands a custom command $AGT_SOCKET and an overlay pty
# $AGTERM_SOCKET, so pass whichever is set through explicitly and let the default stand otherwise.
AGT_SOCK="${AGT_SOCKET:-${AGTERM_SOCKET:-}}"

# Call the CLI, naming the socket only when the environment gave us one. `--socket` is a
# per-subcommand option, so it goes after the subcommand — appending it here is correct.
agt() {
    if [ -n "$AGT_SOCK" ]; then
        "$AGTERMCTL" "$@" --socket "$AGT_SOCK"
    else
        "$AGTERMCTL" "$@"
    fi
}

# --- picker: runs inside the overlay, with a tty --------------------------------------------------

if [ "${1:-}" = "--pick" ]; then
    # A fullwidth plus keeps the create entry from colliding with a real workspace name.
    NEW_LABEL="＋ New workspace…"

    # fzf draws on the alternate buffer, which hides the shell's "Last login" banner. The clear
    # keeps the normal buffer blank between the prompts too.
    clear 2>/dev/null || printf '\033[H\033[2J'

    names=$(agt tree --json | jq -r '.result.tree.workspaces[].name')
    [ -n "$names" ] || exit 0

    # 1) Pick the workspace. Esc, or a selection of nothing, cancels.
    choice=$({ printf '%s\n' "$names"; printf '%s\n' "$NEW_LABEL"; } |
        fzf --prompt='Workspace > ' --layout=reverse --border \
            --header='Pick a workspace · Esc to cancel' --no-multi)
    [ -n "$choice" ] || exit 0

    # 2) When the create entry is picked, ask for the name to create.
    #
    # These prompts are fzf over no candidates, read back with --print-query: the typed text is the
    # answer. Esc still prints whatever was typed, so the 130 exit status is the only thing that
    # separates "cancelled after typing a name" from "confirmed it" — hence the status capture
    # rather than an empty-string test.
    new_ws=no
    if [ "$choice" = "$NEW_LABEL" ]; then
        choice=$(fzf --print-query --prompt='New workspace name > ' \
            --layout=reverse --border --header='Type a name · Esc to cancel' </dev/null)
        status=$?
        [ "$status" -eq 130 ] && exit 0
        [ -n "$choice" ] || exit 0
        new_ws=yes
    fi

    # 3) Ask for the session name. Blank falls through to agterm's own default.
    sname=$(fzf --print-query --prompt='Session name > ' \
        --layout=reverse --border --header='Blank = default name · Esc to cancel' </dev/null)
    status=$?
    [ "$status" -eq 130 ] && exit 0

    set -- --workspace-name "$choice"
    [ "$new_ws" = yes ] && set -- "$@" --create-workspace
    [ -n "$sname" ] && set -- "$@" --name "$sname"
    agt session new "$@"
    exit $?
fi

# --- launcher: runs as the custom command, with no tty of its own ---------------------------------

# The overlay is a fresh pty with its own working directory, so this script hands it an absolute
# path to itself rather than trusting PATH or a relative name.
self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")

# POSIX single-quote a string for embedding in the overlay command, which agterm runs through
# `sh -c`: wrap it in '...' and turn each embedded ' into the '\'' sequence, so a path holding a
# space or a quote cannot break out of the quoting. Same helper as the bundled show-image.sh.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# AGTERMCTL and AGT_BIN_PATH are carried across as assignments PREFIXED onto the overlay command,
# not exported. The overlay's shell is spawned by the app from its own environment plus the AGTERM_*
# set, so nothing this process exports reaches it, and a prefix on the keymap line reaches only the
# launcher — leaving the half that actually runs fzf, jq and the tree call on the defaults. agterm
# runs the overlay command through `eval`, so a leading `VAR=value` is honored.
agt session overlay open \
    "AGTERMCTL=$(sq "$AGTERMCTL") AGT_BIN_PATH=$(sq "$AGT_BIN_PATH") /bin/sh $(sq "$self") --pick" \
    --target "${AGT_SESSION_ID:-active}" --follow --size-percent "${AGT_OVERLAY_SIZE:-60}"
