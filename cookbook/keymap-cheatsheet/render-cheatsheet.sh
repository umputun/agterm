#!/bin/sh
# Runs inside the overlay: render the cheat sheet and hold the pager open.
#
# $1 = python3, $2... = the pager and its flags. Both arrive as absolute paths
# because this script cannot resolve them itself: agterm spawns an overlay
# program from the app's own environment, so it gets the app's PATH and none of
# what the opener exported. The opener does have a working PATH, so it looks
# both up and passes them through the command line, which is the only channel
# there is — an environment variable set by the opener would not arrive, which is
# why there is no override for the sheet script here.
set -eu

PYTHON=$1
shift

SHEET_SCRIPT=$(dirname "$0")/cheatsheet.py

# The pager quits on q, which is what closes the overlay.
"$PYTHON" "$SHEET_SCRIPT" | "$@"
