#!/bin/sh
# sync the working directory of the active pane into the opposite split pane.
#
# takes no arguments: it runs as a keymap custom command, and the runner exports the session, window,
# pane and socket as $AGT_* environment variables and starts the process in the session's directory.
set -eu

AGTERMCTL=${AGTERMCTL:-agtermctl}

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
    agt notify "$1" --title "Same Directory" >/dev/null 2>&1 || true
    exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is not on PATH"

TREE=$(agt tree --json) || fail "failed to read session tree"

# parse target pane and foreground process status from session tree
eval "$(printf '%s' "$TREE" | jq -r '
  .result.tree.workspaces[].sessions[]
  | select(.active)
  | if .split == false then
      "PANE=right BUSY="
    elif .splitFocused == true then
      if .foreground != null then
        "PANE=left BUSY=" + (.foreground[0] | @sh)
      else
        "PANE=left BUSY="
      end
    else
      if .splitForeground != null then
        "PANE=right BUSY=" + (.splitForeground[0] | @sh)
      else
        "PANE=right BUSY="
      end
    end
')"

if [ -n "$BUSY" ]; then
    fail "Target pane is busy running $BUSY"
fi

CWD=${AGT_SESSION_PWD:-$PWD}

if [ "$PANE" = "right" ]; then
    IS_SPLIT=$(printf '%s' "$TREE" | jq -r '.result.tree.workspaces[].sessions[] | select(.active) | .split')
    if [ "$IS_SPLIT" = "false" ]; then
        agt session split on --target "${AGT_SESSION_ID:-active}" >/dev/null
    fi
fi

printf 'cd %q\n' "$CWD" | agt session type --stdin --target "${AGT_SESSION_ID:-active}" --pane "$PANE" >/dev/null
