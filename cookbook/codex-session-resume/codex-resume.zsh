#!/usr/bin/env zsh
# Sourced, not executed: paste this function into ~/.zshrc, or source this file from there.
# See README.md.

# Codex CLI: per-agterm-tab session resume.
# Maps the tab's own uuid (AGTERM_SESSION_ID) to a codex session id under ~/.codex/agterm/,
# so restoring the terminal resumes that tab's own conversation instead of starting fresh.
# Requires: agterm (exports AGTERM_SESSION_ID, restores running commands) + zsh.
_codex_rollout_root_id() {
  emulate -L zsh
  local file=$1 line candidate
  local id=${${file:t:r}[-36,-1]}
  # Codex currently writes compact session_meta JSON with payload.session_id as the
  # first session_id field; the UUID shape check preserves the filename fallback.
  if IFS= read -r line < "$file" &&
      [[ $line == *'"type":"session_meta"'* && $line == *'"session_id":"'* ]]; then
    candidate=${${line#*'"session_id":"'}%%\"*}
    [[ $candidate == ????????-????-????-????-???????????? ]] && id=$candidate
  fi
  [[ $id == ????????-????-????-????-???????????? ]] && print -r -- $id
}

codex() {
  emulate -L zsh
  setopt local_options null_glob
  local sid=${AGTERM_SESSION_ID:l}
  [[ -z $sid ]] && { command codex "$@"; return; }

  local a
  for a in "$@"; do
    case $a in
      -h|--help|-V|--version|--remote|--remote=*|\
      exec|e|review|login|logout|mcp|plugin|mcp-server|app-server|remote-control|app|completion|\
      update|doctor|sandbox|debug|apply|a|resume|archive|delete|unarchive|fork|cloud|exec-server|features|help)
        command codex "$@"; return ;;
    esac
  done

  local mapf=~/.codex/agterm/$sid
  local cid; [[ -f $mapf ]] && cid=$(<$mapf)
  local -a s=(~/.codex/sessions/**/rollout-*-$cid.jsonl(N))
  if [[ -n $cid ]] && (( $#s )); then
    local rid=$(_codex_rollout_root_id $s[1])
    local -a roots=(~/.codex/sessions/**/rollout-*-$rid.jsonl(N))
    if [[ -n $rid ]] && (( $#roots )); then
      [[ $rid != $cid ]] && print -r -- $rid > $mapf
      command codex resume "$rid" "$@"; return
    fi
  fi

  local before=$(mktemp)
  command codex "$@"; local rc=$?
  local -a new=(~/.codex/sessions/**/rollout-*.jsonl(N.om))
  if (( $#new )) && [[ $new[1] -nt $before ]]; then
    local uuid=$(_codex_rollout_root_id $new[1])
    [[ -n $uuid ]] && { mkdir -p ${mapf:h}; print -r -- $uuid > $mapf; }
  fi
  command rm -f $before
  return $rc
}
