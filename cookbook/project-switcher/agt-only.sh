#!/bin/sh
# agt-only.sh "A" - show only the workspaces whose name starts with "A".
#
# Marks the matching workspaces as the sidebar focus set, unmarks the rest,
# then applies the filter. Nothing is closed.
set -e

AGTERMCTL=${AGTERMCTL:-agtermctl}

p=$1
if [ -z "$p" ]; then
	echo "usage: ${0##*/} <workspace-name-prefix>" >&2
	exit 2
fi

# suspend the filter first, so the whole tree is on screen while the set is rebuilt
"$AGTERMCTL" workspace filter off

"$AGTERMCTL" tree --json |
	jq -r --arg p "$p" '.result.tree.workspaces[]
		| "\(if (.name|startswith($p)) then "add" else "off" end) \(.id)"' |
	while read -r mode w; do
		"$AGTERMCTL" workspace focus "$mode" --target "$w"
	done

"$AGTERMCTL" workspace filter on
