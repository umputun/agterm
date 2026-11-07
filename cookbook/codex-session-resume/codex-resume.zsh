#!/usr/bin/env zsh
# Sourced, not executed: paste both functions into ~/.zshrc, or source this file from there.
# The mapping they read is written by codex-resume-hook.zsh, a Codex SessionStart hook. See README.md.

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

  # Every codex this function launches past the passthrough list gets these. The hook records a conversation only for a codex
  # whose environment carries CODEX_AGTERM_TAB, and the -c blanks it for that codex's own tool
  # commands, so a `codex exec` started inside the conversation records nothing. --no-daemon keeps
  # the hook in this codex process: a shared background server would run it with the environment
  # of whichever pane started that server.
  local -a own=(--no-daemon -c 'shell_environment_policy.set.CODEX_AGTERM_TAB=""')

  # agterm replays the argv the pane was running, which starts with `own`. Drop it, and the
  # `resume <id>` this function added after it, so the replay is decided again from the mapping
  # rather than passed through as an explicit resume.
  if [[ $1 == $own[1] && $2 == $own[2] && $3 == $own[3] ]]; then
    shift 3
    [[ $1 == resume && $2 == ????????-????-????-????-???????????? ]] && shift 2
  fi

  local a
  for a in "$@"; do
    case $a in
      -h|--help|-V|--version|--remote|--remote=*|\
      agents|exec|e|review|login|logout|mcp|plugin|mcp-server|app-server|remote-control|app|completion|\
      update|doctor|sandbox|debug|apply|a|resume|queue|archive|delete|migrate-rollouts|migrate-nfs-db|\
      unarchive|fork|cloud|exec-server|features|help)
        command codex "$@"; return ;;
    esac
  done

  # `own` carries --no-daemon, and codex refuses the flag twice, so a typed one is dropped. Words
  # after `--` are prompt text, not flags, and pass through as typed.
  local -i end=${@[(i)--]}
  set -- "${(@)${(@)@[1,end-1]}:#--no-daemon}" "${(@)@[end,-1]}"

  local mapf=~/.codex/agterm/$sid
  local cid; [[ -f $mapf ]] && cid=$(<$mapf)
  if [[ -n $cid ]]; then
    local -a s=(~/.codex/sessions/**/rollout-*-$cid.jsonl(N))
    if (( $#s )); then
      local rid=$(_codex_rollout_root_id $s[1])
      local -a roots=(~/.codex/sessions/**/rollout-*-$rid.jsonl{,.zst}(N))
      if [[ -n $rid ]] && (( $#roots )); then
        [[ $rid != $cid ]] && print -r -- $rid > $mapf
        CODEX_AGTERM_TAB=$sid command codex $own resume "$rid" "$@"; return
      fi
    fi
    # Codex can keep a rollout compressed, and its first line cannot be read without decompressing
    # it. When no plain rollout led to a root, a compressed one under the mapped id is resumed as
    # it is, without the child to root repair.
    local -a z=(~/.codex/sessions/**/rollout-*-$cid.jsonl.zst(N))
    if (( $#z )); then
      CODEX_AGTERM_TAB=$sid command codex $own resume "$cid" "$@"; return
    fi
  fi

  CODEX_AGTERM_TAB=$sid command codex $own "$@"
}
