#!/usr/bin/env zsh
# Sourced, not executed: paste the function into ~/.zshrc, or source this file from there.
# The mapping it reads is written by copilot-resume-hook.sh, a Copilot sessionStart hook. See README.md.

# Copilot CLI: per-agterm-pane session resume.
# Maps the pane's own uuid (AGTERM_PANE_ID) to a Copilot session id under ~/.copilot/agterm/,
# so restoring the terminal resumes that pane's own conversation instead of starting fresh.
# The `function` form still defines the function when an alias named copilot already exists.
function copilot {
  emulate -L zsh
  local pane=${AGTERM_PANE_ID:l}
  local uuid='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  # Run as typed outside an agterm pane, in a Copilot tool shell (a worker), with piped stdin (a
  # headless run, like -p), and for an npm install: agterm records its `node` launcher, so a restart
  # would replay the line without this function.
  if [[ ! $pane =~ $uuid || -n ${COPILOT_CLI-}${COPILOT_AGENT_SESSION_ID-} || ! -t 0 ||
      ${commands[copilot]:A} == */node_modules/* ]]; then
    command copilot "$@"
    return
  fi

  # Marks a copilot this function started, for the hook and for the replay below. No variable of
  # that name exists, so the flag removes nothing from Copilot's shells.
  local own=--secret-env-vars=AGTERM_COPILOT_RESUME

  # agterm replays the argv the pane was running, which starts with `own` and, for a resumed
  # conversation, `--session-id <id>`. Drop both and decide again from the mapping, which /clear or
  # /resume may have moved since that launch. A pane with no mapping of its own starts fresh.
  # Drop -i too, so a restart never sends its prompt again.
  local replay=
  if [[ $1 == $own ]]; then
    replay=1
    shift
    [[ $1 == --session-id && $2 =~ $uuid ]] && shift 2
  fi

  # Options that take a value are listed so the value is never read as a flag or a subcommand.
  local -a kept=()
  local a positional=
  while (( $# )); do
    a=$1
    shift
    case $a in
      --)
        kept+=(-- "$@")
        break ;;
      -h|--help|-v|--version|-p*|--prompt|--prompt=*|-r*|--resume|--resume=*|--continue|\
      --session-id|--session-id=*|--new-session-id|--new-session-id=*|--connect|--connect=*|\
      --acp|--server|--headless|--cloud|-w*|--worktree|--worktree=*|-n*|--name|--name=*)
        command copilot "${kept[@]}" "$a" "$@"
        return ;;
      -i|--interactive)
        [[ -z $replay ]] && kept+=("$a" "${@[1,1]}")
        (( $# )) && shift ;;
      -i?*|--interactive=*)
        [[ -z $replay ]] && kept+=("$a") ;;
      -C|--add-dir|--add-github-mcp-tool|--add-github-mcp-toolset|--additional-content-exclusion-policies|\
      --additional-mcp-config|--agent|--allow-tool|--allow-url|--attachment|--auto-tier|--available-tools|\
      --choice|--config-dir|--context|--decision|--deny-tool|--deny-url|--disable-mcp-server|\
      --dynamic-retrieval|--effort|--enable-mcp-server|--excluded-tools|--extension-sdk-path|--fusion-tier|\
      --log-dir|--log-level|--max-ai-credits|--max-autopilot-continues|--mcp-github-auth|--mode|--model|\
      --output-format|--plugin-dir|--reasoning-effort|--secret-env-vars|--session-idle-timeout|--stream|\
      --usage-output-file)
        kept+=("$a" "${@[1,1]}")
        (( $# )) && shift ;;
      -*)
        kept+=("$a") ;;
      *)
        if [[ -z $positional ]]; then
          positional=1
          case $a in
            app|login|help|init|config|update|version|workflow|workflows|sessions|memories|plugin|\
            mcp|skill|instruction|lsp|sandbox|completion)
              command copilot "${kept[@]}" "$a" "$@"
              return ;;
          esac
        fi
        kept+=("$a") ;;
    esac
  done

  local mapf=${COPILOT_HOME:-$HOME/.copilot}/agterm/$pane id=
  [[ -f $mapf && -r $mapf ]] && id=$(<$mapf)
  if [[ $id =~ $uuid ]]; then
    command copilot $own --session-id $id "${kept[@]}"
  else
    command copilot $own "${kept[@]}"
  fi
}
