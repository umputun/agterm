#!/bin/sh
# agt-win.sh "Project A" - park every other open window in the Dock, then raise that one.
set -e

AGTERMCTL=${AGTERMCTL:-agtermctl}

n=$1
if [ -z "$n" ]; then
	echo "usage: ${0##*/} <window-name>" >&2
	exit 2
fi

t=$("$AGTERMCTL" window list --json)

target=$(printf '%s' "$t" | jq -r --arg n "$n" '.result.windows[] | select(.name == $n) | .id' | head -n 1)
if [ -z "$target" ]; then
	echo "no window named $n" >&2
	exit 1
fi

# closed windows cannot be minimized, so skip them; a full-screen window is
# refused by design, so report it and keep going rather than stopping here
printf '%s' "$t" | jq -r --arg n "$n" '.result.windows[] | select(.open and .name != $n) | .id' |
	while read -r id; do
		"$AGTERMCTL" window minimize "$id" on || echo "could not park window $id" >&2
	done

"$AGTERMCTL" window select "$target"
