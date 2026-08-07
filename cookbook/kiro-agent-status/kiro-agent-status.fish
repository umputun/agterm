# Kiro CLI agent status for fish — source from ~/.config/fish/config.fish.
#
# Defines `kiro-cli` (and `kiro`) as fish FUNCTIONS shadowing the real binaries. Each starts
# kiro-status-detector.sh in the background, runs the real command in the foreground, then kills the
# detector and clears the row the moment that command returns — for any reason, including a crash or
# a Ctrl-C, since that is ordinary job control and not something this file has to arrange. A function
# also catches an `abbr` expanding to `kiro-cli ...`, because fish expands an abbreviation into the
# command line before it looks up what to run.
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

function _kas_run
    set -l real $argv[1]
    set -e argv[1]
    # No `active` report here. `kiro-cli chat` is a REPL: this function spans the whole session, so a
    # status set at entry would sit on the row between turns too. Per-turn state is the poller's job.
    $KIRO_STATUS_DETECTOR >/dev/null 2>&1 &
    set -l pid $last_pid
    disown $pid 2>/dev/null
    command $real $argv
    set -l rc $status
    kill $pid 2>/dev/null
    # no `wait` to match the zsh/bash side: fish cannot wait on a disowned job, and does not leave
    # a zombie behind either, so there is nothing here to reap.
    # The sleep is not cosmetic: killing the poller does not cancel a status write it had already
    # spawned, and that grandchild would otherwise land after the idle below and leave the row
    # showing a turn that is over. One poll interval outlasts that single agtermctl call.
    sleep (test -n "$KIRO_STATUS_INTERVAL"; and echo $KIRO_STATUS_INTERVAL; or echo 0.5) 2>/dev/null
    # The session is over, so nothing about it is worth flagging: `idle` clears the row unconditionally,
    # where a `completed` left to --auto-reset would outlive the thing it describes. The poller already
    # reported completed for the last turn, and it cannot do this itself — it is killed a line above.
    $AGTERM_STATUS_WRAPPER idle >/dev/null 2>&1
    return $rc
end

function kiro-cli
    _kas_run kiro-cli $argv
end

function kiro
    _kas_run kiro $argv
end
