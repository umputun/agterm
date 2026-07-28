#!/bin/sh
# agt-sets.sh work - show only the workspaces in the "work" set.
#
# Sets are named lists of workspace names, written into this file rather than
# passed in, so a keymap entry is the set's name and nothing else. Running the
# set that is already applied suspends the filter instead, so the same chord
# peeks at the whole tree and puts it back. Nothing is closed.
set -e

AGTERMCTL=${AGTERMCTL:-agtermctl}

# --- sets ------------------------------------------------------------------
# One arm per set. One workspace name per line, matched exactly, so names
# holding spaces work as written. Add, rename and reorder freely; the rest of
# the script does not care how many there are.
workspaces_in() {
	case $1 in
	work)
		cat <<-'EOF'
			umputun.dev
			agterm
			ai-thingz
		EOF
		;;
	personal)
		cat <<-'EOF'
			notes
			photos
		EOF
		;;
	*)
		return 1
		;;
	esac
}
# --- end of sets -----------------------------------------------------------

set_name=$1
if [ -z "$set_name" ]; then
	echo "usage: ${0##*/} <set-name>" >&2
	exit 2
fi

# Captured without a pipeline on purpose: a pipeline reports the exit code of its
# LAST command, so piping straight into sed would swallow the unknown-set failure
# and report it later as a set that matched nothing.
if ! wanted=$(workspaces_in "$set_name"); then
	echo "${0##*/}: no set named '$set_name'" >&2
	exit 2
fi
wanted=$(printf '%s\n' "$wanted" | sed '/^[[:space:]]*$/d')

# One read of the tree answers everything: which workspaces exist, which are
# already marked, and whether the filter is currently applied.
snapshot=$("$AGTERMCTL" tree --json)

# Workspace ids the set resolves to, and the names that matched nothing. A name
# that matches nothing is a typo or a renamed workspace, and silence there is
# how a set quietly stops covering half of what you meant.
desired=$(printf '%s' "$snapshot" | jq -r --arg names "$wanted" '
	($names | split("\n")) as $want
	| .result.tree.workspaces[]
	| select(.name as $n | $want | index($n)) | .id' | sort)

missing=$(printf '%s' "$snapshot" | jq -r --arg names "$wanted" '
	[.result.tree.workspaces[].name] as $have
	| ($names | split("\n"))[]
	| select(. as $n | $have | index($n) | not)')
[ -n "$missing" ] && printf '%s: no workspace named %s\n' "${0##*/}" "$missing" >&2

if [ -z "$desired" ]; then
	echo "${0##*/}: set '$set_name' matched no workspace in this window" >&2
	exit 1
fi

# Already showing exactly this set, so the chord means "let me see everything".
# The set stays marked, so pressing it again narrows straight back.
applied=$(printf '%s' "$snapshot" | jq -r '.result.tree.workspaceFilter // false')
marked=$(printf '%s' "$snapshot" | jq -r '.result.tree.workspaces[] | select(.focused) | .id' | sort)
if [ "$applied" = true ] && [ "$marked" = "$desired" ]; then
	"$AGTERMCTL" workspace filter off >/dev/null
	exit 0
fi

# Suspend the filter before rebuilding the set. An add never switches the filter
# on by itself, but a filter left on would hide the rows still to be marked.
"$AGTERMCTL" workspace filter off >/dev/null

printf '%s' "$snapshot" | jq -r --arg names "$wanted" '
	($names | split("\n")) as $want
	| .result.tree.workspaces[]
	| "\(if (.name as $n | $want | index($n)) then "add" else "off" end) \(.id)"' |
	while read -r mode id; do
		"$AGTERMCTL" workspace focus "$mode" --target "$id" >/dev/null
	done

"$AGTERMCTL" workspace filter on >/dev/null
