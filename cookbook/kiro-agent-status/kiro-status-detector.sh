#!/usr/bin/env bash
# Kiro CLI status detector, run in the background by the `kiro-cli` wrapper function
# (kiro-agent-status.zsh / .fish / .bash) while the real kiro-cli runs in the foreground. Not
# meant to be sourced or run by hand.
#
# Kiro has no lifecycle hook that can report status: it declares hooks per agent inside each
# ~/.kiro/agents/<name>.json with no global file, and its only pre-tool event fires identically for
# an auto-approved tool and one waiting on a human, so it cannot mark blocked either way. This
# polls the pane's own recent text through `session text` and calls the stock
# `agterm-agent-status.sh`.
#
# This loop owns all three states, because `kiro-cli chat` is a REPL: a turn ends when kiro returns
# to its prompt, long before the process exits, so the wrapper function around it can only see the
# whole SESSION and would leave the row blinking between turns.
#
# The strings below are what kiro actually renders, captured from a real session rather than guessed
# from its docs. Override if a kiro release renames any of them:
#   export KIRO_STATUS_APPROVAL_RE='requires approval'
#   export KIRO_STATUS_APPROVAL_OPTION_RE='yes, single permission|trust, always allow|no \(tab to edit\)|esc to close'
#   export KIRO_STATUS_WORKING_RE='kiro is working|esc to cancel'
#
# A no-op outside agterm (guarded by $AGTERM_SESSION_ID), so it does nothing if invoked by mistake.
set -u

[ -n "${AGTERM_SESSION_ID:-}" ] || exit 0

: "${KIRO_STATUS_APPROVAL_RE:=requires approval}"
: "${KIRO_STATUS_APPROVAL_OPTION_RE:=yes, single permission|trust, always allow|no \(tab to edit\)|esc to close}"
# kiro's own working footer, or the spinner line above it ("◔ Shell" over "esc to cancel"). This is
# what separates a turn in progress from a finished turn whose output is still on screen.
: "${KIRO_STATUS_WORKING_RE:=kiro is working|esc to cancel}"
: "${KIRO_STATUS_TAIL_LINES:=12}"
: "${KIRO_STATUS_INTERVAL:=0.5}"
# consecutive failed pane reads before giving up. A single failure is transient (socket busy, pane
# briefly unresolvable); a sustained run of them means the app is gone, since no app means no socket.
: "${KIRO_STATUS_MAX_READ_FAILURES:=10}"
# consecutive marker-free frames before a turn counts as finished. NOT 1: kiro's screen goes briefly
# blank of both markers mid-turn — between two tool calls, and in the frame after an approval is
# answered but before the footer returns — and calling that the end fires the finish sound and drops
# the blink in the middle of a turn that is still running.
: "${KIRO_STATUS_DONE_FRAMES:=3}"

# the pane this run started in (used only for the READ below), and the stock status script,
# installed by Help ▸ Install Agent Status Hooks…. Delegating to it instead of calling agtermctl
# directly gets its baked-in agtermctl path for free, the same way the installer's own adapters do.
: "${AGTERM_PANE:=left}"
: "${AGTERM_STATUS_WRAPPER:=$HOME/.config/agterm/agent-status/agterm-agent-status.sh}"

# No --pane here: the stock wrapper already forwards both AGTERM_PANE and AGTERM_PANE_ID from the
# environment, and AGTERM_PANE_ID is what overrides a stale baked role after a pane is promoted
# (#199). Passing our own --pane would duplicate the flag and throw that precedence away.
#
# Missing status script is the one failure worth noticing, because the caller must not then latch the
# state as delivered: a `blocked` believed sent but never drawn stays on the row until some later
# transition happens to repair it. Anything past that point is invisible by design — the stock script
# ends in `|| true; exit 0` so a hook can never break a turn — so the loop simply retries next tick
# while the classification still holds, which costs one extra call and needs no read-back.
report_status() {
  [ -x "$AGTERM_STATUS_WRAPPER" ] || return 1
  "$AGTERM_STATUS_WRAPPER" "$@" >/dev/null 2>&1
}

# Resolve agtermctl for the READ. The stock wrapper cannot help here: the installer bakes its
# absolute CLI path into that script as a local default and never exports it, so a user who installed
# only the hooks — exactly what Setup asks for — has a working status write and no `agtermctl` on
# PATH. Fall back to the bundled binary before giving up, and prefer an explicit override over both.
if [ -z "${AGTERMCTL:-}" ] && ! command -v agtermctl >/dev/null 2>&1; then
  for _kas_app in "$HOME/Applications/agterm.app" /Applications/agterm.app; do
    if [ -x "$_kas_app/Contents/MacOS/agtermctl" ]; then
      AGTERMCTL="$_kas_app/Contents/MacOS/agtermctl"
      break
    fi
  done
fi

# session text has no equivalent in the stock wrapper, so this talks to agtermctl directly.
# --pane is REQUIRED here, unlike on the status write above: session text with no --pane reads
# whatever is currently on screen (the focused pane, or the scratch terminal if one is open over
# it), not necessarily the pane this kiro-cli is actually running in.
# Lowercasing is a separate step so a failing agtermctl is still visible in $?; through a pipe the
# status would be tr's, which succeeds on empty input.
read_screen() {
  local raw
  raw=$("${AGTERMCTL:-agtermctl}" session text --target "$AGTERM_SESSION_ID" --pane "$AGTERM_PANE" \
    --lines "$KIRO_STATUS_TAIL_LINES" ${AGTERM_SOCKET:+--socket "$AGTERM_SOCKET"} 2>/dev/null) || return 1
  printf '%s' "$raw" | /usr/bin/tr '[:upper:]' '[:lower:]'
}

