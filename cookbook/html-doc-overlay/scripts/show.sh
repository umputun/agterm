#!/usr/bin/env bash
set -uo pipefail
AGTERMCTL="${AGTERMCTL:-agtermctl}"

if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "usage: show.sh FILE (got: ${1:-nothing})" >&2
  exit 2
fi
file="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"

if [[ "${AGTERM_ENABLED:-}" != "1" || -z "${AGTERM_SESSION_ID:-}" ]]; then
  open "$file" && echo "not in agterm, opened in browser: $file"
  exit $?
fi

sid="$AGTERM_SESSION_ID"
# tree reports the frontmost window only; a session in a background window would read as missing
# agtermctl never reads AGTERM_SOCKET, so without --socket a second instance would drive the live one
node_json() {
  "$AGTERMCTL" tree --json ${AGTERM_SOCKET:+--socket "$AGTERM_SOCKET"} ${AGTERM_WINDOW_ID:+--window "$AGTERM_WINDOW_ID"} | jq --arg id "$sid" '[.. | objects | select(.id? == $id)][0]'
}

# the reported path may differ from ours by a symlinked parent (/tmp -> /private/tmp)
canon() {
  [[ -z "$1" || ! -e "$1" ]] && { echo "$1"; return; }
  echo "$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
}

node="$(node_json)"
if [[ -z "$node" || "$node" == "null" ]]; then
  echo "session $sid not found in agterm tree" >&2
  exit 1
fi

shown="$(jq -r '[.htmlOverlays // [] | .[] | select(.pane == null)][0].file // ""' <<<"$node")"
shown_url="$(jq -r '[.htmlOverlays // [] | .[] | select(.pane == null)][0].url // ""' <<<"$node")"
program="$(jq -r 'if .overlay == true and ([.htmlOverlays // [] | .[] | select(.pane == null)] | length) == 0 then "yes" else "" end' <<<"$node")"

if [[ -n "$program" ]]; then
  echo "a program overlay is running in this session; close it first, the page was written to $file" >&2
  exit 1
fi

if [[ -n "$shown" && "$(canon "$shown")" == "$file" ]]; then
  "$AGTERMCTL" session overlay reload ${AGTERM_SOCKET:+--socket "$AGTERM_SOCKET"} --target "$sid" >/dev/null || exit 1
  action="reloaded"
else
  if [[ -n "$shown" || -n "$shown_url" ]]; then
    "$AGTERMCTL" session overlay close ${AGTERM_SOCKET:+--socket "$AGTERM_SOCKET"} --target "$sid" >/dev/null || exit 1
  fi
  "$AGTERMCTL" session overlay open ${AGTERM_SOCKET:+--socket "$AGTERM_SOCKET"} --html "$file" --target "$sid" --size-percent 95 --follow >/dev/null || exit 1
  action="opened"
fi

state="loading"
for _ in $(seq 1 25); do
  entry="$(node_json | jq -c '[.htmlOverlays // [] | .[] | select(.pane == null)][0] // {}')"
  state="$(jq -r '.state // "missing"' <<<"$entry")"
  [[ "$state" != "loading" ]] && break
  sleep 0.2
done

if [[ "$state" == "failed" ]]; then
  echo "$action but the page failed to load: $(jq -r '.error // "no error reported"' <<<"$entry")" >&2
  exit 1
fi
echo "$action ($state): $file"
