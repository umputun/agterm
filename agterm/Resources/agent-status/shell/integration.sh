# agterm-agent-status — shell integration for bash and zsh.
# Sets the agterm session's agent-status indicator to `active` while a coding
# agent runs as a foreground command, and back to `idle` at the next prompt.
# Source this from your ~/.zshrc and/or ~/.bashrc.
#
# Which commands count as agents is a regex, override before sourcing to taste:
#   export AGTERM_AGENT_RE='^(gemini|cursor-agent|my-agent)([[:space:]]|$)'
#
# Claude Code, Codex, and Pi are intentionally NOT in the default list — their
# own hooks/extensions drive finer per-turn state, which the coarse
# process-level active/idle here would only fight. Add any of them here if you
# rely on the shell integration alone for it.
#
# Every entry point is best-effort and a clean no-op outside agterm (guarded by
# $AGTERM_SESSION_ID), so sourcing it from a non-agterm shell does nothing.

[ -n "${AGTERM_SESSION_ID:-}" ] || return 0 2>/dev/null

# Locate agterm-agent-status.sh relative to this file (layout is preserved on
# install: shell/integration.sh sits next to agterm-agent-status.sh's dir).
if [ -n "${ZSH_VERSION:-}" ]; then
  _ags_self="${(%):-%x}"
  _ags_dir="${_ags_self:a:h:h}"
else
  _ags_self="${BASH_SOURCE[0]}"
  _ags_dir="$(cd "$(dirname "$_ags_self")/.." >/dev/null 2>&1 && pwd)"
fi
: "${AGTERM_AGENT_BIN:=$_ags_dir/agterm-agent-status.sh}"
: "${AGTERM_AGENT_RE:=^(gemini|cursor-agent|aider|opencode|crush|goose)([[:space:]]|$)}"

if [ -n "${ZSH_VERSION:-}" ]; then
  autoload -Uz add-zsh-hook
  _ags_preexec() { [[ "$1" =~ $AGTERM_AGENT_RE ]] && { "$AGTERM_AGENT_BIN" active --blink; _ags_active=1; }; }
  _ags_precmd()  { [[ -n "${_ags_active:-}" ]] && { "$AGTERM_AGENT_BIN" idle; unset _ags_active; }; }
  add-zsh-hook preexec _ags_preexec
  add-zsh-hook precmd  _ags_precmd

elif [ -n "${BASH_VERSION:-}" ]; then
  _ags_preexec() {
    local cmd="${1:-$BASH_COMMAND}"               # bash-preexec passes the command as $1; a raw DEBUG trap uses $BASH_COMMAND
    [ -n "${COMP_LINE:-}" ] && return             # ignore tab-completion
    case "$cmd" in _ags_*) return ;; esac
    if [[ "$cmd" =~ $AGTERM_AGENT_RE ]]; then
      "$AGTERM_AGENT_BIN" active --blink
      _ags_active=1
    fi
  }
  _ags_precmd() { [ -n "${_ags_active:-}" ] && { "$AGTERM_AGENT_BIN" idle; unset _ags_active; }; }

  if [ -n "${bash_preexec_imported:-}${__bp_imported:-}" ]; then
    # bash-preexec is active: register into its additive arrays so we don't clobber other consumers
    case " ${preexec_functions[*]-} " in *" _ags_preexec "*) : ;; *) preexec_functions+=(_ags_preexec) ;; esac
    case " ${precmd_functions[*]-} "  in *" _ags_precmd "*)  : ;; *) precmd_functions+=(_ags_precmd)  ;; esac
  else
    # no bash-preexec: install the DEBUG trap only when nothing else owns it, so we never break a user's
    # existing preexec tooling. an unrelated existing trap → skip the active-state hook with a notice.
    case "$(trap -p DEBUG 2>/dev/null)" in
      "")             trap '_ags_preexec' DEBUG ;;   # nothing there: safe to install
      *_ags_preexec*) : ;;                            # already ours: idempotent
      *) printf '%s\n' "agterm agent-status: an existing bash DEBUG trap is set; skipping the active-state hook (use bash-preexec, or wire a preexec yourself)." >&2 ;;
    esac
    # precmd via PROMPT_COMMAND is additive and safe regardless of any DEBUG trap
    case "${PROMPT_COMMAND:-}" in
      *_ags_precmd*) : ;;
      *) PROMPT_COMMAND="_ags_precmd${PROMPT_COMMAND:+; $PROMPT_COMMAND}" ;;
    esac
  fi
fi
