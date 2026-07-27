#!/bin/sh
# agt-resume.sh "A" - recreate the workspaces and sessions parked under that prefix.
#
# Each workspace comes back collapsed and each session is a fresh shell in its
# saved directory, running the command that was captured at park time.
set -e

AGTERMCTL=${AGTERMCTL:-agtermctl}
PARK_DIR=${AGT_PARK_DIR:-$HOME/.agterm-projects}

p=$1
if [ -z "$p" ]; then
	echo "usage: ${0##*/} <workspace-name-prefix>" >&2
	exit 2
fi

snapshot="$PARK_DIR/$p.json"
if [ ! -f "$snapshot" ]; then
	echo "no snapshot at $snapshot" >&2
	exit 1
fi

jq -c '.[]' "$snapshot" | while read -r w; do
	ws=$("$AGTERMCTL" workspace new "$(printf '%s' "$w" | jq -r .name)" --collapsed --json | jq -r .result.id)
	printf '%s' "$w" | jq -c '.sessions[]' | while read -r s; do
		cmd=$(printf '%s' "$s" | jq -r .cmd)
		set -- --workspace "$ws" --no-select \
			--cwd "$(printf '%s' "$s" | jq -r .cwd)" \
			--name "$(printf '%s' "$s" | jq -r .name)"
		if [ -n "$cmd" ]; then
			set -- "$@" --command "$cmd"
		fi
		"$AGTERMCTL" session new "$@"
	done
done
