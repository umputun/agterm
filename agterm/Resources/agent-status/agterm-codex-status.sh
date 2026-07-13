#!/usr/bin/env bash
# Codex lifecycle hook installed by agterm's Help ▸ Install Agent Status Hooks command.
#
# Codex fires PermissionRequest before Auto Review decides whether a person must approve. Treating
# that raw event as blocked therefore false-flags automatically reviewed tools. This hook keeps the
# agent-specific workaround inside the installed hook package: one watcher per agterm pane reads the
# live visible footer and reports blocked only after Codex displays an approval or question dialog.
set -u

[ -n "${AGTERM_SESSION_ID:-}" ] || exit 0

action=${1:-}
[ -n "$action" ] || exit 0
shift

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
status_wrapper=${AGTERM_STATUS_WRAPPER:-"$script_dir/agterm-agent-status.sh"}

pane_args=()
[ -n "${AGTERM_PANE:-}" ] && pane_args=(--pane "$AGTERM_PANE")
socket_args=()
[ -n "${AGTERM_SOCKET:-}" ] && socket_args=(--socket "$AGTERM_SOCKET")

report_status() {
  "$status_wrapper" "$@" >/dev/null 2>&1 || true
}

read_visible_screen() {
  "${AGTERMCTL:-agtermctl}" session text \
    --target "$AGTERM_SESSION_ID" \
    "${socket_args[@]+"${socket_args[@]}"}" \
    "${pane_args[@]+"${pane_args[@]}"}" 2>/dev/null
}

watch_file_path() {
  if [ -n "${AGTERM_CODEX_WATCH_FILE:-}" ]; then
    printf '%s' "$AGTERM_CODEX_WATCH_FILE"
    return
  fi
  local key
  key=$(printf '%s-%s' "$AGTERM_SESSION_ID" "${AGTERM_PANE:-left}" | /usr/bin/tr -c 'A-Za-z0-9._-' '_')
  printf '%s/agterm-codex-watch-%s-%s' "${TMPDIR:-/tmp}" "${UID:-0}" "$key"
}

stop_watcher() {
  rm -f -- "$(watch_file_path)" >/dev/null 2>&1 || true
}

start_watcher() {
  local token token_file
  token_file=$(watch_file_path)
  token="$$-${RANDOM:-0}"
  (umask 077; printf '%s\n' "$token" > "$token_file") 2>/dev/null || return 0
  "$0" __watch-blocked "$token" "$token_file" </dev/null >/dev/null 2>&1 &
}

watch_for_blocker() {
  local token=${1:-} token_file=${2:-}
  [ -n "$token" ] && [ -n "$token_file" ] || return 0

  local max_checks=${AGTERM_CODEX_WATCH_MAX_CHECKS:-21600}
  local interval=${AGTERM_CODEX_WATCH_INTERVAL:-0.5}
  case "$max_checks" in ''|*[!0-9]*) max_checks=21600 ;; esac

  local checks=0 prompt_was_visible=0 current_token screen footer
  while [ "$checks" -lt "$max_checks" ]; do
    current_token=$(cat "$token_file" 2>/dev/null) || break
    [ "$current_token" = "$token" ] || break
    screen=$(read_visible_screen) || break
    footer=$(printf '%s\n' "$screen" | /usr/bin/tail -n 12 | /usr/bin/tr '[:upper:]' '[:lower:]')

    case "$footer" in
      *"press enter to confirm"*|*"enter to submit answer"*|*"enter to submit all"*|*"allow command?"*)
        if [ "$prompt_was_visible" -eq 0 ]; then
          # Re-check the token right before writing: a superseding lifecycle event (stop /
          # pre-tool-use / post-tool-use) may have fired during read_visible_screen, and its
          # status must not be clobbered by a late blocked from this now-stale pane read.
          current_token=$(cat "$token_file" 2>/dev/null) || break
          [ "$current_token" = "$token" ] || break
          report_status blocked
          prompt_was_visible=1
        fi
        ;;
      *)
        # The prompt cleared: restore active so a resolved dialog — especially a denied
        # request that fires no follow-up tool event — doesn't linger blocked until the
        # next lifecycle hook lands.
        [ "$prompt_was_visible" -eq 1 ] && report_status active --blink
        prompt_was_visible=0
        ;;
    esac

    checks=$((checks + 1))
    [ "$checks" -ge "$max_checks" ] && break
    [ "$interval" = "0" ] || sleep "$interval"
  done
}

if [ "$action" = "__watch-blocked" ]; then
  watch_for_blocker "${1:-}" "${2:-}"
  exit 0
fi

case "$action" in
  session-start)
    stop_watcher
    report_status idle
    ;;
  user-prompt-submit)
    report_status active --blink
    start_watcher
    ;;
  pre-tool-use|post-tool-use)
    report_status active --blink
    ;;
  permission-request)
    # Candidate only: keep watching while Auto Review decides. The watcher reports blocked only if
    # Codex subsequently leaves a real approval prompt visible for the user.
    start_watcher
    ;;
  stop)
    stop_watcher
    report_status completed --auto-reset
    ;;
esac
exit 0
