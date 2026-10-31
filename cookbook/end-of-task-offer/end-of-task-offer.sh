#!/bin/bash
# offer Clear / Close session / Continue when a Claude Code or codex turn ends after the agent cleared
# its title-bar context. `arm` runs on PostToolUse, `offer` on Stop; `ask` is the detached dialog itself.
set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

[ -n "${AGTERM_SESSION_ID:-}" ] && [ -n "${AGTERM_PANE_ID:-}" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
agtermctl=${AGTERMCTL:-agtermctl}
agents=${END_OF_TASK_AGENTS:-'(^|/)(claude|codex)$'}
# keyed by pane, not session: the agent in the other pane of a split ends its own turns
marker="${TMPDIR:-/tmp}/agterm-end-of-task/$AGTERM_PANE_ID"

ctl() {
    "$agtermctl" "$@" ${AGTERM_SOCKET:+--socket "$AGTERM_SOCKET"}
}

# clear_pane takes left or right and skips a pane that is missing or runs no agent, since a shell
# prompt can also rest the caret at column 2. Column 2 is where an empty Claude Code or codex composer
# puts it, past "› ".
clear_pane() {
    field=foreground
    [ "$1" = right ] && field=splitForeground
    # tree covers only the frontmost window unless --window names this session's own
    ctl tree --json ${AGTERM_WINDOW_ID:+--window "$AGTERM_WINDOW_ID"} 2>/dev/null |
        jq -r --arg sid "$AGTERM_SESSION_ID" --arg f "$field" \
            '.result.tree.workspaces[]?.sessions[]? | select(.id == $sid) | .[$f] // [] | .[]' |
        grep -Eq "$agents" || return 0
    col=$(ctl surface cursor --target "surface:$AGTERM_SESSION_ID:$1" 2>/dev/null) || return 0
    if [ "$col" != 2 ]; then
        ctl session hud open "Not cleared: the prompt has text in it" --hide-after 4 \
            --target "$AGTERM_SESSION_ID" --pane "$1" >/dev/null
        return 0
    fi
    # codex buffers a fast burst as a paste and reads an Enter inside it as a newline, so the
    # submit goes as its own write after a pause
    ctl session type "/clear" --target "$AGTERM_SESSION_ID" --pane "$1" >/dev/null || return 0
    sleep 0.15
    ctl session type $'\n' --target "$AGTERM_SESSION_ID" --pane "$1" >/dev/null
}

case "${1:-}" in
arm)
    cmd=$(jq -r '.tool_input.command // "" | if type == "array" then join(" ") else . end' 2>/dev/null)
    case "$cmd" in
    *"session context --clear"*"$AGTERM_SESSION_ID"*)
        mkdir -p "$(dirname "$marker")" && touch "$marker"
        ;;
    esac
    ;;
offer)
    [ -f "$marker" ] || exit 0
    rm -f "$marker"
    nohup "$0" ask </dev/null >/dev/null 2>&1 &
    ;;
ask)
    answer=$(ctl ask open "Task finished" --message "Clear the conversation, close the session, or keep going?" \
        --button clear=Clear --button close="Close session" --button continue=Continue --default clear \
        --cancel continue --target "$AGTERM_SESSION_ID" | jq -r '.id // empty')
    case "$answer" in
    clear)
        clear_pane left
        clear_pane right
        ;;
    close)
        ctl session close --undoable --target "$AGTERM_SESSION_ID" >/dev/null
        ;;
    esac
    ;;
esac
exit 0
