# FZF path picker

Pick a file or directory with fzf in an overlay, and have the path typed into the shell you pressed the key in.

## What it does

Press the key and an 80% floating overlay opens over the current session running fzf over your project trees. Pick something, and the path is typed into that session's prompt without a Return, so it arrives as an argument to whatever you were already writing. Esc closes the overlay and types nothing.

Two entries: one over files, one over directories. It is the terminal-side answer to hunting for a path in another window and pasting it back.

## Requirements

- agterm 0.8.0 or later. The commands are older, but floating overlays settled into their current behavior in that release: an overlay opens on its target session in the background, and switches to it only with `--follow`.
- `fzf` and `fd`
- `zsh`, which the script's shebang names

## Setup

Copy the script somewhere and make it executable:

```sh
mkdir -p ~/bin
cp fzf-insert.zsh ~/bin/
chmod +x ~/bin/fzf-insert.zsh
```

Point `AGT_FZF_ROOTS` at the trees you want to search, colon-separated, in your shell config:

```sh
export AGT_FZF_ROOTS="$HOME/src:$HOME/work"
```

Put that export in `.zshenv` or `.zprofile`, not in `.zshrc`. The keymap entry below runs the script under `zsh -lc`, a non-interactive login shell, which reads the first two and skips `.zshrc` entirely. The same applies to anything else the script needs from your shell config, `PATH` included. Use `zsh -ilc` if it has to come from `.zshrc`.

`AGT_FZF_ROOTS` defaults to `$HOME/src`, and the script prints a message and exits if none of the listed directories exist. You will not see that message with the keymap entries below: they open the overlay without `--wait`, so it closes the moment the script exits and takes the text with it. Add `--wait` to the entry to hold the overlay on a "press any key to close" prompt while you are getting the roots right, or run the script in a shell. Keep the list to the trees you actually work in. Searching all of `$HOME` is slow, and it walks Documents, Desktop and Downloads, which makes macOS raise a privacy prompt per directory.

Add two entries to `~/.config/agterm/keymap.conf`:

```
command "FZF Files" ctrl+a>f agtermctl session overlay open 'zsh -lc "$HOME/bin/fzf-insert.zsh files {AGT_SESSION_ID}"' --size-percent 80 --target {AGT_SESSION_ID}
command "FZF Dirs" ctrl+a>shift+f agtermctl session overlay open 'zsh -lc "$HOME/bin/fzf-insert.zsh dirs {AGT_SESSION_ID}"' --size-percent 80 --target {AGT_SESSION_ID}
```

Apply the file with File ▸ Reload Keymap or `agtermctl keymap reload`. `ctrl+a>f` is a leader sequence: press ⌃A, release, then press F. Any chord with a modifier works, and leaving the chord out makes the entry palette-only.

If `agtermctl` is not on your `PATH`, set `AGTERMCTL` to its full path in the environment the script runs in.

## Usage

Press ⌃A then F for files, ⌃A then ⇧F for directories. Type to filter, Enter to insert, Esc to cancel.

The overlay runs on the session you pressed the key in, so the path goes back to that shell whichever pane or window you were in.

## How it works

The keymap entry opens an overlay running the script, and the script ends by calling `agtermctl session type` to put the result back.

Two things about overlays shape the whole recipe.

An overlay is a fresh pty, and the `AGT_*` values a keybinding sees belong to the custom command's own process, not to any terminal. So `$AGT_SESSION_ID` is empty inside the script, and it is passed as an argument instead: the keymap expands `{AGT_SESSION_ID}` before the command runs, once for `--target` (which session the overlay opens over) and once as the script's own argument (where to type the result). Without it `session type` falls back to `--target active`, which is right only until you switch sessions while fzf is open.

The overlay pty does carry agterm's own `AGTERM_SESSION_ID`, naming the session the overlay was opened over, and a script that always opens over the current session can read that instead of taking an argument. Passing the id keeps the two independent, so the same script still works when the overlay is opened over some other session.

An overlay also runs under the app's `PATH`, which is the launchd default and does not include `/opt/homebrew/bin`. A bare `fzf-insert.zsh`, or a bare `fd` inside it, fails with exit 127 and the overlay flashes open and vanishes. Hence `zsh -lc`: a login shell sources your profile, so `PATH` is the one you normally have. The alternative is absolute paths for every binary the script touches.

`session type` injects keystrokes rather than pasting, and the command substitution around fzf already stripped the trailing newline, so the path arrives as text with no Return. `--size-percent 80` makes the overlay a floating panel with the session still visible around it; drop it for a full-pane overlay.

## Limits

`ctrl+a` becomes a leader once bound, so agterm consumes it and it no longer reaches the terminal. If you rely on ⌃A for beginning-of-line in readline, or as a tmux prefix, pick another leader.

Nothing is typed if you cancel, but the path is typed with no confirmation if you pick. A path with a space arrives unquoted, so quote it yourself before pressing Return.

The script searches with `fd`, which honors `.gitignore` by default. A file inside an ignored directory does not appear. Add `--no-ignore` to the `fd` calls if you want everything.

Only the main pane receives the text. `session type` takes a `--pane left|right|scratch` option and the keymap expands `{AGT_PANE}` to the pane the key was pressed in, so a split-aware version passes that through the overlay command into the script and on to `session type`.
