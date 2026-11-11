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
                case -r --resume --session-id '--resume=*' '--session-id=*' '-r=*' -c --continue -p --print --bg --background -v --version -h --help agents attach auth auto-mode config doctor gateway import install logs mcp migrate-installer plugin plugins purge respawn rm setup-token stop kill ultrareview update upgrade
                    command claude $argv                          # -> hand off untouched
                    return
            end
        end
    end

    # The account. CLAUDE_CONFIG_DIR names it for a launch the user typed, but agterm replays a
    # pane's argv and not its environment, so the variable is gone from a restored launch and the
    # tab would look for its conversation under the default account. The remembered directory is
    # consulted only when the default account holds nothing for this tab, so it never takes a
    # working default-account resume away.
    set -l default "$HOME/.claude"
    set -l state "$XDG_STATE_HOME"
    test -n "$state"; or set state "$HOME/.local/state"
    set -l memo "$state/agterm-claude-resume/$sid"
    set -l roots "$CLAUDE_CONFIG_DIR"
    test -n "$roots[1]"; or set roots "$default"
    if test -z "$CLAUDE_CONFIG_DIR"; and test -r "$memo"
        read -l remembered <"$memo"
        if test -n "$remembered"; and test "$remembered" != "$roots[1]"; and test -d "$remembered/projects"
            set -a roots "$remembered"
        end
    end

    set -l pick_root
    set -l pick_candidate
    set -l pick_action

    for root in $roots
        set -l generation 0
        set -l action
        set -l candidate

        while true
            set candidate "$sid"
            if test $generation -gt 0
                set -l tail (math "(0x"(string sub -s -8 -- "$sid")" + $generation) % 4294967296")
                set candidate (string replace -r '[0-9a-f]{8}$' (printf '%08x' "$tail") -- "$sid")
            end

            set -l transcripts "$root/projects"/*/"$candidate.jsonl"
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
                end <"$transcript"
                if test $found -eq 0; or test $other -eq 1
                    set action --resume
                    set found_conversation 1
                    break
                end
            end
            test $found_conversation -eq 1; and break
            set generation (math $generation + 1)              # metadata-only transcript -> leave it intact
            if test $generation -gt 64
                set action --session-id
                break
            end
        end

        if test -z "$pick_action"
            set pick_root "$root"                              # the effective account decides by default
            set pick_candidate "$candidate"
            set pick_action "$action"
        end
        if test "$action" = --resume
            set pick_root "$root"
            set pick_candidate "$candidate"
            set pick_action "$action"
            break
        end
    end

    if test -n "$CLAUDE_CONFIG_DIR"; and test "$CLAUDE_CONFIG_DIR" != "$default"
        if mkdir -p (dirname "$memo") 2>/dev/null
            printf '%s\n' "$CLAUDE_CONFIG_DIR" >"$memo" 2>/dev/null
        end
    end

    # Claude Code reads a set CLAUDE_CONFIG_DIR as a separate account even when it names the default
    # directory, so a launch that did not carry one keeps it unset unless the memo's account was
    # picked. A launch the user prefixed already has it in the environment. The export stays at
    # function level: a `set -lx` inside `if ... end` is gone after the `end`.
    test -z "$CLAUDE_CONFIG_DIR"; and test "$pick_root" != "$default"; and set -lx CLAUDE_CONFIG_DIR "$pick_root"
    command claude "$pick_action" "$pick_candidate" $args
end
