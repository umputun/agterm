#!/usr/bin/env zsh
# Sourced, not executed: paste this function into ~/.zshrc, or source this file from there.
# See README.md.

# Codex CLI: per-agterm-tab session resume.
# Maps the tab's own uuid (AGTERM_SESSION_ID) to a codex session id under ~/.codex/agterm/,
# so restoring the terminal resumes that tab's own conversation instead of starting fresh.
# Requires: agterm (exports AGTERM_SESSION_ID, restores running commands) + zsh.
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
    command codex resume "$cid" "$@"; return
  fi

  local before=$(mktemp)
  command codex "$@"; local rc=$?
  local -a new=(~/.codex/sessions/**/rollout-*.jsonl(N.om))
  if (( $#new )) && [[ $new[1] -nt $before ]]; then
    local uuid=${${new[1]:t:r}[-36,-1]}
    [[ $uuid == ????????-????-????-????-???????????? ]] && { mkdir -p ${mapf:h}; print -r -- $uuid > $mapf; }
  fi
  command rm -f $before
  return $rc
}
