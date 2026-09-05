#!/bin/bash
# Claude Code UserPromptSubmit hook that keeps agterm's title-bar context describing the task in hand.
#
# It never works out what the task is. It prints the CURRENT context line and lets the model replace
# it when that line no longer matches what it is doing. Divergence is the signal, so nothing has to
# detect a task boundary - a boundary is not observable to a hook, while a mismatch is obvious to the
# model. A continuation turn costs nothing, because a line that still fits produces no tool call.
#
# The emitted command carries the LITERAL session id. A Claude Code permission rule cannot match a
# command containing $AGTERM_SESSION_ID - the matcher refuses simple expansion - and one denial makes
# the model abandon the write for the rest of the turn.
#
# Fail open everywhere: a missing agtermctl, an unreadable tree or a session that has gone emits
# nothing. A silent turn costs one stale line; a wrong line is worse than no nudge.
set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

[ -n "${AGTERM_SESSION_ID:-}" ] || exit 0

# a headless `claude -p` inherits AGTERM_* and would otherwise write its spawner's line. Claude Code
# sets this itself: sdk-cli for a headless run, cli only for the agent sitting in the pane.
[ "${CLAUDE_CODE_ENTRYPOINT:-cli}" = cli ] || exit 0

# context belongs to the SESSION, not the pane, so in a split only the main pane writes it.
# AGTERM_PANE is the shell's spawn role and goes stale after a promotion or `session swap`, and
# nothing read-only resolves the live slot. CONTEXT_NUDGE_PANE corrects it.
case "${CONTEXT_NUDGE_PANE:-${AGTERM_PANE:-left}}" in right | scratch) exit 0 ;; esac

# the agtermctl on PATH can belong to a different agterm install than the app serving this socket,
# and the running app points GHOSTTY_BIN_DIR at its own bundle. Other terminals export that variable
# too, so the -x test on agtermctl is what makes it agterm's.
if [ -n "${AGTERMCTL:-}" ]; then
    agtermctl=$AGTERMCTL
elif [ -n "${GHOSTTY_BIN_DIR:-}" ] && [ -x "$GHOSTTY_BIN_DIR/agtermctl" ]; then
    agtermctl=$GHOSTTY_BIN_DIR/agtermctl
else
    agtermctl=$(command -v agtermctl 2>/dev/null) || exit 0
fi
command -v jq >/dev/null 2>&1 || exit 0

# macOS ships no timeout(1); use it when coreutils put one on PATH and call directly otherwise, so a
# missing binary costs the guard rather than the whole hook.
read_tree() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 2 "$@"
        return
    fi
    "$@"
}

# tree reports the FRONTMOST window only, so without --window every session in a background window
# reads as absent and the hook goes silent - which is exactly the case this nudge exists for.
# the :+ form rather than an array: this runs under /bin/bash, which is 3.2.57 on macOS, where
# expanding an EMPTY array under set -u is itself an unbound-variable error.
tree=$(read_tree "$agtermctl" tree --json ${AGTERM_WINDOW_ID:+--window "$AGTERM_WINDOW_ID"} \
    2>/dev/null) || exit 0

# a session that is not in the tree must stay silent, not be reported as one whose context is unset.
# agterm rejects control characters in the value, so \001 can never be a real line.
context=$(printf '%s' "$tree" | jq -r --arg sid "$AGTERM_SESSION_ID" \
    '[.result.tree.workspaces[]?.sessions[]? | select(.id == $sid)] as $m
     | if ($m | length) == 0 then "\u0001" else ($m[0].context // "") end' 2>/dev/null) || exit 0
[ "$context" != "$(printf '\001')" ] || exit 0

if [ -z "$context" ]; then
    cat <<EOF
SESSION CONTEXT (agterm title bar) is not set.

As soon as you know what this task is, set it, so a glance at the title bar says what this session
is working on:

  agtermctl session context 'one short line' --target $AGTERM_SESSION_ID

Plain text, up to about 100 characters. Say what the work is ABOUT, not what was asked for and not
which tools are running: "#1234 sidebar rename drops the workspace suffix", never "looking into the
rename bug with the review tool". A bare ticket number says nothing to someone glancing at it. The
session name is already shown beside it, so do not repeat the project or repo either. Write it when
you know what the task is, not before - a turn that never gets there simply leaves it unset.
EOF
    exit 0
fi

cat <<EOF
SESSION CONTEXT (agterm title bar): $context

If that still describes what you are working on, do nothing at all. If it does not, replace it:

  agtermctl session context 'one short line' --target $AGTERM_SESSION_ID

Plain text, up to about 100 characters. Say what the work is ABOUT, not what was asked for and not
which tools are running: "#1234 sidebar rename drops the workspace suffix", never "looking into the
rename bug with the review tool". A bare ticket number says nothing to someone glancing at it. The
session name is already shown beside it, so do not repeat the project or repo either. If the work it
names is already done from this side - change delivered, reply posted, pull request merged, even if
the ticket stays open for someone else - clear it now:

  agtermctl session context --clear --target $AGTERM_SESSION_ID
EOF
