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
  local compact=${sid//-/}
  if [[ ${#sid} != 36 || $sid != ????????-????-????-????-???????????? ||
    ${#compact} != 32 || $compact == *[^0-9a-f]* ]]; then
    command claude "$@"; return                                 # malformed tab id -> do not use it in a path
  fi

  local replay=${2:l}
  if [[ "$1" == (--session-id|-r|--resume) && ${#replay} == 36 &&
    ${replay[1,-9]} == ${sid[1,-9]} && ${replay[-8,-1]} != *[^0-9a-f]* ]]; then
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

  local projects=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects
  local candidate transcript tail action generation=0

  while true; do
    candidate=$sid
    if (( generation )); then
      builtin printf -v tail '%08x' $(( (16#${sid[-8,-1]} + generation) & 0xffffffff ))
      candidate=${sid[1,-9]}$tail
    fi

    local transcripts=($projects/*/$candidate.jsonl(N))
    if (( ! ${#transcripts} )); then
      action=--session-id
      break
    fi

    for transcript in $transcripts; do
      local line found=0 other=0
      while IFS= read -r line || [[ -n $line ]]; do
        [[ -z $line ]] && continue
        found=1
        if [[ $line != '{"type":"bridge-session"'* ||
          $line != *'"sessionId":"'"$candidate"'"'* || $line != *\} ]] ||
          ! [[ $line =~ '"bridgeSessionId":"[^"]+"' ]] ||
          ! [[ $line =~ '"lastSequenceNum":[0-9]+' ]]; then
          other=1
          break
        fi
      done < "$transcript"
      if (( ! found || other )); then
        action=--resume
        break 2
      fi
    done
    (( generation++ ))                                          # metadata-only transcript -> leave it intact
  done

  command claude "$action" "$candidate" "$@"
}
