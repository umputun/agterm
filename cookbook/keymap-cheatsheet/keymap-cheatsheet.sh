#!/bin/sh
# Bring the cheat sheet level with keymap.conf, then show it in an overlay.
#
# $1 = session id, from {AGT_SESSION_ID} in the keymap line.
#
# No PATH handling here. A custom command is spawned with a widened PATH that
# carries the bundled agtermctl, /usr/local/bin and /opt/homebrew/bin, so the
# names below resolve. See Requirements for the version that starts at.
set -eu

SESSION=${1:-}

AGTERMCTL=${AGTERMCTL:-agtermctl}
DIR=$(dirname "$0")
SHEET_SCRIPT=${AGTERM_CHEATSHEET_SCRIPT:-$DIR/cheatsheet.py}
RENDER=${AGTERM_CHEATSHEET_RENDER:-$DIR/render-cheatsheet.sh}
SIZE=${AGTERM_CHEATSHEET_SIZE:-90}

export AGTERMCTL

# Resolve the overlay's tools HERE and pass them across as absolute paths. The
# overlay program is spawned by the terminal from the app's own environment, so
# it inherits neither this PATH nor anything exported below, and its command
# line is the only channel into it.
PYTHON=$(command -v "${PYTHON:-python3}" || true)
[ -n "$PYTHON" ] || PYTHON=/usr/bin/python3

# The pager is a command with its flags, so it has to word-split.
# shellcheck disable=SC2086
set -- ${AGTERM_CHEATSHEET_PAGER:-glow -p -}
PAGER_BIN=$(command -v "$1" || true)
if [ -n "$PAGER_BIN" ]; then
  shift
  set -- "$PAGER_BIN" "$@"
else
  # glow is not installed, or is somewhere this PATH does not reach. Raw markdown
  # in less beats an overlay that flashes shut with nothing in it, which is
  # indistinguishable from a chord that never fired. less is on every mac.
  set -- /usr/bin/less -R
fi

# The overlay command is `eval`ed by sh on the other side, so each word is quoted
# here. A path containing a single quote is the one case this does not survive.
#
# The three path settings ride along for the same reason the binaries do: an overlay
# program is spawned from the app's environment, so anything exported here would be
# lost, and the render half would fall back to the default sheet and show the wrong
# file. Empty values are passed as empty and ignored on the other side.
COMMAND="'$RENDER' '${AGTERM_CONFIG_DIR:-}' '${AGTERM_KEYMAP:-}' '${AGTERM_CHEATSHEET:-}'"
COMMAND="$COMMAND '${AGTERM_CHEATSHEET_STAMP:-}'"
COMMAND="$COMMAND '$PYTHON'"
for word do
  COMMAND="$COMMAND '$word'"
done

# The maintenance pass runs BEFORE the overlay, because a session has one overlay
# slot and its progress panel needs it. It returns at once unless keymap.conf
# changed since the last press. A failure inside it is not a reason to withhold
# the sheet, so its exit status is dropped.
"$PYTHON" "$SHEET_SCRIPT" --sync || true

# With no id, the overlay lands on the active session, which is the same one in
# practice. Passing an empty --target is not the same thing and is rejected.
if [ -n "$SESSION" ]; then
  exec "$AGTERMCTL" session overlay open "$COMMAND" \
    --target "$SESSION" --size-percent "$SIZE" --follow
fi

exec "$AGTERMCTL" session overlay open "$COMMAND" --size-percent "$SIZE"
