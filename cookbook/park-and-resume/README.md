# Park and resume

Put a project away by closing its workspaces, and bring it back later from a snapshot.

Ported from [discussion #293](https://github.com/umputun/agterm/discussions/293).

## What it does

`agt-park.sh A` records every workspace whose name starts with `A`, along with each session's name, working directory and the command it is running, into a JSON file. It then deletes those workspaces.

`agt-resume.sh A` reads that file back and recreates the workspaces and their sessions in the saved directories, re-running the captured commands.

**Parking closes the shells.** Every process in those sessions is killed, and the scrollback is gone. What comes back is a fresh shell per session, in the same directory, running the same command line. Read the *Limits* section before you use this.

The snapshot is plain JSON, so it can be edited by hand into the launch configuration you actually want, rather than whatever happened to be running when you parked.

## Requirements

- agterm 0.16.0 or later. `workspace new --collapsed` shipped in that release; the rest is older.
- `jq`
- `zsh`, whose login shell the replayed command runs under. *How it works* has the one-word change if your `PATH` comes from a bash profile instead.
- workspace names carrying a per-project prefix, for example `A / frontend` and `A / backend`

## Setup

Copy both scripts somewhere on your `PATH` and make them executable:

```sh
mkdir -p ~/bin
cp agt-park.sh agt-resume.sh ~/bin/
chmod +x ~/bin/agt-park.sh ~/bin/agt-resume.sh
```

Snapshots go to `~/.agterm-projects` by default. Set `AGT_PARK_DIR` to put them elsewhere; both scripts read the same variable, so they must agree. That variable reaches the scripts only when you run them from a shell: agterm never read your shell config, so an export in `.zshrc` or `.zprofile` does not carry into a run started from a key chord or the palette. Change the fallback in both scripts if you want a different directory there.

Add one pair of entries per project to `~/.config/agterm/keymap.conf`:

```
command "park A"    ctrl+alt+1  ~/bin/agt-park.sh "A"
command "resume A"  ctrl+alt+2  ~/bin/agt-resume.sh "A"
command "park B"                ~/bin/agt-park.sh "B"
command "resume B"              ~/bin/agt-resume.sh "B"
```

The token after the quoted name is a key chord when it carries a modifier. Leave it out and the entry is palette-only, which scales better than chords past two or three projects. Apply the file with File ▸ Reload Keymap or `agtermctl keymap reload`.

Fired from a key chord or the palette, the scripts run under the app's `PATH` rather than your shell's. That is the launchd default: `/usr/local/bin` plus the system directories, with no `/opt/homebrew/bin` and nothing else your profile adds. Every binary the scripts call has to resolve there or be written in full, `jq` as much as `agtermctl`. `agtermctl` normally does, because **Help ▸ Install Command Line Tool…** symlinks it into `/usr/local/bin`. `jq` does only if it is a system one; recent macOS ships `/usr/bin/jq`, but a Homebrew `jq` is out of reach and needs its absolute path written into the scripts. Set `AGTERMCTL` to the binary's full path if yours sits somewhere unusual.

## Usage

```sh
agt-park.sh A       # snapshot A's workspaces, then delete them
agt-resume.sh A     # recreate them from the snapshot
```

Or press ⌃⇧P and pick the entry by name. Custom commands appear in the action palette marked `custom`.

Resumed workspaces come back collapsed, so a resume does not rearrange the sidebar around you. Click a workspace row to open it.

## How it works

Park takes one `agtermctl tree --json` and uses it twice. The first pass builds the snapshot: for each matching workspace it keeps the name and, per session, the `name`, `cwd` and `foreground` fields. `foreground` is the live argv of the pane's foreground process, absent when the pane sits at its shell prompt and also when agterm cannot read the process, so either way the session is recorded with an empty command and comes back as a plain shell. *Limits* has what that second case costs. The second pass deletes the workspaces by id with `workspace delete --target`.

The snapshot is written to a temporary file and moved into place only when it holds at least one workspace. A capture that fails cannot destroy the previous snapshot, because `set -e` stops the script before the move and the deletions. Neither can a capture that succeeds and matches nothing: the temporary file is discarded, the prefix is reported on stderr, and the script exits non-zero without deleting anything. That is what makes a second park of the same prefix, or a park run with a different window frontmost, safe — both match nothing, and both leave the earlier snapshot in place.

Resume replays the file. Each workspace is created with `workspace new <name> --collapsed --json`, which returns the new id, and each session with `session new --workspace <id> --no-select --cwd <dir> --name <name>`, plus `--command` when one was captured. `--no-select` keeps the current selection and focus in place while the tree is rebuilt, and `--collapsed` keeps a resumed workspace out of the sidebar focus set, so a resume does not widen a filter you have applied.

agterm runs a `--command` value as `/bin/bash --noprofile --norc -c 'exec -l <command>'`, so the value passes through a shell and ordinary shell quote removal applies to it. That shell reads no profile, so it inherits the app's `PATH`: the launchd default, with no `/opt/homebrew/bin`.

What comes back from `foreground` is the argv as it was typed. A Homebrew-installed tool is recorded as `nvim`, not as `/opt/homebrew/bin/nvim`, and run straight under that `PATH` it would fail with exit 127. So the replay goes through a login shell instead: `jq` quotes each argument with `@sh`, joins them into one line, quotes that whole line again, and prefixes `zsh -lc`, which makes the `--command` value `zsh -lc '<the original line>'`. The login shell sources your profile, so the command resolves against the `PATH` you normally have. The second round of quoting is what keeps the line intact: an argument holding a space, a single quote or a glob survives both rounds of quote removal and replays as one argument rather than several.

`zsh -lc` is a non-interactive login shell, so it reads `.zshenv`, `.zprofile` and `.zlogin` and skips `.zshrc`. Use `zsh -ilc` if your `PATH` is set there, or `bash -lc` if it comes from a bash profile; either is a one-word change to the `"zsh -lc "` prefix in `agt-park.sh`. A hand-edited snapshot takes the same shape, so write `zsh -lc 'make watch'` rather than a bare `make watch`.

## Limits

**Parking closes the shells.** `workspace delete` kills every process in those sessions. A build, a dev server, an SSH connection or an agent running there dies with it. If that is not what you want, use the `project-switcher` recipe instead, which hides workspaces without closing anything.

**A resumed session is a fresh shell with no scrollback.** It starts in the saved directory and re-runs the captured command line. Nothing is reattached.

`workspace delete` keeps at least one workspace per window. Parking literally every workspace in a window leaves one behind, and the resume then adds the recreated ones alongside it.

Split panes are not restored. The snapshot records the main pane's command only, so a session that had a split comes back as a single pane.

Session names come back as explicit custom names, including the ones agterm had derived automatically.

A captured command line is re-quoted from its argv. A program invoked with unusual quoting may need the snapshot edited by hand before it replays correctly.

**A snapshot holds the full command line of everything that was running**, so it can contain an API token, a database connection string or a password that was passed as an argument. `agt-park.sh` sets `umask 077` before it creates anything, so a directory and a snapshot it creates come out `0700` and `0600`, readable by you alone. A directory that already exists keeps the mode it has, so `chmod 700` one left behind by an earlier copy of the script.

The snapshot can only record what the control API reports, and `foreground` comes back missing for two different reasons: the pane is idle at its shell prompt, or agterm could not read the process at all. The JSON does not distinguish them. A session whose process cannot be read is recorded as idle, comes back as a plain shell, and its workspace is deleted like any other, so the record of what it was running is gone with it. Look at `agtermctl tree --json` before parking if that matters.

Only processes are captured. A shell function or an alias is not one, so it never comes back by name: a session sitting in a function with nothing running under it is recorded with no command and returns as a plain shell, and one that had already started a program returns running that program directly.

The prefix is used as the snapshot file name, so it has to be usable as one. Parking is per window, since `tree` reports the frontmost window's workspaces.
