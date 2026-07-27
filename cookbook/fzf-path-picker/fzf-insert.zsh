#!/usr/bin/env zsh
# fzf-insert.zsh files|dirs <session-id> - pick a path under the configured roots with fzf,
# then type it into the session the keybinding was pressed in.
#
# Meant to run inside an agterm overlay. The session id has to be passed in: the keybinding's
# $AGT_* values live in the custom command's own process, not in the overlay's fresh pty, so the
# `session type` at the end needs an explicit --target.

AGTERMCTL=${AGTERMCTL:-agtermctl}

mode=$1
session=$2

if [ -z "$mode" ] || [ -z "$session" ]; then
	printf '\n  usage: %s files|dirs <session-id>\n\n' "${0##*/}"
	exit 2
fi

# search roots, colon-separated. A bounded set of trees keeps the walk fast and avoids the macOS
# privacy prompts that a walk over Documents, Desktop or Downloads triggers.
roots=()
for d in ${(s.:.)${AGT_FZF_ROOTS:-$HOME/src}}; do
	[ -d "$d" ] && roots+=("$d")
done
if [ ${#roots[@]} -eq 0 ]; then
	printf '\n  no search roots exist. Set AGT_FZF_ROOTS to a colon-separated list of directories.\n\n'
	exit 1
fi

case "$mode" in
	files)
		sel=$(fd --type f . "${roots[@]}" | fzf --header 'Files (Enter: insert path, Esc: cancel)')
		;;
	dirs)
		sel=$(fd --type d . "${roots[@]}" | fzf --header 'Directories (Enter: insert path, Esc: cancel)')
		;;
	*)
		printf '\n  usage: %s files|dirs <session-id>\n\n' "${0##*/}"
		exit 2
		;;
esac

# Esc or no pick leaves nothing to insert
[ -n "$sel" ] || exit 0

# type the path into the session's main pane. Command substitution already stripped the trailing
# newline, so the path arrives without a Return and the shell does not run it.
"$AGTERMCTL" session type "$sel" --target "$session"
