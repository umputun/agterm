# Project launcher

Press one key anywhere, pick a project from the native fuzzy picker, and get a new session in that project's workspace — created on the spot when it does not exist yet. With a command configured, typing a prompt after the project's name hands it to that command, so one line starts an agent already working.

## What it does

Press the key and the picker agterm draws for its own palettes opens over the current window, listing your projects: every direct subdirectory of the roots you name. Type a few letters, press Return, and a new session opens in that project's directory, inside a workspace named after the project. The workspace is created if the sidebar does not have it yet and reused if it does, so pressing the key twice for the same project stacks a second session into the same workspace rather than making a second workspace.

It closes the gap between "I am somewhere" and "I want a shell in that project". The built-in ⌘N opens a session where you already are, and reaching a different project through the sidebar means finding its workspace first — or creating one, naming it, and setting the directory by hand when it is a project you have not opened this week. Here the starting point does not matter: any session, any workspace, one key, no typing beyond the filter.

Two recipes in this cookbook sit close by. [`native-dir-picker`](../native-dir-picker/) is the same enumeration feeding the same picker; the difference is the last line, which types the chosen path into the shell you are in, where this one opens a session there. It also walks deep with `fd`, while this recipe stays one level down — so run that one to reach an arbitrary directory, this one to reach a project. [`new-session-in-workspace`](../new-session-in-workspace/) also creates a workspace from a picker, but a workspace is all it makes: you type its name rather than pick a directory, and the session's `--cwd` is not set, because nothing in it maps workspaces to places on disk.

The session runs your login shell by default. Set one variable and it runs something else instead — a coding agent is the obvious candidate, so that the key becomes "new agent in any project" — but nothing in the recipe assumes one.

With that command set, the same picker line can carry the work itself: keep typing past the project's name — `api fix the failing render test` — and Return opens the session with everything after the first word handed to the command as its first argument. For an agent, that is the prompt, and the gap this closes is the round trip: without it you launch, wait for the agent to come up, and type the request you already had in your head when you pressed the key. The first word needs only to identify the project — any unambiguous piece of its name works, resolved exact-first, so `gate` reaches `gateway` and `api` means the project named `api` even when `api-gateway` sits beside it.

## Requirements

- agterm 0.19.0 or later. The floor comes from `agtermctl pick`, which shipped in 0.19.0: it reads choices on stdin, shows them in the native fuzzy picker, and prints the chosen one back as JSON — including, with `--allow-custom`, a line of free text that matches no row, which is what the prompt flow rides on. Everything else the script calls — `session new` with `--workspace-name`, `--create-workspace`, `--cwd`, `--command`, `--window`, and `notify` — is older than that.
- `jq`, to build the picker's items.
- `/bin/sh`. The script is POSIX shell and does not need a particular one.

## Setup

Copy the script somewhere and make it executable:

```sh
mkdir -p ~/bin
cp project-launcher.sh ~/bin/
chmod +x ~/bin/project-launcher.sh
```

Add an entry to `~/.config/agterm/keymap.conf`:

```
command "Launch Project" cmd+shift+g zsh -lc "$HOME/bin/project-launcher.sh"
```

Apply it with File ▸ Reload Keymap or `agtermctl keymap reload`. ⌘⇧G is free in agterm's shipped defaults, so nothing is shadowed by taking it; any chord with a modifier works, and leaving the chord out makes the entry palette-only.

`zsh -lc` is there for `PATH`. A custom command inherits the app's environment, which is the launchd default and has no `/opt/homebrew/bin` in it, so a bare `jq` inside the script fails. A login shell sources your profile first and gives the script the `PATH` you normally have.

Two variables configure it, both read from the environment the script runs in:

- `AGT_PROJECT_ROOTS` — colon-separated directories whose direct children are your projects, defaulting to `$HOME/src`. This is the one you almost certainly need to set.
- `AGT_PROJECT_COMMAND` — a command to run as the new session's process instead of your login shell, and the receiver of a typed prompt. Leave it unset for a plain shell. The script wraps it in a login shell itself, so a bare `claude` resolves from your normal `PATH`.

