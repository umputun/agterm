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
- workspace names carrying a per-project prefix, for example `A / frontend` and `A / backend`

## Setup

Copy both scripts somewhere on your `PATH` and make them executable:

```sh
mkdir -p ~/bin
cp agt-park.sh agt-resume.sh ~/bin/
chmod +x ~/bin/agt-park.sh ~/bin/agt-resume.sh
```

Snapshots go to `~/.agterm-projects` by default. Set `AGT_PARK_DIR` to put them elsewhere; both scripts read the same variable, so they must agree.

Add one pair of entries per project to `~/.config/agterm/keymap.conf`:

```
command "park A"    ctrl+alt+1  ~/bin/agt-park.sh "A"
command "resume A"  ctrl+alt+2  ~/bin/agt-resume.sh "A"
command "park B"                ~/bin/agt-park.sh "B"
command "resume B"              ~/bin/agt-resume.sh "B"
```

The token after the quoted name is a key chord when it carries a modifier. Leave it out and the entry is palette-only, which scales better than chords past two or three projects. Apply the file with File ▸ Reload Keymap or `agtermctl keymap reload`.

If `agtermctl` is not on your `PATH`, set `AGTERMCTL` to its full path in the environment the scripts run in.

## Usage

```sh
agt-park.sh A       # snapshot A's workspaces, then delete them
agt-resume.sh A     # recreate them from the snapshot
```

Or press ⌃⇧P and pick the entry by name. Custom commands appear in the action palette marked `custom`.

Resumed workspaces come back collapsed, so a resume does not rearrange the sidebar around you. Click a workspace row to open it.

## How it works

Park takes one `agtermctl tree --json` and uses it twice. The first pass builds the snapshot: for each matching workspace it keeps the name and, per session, the `name`, `cwd` and `foreground` fields. `foreground` is the live argv of the pane's foreground process, absent when the pane sits at its shell prompt, so a session at a prompt is recorded with an empty command and comes back as a plain shell. The second pass deletes the workspaces by id with `workspace delete --target`.

The snapshot is written to a temporary file and moved into place only when it holds at least one workspace. A capture that fails cannot destroy the previous snapshot, because `set -e` stops the script before the move and the deletions. Neither can a capture that succeeds and matches nothing: the temporary file is discarded, the prefix is reported on stderr, and the script exits non-zero without deleting anything. That is what makes a second park of the same prefix, or a park run with a different window frontmost, safe — both match nothing, and both leave the earlier snapshot in place.

Resume replays the file. Each workspace is created with `workspace new <name> --collapsed --json`, which returns the new id, and each session with `session new --workspace <id> --no-select --cwd <dir> --name <name>`, plus `--command` when one was captured. `--no-select` keeps the current selection and focus in place while the tree is rebuilt, and `--collapsed` keeps a resumed workspace out of the sidebar focus set, so a resume does not widen a filter you have applied.

agterm runs a `--command` value as `/bin/bash --noprofile --norc -c 'exec -l <command>'`, so the value passes through a shell and ordinary shell quote removal applies to it. That is why the snapshot quotes each argument with jq's `@sh`: a working directory or an argument containing spaces survives the round trip and replays as one argument rather than several.

The captured argv is absolute, for example `/opt/homebrew/bin/nvim` rather than `nvim`, so `--command` runs it directly. That matters because the shell above reads no profile and inherits the app's GUI `PATH`, which does not include the usual Homebrew directory. A relative command name would fail with exit 127.

## Limits

**Parking closes the shells.** `workspace delete` kills every process in those sessions. A build, a dev server, an SSH connection or an agent running there dies with it. If that is not what you want, use the `project-switcher` recipe instead, which hides workspaces without closing anything.

**A resumed session is a fresh shell with no scrollback.** It starts in the saved directory and re-runs the captured command line. Nothing is reattached.

`workspace delete` keeps at least one workspace per window. Parking literally every workspace in a window leaves one behind, and the resume then adds the recreated ones alongside it.

Split panes are not restored. The snapshot records the main pane's command only, so a session that had a split comes back as a single pane.

Session names come back as explicit custom names, including the ones agterm had derived automatically.

A captured command line is re-quoted from its argv. A program invoked with unusual quoting may need the snapshot edited by hand before it replays correctly.

The prefix is used as the snapshot file name, so it has to be usable as one. Parking is per window, since `tree` reports the frontmost window's workspaces.
