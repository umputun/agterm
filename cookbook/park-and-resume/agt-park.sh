#!/bin/sh
# agt-park.sh "A" - snapshot every workspace whose name starts with "A", then delete them.
#
# DESTRUCTIVE: the parked workspaces are deleted and their shells are killed.
# Only the snapshot below survives, and agt-resume.sh replays it into fresh shells.
set -e

# the snapshot records the full argv of every process that was running, which can carry
# tokens, connection strings and passwords given on a command line. Keep the directory and
# the file private to this user: 0700 and 0600 rather than whatever the ambient umask gives.
umask 077

AGTERMCTL=${AGTERMCTL:-agtermctl}
PARK_DIR=${AGT_PARK_DIR:-$HOME/.agterm-projects}

p=$1
if [ -z "$p" ]; then
	echo "usage: ${0##*/} <workspace-name-prefix>" >&2
	exit 2
fi

mkdir -p "$PARK_DIR"
t=$("$AGTERMCTL" tree --json)

# write the snapshot to a temp file first, so a failed capture cannot destroy
# the previous one and cannot be followed by the deletions below.
#
# each cmd is the captured argv quoted twice: once per argument, then again around
# the joined line, so the whole line reaches "zsh -lc" as one argument. The login
# shell is there to restore PATH - argv comes back as it was typed, so a bare "nvim"
# would not resolve under the app's own PATH. Swap zsh for the shell that reads your
# profile if it is not zsh.
printf '%s' "$t" | jq --arg p "$p" '[.result.tree.workspaces[] | select(.name|startswith($p))
	| {name, sessions: [.sessions[] | {name, cwd, cmd: (if (.foreground // []) == [] then ""
		else "zsh -lc " + ((.foreground | map(@sh) | join(" ")) | @sh) end)}]}]' \
	>"$PARK_DIR/$p.json.tmp"

# a successful capture of nothing must not overwrite a good snapshot with an empty
# one, so refuse to publish it and stop before the deletions below
if [ "$(jq 'length' "$PARK_DIR/$p.json.tmp")" -eq 0 ]; then
	rm -f "$PARK_DIR/$p.json.tmp"
	echo "${0##*/}: no workspace name starts with '$p' in the frontmost window; nothing parked" >&2
	exit 1
fi

mv "$PARK_DIR/$p.json.tmp" "$PARK_DIR/$p.json"

printf '%s' "$t" | jq -r --arg p "$p" '.result.tree.workspaces[] | select(.name|startswith($p)) | .id' |
	while read -r w; do
		"$AGTERMCTL" workspace delete --target "$w"
	done
