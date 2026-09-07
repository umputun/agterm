#!/bin/sh
# Runs inside the overlay: render the cheat sheet and hold the pager open.
#
# Everything arrives on the command line because nothing else can reach here. agterm
# spawns an overlay program from the app's own environment, so it has the app's PATH
# and none of what the opener exported. The opener has both, so it resolves the
# binaries and forwards the settings, and this script puts them back.
#
#   $1     AGTERM_CONFIG_DIR, or empty
#   $2     AGTERM_KEYMAP, or empty
#   $3     AGTERM_CHEATSHEET, or empty
#   $4     AGTERM_CHEATSHEET_STAMP, or empty
#   $5     python
#   $6...  the pager and its flags
set -eu

[ -n "$1" ] && export AGTERM_CONFIG_DIR="$1"
[ -n "$2" ] && export AGTERM_KEYMAP="$2"
[ -n "$3" ] && export AGTERM_CHEATSHEET="$3"
[ -n "$4" ] && export AGTERM_CHEATSHEET_STAMP="$4"
PYTHON=$5
shift 5

SHEET_SCRIPT=$(dirname "$0")/cheatsheet.py

# The pager quits on q, which is what closes the overlay.
"$PYTHON" "$SHEET_SCRIPT" | "$@"
