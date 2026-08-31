#!/usr/bin/env fish
# Sourced, not executed: put this function in a fish autoload file, e.g.
# ~/.config/fish/functions/claude.fish, or source this file from ~/.config/fish/config.fish.
# See README.md.

# Claude Code: per-agterm-tab session resume.
# Binds each tab's Claude Code session id to the tab's own uuid (AGTERM_SESSION_ID),
# so restoring the terminal resumes that tab's own conversation instead of starting fresh.
# Requires: agterm (exports AGTERM_SESSION_ID, restores running commands) + fish.
function claude --description 'Per-agterm-tab Claude Code session resume'
    if not status is-interactive
        command claude $argv                                    # non-interactive (script/subshell) -> passthrough
        return
    end

    set -l sid (string lower -- "$AGTERM_SESSION_ID")
    if test -z "$sid"
        command claude $argv                                    # not in an agterm tab -> passthrough
        return
    end
    if not string match -qr '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -- "$sid"
        command claude $argv                                    # malformed tab id -> do not use it in a path
        return
    end

    set -l args $argv
    set -l replay_prefix (string replace -r '[0-9a-f]{8}$' '' -- "$sid")

    if contains -- "$argv[1]" --session-id -r --resume
        and string match -qr "^"(string escape --style=regex "$replay_prefix")"[0-9a-f]{8}\$" -- (string lower -- "$argv[2]")
        set args $argv[3..-1]                                    # restore replayed our own flag -> re-decide below
    else
        for a in $argv                                           # user steering a session/subcommand/headless?
            switch $a
                case -r --resume --session-id '--resume=*' '--session-id=*' '-r=*' -c --continue -p --print -v --version -h --help mcp update doctor config install migrate-installer setup-token
                    command claude $argv                          # -> hand off untouched
                    return
            end
        end
    end

    set -l config_dir "$CLAUDE_CONFIG_DIR"
    test -n "$config_dir"; or set config_dir "$HOME/.claude"
    set -l projects "$config_dir/projects"

    set -l generation 0
    set -l action
    set -l candidate

    while true
        set candidate "$sid"
        if test $generation -gt 0
            set -l tail (math "(0x"(string sub -s -8 -- "$sid")" + $generation) % 4294967296")
            set candidate (string replace -r '[0-9a-f]{8}$' (printf '%08x' "$tail") -- "$sid")
        end

        set -l transcripts "$projects"/*/"$candidate.jsonl"
        if not test -f "$transcripts[1]"
            set action --session-id
            break
        end

        set -l found_conversation 0
        for transcript in $transcripts
            set -l found 0
            set -l other 0
            while read -l line
                test -z "$line"; and continue
                set found 1
                if not string match -q '{"type":"bridge-session"*' -- "$line"
                    or not string match -q '*"sessionId":"'"$candidate"'"*' -- "$line"
                    or not string match -qr '"bridgeSessionId":"[^"]+"' -- "$line"
                    or not string match -qr '"lastSequenceNum":[0-9]+' -- "$line"
                    or not string match -q '*}' -- "$line"
                    set other 1
                    break
                end
            end < "$transcript"
            if test $found -eq 0; or test $other -eq 1
                set action --resume
                set found_conversation 1
                break
            end
        end
        test $found_conversation -eq 1; and break
        set generation (math $generation + 1)                   # metadata-only transcript -> leave it intact
    end

    command claude "$action" "$candidate" $args
end
