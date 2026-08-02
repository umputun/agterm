#!/bin/bash
# pane-map-statusline.sh — a minimal Claude Code status line that records which transcript is live
# in which agterm pane, so claude-recap.zsh can find the exact session.
#
# only for readers who have no status line of their own: Claude Code runs exactly one, so anyone who
# already has one pastes the recording block into it instead (see the recipe README).
#
# the pane's shell never enters a worktree Claude Code moved into, so cwd alone cannot identify the
# transcript, and two panes of a split rooted at the same repository are indistinguishable without
# this. the status line runs as a child of claude, which is a child of the pane's shell, so it
# inherits AGTERM_SESSION_ID and AGTERM_PANE.

set -f

input=$(cat)
[ -n "$input" ] || { printf 'Claude'; exit 0; }

if [ -n "${AGTERM_SESSION_ID:-}" ]; then
    transcript_path=$(echo "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
    if [ -n "$transcript_path" ]; then
        pane_map_dir="${PANE_MAP_DIR:-/tmp/claude/panes}"
        mkdir -p "$pane_map_dir" 2>/dev/null
        printf '%s\n' "$transcript_path" > "$pane_map_dir/${AGTERM_SESSION_ID}.${AGTERM_PANE:-left}"
    fi
fi

printf '%s' "$(echo "$input" | jq -r '.model.display_name // "Claude"' 2>/dev/null)"
