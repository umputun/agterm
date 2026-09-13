#!/bin/sh
# window-switcher.sh - jump to an agterm window by number, or pick one from a list that
# shows which windows have sessions waiting for you.
#
#   goto N   raise window number N. A window's number is its position in
#            `agtermctl window list`, i.e. the library order, closed windows included,
#            so the number does not depend on which window is frontmost and does not
#            shift when a window is closed. `goto` on a closed window reopens it.
#   pick     a native picker over every window: the ⌘N shortcut on the left, ● in place
#            of the number on the current window, a "◆ N" badge on windows with sessions
#            needing attention and up to two of them spelled out in the subtitle. Opens
#            on the current window when the CLI knows `pick --select`.
#   items    print the picker rows as JSON, for reading them or tuning the gutter without
#            opening the picker.
#
# "Attention" is agterm's own notion: a session whose agent status is `blocked` (waiting
# for input) or `completed` (finished, not yet looked at), the set ⌃⌥↑/↓ walk within a
# window. The session on screen in the current window is left out of that window's badge:
# you can already see it, and the badge is for what you can't.
set -eu

AGTERMCTL=${AGTERMCTL:-agtermctl}
sock=${AGT_SOCKET:-}
TAB=$(printf '\t')

# Gutter padding for the first line, where ⌘N or ● sits before the window name. `pick`
# has no columns, so the gutter is made of spaces, measured against the default palette
# font: "⌘N" plus PAD_SHORTCUT, ● plus PAD_CURRENT and PAD_NONE alone come out the same
# width. The subtitle is set in a smaller font, so no whole number of spaces lines it up
# with the name and it is deliberately not indented.
PAD_SHORTCUT=${PAD_SHORTCUT:-'   '}   # after ⌘N
PAD_CURRENT=${PAD_CURRENT:-'     '}   # after ●, which replaces the shortcut on the current window
PAD_NONE=${PAD_NONE:-'          '}    # windows past the ninth, which get no shortcut

agt() {
	if [ -n "$sock" ]; then
		"$AGTERMCTL" "$@" --socket "$sock"
	else
		"$AGTERMCTL" "$@"
	fi
}

# Every window in `window list` order; the position in this array is the window number.
all_windows() {
	agt window list --json | jq -c '.result.windows'
}

# One object per window, on top of its `window list` entry: `where`, the workspace and
# the session selected there ("closed" for a closed window), and `attn`, the sessions
# needing attention, freshest status first, each as {name, status, at}. A closed window
# has no tree to read, so it gets an empty list without a round trip.
windows_info() {
	windows=$(all_windows)
	now=$(date +%s)
	extra=$(printf '%s' "$windows" | jq -r '.[] | "\(.open)\t\(.active)\t\(.id)"' |
		while IFS="$TAB" read -r open active id; do
			if [ "$open" != "true" ]; then
				printf '{"where":"closed","attn":[]}\n'
				continue
			fi
			agt tree --window "$id" --json 2>/dev/null | jq -c --argjson current "$active" '
				# an auto-named session is its working directory, which the picker row
				# has no room for, so a path-like name is cut down to its last component
				def short: if test("^(…|~|\\.)?/")
				           then (split("/") | map(select(. != "")) | last) // .
				           else . end;
				[.result.tree.workspaces[]? | .name as $ws | .sessions[]?
				 | . + {ws: $ws, name: (.name | short)}] as $sessions
				| {
				    where: ([$sessions[] | select(.active) | "\(.ws) › \(.name)"] | first // ""),
				    attn: ([$sessions[]
				            | select(.status == "blocked" or .status == "completed")
				            | select(($current and .active) | not)
				            | {name, status, at: (.statusChangedAt // 0)}]
				           | sort_by(-.at))
				  }' 2>/dev/null || printf '{"where":"","attn":[]}\n'
		done | jq -s .)
	printf '%s' "$windows" | jq -c --argjson extra "$extra" --argjson now "$now" '
		to_entries | map(.value + ($extra[.key] // {where: "", attn: []}) + {slot: .key, now: $now})'
}

# Picker rows in window order. The subtitle is one line the picker truncates in the
# middle when it overflows, so at most two attention sessions are spelled out and the
# rest fold into "+N".
items() {
	windows_info | jq -c \
		--arg pad "$PAD_SHORTCUT" --arg padCur "$PAD_CURRENT" --arg padNone "$PAD_NONE" '
		def age: [.now - .at, 0] | max | floor
		  | if . < 60 then "\(.)s"
		    elif . < 3600 then "\(. / 60 | floor)m"
		    elif . < 86400 then "\(. / 3600 | floor)h"
		    else "\(. / 86400 | floor)d" end;
		def word: if . == "blocked" then "blocked" else "done" end;
		map(. as $w
		  | {
		      id: .id,
		      label: ((if .active then "●" + $padCur
		               elif .slot < 9 then "⌘\(.slot + 1)" + $pad
		               else $padNone end)
		              + .name
		              + (if (.attn | length) > 0 then "  ◆ \(.attn | length)" else "" end)),
		      subtitle: (if (.attn | length) == 0 then .where
		                 else ((if .where == "" then "" else .where + "  " end)
		                       + "◆ "
		                       + (([.attn[:2][] | "\(.name) \(.status | word) \({now: $w.now, at: .at} | age)"]
		                           + (if (.attn | length) > 2 then ["+\(.attn | length - 2)"] else [] end))
		                          | join(", ")))
		                 end)
		    })
		| map(if .subtitle == "" then del(.subtitle) else . end)'
}

# `pick --select` shipped after 0.29.1. An older CLI rejects the option before it opens
# anything, and its `--help` does not list it, so the check costs no socket round trip.
supports_select() {
	"$AGTERMCTL" pick open --help 2>&1 | grep -q -- '--select'
}

case "${1:-pick}" in
goto)
	n=${2:-}
	case "$n" in '' | *[!0-9]*)
		echo "usage: ${0##*/} goto N" >&2
		exit 64
		;;
	esac
	id=$(all_windows | jq -r --argjson n "$n" 'if $n >= 1 and $n <= length then .[$n - 1].id else "" end')
	[ -n "$id" ] || exit 0
	agt window select "$id"
	;;
items)
	items
	;;
pick)
	rows=$(items)
	current=$(printf '%s' "$rows" | jq -r '[.[] | select(.label | startswith("●")) | .id] | first // ""')
	if [ -n "$current" ] && supports_select; then
		set -- --select "$current"
	else
		set --
	fi
	result=$(printf '%s' "$rows" | agt pick --prompt "Select a window..." "$@") || exit 0
	id=$(printf '%s' "$result" | jq -r 'if .result == "picked" then .id else "" end')
	[ -n "$id" ] || exit 0
	agt window select "$id"
	;;
*)
	echo "usage: ${0##*/} goto N | pick | items" >&2
	exit 64
	;;
esac