# Two independent stop conditions, because either alone has a hole. Deliberately NOT a check budget:
# `kiro-cli chat` can sit at a prompt for a whole workday, and a fixed cap would stop reporting
# partway through a session that is still running.
#   1. the spawning shell died — ordinary teardown
#   2. pane reads keep failing — no app means no socket. This is the one that covers a hard-killed
#      app, which runs no teardown and sends no SIGHUP here, because the pty's session leader is the
#      surviving `login`: the shell can outlive the app, so path 1 cannot be relied on for it.
# The wrapper kills this process as soon as kiro-cli returns, so neither normally comes into play.
parent=$PPID
failures=0

# Every marker is matched as a LINE, not as a substring anywhere in the tail, so that kiro quoting
# "Kiro is working..." back at you mid-sentence does not read as kiro working. That is the case this
# buys and the ONLY one. What it does not buy, and what a reader should not assume from it:
#   - a leading run of non-letters passes any quote, bullet, diff marker or line number, so a
#     blockquoted "> Kiro is working" reads as working, and these files in a pager still match.
#   - requiring two strings for `blocked` raises the bar but does not close it. The two greps scan the
#     same 12-line window INDEPENDENTLY, so they need not even describe the same line: "- Shell
#     requires approval" plus "- Yes, single permission is one option" anywhere in the tail raises a
#     blocked, as does the single line "> Yes, single permission -- shell requires approval". That is
#     the one false state that actively summons a human.
# Both are accepted rather than fixed: tightening enough to exclude them costs false negatives on the
# real dialog, and a row that stops reporting is worse than one that occasionally over-reports. The
# debounce cannot help either, since prose sits on screen as steadily as a dialog does.
#
# The two anchors differ because the two lines do:
#   " Kiro is working..." / " esc to cancel" / "> Yes, single permission" start the line, after
#     nothing but indentation and spinner or cursor glyphs — hence a leading run of non-letters.
#   " shell requires approval" ENDS the line but begins with a tool name, so it takes a trailing
#     anchor instead; prose that continues past the phrase is rejected by it.
_kas_bol='^[^[:alpha:]]*'
_kas_eol='[[:space:]]*$'

# Approval still needs the anchor line AND one option line: the anchor alone is a phrase kiro itself
# prints when explaining what it is about to do.
classify() {
  if printf '%s' "$1" | /usr/bin/grep -qE "(${KIRO_STATUS_APPROVAL_RE})${_kas_eol}" &&
     printf '%s' "$1" | /usr/bin/grep -qE "${_kas_bol}(${KIRO_STATUS_APPROVAL_OPTION_RE})"; then
    printf blocked
  elif printf '%s' "$1" | /usr/bin/grep -qE "${_kas_bol}(${KIRO_STATUS_WORKING_RE})"; then
    printf working
  else
    printf other
  fi
}

# Reports only on a state CHANGE: re-asserting blocked every tick would defeat --auto-reset and
# re-fire the configured blocked sound, and re-asserting active would fight a status the user
# already cleared by typing into the session. Seeded `idle` rather than `active` because `kiro-cli
# chat` opens on an empty prompt having done nothing yet, so a session you start and walk away from
# stays quiet.
#
# `reported` is assigned only when the write reported success, so a failed one is retried on the next
# tick instead of being remembered as delivered.
reported=idle
quiet=0
while kill -0 "$parent" 2>/dev/null; do
  if screen=$(read_screen); then
    failures=0
    case "$(classify "$screen")" in
      blocked)
        quiet=0
        [ "$reported" != blocked ] && report_status blocked && reported=blocked
        ;;
      working)
        # Also how blocked is left when you answer yes: the dialog is gone and kiro is working again.
        quiet=0
        [ "$reported" != active ] && report_status active --blink && reported=active
        ;;
      *)
        # Neither marker. That is the end of a turn only if it STAYS that way — see
        # KIRO_STATUS_DONE_FRAMES above for why one frame is not enough. Guarded on the tracked
        # states so a kiro idling at its prompt, and a session the user already cleared by typing
        # into it, are never re-announced. `blocked` counts alongside `active` because answering No
        # returns kiro straight to its prompt with no working footer in between, and leaving that as
        # blocked would keep the row demanding attention it no longer needs.
        quiet=$((quiet + 1))
        if [ "$quiet" -ge "$KIRO_STATUS_DONE_FRAMES" ]; then
          case $reported in
            active | blocked) report_status completed --auto-reset && reported=completed ;;
          esac
        fi
        ;;
    esac
  else
    # A failed read is not a quiet frame: the screen it would have shown may well have held the
    # working footer, and counting it toward the streak lets interleaved failures fake a finished
    # turn. Only frames actually seen to be marker-free may end one.
    quiet=0
    failures=$((failures + 1))
    [ "$failures" -ge "$KIRO_STATUS_MAX_READ_FAILURES" ] && break
  fi
  sleep "$KIRO_STATUS_INTERVAL"
done