Put the exports in `.zshenv` or `.zprofile` — the keymap entry runs the script under `zsh -lc`, a non-interactive login shell, which reads those two and skips `.zshrc` entirely. Setting them on the keymap line itself works too, and keeps them out of your shell:

```
command "Launch Project" cmd+shift+g zsh -lc "AGT_PROJECT_ROOTS=$HOME/src:$HOME/work AGT_PROJECT_COMMAND=claude $HOME/bin/project-launcher.sh"
```

If `agtermctl` is not on your `PATH`, set `AGTERMCTL` to its full path. **Help ▸ Install Command Line Tool…** normally puts it in `/usr/local/bin`.

## Usage

Press ⌘⇧G. Type to filter, Return to launch, Esc to cancel and launch nothing.

Each row shows the project's name with its path underneath, `$HOME` written as `~`, so two projects that share a name in different roots stay distinguishable in the list. The new session is selected when it opens, and its workspace appears in the sidebar under the project's name if it was not already there.

To launch with a prompt, type the project's name — or any unambiguous piece of it — then a space and the request: `api fix the failing render test`, Return. The picker shows the whole line as its free-text row once it stops matching a project row; Return accepts it, the session opens in `api`, and the command receives everything after the first word as its first argument. A first word that matches nothing raises a banner naming the problem; one that matches several projects raises a banner listing them, so a wrong guess costs a keypress, not a session in the wrong repo. One kind of line defeats the flow entirely — when one project's row still fuzzy-matches every word you typed, Return opens that project without the prompt; Limits describes the shape and the escape.

The sidebar row takes its label from the session the usual way — the shell's title when it sets one, the directory's basename when it does not. Nothing here pins a name, so agents or scripts that retitle their session keep working.

## How it works

The script does three things over the control socket: it hands the project list to `agtermctl pick`, opens the session with `agtermctl session new`, and reports its own failures with `agtermctl notify`.

It runs as the custom command's own process rather than inside an overlay, which is what keeps it short — no second pty, no fzf, nothing to install. The runner exports `$AGT_WINDOW_ID` and `$AGT_SOCKET` into the process, so the script reads its targets out of the environment instead of taking `{AGT_X}` tokens as arguments.

The project list is a plain directory listing, one glob per root, not a filesystem walk. That is a deliberate difference from a finder-based picker: roots-with-children is how people actually keep projects (`~/src/*`), it needs no `fd`, and it stays far from the picker's 1000-item cap where a recursive walk gets there quickly.

Choices go to `pick` as JSON objects rather than plain lines because id, label, and subtitle differ: the id is the absolute path `session new` needs, the label is the basename you filter on, and the subtitle is the path so you can tell twins apart. `pick` blocks until the picker is answered and prints one JSON line — `{"result":"picked","id":...}` at exit 0, `{"result":"cancelled"}` at exit 2. Cancelling is an ordinary way out rather than an error, so the script treats exit 2 as success and stops. `--window` pins the picker to the window the key was pressed in; without it the picker opens in the frontmost window, which is the wrong one as soon as you have two.

The prompt flow is one picker doing two jobs, and it leans on how the free-text row behaves. `--allow-custom` adds a "Use …" row only while the query matches **no** project row, and the palette's filter is fuzzy: every whitespace-separated word of the query has to match a row, but a scattered subsequence counts as matching. A line therefore usually stops matching everything the moment a real prompt word follows the project, and arrives back whole as `{"result":"custom","query":...}` — usually, not always; the case where a row keeps matching is in Limits. The script splits a custom result on the first space: the first word resolves against the project names (exact match first, then unique prefix, then unique substring, case-insensitive), the rest is the prompt. Picking a row the ordinary way still means "no prompt", so the plain flow is untouched.

The prompt reaches the command by temp file, not by splicing. `--command` is tokenized argv-style with no shell in between, and quoting arbitrary text into a shell line inside a JSON argument is exactly the kind of construction that breaks on the first apostrophe. The script writes the prompt to a `mktemp` file instead and builds `zsh -lc 'p=$(cat <file>); rm -f <file>; <command> "$p"'` — the session's own shell reads the file, deletes it, and passes the text as one argument, whatever is in it. This is also why `AGT_PROJECT_COMMAND` itself may not contain a single quote: the command line is spliced into that single-quoted token, and the script refuses at startup rather than truncating it silently.

