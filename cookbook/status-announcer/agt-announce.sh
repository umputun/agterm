#!/bin/sh
# agt-announce.sh - speak agent status changes out loud, from a dedicated session.
#
# No argument toggles the announcer: it closes the session when one is already
# running, and creates it running the event loop when none is. "loop" is the
# loop itself, which is what that session runs. You call the first form; the
# second one calls itself.
set -e

AGTERMCTL=${AGTERMCTL:-agtermctl}

# The dedicated session's name. Toggling off closes whatever session carries it,
# so pick something you would not name a session of your own.
ANNOUNCER_NAME=${ANNOUNCER_NAME:-status-announcer}

# Which statuses to speak, space separated. "active" is deliberately absent: the
# agent-status hooks re-assert it on every tool call, so speaking it never stops.
SPOKEN=${SPOKEN:-"blocked completed idle"}

TAB=$(printf '\t')

# This script's absolute path. The toggle passes it to session.new as the new
# session's command, so the path has to survive leaving this process.
self_path() {
	dir=$(dirname "$0")
	cd "$dir" 2>/dev/null || exit 1
	printf '%s/%s' "$(pwd)" "$(basename "$0")"
}

# The announcer's session id, searched across every open window, empty when it is
# not running. Scanning all windows rather than the frontmost one keeps the toggle
# honest: found from anywhere, so a second announcer is never started by accident.
find_announcer() {
	"$AGTERMCTL" window list --json |
		jq -r '.result.windows[] | select(.open) | .id' |
		while read -r window; do
			"$AGTERMCTL" tree --json --window "$window" |
				jq -r --arg name "$ANNOUNCER_NAME" \
					'.result.tree.workspaces[].sessions[]
						| select(.name == $name) | .id'
		done | head -n 1
}

# A workspace's name from the ids the event carried. Empty when the window has
# closed since, which the caller speaks around rather than failing on.
workspace_name() {
	[ -n "$1" ] && [ -n "$2" ] || return 0
	"$AGTERMCTL" tree --json --window "$1" 2>/dev/null |
		jq -r --arg id "$2" '.result.tree.workspaces[]
			| select(.id == $id) | .name' |
		head -n 1
}

# Print the change, then speak it. Printing first means the session shows an event
# as it arrives, rather than after say has finished talking about the one before.
# The line keeps the real names; only the spoken copy is flattened.
announce() {
	ws=$1
	sess=$2
	st=$3
	if [ -n "$ws" ]; then
		printf '%s  %s / %s  %s\n' "$(date +%H:%M:%S)" "$ws" "$sess" "$st"
		phrase="$ws, $sess $st"
	else
		printf '%s  %s  %s\n' "$(date +%H:%M:%S)" "$sess" "$st"
		phrase="$sess $st"
	fi
	# say pronounces punctuation, so "umputun.dev" comes out as "umputun dot dev".
	# Flattening the separators is the difference between a name and a spelling.
	say "$(printf '%s' "$phrase" | tr '._-' '   ')"
}

# Read the status stream and speak each transition. jq filters the whole stream in
# one pass; --unbuffered is what makes it arrive per event rather than per block.
loop() {
	printf 'status announcer: listening for %s\n' "$SPOKEN"
	printf 'run the toggle again to stop\n\n'
	"$AGTERMCTL" events --json --kind status |
		jq -r --unbuffered --arg self "${AGTERM_SESSION_ID:-}" --arg spoken "$SPOKEN" '
			($spoken | split(" ")) as $want
			| select(.session != $self)
			| select(.payload.status as $status | $want | index($status))
			| [.payload.status, .payload.name, .window, .workspace] | @tsv' |
		while IFS="$TAB" read -r status name window workspace; do
			announce "$(workspace_name "$window" "$workspace")" "$name" "$status"
		done
	# nothing is printed past here on purpose: the session was created with
	# --command, so it closes the moment this function returns, and a parting
	# message would be torn down before it could be read.
}

toggle() {
	running=$(find_announcer)
	if [ -n "$running" ]; then
		"$AGTERMCTL" session close --target "$running"
		return
	fi
	# session.new execs its command directly under the app's launchd PATH, which
	# has no /opt/homebrew/bin, so jq would exit 127 and the session would vanish
	# the moment it opened. The login shell is what puts your own PATH back.
	# --no-select leaves your selection and focus where they are. The announcer is a
	# background thing; being yanked into it every time you start it is a nuisance.
	script=$(self_path)
	"$AGTERMCTL" session new --name "$ANNOUNCER_NAME" --no-select \
		--command "/bin/zsh -lc \"'$script' loop\""
}

case ${1:-toggle} in
toggle) toggle ;;
loop) loop ;;
*)
	echo "usage: ${0##*/} [toggle|loop]" >&2
	exit 2
	;;
esac
