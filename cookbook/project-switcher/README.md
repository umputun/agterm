# Project switcher

Show one project's workspaces in the sidebar and hide the rest, without closing anything.

Ported from [discussion #293](https://github.com/umputun/agterm/discussions/293).

## What it does

`agt-only.sh A` marks every workspace whose name starts with `A` as the sidebar's focus set, unmarks the others, and applies the filter. The sidebar then shows that project's workspaces only. Session navigation follows the filter, so `session go`, Ctrl-Tab, attention navigation and the ⌃P session palette are all scoped to the marked workspaces while it is applied.

Run it again with another prefix to swap projects. The marked set and the filter flag are independent, so `agtermctl workspace filter off` puts the whole tree back on screen without losing the selection, and `workspace filter on` narrows it again.

## Requirements

- agterm 0.18.0 or later. `workspace filter` and the `workspace focus add` mode shipped in that release.
- `jq`
- workspace names carrying a per-project prefix, for example `A / frontend` and `A / backend`

## Setup

Copy the script somewhere on your `PATH` and make it executable:

```sh
mkdir -p ~/bin
cp agt-only.sh ~/bin/
chmod +x ~/bin/agt-only.sh
```

Add one entry per project to `~/.config/agterm/keymap.conf`:

```
command "only A"  ~/bin/agt-only.sh "A"
command "only B"  ctrl+alt+1  ~/bin/agt-only.sh "B"
```

The token after the quoted name is a key chord when it carries a modifier. Leave it out and the entry is palette-only, which scales better than chords once there are more than two or three projects. Apply the file with File ▸ Reload Keymap or `agtermctl keymap reload`.

Fired from a key chord or the palette, the script runs under the app's `PATH` rather than your shell's. That is the launchd default: `/usr/local/bin` plus the system directories, with no `/opt/homebrew/bin` and nothing else your profile adds. Every binary the script calls has to resolve there or be written in full, `jq` as much as `agtermctl`. `agtermctl` normally does, because **Help ▸ Install Command Line Tool…** symlinks it into `/usr/local/bin`. `jq` does only if it is a system one; recent macOS ships `/usr/bin/jq`, but a Homebrew `jq` is out of reach and needs its absolute path written into the script. Set `AGTERMCTL` to the binary's full path if yours sits somewhere unusual.

A binary that does not resolve fails silently here. A custom command's output goes nowhere, and a missing `jq` breaks the marking loop from inside a pipeline, which `set -e` does not catch, so the script still reaches its final `workspace filter on` and the sidebar comes back showing the set from the previous run. Run the script from a shell if the result looks wrong; that is where the error text goes.

## Usage

```sh
agt-only.sh A
```

Or press ⌃⇧P, type the project name and hit Enter. Custom commands appear in the action palette marked `custom`. ⌃⇧O opens a palette holding the custom commands alone, which is the shorter route once you have a few of these.

To see the whole tree again without losing the set, use the grid button in the sidebar's bottom bar, View ▸ Toggle Workspace Filter, or `agtermctl workspace filter off`.

## How it works

Three commands do the work. `agtermctl tree --json` lists the window's workspaces with their ids and names. `workspace focus add|off --target <id>` marks or unmarks one workspace. `workspace filter on|off` applies or suspends the whole set for the window.

The script suspends the filter before it touches the set. An `add` never switches the filter on by itself, and that is deliberate: a mark that narrowed the tree would hide the rows still to be marked. So the script unmarks and marks with the full tree on screen, then applies once at the end.

Read the result back from `agtermctl tree --json`: each workspace node carries `focused` when it is a member of the set, and the tree's top level carries `workspaceFilter` for the flag. The two are reported independently, so a script can record a working set and put it back exactly as it was.

## Limits

The recipe rests on a naming convention. It matches workspaces by name prefix, so it only works if you name workspaces per project, and a prefix that is also the start of another project's name matches both. If prefixes do not fit how you think about your projects, key off something else: a file listing workspace names per project, the session working directory, a flag. The three commands are the same either way.

The filter is per window. The script acts on the frontmost window's tree, so a project spread across two windows needs a run in each.

`workspace filter on` with nothing marked is refused. It returns ok having changed nothing, so a prefix that matches no workspace leaves the sidebar unfiltered rather than blank.

Selecting a session outside the marked set switches the filter off and keeps the set, so jumping out and back costs one `workspace filter on`.

The flagged sidebar view is a flat session list and ignores the filter entirely.
