#!/usr/bin/env fish
# Sourced, not executed: put this function in a fish autoload file, e.g.
# ~/.config/fish/functions/claude.fish, or source this file from ~/.config/fish/config.fish.
# See README.md.

# Claude Code: per-agterm-tab session resume.
# Binds each tab's Claude Code session id to the tab's own uuid (AGTERM_SESSION_ID),
# so restoring the terminal resumes that tab's own conversation instead of starting fresh.
# Requires: agterm (exports AGTERM_SESSION_ID, restores running commands) + fish.
function claude --description 'Per-agterm-tab Claude Code session resume'
    set -l sid (string lower -- "$AGTERM_SESSION_ID")
    if test -z "$sid"
        command claude $argv                                    # not in an agterm tab -> passthrough
        return
    end

    set -l args $argv

    if contains -- "$argv[1]" --session-id -r --resume
        and test (string lower -- "$argv[2]") = "$sid"
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

    set -l existing ~/.claude/projects/*/$sid.jsonl               # does this tab's session already exist?
    if test (count $existing) -gt 0
        command claude --resume "$sid" $args                      # yes -> continue it
    else
        command claude --session-id "$sid" $args                  # no  -> create it with this fixed id
    end
end
