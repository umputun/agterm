#!/usr/bin/env zsh
# Sourced, not executed: paste both functions into ~/.zshrc, or source this file from there.
# See README.md.

# opencode: per-agterm-tab session resume.
# Maps the tab's own uuid (AGTERM_SESSION_ID) to an opencode session id under
# ~/.local/state/opencode/agterm/, so restoring the terminal resumes that tab's own
# conversation instead of starting fresh.
# Requires: agterm (exports AGTERM_SESSION_ID, restores running commands) + zsh.

# Session ids of the current project, most recently updated first.
# opencode keeps sessions in sqlite, so the CLI is the only supported way to ask. The list is
# scoped to the project while --session is not scoped at all, so anything listed is resumable.
_agterm_opencode_sessions() {
  emulate -L zsh
  local line
  command opencode session list --format json 2>/dev/null | while read -r line; do
    [[ $line == '"id": "ses_'* ]] || continue      # one field per line, so a title cannot fake an id line
    line=${line#*: \"}
    print -r -- ${line%%\"*}
  done
}

opencode() {
  emulate -L zsh
  local sid=${AGTERM_SESSION_ID:l}
  [[ -z $sid ]] && { command opencode "$@"; return; }              # not in an agterm tab -> passthrough

  local mapf=${XDG_STATE_HOME:-$HOME/.local/state}/opencode/agterm/$sid
  local cid; [[ -f $mapf ]] && cid=$(<$mapf)

  if [[ $1 == (-s|--session) && -n $cid && $2 == $cid ]]; then
    shift 2                                                        # restore replayed our own flag -> re-decide below
  else
    local a
    for a in "$@"; do                                              # user steering a session/subcommand?
      case $a in
        -s|--session|--session=*|-c|--continue|--fork|-h|--help|-v|--version|\
        run|attach|serve|web|acp|mcp|models|stats|export|import|session|plugin|plug|db|\
        debug|agent|providers|auth|github|pr|upgrade|uninstall|completion)
          command opencode "$@"; return ;;                         # -> hand off untouched
      esac
    done
  fi

  local -a before=( ${(f)"$(_agterm_opencode_sessions)"} )         # what existed before this run
  if [[ -n $cid ]] && (( ${before[(Ie)$cid]} )); then
    command opencode --session $cid "$@"                           # this tab's session is still there -> continue it
    return
  fi

  command opencode "$@"                                            # nothing to resume -> plain run, then adopt what it made
  local rc=$? id
  for id in ${(f)"$(_agterm_opencode_sessions)"}; do
    [[ -n $id ]] || continue
    (( ${before[(Ie)$id]} )) && continue                           # was already there -> not this run's
    command mkdir -p ${mapf:h} && print -r -- $id > $mapf
    break
  done
  return $rc
}
