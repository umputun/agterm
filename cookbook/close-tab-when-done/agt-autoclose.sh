#!/bin/sh
# agt-autoclose.sh - arm a session to close itself when the agent stops replying.
#
# DESTRUCTIVE: firing closes the session, killing every process in it and
# discarding its scrollback. There is no undo. Read the README's Limits.
#
# toggle|on|off|status take a session id, defaulting to $AGTERM_SESSION_ID, so a
# chord passes "{AGT_SESSION_ID}" and a shell inside the session passes nothing.
# fire is what the agent's stop hook calls; it reads the environment only.
set -e

AGTERMCTL=${AGTERMCTL:-agtermctl}
STATE_DIR=${AGT_AUTOCLOSE_DIR:-$HOME/.agterm-autoclose}
# no colon: an empty AGT_AUTOCLOSE_BADGE means "no badge", not "the default"
BADGE=${AGT_AUTOCLOSE_BADGE-⏻ }
GRACE=${AGT_AUTOCLOSE_GRACE:-0.4}

# A chord exports AGT_SOCKET; a session's shell, and every hook it spawns,
# exports AGTERM_SOCKET. Addressing the socket the caller came from is what
# keeps a second agterm, running from another state directory, out of it.
socket=${AGT_SOCKET:-${AGTERM_SOCKET:-}}

# The socket path holds a space on a default install, so it can never be pasted
# into a command line as bare words. One wrapper keeps every call quoted.
agt() {
	if [ -n "$socket" ]; then
		"$AGTERMCTL" "$@" --socket "$socket"
	else
		"$AGTERMCTL" "$@"
	fi
}

# A session id becomes a file name, so it is validated rather than trusted: an id
# is a UUID and nothing else. Without this, `on ../../notes.md` truncates that
# file and `off` deletes it - and the id is an advertised argument, so a typo
# reaches it, not only malice. Upper-cased because agterm reports ids upper-case:
# a lower-case id would arm one marker while fire looks for another.
canonical_id() {
	printf '%s' "$1" | tr '[:lower:]' '[:upper:]' |
		grep -Ex '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}'
}

marker_for() { printf '%s/%s\n' "$STATE_DIR" "$1"; }

# `tree` reports one window, the frontmost, but an armed session can be anywhere:
# the agent works in a background window while you use another. So walk the
# windows rather than reading the frontmost tree and calling a miss "not found".
# select(.open): `window list` reports closed windows too, and `tree` answers a
# null tree for one, which jq then fails to iterate over.
# Returns 1 when a read failed and 0 with no output when the session is simply
# not there. A pipeline would report neither: jq on empty input and a `while`
# loop both succeed, so a missing CLI would read as "session not found" and the
# caller would arm a tab it could not badge.
session_name() {
	windows=$(agt window list --json) || return 1
	ids=$(printf '%s' "$windows" | jq -r '.result.windows[] | select(.open) | .id') || return 1
	for w in $ids; do
		tree=$(agt tree --window "$w" --json) || return 1
		n=$(printf '%s' "$tree" | jq -r --arg s "$1" '
			(.result.tree.workspaces // [])[].sessions[]?
			| select((.id | ascii_upcase) == $s)
			| .name // empty') || return 1
		if [ -n "$n" ]; then
			printf '%s\n' "$n"
			return 0
		fi
	done
	return 0
}

badge_on() {
	[ -n "$BADGE" ] || return 0
	name=$(session_name "$1") || return 1
	# an empty name means the session was not found in any open window; renaming
	# one that is not there is not worth an error, the marker is what counts
	case $name in
	"$BADGE"* | '') return 0 ;;
	esac
	agt session rename "$BADGE$name" --target "$1" >/dev/null
}

badge_off() {
	[ -n "$BADGE" ] || return 0
	name=$(session_name "$1") || return 1
	case $name in
	"$BADGE"*) agt session rename "${name#"$BADGE"}" --target "$1" >/dev/null ;;
	esac
}

