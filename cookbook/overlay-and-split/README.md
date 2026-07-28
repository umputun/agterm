# Overlay and split keybindings

A split toggle that reads the current state before deciding, plus three TUIs on leader keys, all as `keymap.conf` lines.

## What it does

Four entries, no script files.

`Smart Split` on ⌃A then A is one key for both directions. With no split shown it opens the split and puts the cursor in the new right pane. With a split shown it moves the cursor left and hides the right pane. The branch is not a guess: it reads the session's split state from `agtermctl tree --json` first.

Three more entries run a TUI in a 95% floating overlay over the current session: lazygit on ⌃A then L, yazi on ⌃A then Y, midnight commander on ⌃A then M. Each starts in the session's working directory, and the overlay closes by itself when the program exits.

## Requirements

- agterm 0.10.0 or later. The four entries themselves work from 0.8.0, where floating overlays settled into their current behavior: an overlay opens on its target session in the background, and switches to it only with `--follow`. The `splitFocused` read-back described below arrived in 0.10.0.
- `jq`, for the `Smart Split` entry
- whichever TUIs you want to bind: `lazygit`, `yazi`, `mc`

## Setup

Add the lines to `~/.config/agterm/keymap.conf` and apply the file with File ▸ Reload Keymap or `agtermctl keymap reload`.

```
# ctrl+a>a: smart split. Nothing shown -> open the split and focus the right pane.
# Already shown -> focus the left pane and hide the right one, keeping its shell alive.
command "Smart Split" ctrl+a>a if [ "$(agtermctl tree --json | jq -r '.result.tree.workspaces[].sessions[]|select(.active)|.split')" = true ]; then agtermctl session focus left; agtermctl session split off; else agtermctl session split on; agtermctl session focus right; fi

# TUIs in a 95% floating overlay over the current session, each in its working directory
command "Lazygit" ctrl+a>l agtermctl session overlay open 'zsh -lc lazygit' --size-percent 95
command "Yazi" ctrl+a>y agtermctl session overlay open 'zsh -lc yazi' --size-percent 95
command "Midnight Commander" ctrl+a>m agtermctl session overlay open 'zsh -lc "mc -u"' --size-percent 95
```

`ctrl+a>a` is a leader sequence: press ⌃A, release, then press A. Any chord with a modifier works as the leader, and leaving the chord out entirely makes the entry palette-only. Drop the entries you have no use for; each line stands alone.

These lines call `agtermctl` and `jq` by bare name, which is the exception to the rule the rest of the cookbook follows. A script in this collection reaches the CLI through `AGTERMCTL=${AGTERMCTL:-agtermctl}` so a reader can point it elsewhere, but keymap lines are copied into your own `keymap.conf` and there is no variable to override, so a bare name is the right form here. If a binary is not on the `PATH` the custom command sees, write its absolute path into the line.

## Usage

Press the leader, release, then the second key. Custom commands also show up in the ⌃⇧P action palette marked `custom`, so you can run any of them by name without the chord.

`Smart Split` is a toggle, so each press flips the state and two presses put you back where you started, once the first has finished. Holding the key does not repeat it: agterm ignores key repeats for custom commands, so a held key fires exactly once and leaves you in the opposite state.

## How it works

`agterm` knows the split state, so the toggle asks instead of tracking it. `agtermctl tree --json` returns the frontmost window's workspaces and sessions; `.result.tree.workspaces[].sessions[]|select(.active)|.split` picks the selected session and reads whether its split is currently shown. `session split on|off` shows or hides it, and `session focus left|right` moves the keyboard focus between the two panes.

Hiding a split does not kill it. `session split off` keeps the pane's shell alive and maximizes the other one, which is why the toggle can flip back and forth without losing what was running. That is also why the `jq` path reads `split` rather than a has-a-split field: `split` is "currently shown", which is what the toggle needs.

Custom commands run through `/bin/sh -c`, so the `if ... then ... else ... fi` and the pipe in the `Smart Split` line work as written.

The overlay entries need the `zsh -lc` wrapper for a reason worth stating in full. An overlay command runs under the app's `PATH`, which is the launchd default and does not include `/opt/homebrew/bin` or any other directory your shell adds. A bare `lazygit` there fails with exit 127, and all you see is an overlay that flashes open and disappears. A login shell sources your profile first, so `PATH` becomes the one you normally have. Absolute paths work too: `agtermctl session overlay open /opt/homebrew/bin/lazygit --size-percent 95`.

`zsh -lc` is a non-interactive login shell, so it reads `.zshenv`, `.zprofile` and `.zlogin` and skips `.zshrc`. If your `PATH` is set in `.zshrc` only, move it or use `zsh -ilc` instead.

`--size-percent 95` makes the overlay a floating framed panel at 95% of the pane with the session visible around it. Drop the option for a full-pane overlay that hides the session behind it.

Read the state back the same way the toggle does. `session split` and `session focus` answer `ok` and report nothing about what they changed; their read side sits on the `tree` session node. `split` says whether the split is shown, `splitFocused` says which pane holds focus (`true` is the right pane, `false` the left, absent when there is no split). `splitRatio` is there too, the read side of `session resize`, so a script can record the divider position before maximizing a pane and restore it exactly.

## Limits

`ctrl+a` becomes a leader once bound, so agterm consumes it and it no longer reaches the terminal. If you rely on ⌃A for beginning-of-line in readline, or as a tmux prefix, pick another leader.

`Smart Split` acts on the frontmost window's selected session. It reads `tree` without a window selector, so running it against a background window needs `--window` on both the read and the writes.

The `jq` path assumes exactly one selected session, which is what `tree` reports for a window. With no session selected the read returns nothing, the comparison fails, and the entry takes the open branch.

Nothing here closes a split. `session split off` hides it and keeps the shell running; the pane goes away only when its own shell exits.

A TUI that expects a full-size terminal can look cramped at 95% of a small pane. Raise the percentage, drop `--size-percent` for a full-pane overlay, or maximize the window first.
