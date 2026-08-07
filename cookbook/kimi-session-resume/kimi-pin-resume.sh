#!/bin/bash
# kimi-code SessionStart hook: pin this agterm tab's restore command to
# `kimi -r <session_id>`, so restoring the terminal resumes the tab's own
# conversation. Installed via a [[hooks]] block in ~/.kimi-code/config.toml;
# see README.md. Outside agterm it is a silent no-op.

[ -n "$AGTERM_SESSION_ID" ] || exit 0
[ -n "$AGTERM_SOCKET" ] || exit 0

# A kimi run spawned by a Claude Code session (a worker inside an agent
# pipeline) shares the pane with its parent: the pane's pin belongs to the
# Claude conversation, not the child. Skip those.
[ -n "$CLAUDE_CODE_SESSION_ID" ] && exit 0

AGTERMCTL=${AGTERMCTL:-agtermctl}
command -v "$AGTERMCTL" >/dev/null 2>&1 || exit 0

# kimi hooks deliver JSON on stdin; SessionStart carries the session id.
session_id=$(python3 -c 'import sys,json;print(json.load(sys.stdin).get("session_id",""))' 2>/dev/null)
[ -n "$session_id" ] || exit 0

# Carry the -m model flag of the owning kimi process into the resume, so a
# lane launched against a specific route comes back on the same one. Hooks
# run under an intermediate shell, so walk up the process tree to find it.
flags=""
pid=$$
for _ in 1 2 3 4 5 6; do
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  { [ -n "$pid" ] && [ "$pid" -gt 1 ]; } 2>/dev/null || break
  parent_cmd=$(ps -o command= -p "$pid" 2>/dev/null)
  case "$parent_cmd" in
    kimi\ *|*/kimi\ *|kimi-code*|*/kimi-code*)
      # First standalone -m token. The value lands in shell code (the pinned
      # restore line), so anything outside a safe charset is dropped, not quoted.
      model=$(printf '%s' "$parent_cmd" |
        awk '{for (i = 1; i < NF; i++) if ($i == "-m") { print $(i + 1); exit }}')
      case $model in
        *[!A-Za-z0-9._:@/-]*) ;;
        ?*) flags=" -m $model";;
      esac
      break;;
  esac
done

pane_flag=""
[ -n "$AGTERM_PANE_ID" ] && pane_flag="--pane-id $AGTERM_PANE_ID"

# shellcheck disable=SC2086  # pane_flag is deliberately word-split
"$AGTERMCTL" session restore "kimi${flags} -r $session_id" \
  --target "$AGTERM_SESSION_ID" $pane_flag \
  --socket "$AGTERM_SOCKET" >/dev/null 2>&1 || true
exit 0
