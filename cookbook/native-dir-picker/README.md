# Native directory picker

Pick a directory in agterm's own fuzzy picker and have its path typed into the shell you pressed the key in.

## What it does

Press the key and the picker agterm draws for its own palettes opens in the current window, listing the directories under your search roots. Type to filter, press Return, and the path is typed into that session without a Return of its own, so it arrives as an argument to whatever you were already writing. Type `cd ` first and the pick finishes the command. Esc closes the picker and types nothing.

Nothing runs in a terminal to make this happen. No overlay opens, no second shell starts, and no fuzzy finder has to be installed: the app draws the list itself and the script only supplies the choices and does something with the answer.

## Requirements

- agterm 0.19.0 or later. That release added `agtermctl pick`, which reads choices on stdin, shows them in the native fuzzy picker, and prints the chosen one back as JSON.
- `fd`, to enumerate the directories, and `jq`, to build the picker's items
- `/bin/sh`. The script is POSIX shell and does not need a particular one.

## Setup

Copy the script somewhere and make it executable:

```sh
mkdir -p ~/bin
cp pick-dir.sh ~/bin/
chmod +x ~/bin/pick-dir.sh
```

Add an entry to `~/.config/agterm/keymap.conf`:

```
command "Pick Directory" ctrl+a>d zsh -lc "$HOME/bin/pick-dir.sh"
```

Apply it with File ▸ Reload Keymap or `agtermctl keymap reload`. `ctrl+a>d` is a leader sequence: press ⌃A, release, then press D. Any chord with a modifier works, and leaving the chord out makes the entry palette-only.

`zsh -lc` is there for `PATH`. A custom command inherits the app's environment, which is the launchd default and has no `/opt/homebrew/bin` in it, so a bare `fd` or `jq` inside the script fails. A login shell sources your profile first and gives the script the `PATH` you normally have.

The script searches the session's own directory by default, which needs no configuration and answers "somewhere below where I already am". To search fixed trees instead, set `AGT_PICK_ROOTS` to a colon-separated list, and `AGT_PICK_DEPTH` to how deep to go below each root (4 by default):

```sh
export AGT_PICK_ROOTS="$HOME/src:$HOME/work"
export AGT_PICK_DEPTH=3
```

Put that export in `.zshenv` or `.zprofile`. The keymap entry runs the script under `zsh -lc`, a non-interactive login shell, which reads those two and skips `.zshrc` entirely. Setting the variables in the keymap entry itself works too, and keeps them out of your shell:

```
command "Pick Directory" ctrl+a>d zsh -lc "AGT_PICK_ROOTS=$HOME/src:$HOME/work $HOME/bin/pick-dir.sh"
```

If `agtermctl` is not on your `PATH`, set `AGTERMCTL` to its full path in the environment the script runs in.

## Usage

Press ⌃A then D. Type to filter, Return to insert the path, Esc to cancel.

Each row shows the full path with `$HOME` written as `~`, the way you would type it yourself, and the query matches anywhere in it. A directory outside your home directory shows its absolute path.

The path is typed with a trailing slash and no Return, so the usual sequence is to type `cd `, press the chord, pick, and press Return yourself once you can see what you picked.

## How it works

The script does three things over the control socket: it hands the directory list to `agtermctl pick`, types the answer back with `agtermctl session type`, and reports its own failures with `agtermctl notify`.

It runs as the custom command's own process rather than inside an overlay, which is what keeps it short. The runner exports `$AGT_SESSION_ID`, `$AGT_WINDOW_ID`, `$AGT_PANE` and `$AGT_SOCKET` into it and starts it in the session's working directory, so the script reads its target out of the environment instead of taking `{AGT_X}` tokens as arguments, and the search root can default to where the session already is. An overlay is a fresh pty and carries none of that.

`--window` pins the picker to the window the key was pressed in. Without it the picker opens in the frontmost window, which is the wrong one as soon as you have two.

Choices arrive on stdin, and the first non-whitespace byte decides the format. A plain list of lines makes each line both the id and the label, which is the short way when the two are the same. A leading `[` switches to JSON objects with `id` and `label`, which is what the script builds with `jq`, because here the two differ: the row reads `~/src/agterm/cookbook/` while the value stays the real path the shell needs. An optional `subtitle` is available as a second line per row, and this recipe leaves it out, since a path that already reads as a path has nothing to explain.

`pick` blocks until the picker is answered and prints one JSON line. A choice is `{"result":"picked","id":...}` at exit 0, and cancelling is `{"result":"cancelled"}` at exit 2. Cancelling is an ordinary way out rather than an error, so the script treats exit 2 as success and stops.

The picker holds at most 1000 items and rejects a longer list outright instead of truncating it. The script counts the candidates first and explains the number, which is also why it offers directories and not files: a source tree passes 1000 files long before it passes 1000 directories.

A keybinding's command runs with stdout and stderr on `/dev/null`, and a non-zero exit raises only a bare "exit N" banner with no detail. Anything the reader has to see is therefore posted with `agtermctl notify`, which is the one channel that reaches a script whose output goes nowhere.

`session type` injects keystrokes rather than pasting, and the text carries no newline, so nothing is submitted for you. `fd` already prints a directory with a trailing slash, and the script adds one when it is missing.

## Limits

The path is typed into the shell with no confirmation once you press Return, and a path containing a space arrives unquoted, so quote it yourself before running the command.

The default root is the session's own directory, which in a session you have not moved out of is your home directory. Searching all of `$HOME` is slow, it walks Documents, Desktop and Downloads, which makes macOS raise a privacy prompt per directory, and it reaches the item cap quickly. Set `AGT_PICK_ROOTS` to the trees you work in, or press the key from a project directory.

The picker takes 1000 items at most. Past that the script posts a banner and does nothing, so keep `AGT_PICK_ROOTS` to the trees you actually work in and `AGT_PICK_DEPTH` shallow. There is no partial list: an over-long list is refused rather than cut short.

`fd` skips hidden directories and honors `.gitignore`, so an ignored build directory does not appear, and neither does `.config`. Add `--hidden` or `--no-ignore` to the `fd` call in the script to change that.

Only one picker can be open per window. Pressing the key while one is already open in that window fails with `pick already pending`, which arrives as a failure banner.

`ctrl+a` becomes a leader once bound, so agterm consumes it and it no longer reaches the terminal. If you rely on ⌃A for beginning-of-line in readline, or as a tmux prefix, pick another leader.

Only the pane the key was pressed in receives the path. That is what `$AGT_PANE` carries, and the script passes it straight through to `session type`.
