# Named companion

One chord duplicates the session as a tinted companion and asks what to call it; leave the name blank and the companion's Claude Code names it from its task.

## What it does

Duplicate as Companion copies the session's split layout and starts another copy of each pane's program, nested under the parent in the sidebar. The copy comes up without a name of its own, so a few of them under one parent are hard to tell apart.

This binds a chord that asks for the name first, in a small dialog, then creates the companion, names it, and tints its icon and name gray so a copy is told apart from its parent at a glance.

Often the name is not known yet, because the companion exists to start something new. Leave the field blank and the companion takes the parent's name for now. If you also run the [session-context-nudge](../session-context-nudge/) hook, the companion's Claude Code renames it to a short form of its title-bar context once it knows what it is working on. Without that hook the parent's name simply stays until you rename it.

## Requirements

- agterm 0.39.0 or later, which shipped companions (`session duplicate --companion`) and row tints (`session tint`)
- Python 3.9 or later, which macOS ships as `/usr/bin/python3`
- For the automatic rename only: the session-context-nudge hook in Claude Code

## Setup

Copy the script somewhere and make it executable:

```sh
mkdir -p ~/bin
cp companion.py ~/bin/
chmod +x ~/bin/companion.py
```

Add an entry to `~/.config/agterm/keymap.conf` and apply it with File ▸ Reload Keymap or `agtermctl keymap reload`:

```
command "Companion" ctrl+a>h --error-hud ~/bin/companion.py
```

Any free chord works. `--error-hud` shows the script's error in a panel over the session when something refuses, such as a pane whose program cannot be copied.

Fired from a chord or the palette, the script runs under the PATH agterm gives custom commands: the app's own bundled CLI directory first, so `agtermctl` is the one belonging to the app that fired the chord, and `python3` resolves from `/usr/bin`. Set `AGTERMCTL` to a full path to use a different CLI, as a prefix on the keymap line:

```
command "Companion" ctrl+a>h --error-hud AGTERMCTL=/path/to/agtermctl ~/bin/companion.py
```

The tint is the `TINT` constant at the top of the script; any color `agtermctl session tint` accepts works.

For the automatic rename, install [session-context-nudge](../session-context-nudge/) as its README describes and allow `Bash(agtermctl session rename:*)` alongside `Bash(agtermctl session context:*)` if you run Claude Code with an allowlist.

## Usage

Press the chord in the session you want a companion of. Type a name and press Return, or press Return on an empty field to take the parent's name. Esc or Cancel creates nothing.

From inside a companion the chord makes a sibling: a companion always belongs to the top-level session, so a blank name takes that session's name.

## How it works

The dialog is `agtermctl ask --style gui --input line`. Its exit code separates a dismissal from a failure: 3 is Esc and 2 a cancellation, both answers the script treats as "do nothing", while 1 means no dialog could be shown and is reported.

`agtermctl session duplicate --companion --json` answers with the new session's `id` and its `parent`. The parent is the top-level session even when the chord fired in a companion, which is why the blank-name path reads the parent's name from `agtermctl tree` instead of using the session the chord fired in. The copy is then renamed and tinted by id.

A blank name also writes a marker file, `~/.cache/agterm/companion-names/<companion id>`, holding the name it was given. The session-context-nudge hook looks for that file on every prompt in the companion. While the session still carries that name, the hook asks Claude Code to rename it; once the name differs, renamed by the agent or by you, the hook deletes the marker and stops asking.

Every call passes `--socket "$AGT_SOCKET"` when the runner set it, so the app that fired the chord is the one addressed, whatever `agtermctl` is first on `PATH`.

## Limits

The companion starts a second copy of every program the source session's panes run, the source being the session the chord fired in, a companion included. A source running Claude Code and codex gets a companion running two more, each starting a fresh conversation in the same directory.

A program started with its session id in its arguments carries the source's id into the copy on agterm 0.39.1 and earlier, where Duplicate as Companion copies arguments verbatim; such a copy addresses the source session. A plain `agtermctl session restart` replays those same arguments, so exit the copied program and start it again through its usual launcher, or restart the pane with an explicit `--command`.

The rename is a nudge to the agent, not a guarantee: it happens on the companion's next prompt at the earliest, and only in a pane where the nudge hook runs. A marker for a companion closed before it was renamed stays in `~/.cache/agterm/companion-names` until you delete it; it names a session id that will not come back, so it does nothing.

Without the session-context-nudge hook, a blank name leaves the companion named exactly like its parent, and the marker is never read.
