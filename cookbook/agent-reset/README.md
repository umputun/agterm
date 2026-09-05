# Agent reset

One chord clears the coding agent running in the pane you pressed it in, and does nothing at all when no agent is running there.

## What it does

Starting a fresh conversation is the thing you do most often and the thing that is most annoying to reach: the context is long, the reply is slow, and you have to click into the right pane first. This binds it to a chord, and sends each agent the command it actually has — `/clear` for Claude Code, `/new` for codex.

The part worth copying is the guard. A slash command is meaningful to a coding agent and to nothing else, so the script reads what the pane is actually running before it sends anything, and sends only when that is an agent it recognizes. Anywhere else it exits without a keystroke rather than pushing text at a program that never asked for it. Each pane is matched on its own foreground, so a split running Claude Code on one side and codex on the other gets the right command on each side.

Two things follow from the chord being pressed in the main pane rather than the split. It resets the split's agent as well, because the main pane's agent is the one that owns the session. And it clears the session's title-bar context, because the task that line described is over. From the split it resets that pane alone: one of two agents starting fresh is not the session starting fresh.

## Requirements

- agterm 0.26.0 or later, which shipped `session context` — the title-bar line this recipe clears when a reset comes from the main pane.
- Python 3.9 or later, which macOS ships as `/usr/bin/python3`
- Claude Code, codex, or both

## Setup

Copy the script somewhere and make it executable. Anywhere works as long as the keymap line points at it:

```sh
mkdir -p ~/bin
cp agent-reset.py ~/bin/
chmod +x ~/bin/agent-reset.py
```

Add an entry to `~/.config/agterm/keymap.conf` and apply it with File ▸ Reload Keymap or `agtermctl keymap reload`:

```
command "Agent Reset" ctrl+a>x ~/bin/agent-reset.py
```

Any free chord works; `agtermctl keymap list` shows what every chord currently resolves to. Leave the chord out entirely and the entry is palette-only.

Fired from a chord or the palette, the script runs under the app's `PATH` rather than your shell's. That is the launchd default: `/usr/local/bin` plus the system directories, with no `/opt/homebrew/bin` and nothing else your profile adds. Both binaries this recipe needs resolve there — `python3` from `/usr/bin`, and `agtermctl` from `/usr/local/bin`, where **Help ▸ Install Command Line Tool…** symlinks it.

Three settings, all read from the environment, all optional:

- `AGTERMCTL` — the CLI's full path, if yours sits somewhere unusual.
- `CLAUDE_FG_MATCH` — the regular expression that decides whether a pane's foreground process is Claude Code. The default, `(^|/)claude$`, matches the binary itself. If you launch it through a wrapper script, add the wrapper's name: `CLAUDE_FG_MATCH='(^|/)(claude|mywrapper)$'`.
- `CODEX_FG_MATCH` — the same for codex, defaulting to `(^|/)codex$`.

Set either match in the keymap line as a prefix assignment, since the script is run by `/bin/sh -c`:

```
command "Agent Reset" ctrl+a>x CLAUDE_FG_MATCH='(^|/)(claude|mywrapper)$' ~/bin/agent-reset.py
```

## Usage

Press the chord in a pane running an agent. The reset is typed into it and submitted, exactly as if you had typed it yourself.

Press it in a pane that is not running one and nothing happens. There is no message and no error; the chord is simply inert there.

To try it outside a chord, supply the two variables the runner would have:

```sh
AGT_SESSION_ID=<id> AGT_PANE=left ~/bin/agent-reset.py
```

## How it works

`agtermctl tree --json` reports each session's `foreground` and `splitForeground`, the live argv of whatever each pane is running. The script finds its own session by the id the runner gave it, reads the field for the pane the chord fired in, and matches that argv against the two patterns. A wrapper script shows up as its own argv element, which is why the match is against any element rather than the first.

The two agents need different writes. Claude Code takes `/clear` with a newline, the ordinary submit. codex has both `/clear` and `/new`, and they differ: `/clear` wipes the terminal as well as the conversation, `/new` starts a new chat and leaves the scrollback alone. `/new` is the one to send, so anything reading the pane back with `agtermctl session text` still finds what was there.

codex also turns on the Kitty keyboard protocol, and under it agterm's synthetic Return produces nothing codex acts on — `agtermctl session type $'/status\n'` leaves `/status` sitting in the composer. The submit has to be written as the Kitty encoding of Enter instead, `CSI 13;1u`.

That escape has to be its own write. Sent in the same write as the command it is dropped and the line stays in the composer, exactly as a plain newline does; sent separately a fraction of a second later it submits. The pause in the script is what makes the second write land, not a precaution.

Every call passes `--socket "$AGT_SOCKET"`, the socket of the app that fired the chord. That matters when more than one agterm is running, or when the `agtermctl` on `PATH` belongs to a different install than the app you pressed the key in: the socket decides which app is addressed, not the binary.

The title-bar clear is gated on the main pane's own write succeeding, and not on the split's. A failed write leaves that agent still holding its task, so the line has to keep describing it. The split's agent does not own the line either way.

## Limits

**A reset throws away the agent's conversation.** That is the whole point of the chord, but it is not undoable and the agent will not ask: whatever context it had built up is gone the moment the chord lands. Pressed in the main pane it does this to the split's agent too, which is the surprising half — two conversations end on one keypress.

It also clears the session's title-bar context, so a note you wanted to keep there has to be set again.

Detection is by process name. A pane running an agent under a wrapper the patterns do not name reads as "no agent" and the chord is silently inert there; a pane running something whose name ends in `claude` or `codex` reads as an agent and gets a slash command typed into it. Both are fixed by setting the match variables.

The pane the chord fired in comes from `$AGT_PANE`, which is the shell's spawn role rather than its live position. After a pane promotion or an `agtermctl session swap` that value can name the other side, and the reset follows the stale role.

A chord fired from the scratch terminal does nothing at all. The tree reports a session's main and split panes only, so the script has no way to see what the scratch pane is running.
