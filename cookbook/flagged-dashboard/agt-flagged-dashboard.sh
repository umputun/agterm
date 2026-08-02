#!/bin/sh
# agt-flagged-dashboard.sh - grid the flagged panes that are actually running something.
#
# The flagged sidebar view as live terminals instead of names, minus the panes
# sitting at a prompt: flag what you are babysitting, press the chord, watch it.
# Pressing the chord while the grid already shows that same set closes it, so one
# key both opens and dismisses. Nothing is closed and no shell is killed; only the
# grid overlay comes and goes.
set -e

AGTERMCTL=${AGTERMCTL:-agtermctl}

# The grid's pane limit. Only used to tell a grid trimmed by the cap from one
# that is short because the flags changed; raise it if a later agterm does.
CAP=9

# One read answers every question: which panes are flagged and busy, which are on
# the grid, and how many cells it holds. Two reads could disagree if a command
# finished between them.
snapshot=$("$AGTERMCTL" tree --json)

# A pane earns a cell when its session is flagged AND it reports a foreground
# command. `foreground`/`splitForeground` are omitted for a pane at its shell
# prompt, which is exactly the pane worth leaving off the grid.
panes=$(printf '%s' "$snapshot" | jq -r '
	.result.tree.workspaces[].sessions[]
	| select(.flagged)
	| (if .foreground then "\(.id):left" else empty end),
	  (if .splitForeground then "\(.id):right" else empty end)')

if [ -z "$panes" ]; then
	echo "${0##*/}: no flagged session is running anything" >&2
	exit 1
fi

# The grid is mine when it holds exactly the panes I would open. A full grid
# holding nothing but those panes counts too, because at the cap it CANNOT hold
# the whole set and demanding equality would leave the chord unable to close it.
verdict=$(printf '%s' "$snapshot" | jq -r --argjson cap "$CAP" '
	. as $root
	| ($root.result.tree.dashboardMembers // [] | unique) as $onscreen
	| ([$root.result.tree.workspaces[].sessions[]
	    | select(.flagged)
	    | (if .foreground then "\(.id):left" else empty end),
	      (if .splitForeground then "\(.id):right" else empty end)] | unique) as $wanted
	| if ($onscreen | length) == 0 then "open"
	  elif $onscreen == $wanted then "close"
	  elif ($onscreen | length) >= $cap and (($onscreen - $wanted) | length) == 0 then "close"
	  else "open"
	  end')

if [ "$verdict" = close ]; then
	"$AGTERMCTL" dashboard --close >/dev/null
	exit 0
fi

# Pane refs collected as positional parameters rather than an unquoted variable,
# so the expansion stays explicit and shellcheck has nothing to complain about.
set --
for ref in $panes; do
	set -- "$@" "$ref"
done

# The grid caps at nine panes and says so in the response when it trims. Fired
# from a chord that goes nowhere; run the script from a shell to read it.
note=$("$AGTERMCTL" dashboard "$@" --auto-size --json | jq -r '.result.text // empty')
[ -n "$note" ] && echo "${0##*/}: $note" >&2

exit 0