`--workspace-name` plus `--create-workspace` is the pair that makes the workspace half automatic: the name is looked up first, created only when missing, reused otherwise. Reuse-not-duplicate is `--create-workspace`'s documented behavior, and it is what turns the recipe from "session factory" into "take me to that project".

`session new` carries `--window` for the same reason `pick` does, and it matters twice here: the session must land in the window the picker showed in, and the workspace-name lookup itself is scoped to the target window — an unpinned call matches, or creates, against whatever window is frontmost by the time the pick lands, which after a moment of window-switching is not necessarily where you pressed the key.

A keybinding's command runs with stdout and stderr on `/dev/null`, and a non-zero exit raises only a bare "exit N" banner with no detail. Anything the reader has to see is therefore posted with `agtermctl notify`, which is the one channel that reaches a script whose output goes nowhere.

## Limits

Picking a project **creates** a workspace when none has its name yet. Nothing is closed or deleted anywhere in this recipe, but every launch into a fresh project leaves a real workspace in the sidebar that you remove by hand when you are done with it.

The workspace is found by name, within the window the key was pressed in. A workspace you named after something other than its project will not match, so the launcher makes a second workspace beside it; a matching workspace in one of your *other* windows does not count either, so each window grows its own copy of a project you launch in both. Two same-named workspaces in one window take the first match. And two projects with the same basename under different roots — distinguishable in the picker by their subtitle — land in the same workspace, because the name is all `session new` gets.

Only direct children of the roots are offered. A project nested two levels down needs its parent added to `AGT_PROJECT_ROOTS`; the recipe deliberately does not walk the tree.

With `AGT_PROJECT_COMMAND` set, the session runs that command instead of a shell and **closes when it exits**, including when it fails to start. A command that dies instantly — a typo, a binary not on the launchd `PATH` — looks like the key doing nothing; the script's own login-shell wrapper covers `PATH`, but the command still has to exist. Unset the variable to get an ordinary shell that stays.

A typed prompt needs that command: with `AGT_PROJECT_COMMAND` unset there is nothing to hand it to, so the script says so in a banner and opens the plain shell rather than losing the text silently. The command also may not contain a single quote — the script refuses at startup with a banner rather than mangling it.

The single-line flow can silently lose a typed prompt. The free-text row exists only while the query matches nothing, and the palette's matcher is generous: every word of the query must match, but a scattered subsequence counts — `api ga` still matches `api-gateway`, and a long project name can absorb several short words letter-by-letter. On 0.19.0 and 0.19.1 a row's subtitle — here the project's path — is matched as well, which widens the net further. As long as one row survives every word of the line, no free-text row appears and Return is an ordinary pick: the session opens plainly and the rest of the line is gone, with no banner, because the script only ever sees a picked row. A colon on the project word (`api: ga`) matches no label, forces the free-text row, and is stripped before resolving — when the prompt matters, glance for the "Use …" row before pressing Return, or make the colon a habit. And since the matcher is palette UI rather than control API, a release can retune its scoring without anything in this recipe failing loudly — it has already narrowed once since 0.19.1 — so the colon, not a mental model of the scoring, is the reliable escape.

The prompt crosses to the new session through a file in `$TMPDIR`, which is per-user and closed to other users on macOS — the question is the file's lifetime, not who can read it. The session's shell deletes it as its first act, and the script deletes it itself when `session new` fails, so both ordinary outcomes remove it within the session's startup. What leaks is the in-between: a session that opens and then dies before its shell runs leaves the file behind, holding the prompt's text until macOS's periodic temp cleanup collects it. Fine for a work request; still not the place for a secret.

The picker holds at most 1000 items and rejects a longer list outright instead of truncating it. The script counts first and posts a banner explaining the number, so an over-long list is refused with a reason rather than cut short.

Only one picker can be open per window. Pressing the key while one is already open in that window fails with `pick already pending`, which arrives as a failure banner.
