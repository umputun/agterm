# Agent reset

One chord clears the coding agent running in the pane you pressed it in, and does nothing at all when no agent is running there.

## What it does

Starting a fresh conversation is the thing you do most often and the thing that is most annoying to reach: the context is long, the reply is slow, and you have to click into the right pane first. This binds it to a chord.

The part worth copying is the guard. A slash command is meaningful to a coding agent and to nothing else, so the script reads what the pane is actually running before it sends anything, and sends only when that is an agent it recognizes. Anywhere else it exits without a keystroke rather than pushing text at a program that never asked for it. Each pane is matched on its own foreground, so a split running Claude Code on one side and codex on the other gets the submit each one needs.

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

Both agents take `/clear` and submit it with a newline. What differs is where that newline goes.

Claude Code accepts it on the end of the command, in one write. codex does not: an Enter that shares a write with the text is not acted on, and the command sits in the composer unsent. Measured on codex 0.153.4, `agtermctl session type $'probe\n'` leaves `probe` in the composer, while the same text followed by `agtermctl session type $'\n'` as a second call submits it. Back-to-back calls with no sleep between them submit too, so the script waits for nothing. Note what that measured: two `agtermctl` invocations, which are always a process launch apart. A caller that collapsed both writes into one process holding the socket open would send them far closer together than anything tested here, and should check for itself rather than assume.

So the codex path is two writes of the same bytes rather than one, which is why the script returns a tuple of writes per agent instead of a single string.

Every call passes `--socket "$AGT_SOCKET"`, the socket of the app that fired the chord. That matters when more than one agterm is running, or when the `agtermctl` on `PATH` belongs to a different install than the app you pressed the key in: the socket decides which app is addressed, not the binary.

The title-bar clear is gated on the main pane's own write succeeding, and not on the split's. A failed write leaves that agent still holding its task, so the line has to keep describing it. The split's agent does not own the line either way.

## Limits

**A reset throws away the agent's conversation.** That is the whole point of the chord, but it is not undoable and the agent will not ask: whatever context it had built up is gone the moment the chord lands. Pressed in the main pane it does this to the split's agent too, which is the surprising half — two conversations end on one keypress.

On codex it destroys more than the conversation. That agent's `/clear` wipes the pane's scrollback along with the chat, so output you had not finished reading is gone, and anything polling the pane with `agtermctl session text` reads nothing but codex's fresh banner until new output arrives.

It also clears the session's title-bar context, so a note you wanted to keep there has to be set again.

Detection is by process name. A pane running an agent under a wrapper the patterns do not name reads as "no agent" and the chord is silently inert there; a pane running something whose name ends in `claude` or `codex` reads as an agent and gets a slash command typed into it. Both are fixed by setting the match variables.

The pane the chord fired in comes from `$AGT_PANE`, which is the shell's spawn role rather than its live position. After a pane promotion or an `agtermctl session swap` that value can name the other side, and the reset follows the stale role.

A chord fired from the scratch terminal does nothing at all. The tree reports a session's main and split panes only, so the script has no way to see what the scratch pane is running.