# Fail closed. A marker with no badge on it is a tab that closes with no warning
# at all, so an arm that cannot reach agterm leaves nothing behind: one live read
# proves the CLI resolves, the socket answers, and jq is there to parse it.
arm() {
	if ! windows=$(agt window list --json 2>/dev/null) ||
		! printf '%s' "$windows" | jq -e '.result.windows' >/dev/null 2>&1; then
		echo "${0##*/}: cannot reach agterm - check agtermctl, the socket and jq" >&2
		return 1
	fi
	mkdir -p "$STATE_DIR"
	: >"$(marker_for "$1")"
	if ! badge_on "$1"; then
		rm -f "$(marker_for "$1")"
		echo "${0##*/}: could not badge the session, left disarmed" >&2
		return 1
	fi
}

disarm() {
	rm -f "$(marker_for "$1")"
	badge_off "$1"
}

# Claude Code runs a background or adopted session inside a daemon-hosted worker
# (`claude daemon run`, `bg-pty-host`, `bg-spare`), and such a worker carries the
# AGTERM_SESSION_ID of whichever tab first started the daemon - usually a tab
# that has since been closed, and whose id says nothing about where this agent is
# running. Firing on that id closes a session that has nothing to do with this
# turn, so a daemon-hosted run does not fire at all. $CLAUDE_PID is the Claude
# process that spawned the hook; its ancestors are what tell the two apart.
daemon_hosted() {
	pid=${CLAUDE_PID:-$PPID}
	hops=0
	while [ "$hops" -lt 12 ]; do
		hops=$((hops + 1))
		{ [ -n "$pid" ] && [ "$pid" -gt 1 ]; } 2>/dev/null || break
		cmd=$(ps -o command= -p "$pid" 2>/dev/null) || break
		[ -n "$cmd" ] || break
		case $cmd in
		*bg-spare* | *bg-pty-host* | *"daemon run"*) return 0 ;;
		esac
		pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
	done
	return 1
}

# Every path out of here exits 0. A stop hook that fails makes the agent report a
# hook error at the end of a turn that went fine, and there is nothing the user
# can do about it from there. Outside agterm, or without the CLI, it is a silent
# no-op, which is what makes it safe to install once and leave alone.
fire() {
	sid=$(canonical_id "${AGTERM_SESSION_ID:-}") || exit 0
	[ -n "$sid" ] || exit 0
	command -v "$AGTERMCTL" >/dev/null 2>&1 || exit 0
	m=$(marker_for "$sid")
	[ -f "$m" ] || exit 0
	! daemon_hosted || exit 0

	# one shot, and the marker goes first: a close that fails for any reason leaves
	# a disarmed session rather than one closing at an unrelated moment. Plain
	# `rm`, not `rm -f`: removing the marker is what CLAIMS the close, and -f
	# succeeds on a file that is already gone - a disarm racing this hook, or a
	# second Stop arriving alongside it, would both go on to close the tab.
	rm "$m" 2>/dev/null || exit 0

	# `session close` kills the agent, which is this hook's own parent, so the
	# call has to outlive the hook: nohup makes it ignore the SIGHUP that reaches
	# the session's processes. Re-entering this script rather than composing an
	# `sh -c` line keeps the socket path, which holds a space, out of a second
	# round of shell quoting. The badge is left alone - the row it sits on is
	# about to go, and a window walk here would spend the hook's timeout.
	nohup "$0" close-later "$sid" >/dev/null 2>&1 &
	exit 0
}

cmd=${1:-}
case $cmd in
fire)
	fire
	;;
close-later)
	# internal, detached by fire: wait out the grace period so the agent finishes
	# drawing the reply, then close. Never bind this to a chord.
	sleep "$GRACE"
	agt session close --target "$2" >/dev/null 2>&1 || true
	;;
toggle | on | off | status)
	if ! sid=$(canonical_id "${2:-${AGTERM_SESSION_ID:-}}"); then
		echo "${0##*/}: not a session id: '${2:-${AGTERM_SESSION_ID:-}}'" >&2
		exit 2
	fi
	case $cmd in
	toggle) if [ -f "$(marker_for "$sid")" ]; then disarm "$sid"; else arm "$sid"; fi ;;
	on) arm "$sid" ;;
	off) disarm "$sid" ;;
	status) if [ -f "$(marker_for "$sid")" ]; then echo on; else echo off; fi ;;
	esac
	;;
*)
	echo "usage: ${0##*/} toggle|on|off|status [session-id]" >&2
	echo "       ${0##*/} fire        (called by the agent's stop hook)" >&2
	exit 2
	;;
esac
