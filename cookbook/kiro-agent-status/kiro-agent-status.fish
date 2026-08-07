#!/usr/bin/env fish
# Kiro CLI agent status for fish — source from ~/.config/fish/config.fish.
#
# Defines `kiro-cli` (and `kiro`) as fish FUNCTIONS shadowing the real binaries. Each starts
# kiro-status-detector.sh in the background, runs the real command in the foreground, then kills the
# detector and clears the row the moment that command returns, crash included, since that is ordinary
# job control and not something this file has to arrange. Not covered: a terminal SIGINT, which hits
# the whole foreground group and abandons the rest of this function along with kiro-cli — see the
# Ctrl-C entry in README.md's Limits. A function also catches an `abbr` expanding to `kiro-cli ...`,
# because fish expands an abbreviation into the command line before it looks up what to run.
#
# The poller owns all three per-turn states (active, blocked, completed); this file owns only its
# lifetime and the final `idle`. Alternative to agterm's shipped shell/integration.fish, whose default
# AGTERM_AGENT_RE does not list kiro — do not add kiro to that regex on top of this, since for a REPL
# it pins one `active` across the whole session, which is what this recipe exists to avoid.
#
# zsh/bash users want kiro-agent-status.zsh instead.

if not set -q AGTERM_SESSION_ID
    return 0 2>/dev/null
end

# Locate kiro-status-detector.sh and the stock status script relative to this file.
set -l _kas_dir (dirname (status filename))
if not set -q KIRO_STATUS_DETECTOR
    set -g KIRO_STATUS_DETECTOR "$_kas_dir/kiro-status-detector.sh"
end
if not set -q AGTERM_STATUS_WRAPPER
    set -g AGTERM_STATUS_WRAPPER "$HOME/.config/agterm/agent-status/agterm-agent-status.sh"
end

# Is that pid still our detector? The poller has stop conditions of its own — a hard-killed app takes
# about five seconds of failed reads — so it can be long gone while kiro-cli runs on for hours, and
# fish reaps it, which frees the number for reuse. Killing a bare remembered pid would then signal
# whatever inherited it. Checked against argv rather than trusted.
#
# Matched on $KIRO_STATUS_DETECTOR, not on the basename this file ships with: that variable is a
# documented override, so a renamed or symlinked poller would fail a basename test and be skipped by
# the teardown below — trading a rare wrong kill for a reliable orphan, which is the worse bug. The
# check is best-effort by nature (`ps` could be missing, and the pid could in principle be reused by
# another session's poller), so it errs toward killing: only a definite mismatch skips teardown.
function _kas_is_detector
    set -l cmd (/bin/ps -o command= -p $argv[1] 2>/dev/null)
    or return 0
    test -z "$cmd"; and return 1
    # `string replace`, not `string match`: the latter reads the path as a glob, so a `*` or `[` in an
    # overridden KIRO_STATUS_DETECTOR would match paths that are not it. This is a literal search.
    string replace -q -- "$KIRO_STATUS_DETECTOR" "" "$cmd"
end

function _kas_run
    set -l real $argv[1]
    set -e argv[1]
    set -l pid
    # The -x test is load-bearing here, more than on the zsh side. fish leaves $last_pid untouched
    # when a launch fails, so a detector that lost its executable bit in transit gives us the pid of
    # whatever ran in the background before it — and the kill below then shoots that innocent job.
    # (Verified on fish 4.8.1; bash and zsh instead fork a child that fails to exec, so their $! is a
    # fresh already-dead pid and the kill is harmless.) Checking first also turns a silent no-op into
    # one warning per shell, rather than a session that reports nothing and never says why.
    if test -x "$KIRO_STATUS_DETECTOR"
        # No `active` report here. `kiro-cli chat` is a REPL: this function spans the whole session, so
        # a status set at entry would sit on the row between turns too. Per-turn state is the poller's.
        $KIRO_STATUS_DETECTOR >/dev/null 2>&1 &
        set pid $last_pid
        disown $pid 2>/dev/null
    else if not set -q _kas_warned
        set -g _kas_warned 1
        echo "kiro-agent-status: $KIRO_STATUS_DETECTOR is not executable, so status reporting is off (chmod +x it)." >&2
    end
    command $real $argv
    set -l rc $status
    if test -n "$pid"; and _kas_is_detector $pid
        kill $pid 2>/dev/null
        # no `wait` to match the zsh/bash side: fish cannot wait on a disowned job, and does not leave
        # a zombie behind either, so there is nothing here to reap.
        # The sleep is not cosmetic: killing the poller does not cancel a status write it had already
        # spawned, and that grandchild would otherwise land after the idle below and leave the row
        # showing a turn that is over. One poll interval outlasts that single agtermctl call.
        sleep (test -n "$KIRO_STATUS_INTERVAL"; and echo $KIRO_STATUS_INTERVAL; or echo 0.5) 2>/dev/null
    end
    # The session is over, so nothing about it is worth flagging: `idle` clears the row unconditionally,
    # where a `completed` left to --auto-reset would outlive the thing it describes. The poller cannot do
    # this itself — by here it is dead either way, killed above or already self-exited. Runs even when no
    # poller started, since some earlier session may have left a status on the row.
    #
    # Guarded on -x because fish prints its own `Unknown command:` diagnostic, with a caret diagram,
    # BEFORE the redirection applies — so a missing hooks package would put that on the user's screen
    # after every single kiro-cli. zsh's `command not found` is silenced by the redirection; fish's
    # is not.
    if test -x "$AGTERM_STATUS_WRAPPER"
        $AGTERM_STATUS_WRAPPER idle >/dev/null 2>&1
    end
    return $rc
end

function kiro-cli
    _kas_run kiro-cli $argv
end

function kiro
    _kas_run kiro $argv
end
