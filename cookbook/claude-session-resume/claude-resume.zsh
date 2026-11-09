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
        -r|--resume|--session-id|--resume=*|--session-id=*|-r=*|-c|--continue|-p|--print|-v|--version|-h|--help|agents|attach|auth|auto-mode|config|doctor|gateway|import|install|logs|mcp|migrate-installer|plugin|plugins|purge|respawn|rm|setup-token|stop|kill|ultrareview|update|upgrade)
          command claude "$@"; return ;;                        # -> hand off untouched
      esac
    done
  fi

  # The account. CLAUDE_CONFIG_DIR names it for a launch the user typed, but agterm replays a
  # pane's argv and not its environment, so the variable is gone from a restored launch and the
  # tab would look for its conversation under the default account. The remembered directory is
  # consulted only when the default account holds nothing for this tab, so it never takes a
  # working default-account resume away.
  local default=$HOME/.claude
  local memo=${XDG_STATE_HOME:-$HOME/.local/state}/agterm-claude-resume/$sid
  local -a roots=(${CLAUDE_CONFIG_DIR:-$default})
  if [[ -z ${CLAUDE_CONFIG_DIR:-} && -r $memo ]]; then
    local remembered
    IFS= read -r remembered < $memo
    [[ -n $remembered && $remembered != $roots[1] && -d $remembered/projects ]] && roots+=($remembered)
  fi

  local root candidate action tail transcript line found other generation
  local -a transcripts
  local pick_root= pick_candidate= pick_action=
  for root in $roots; do
    generation=0
    candidate= action=
    while (( generation <= 64 )); do
      candidate=$sid
      if (( generation )); then
        builtin printf -v tail '%08x' $(( (16#${sid[-8,-1]} + generation) & 0xffffffff ))
        candidate=${sid[1,-9]}$tail
      fi

      transcripts=($root/projects/*/$candidate.jsonl(N))
      if (( ! ${#transcripts} )); then
        action=--session-id
        break
      fi

      for transcript in $transcripts; do
        found=0 other=0
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
        (( other || ! found )) && { action=--resume; break; }
      done
      [[ $action == --resume ]] && break
      (( generation++ ))                                        # metadata-only transcript -> leave it intact
    done
    [[ -z $action ]] && action=--session-id                     # ran out of generations
    if [[ -z $pick_action ]]; then
      pick_root=$root pick_candidate=$candidate pick_action=$action   # the effective account decides by default
    fi
    [[ $action == --resume ]] && { pick_root=$root pick_candidate=$candidate pick_action=$action; break; }
  done

  if [[ -n ${CLAUDE_CONFIG_DIR:-} && $CLAUDE_CONFIG_DIR != $default ]]; then
    mkdir -p ${memo:h} 2>/dev/null && print -r -- $CLAUDE_CONFIG_DIR > $memo 2>/dev/null
  fi

  CLAUDE_CONFIG_DIR=$pick_root command claude "$pick_action" "$pick_candidate" "$@"
}
