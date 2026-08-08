#!/bin/zsh
# sync the working directory of the active pane into the opposite split pane.
#
# takes no arguments: it runs as a keymap custom command, and the runner exports the session, window,
# pane and socket as $AGT_* environment variables and starts the process in the session's directory.
set -eu

AGTERMCTL=${AGTERMCTL:-agtermctl}

# carry the socket when the session names one, so the recipe also works in a second instance
agt() {
    if [[ -n "${AGT_SOCKET:-}" ]]; then
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

# parse target pane, foreground process status, and whether the split is currently shown.
# .split is "currently shown", not "has a split": session split off hides the pane while
# keeping its shell alive, so a hidden split still has a surface that may be running a TUI.
eval "$(printf '%s' "$TREE" | jq -r '
  .result.tree.workspaces[].sessions[]
  | select(.active)
  | if .split == false then
      if .splitForeground != null then
        "PANE=right BUSY=" + (.splitForeground[0] | @sh) + " NEED_SHOW=0"
      else
        "PANE=right BUSY= NEED_SHOW=1"
      end
    elif .splitFocused == true then
      if .foreground != null then
        "PANE=left BUSY=" + (.foreground[0] | @sh) + " NEED_SHOW=0"
      else
        "PANE=left BUSY= NEED_SHOW=0"
      end
    else
      if .splitForeground != null then
        "PANE=right BUSY=" + (.splitForeground[0] | @sh) + " NEED_SHOW=0"
      else
        "PANE=right BUSY= NEED_SHOW=0"
      end
    end
')"

if [[ -n "$BUSY" ]]; then
    fail "Target pane is busy running $BUSY"
fi

CWD=${AGT_SESSION_PWD:-$PWD}
TARGET=${AGT_SESSION_ID:-active}

# show the split if it is hidden or does not exist yet
if [[ "$NEED_SHOW" = "1" ]]; then
    agt session split on --target "$TARGET" >/dev/null
fi

# the split surface is created lazily after session split on; session type --pane right fails
# fast with "session has no split pane" when the surface is not yet realized, so retry a few
# times with a short sleep to let the layout pass complete.
tries=0
while [ "$tries" -lt 10 ]; do
    if printf 'cd %q\n' "$CWD" | agt session type --stdin --target "$TARGET" --pane "$PANE" >/dev/null 2>&1; then
        exit 0
    fi
    sleep 0.1
    tries=$(( tries + 1 ))
done

fail "could not type into the $PANE pane after $tries attempts"
