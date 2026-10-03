#!/usr/bin/env sh
# Sourced, not executed: paste this function into ~/.zshrc (or ~/.bashrc), or
# source this file from there. See README.md.
# POSIX syntax throughout (no zsh- or bash-only constructs, no `local`), so the
# same file works sourced from either shell's rc file.

# Copilot CLI: per-agterm-tab session resume.
# Pins each tab's Copilot CLI session to the tab's own uuid (AGTERM_SESSION_ID).
# --session-id both creates a session under that id and resumes it if the id
# already exists, so the tab always owns exactly one conversation and there is
# no mapping file or existence check to get wrong.
# Requires: agterm (exports AGTERM_SESSION_ID, restores running commands).
copilot() {
  _copilot_resume_sid=$AGTERM_SESSION_ID
  if [ -z "$_copilot_resume_sid" ]; then
    command copilot "$@"                                              # not in an agterm tab -> passthrough
    unset _copilot_resume_sid
    return
  fi
  _copilot_resume_sid=$(printf '%s' "$_copilot_resume_sid" | tr '[:upper:]' '[:lower:]')

  for _copilot_resume_arg in "$@"; do                                  # user steering a session/subcommand/headless?
    case $_copilot_resume_arg in
      --session-id | --session-id=* | -r | --resume | --resume=* | -p | --prompt | --continue | \
        --connect | --connect=* | --acp | -v | --version | -h | --help | \
        completion | help | init | login | mcp | plugin | plugins | skill | update | version)
        command copilot "$@"
        unset _copilot_resume_sid _copilot_resume_arg
        return
        ;;
    esac
  done
  unset _copilot_resume_arg

  command copilot --session-id "$_copilot_resume_sid" "$@"             # pin/resume this tab's conversation
  unset _copilot_resume_sid
}
