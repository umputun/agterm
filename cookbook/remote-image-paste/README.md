# Remote image paste

Paste a screenshot into a program running in a remote session, such as Claude Code on another Mac.

## What it does

In a session attached with `agtermctl zmx attach`, Claude Code and codex on the far Mac read that Mac's
clipboard when you press ctrl+v, so a screenshot you just took here never reaches them. This recipe adds one chord that copies the image on this Mac's clipboard to the remote Mac's clipboard. Press
it, wait for the "image copied" panel, then press ctrl+v as usual, and Claude Code or codex on the far
side pastes a real image. In a local session the chord does nothing.

## Requirements

agterm 0.31.0 or later, which added the `--error-hud` option the keymap line uses. The script also
relies on `session hud open --hide-after` from 0.30.1 and `AGT_SESSION_HOST` from 0.29.0.

The remote side is a Mac, since the script sets its clipboard with `osascript`. Key-based ssh to it works
non-interactively, which `zmx attach` already needs, and logs in as the account signed in to that Mac's
desktop, since that account's clipboard is the one Claude Code and codex read.

## Setup

1. Copy `copy-image-to-host.sh` to `~/.config/agterm/scripts/` and keep it executable.
2. Add the chord to `~/.config/agterm/keymap.conf`:

   ```
   command "copy image to session host" cmd+shift+v --error-hud ~/.config/agterm/scripts/copy-image-to-host.sh
   ```

3. Run `agtermctl keymap reload`.

Pick another chord if cmd+shift+v is already taken in your keymap. To use a different CLI, prefix the
script path in the keymap line with `AGTERMCTL=/path/to/agtermctl`.

## Usage

Put a screenshot on this Mac's clipboard (ctrl+shift+cmd+4 captures a selection straight to it), focus
the remote pane, and press cmd+shift+v. When the panel says "image copied to <host>, press ctrl+v",
press ctrl+v in the program.

## How it works

The chord runs the script with the session's `AGT_SESSION_HOST`. The script writes the clipboard's PNG
to a temp file, copies it to the same path on the host with scp, and runs a small `sh` script over ssh
that puts the file on the host's clipboard and deletes it. When the ssh account is the one logged in to
that Mac's desktop, a command run over ssh writes the clipboard Claude Code and codex read there.

The ctrl+v itself is never touched, so every program receives its normal key. Replaying ctrl+v from a
script does not work everywhere: codex ignores the raw control byte and reacts only to the key as its
keyboard protocol encodes it.

The remote step goes through `sh -s` because ssh runs a remote command through the account's login
shell, and zsh, fish and tcsh each reject part of an inline script.

The chord returns before the upload finishes, so the panel is the signal that the host's clipboard holds
the new image. A ctrl+v pressed before it pastes whatever the host's clipboard held before.

## Limits

Each use replaces the remote Mac's clipboard.

Images only. Files and text are not copied, and a file dropped on a remote pane still inserts its local
path.

The host comes from the session, so the chord in a local split or the scratch pane of a remote session
still copies to that host.

codex rejects palette-based (8-bit colormap) PNGs. Screenshots taken on a Mac are truecolor and paste
fine.
