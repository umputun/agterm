# New session in workspace

Press one key, pick a workspace from a searchable list, and get a new session in it — creating the workspace too if it does not exist yet.

## What it does

Press the key and a 60% floating overlay opens over the current session, running three fzf prompts in sequence:

1. Pick a workspace from the ones the window already has, or pick `＋ New workspace…` to make one.
2. If you picked the create entry, type the new workspace's name.
3. Type the session's name, or leave it blank to let agterm label the row itself.

The session is created in the workspace you chose and selected, and the overlay closes. Esc at any prompt cancels and creates nothing.

It is the answer to the gap between ⌘N, which puts a session in the workspace you are already in, and the sidebar, where getting a session into a different workspace means going to that workspace first. Here the destination is a search box, so it does not matter how many workspaces you have or which one you happen to be standing in.

## Requirements

- agterm 0.8.0 or later. `session overlay open --follow` shipped in that release, and the recipe uses it to pull you to the overlay when the key is pressed from another session. The rest of the commands — `tree`, `session new --workspace-name`/`--create-workspace`, `overlay open --size-percent` — are older.
- `jq`
- `fzf`
- POSIX `sh`, which the script's shebang names

## Setup

Copy the script somewhere and make it executable:

```sh
mkdir -p ~/bin
cp agt-new-session.sh ~/bin/
chmod +x ~/bin/agt-new-session.sh
```

Add one entry to `~/.config/agterm/keymap.conf`:

```
command "New Session in Workspace…" cmd+t ~/bin/agt-new-session.sh
```

Apply it with File ▸ Reload Keymap or `agtermctl keymap reload`. Any chord with a modifier works, and leaving the chord out makes the entry palette-only. ⌘T is free in agterm's own defaults, so nothing is shadowed by taking it.

Three things are tunable through the environment, and none needs setting on an ordinary install:

- `AGT_BIN_PATH` — the directories prepended to `PATH` so `fzf` and `jq` resolve, defaulting to `/opt/homebrew/bin:/usr/local/bin`. Set it if your binaries live somewhere else.
- `AGTERMCTL` — the CLI's full path, if it is not on `PATH`. **Help ▸ Install Command Line Tool…** normally puts it in `/usr/local/bin`.
- `AGT_OVERLAY_SIZE` — the overlay's size as a percent of the pane, defaulting to `60`.

## Usage

Press ⌘T. Type to filter the workspace list, Enter to choose, Esc to cancel.

The list holds the workspaces of the frontmost window plus the `＋ New workspace…` entry. On the two typing prompts there is nothing to filter — fzf is there for the line editor and the consistent look, and what you type is the answer.

A name typed at the last prompt is a manual rename and pins the sidebar row to it. Leaving it blank lets the row track the session instead — the shell's terminal title when it sets one, the working directory's basename when it does not — which is usually what you want for a session you are about to `cd` around in.

## How it works

A custom command runs detached with no terminal, so it cannot host fzf. The script therefore has two halves and calls itself: pressed as a keybinding it opens an overlay — a real pty — running `sh <itself> --pick`, and that second invocation is the part that draws the prompts. `show-image.sh` in the bundled agent skill uses the same self-reinvoking shape.

`--follow` is what makes the overlay come to you. A floating overlay opens on its target session in the background by default, so without it the prompts would be running on a session you may not be looking at.

Three details cost real time to find.

An overlay inherits the app's `PATH`, which is the launchd default: `/usr/local/bin` plus the system directories, with nothing your shell profile adds. A bare `fzf` is therefore not found, the script exits 127, and because the overlay opens without `--wait` it closes instantly and takes the error message with it — the visible symptom is an overlay that flashes and vanishes. Hence the `PATH` prepend at the top. Run the script from a shell if something looks wrong; that is where the error text goes.

The overlay does not inherit the *launcher's* environment either, which is why `AGTERMCTL` and `AGT_BIN_PATH` are prefixed onto the overlay command as assignments rather than exported. agterm spawns the overlay's shell itself, from the app's environment plus the `AGTERM_*` set, so a value this process exports never arrives — and a `VAR=value` prefix on the keymap line reaches only the launcher, leaving the half that runs `fzf`, `jq` and the `tree` call on the defaults. Since agterm runs the overlay command through `eval`, a leading assignment is honored, so the two values ride across in the command string. Both are single-quote-escaped for the same reason the path is.

`fzf --print-query` prints the query whether you confirmed it or cancelled, so on the two typing prompts an empty-string test cannot tell "typed a name and pressed Esc" from "typed a name and pressed Enter". The exit status can: 130 is the cancel. That is why those two prompts capture `$?` into a variable and check it before looking at the text at all.

`agtermctl` resolves its socket from `--socket`, then `AGTERM_STATE_DIR`, then the app-support default. It does **not** read `AGTERM_SOCKET`, despite agterm exporting exactly that into every session it spawns — an `export AGTERM_SOCKET=…` in a script like this looks load-bearing and does nothing. The script passes the socket through explicitly instead: `$AGT_SOCKET` in the launcher (agterm gives a custom command that one) or `$AGTERM_SOCKET` in the overlay (agterm gives a pty that one), and neither set means the default resolution stands.

The path the script hands the overlay is absolute, because the overlay starts with its own working directory, and it is single-quote-escaped, because agterm runs the overlay command through `sh -c` and a directory name with a space or an apostrophe in it would otherwise break the line apart.

## Limits

Picking `＋ New workspace…` **creates** a workspace. Nothing is closed or deleted anywhere in this recipe, but a typo at that prompt leaves a real workspace in the sidebar that you have to remove by hand.

The workspace list comes from `agtermctl tree`, which reports the frontmost window, and the session is created there. Workspaces in your other windows are not offered, so a session for one of those means going to that window first and pressing the key again.

Two workspaces with the same name are indistinguishable in the list, and `session new --workspace-name` takes the first match, so the session may land in the other one. Picking the create entry and typing a name that already exists reuses that existing workspace rather than making a second one, which is `--create-workspace`'s documented behavior and usually what you want.

A workspace literally named `＋ New workspace…` would shadow the create entry. The fullwidth plus makes that unlikely rather than impossible.

Cancelling is always safe — the workspace is created in the same `session new` call that creates the session, so an Esc at the last prompt leaves nothing behind, even when you typed a new workspace name at the prompt before it.

Pressing the key in a window whose sessions have **all** exited does not create anything. The overlay has to open over a session, and with none left there is nothing for `--target active` to resolve to. A custom command's output goes nowhere, so the error text is lost — but the failure is not: the non-zero exit posts a *Command failed* banner naming the command and its exit status, unless you have turned banners off in Settings ▸ Notifications. That is the state you would most like a session-creating shortcut to work in, and it is the one state it cannot. The built-in New Session (⌘N) is unaffected, so getting one session back makes the key work again.
