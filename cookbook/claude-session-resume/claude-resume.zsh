#!/usr/bin/env zsh
# Sourced, not executed: paste this function into ~/.zshrc, or source this file from there.
# See README.md.

# Claude Code: per-agterm-tab session resume.
# Binds each tab's Claude Code session id to the tab's own uuid (AGTERM_SESSION_ID),
# so restoring the terminal resumes that tab's own conversation instead of starting fresh.
# Requires: agterm (exports AGTERM_SESSION_ID, restores running commands) + zsh.
claude() {
  emulate -L zsh
  local sid=${AGTERM_SESSION_ID:l}
  [[ -z $sid ]] && { command claude "$@"; return; }             # not in an agterm tab -> passthrough

  if [[ "$1" == (--session-id|-r|--resume) && "${2:l}" == $sid ]]; then
    shift 2                                                      # restore replayed our own flag -> re-decide below
  else
    local a
    for a in "$@"; do                                           # user steering a session/subcommand/headless?
      case $a in
        -r|--resume|--session-id|--resume=*|--session-id=*|-r=*|-c|--continue|-p|--print|-v|--version|-h|--help|mcp|update|doctor|config|install|migrate-installer|setup-token)
          command claude "$@"; return ;;                        # -> hand off untouched
      esac
    done
  fi

  local -a f=(~/.claude/projects/*/$sid.jsonl(N))               # does this tab's session already exist?
  if (( $#f )); then command claude --resume "$sid" "$@"        # yes -> continue it
  else command claude --session-id "$sid" "$@"; fi              # no  -> create it with this fixed id
}
