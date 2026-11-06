#!/usr/bin/env bash
set -euo pipefail

AGTERMCTL=${AGTERMCTL:-agtermctl}
JQ=${JQ:-jq}
FLAG_RECENT_MINUTES=${FLAG_RECENT_MINUTES:-30}

socket=${AGT_SOCKET:?run this as an agterm custom command, which supplies AGT_SOCKET}
win=${AGT_WINDOW_ID:-active}
ctl() { "$AGTERMCTL" "$@" --socket "$socket"; }

cutoff=$(($(date +%s) - FLAG_RECENT_MINUTES * 60))
rows=$(ctl tree --json --window "$win" | CUTOFF=$cutoff "$JQ" -r '
	.result.tree.workspaces[] | {ws: .name} + .sessions[]
	| select(.status == "active" or (.statusChangedAt // 0) >= (env.CUTOFF | tonumber))
	| [.id, "\(.name) : \(.ws)",
	   (.status // "idle")
	   + (if .statusChangedAt then ", \(((now - .statusChangedAt) / 60) | floor)m ago" else "" end)
	   + (if .context then " - \(.context)" else "" end)]
	| @tsv')

if [ -z "$rows" ]; then
	ctl session hud open "no sessions with a recent status" --hide-after 5 --target "${AGT_SESSION_ID:-active}" >/dev/null
	exit 0
fi

args=()
while IFS=$'\t' read -r id label sub; do
	args+=(--choice "$id=$label" --choice-subtitle "$id=$sub" --checked "$id")
done <<<"$rows"

# cancel and esc exit 3, an administrative cancel 2: both leave the flags alone
if answer=$(ctl ask open "Flag recent sessions" --multiple "${args[@]}" --window "$win"); then rc=0; else rc=$?; fi
case $rc in
0) ;;
2 | 3) exit 0 ;;
*) exit "$rc" ;;
esac
[ "$(printf '%s' "$answer" | "$JQ" -r '.id')" = ok ] || exit 0
ids=$(printf '%s' "$answer" | "$JQ" -r '.selected[]')

ctl session flag clear --window "$win" >/dev/null
for id in $ids; do
	ctl session flag on --target "$id" --window "$win" >/dev/null
done
# sidebar mode targets the window frontmost at this call, not necessarily the invoking window
ctl sidebar mode flagged >/dev/null
