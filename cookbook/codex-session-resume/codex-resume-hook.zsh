#!/usr/bin/env zsh
# Codex SessionStart hook for codex-session-resume: record which conversation this agterm tab shows.
#
# Codex runs it at a conversation's first turn, with the event as JSON on stdin, and again after
# /clear starts another conversation in the same codex, so the mapping follows what the tab shows. It acts only when CODEX_AGTERM_TAB is set. The codex function sets it for the
# codex it starts and blanks it for that codex's tool commands, so every other codex on the machine,
# such as a `codex exec` another agent runs in the same tab, leaves the mapping alone.
emulate -R zsh

tab=${CODEX_AGTERM_TAB-}
[[ -z $tab ]] && exit 0
# The tab id names a file, so anything but a lowercase UUID is refused rather than written.
if [[ ! $tab =~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' ]]; then
  print -ru2 -- "codex-resume-hook: CODEX_AGTERM_TAB is not a tab id: $tab"
  exit 1
fi

event=$(cat)
# Codex's background memory session fires SessionStart in the same codex process, with a
# transcript_path of null and a session id that has no rollout. Recording it would point the tab
# at a conversation the next codex cannot resume, so an event without a transcript is skipped.
if [[ ! $event =~ '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]' ]]; then
  exit 0
fi
# The first `"session_id": "<uuid>"` pair in the event, whitespace around the colon allowed.
if [[ ! $event =~ '"session_id"[[:space:]]*:[[:space:]]*"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"' ]]; then
  print -ru2 -- "codex-resume-hook: no session id in the SessionStart event"
  exit 1
fi
id=$match[1]

mapf=~/.codex/agterm/$tab
mkdir -p ${mapf:h} && print -r -- $id > $mapf.tmp && mv -f $mapf.tmp $mapf
