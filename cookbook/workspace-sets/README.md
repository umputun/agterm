# Workspace sets

Bind named groups of workspaces to keys and switch the sidebar between them, one chord per group.

## What it does

A set is a named list of workspace names, written into the script rather than passed to it. `agt-sets.sh work` marks exactly the workspaces in the `work` set, unmarks everything else, and applies the sidebar filter, so the tree shows that group alone. Bind one keymap entry per set and each group is one chord away. Nothing is closed.

Pressing the chord for the group already on screen suspends the filter instead, putting the whole tree back with the group still marked. Press it again and the tree narrows to the same group. So the same key both switches to a group and peeks past it.

This is the second answer to [discussion #293](https://github.com/umputun/agterm/discussions/293), where the ask was folders above workspaces. The sibling [project-switcher](../project-switcher/) recipe answers it by matching a name prefix, which is shorter and stays correct as you add workspaces, at the price of naming every workspace to carry its project. This one takes an explicit list, so workspaces keep whatever names they already have and a group can hold names with nothing in common. The cost is the other way round: a new workspace is not in any group until you add it.

## Requirements

- agterm 0.18.0 or later. `workspace filter` and the `workspace focus add` mode shipped in that release.
- `jq`

## Setup

Copy the script somewhere on your `PATH` and make it executable:

```sh
mkdir -p ~/bin
cp agt-sets.sh ~/bin/
chmod +x ~/bin/agt-sets.sh
```

Edit the block between the `--- sets ---` markers. One `case` arm per group, one workspace name per line, matched exactly:

```sh
work)
	cat <<-'EOF'
		umputun.dev
		agterm
		ai-thingz
	EOF
	;;
```

Names holding spaces need no quoting, because each line is one name. Add as many arms as you want; nothing below the block counts them.

Then add one entry per group to `~/.config/agterm/keymap.conf`:

```
command "focus work"     ctrl+a>1  ~/bin/agt-sets.sh work
command "focus personal" ctrl+a>2  ~/bin/agt-sets.sh personal
```

`ctrl+a>1` is a leader sequence: press ⌃A, release, then press 1. Any chord carrying a modifier works as the leader, and the second key needs none. Leave the chord out entirely and the entry is palette-only, which scales better past three or four groups.

Apply the file with File ▸ Reload Keymap or `agtermctl keymap reload`.

Fired from a chord or the palette, the script runs under the app's `PATH` rather than your shell's. That is the launchd default: `/usr/local/bin` plus the system directories, with no `/opt/homebrew/bin` and nothing else your profile adds. `agtermctl` normally resolves there, because **Help ▸ Install Command Line Tool…** symlinks it into `/usr/local/bin`. `jq` resolves only if it is a system one; recent macOS ships `/usr/bin/jq`, but a Homebrew `jq` is out of reach and needs its absolute path written into the script. Set `AGTERMCTL` to the binary's full path if yours sits somewhere unusual.

## Usage

Press ⌃A, release, then the group's key. Custom commands also appear in the ⌃⇧P action palette marked `custom`, and ⌃⇧O opens a palette holding the custom ones alone, so every group is reachable by name without a chord.

The same chord twice puts the whole tree back. A third press narrows to the group again.

```sh
agt-sets.sh work
```

Run it from a shell when the result looks wrong. It prints nothing on success and sends its complaints to stderr, so a shell is where you see a set naming a workspace that no longer exists.

## How it works

Three commands do the work, the same three the sibling recipe uses. `agtermctl tree --json` lists the window's workspaces with their ids, names and membership. `workspace focus add|off --target <id>` marks or unmarks one workspace. `workspace filter on|off` applies or suspends the whole set for the window.

One `tree` read answers every question the script has: which workspaces exist, which are already marked, and whether the filter is applied. Everything after it is `jq` over that one snapshot, so the state cannot shift underneath the decision.

The peek is a set comparison. The script sorts the ids currently marked and the ids the group resolves to, and if they match while the filter is applied, the chord means "show me everything" rather than "apply this again", so it suspends the filter and stops. The set is left marked, which is what makes the next press narrow straight back.

Otherwise it rebuilds. The filter goes off first, then every workspace gets `add` or `off` by whether its name is in the group, then the filter goes on. An `add` never switches the filter on by itself, but a filter left applied would hide the rows still to be marked, so the rebuild happens with the whole tree on screen.

Names are matched exactly, which is why the list is newline separated rather than a space separated string. A workspace called `A / frontend` is one name, and splitting on spaces would quietly turn it into three that match nothing.

One shell detail cost real time and is worth stating plainly. The set lookup is captured as `if ! wanted=$(workspaces_in "$name")`, not piped through `sed` in the same assignment, because a pipeline reports the exit status of its **last** command. Piping the lookup straight into `sed` swallows the unknown-set failure, and the script then reports a set that matched no workspace rather than a set that does not exist.

Read the result back the way the script does. Each workspace node carries `focused` when it is a member of the marked set, and the tree's top level carries `workspaceFilter` for the flag. The two are reported independently, so a script can record a working set and put it back exactly as it was.

## Limits

Nothing here closes anything. Applying a group only changes what the sidebar shows, and every workspace, session and shell outside the group keeps running.

The groups are a list you maintain. A workspace you create later belongs to no group until you add it, and renaming one drops it out of its group silently as far as the sidebar is concerned. The script does print a complaint naming it, but a chord throws that away, so the first sign is a group that comes up one workspace short.

The filter is per window. The script reads and writes the frontmost window's tree, so a group spread across two windows needs a run in each.

`workspace filter on` with nothing marked is refused, and the script stops before that with an error of its own when a group matches no workspace at all. Either way the sidebar is left unfiltered rather than blank.

Selecting a session outside the marked set switches the filter off and keeps the set, so jumping out and back costs one more press of the same chord.

The flagged sidebar view is a flat session list and ignores the filter entirely.

`ctrl+a` becomes a leader once bound, so agterm consumes it and it no longer reaches the terminal. If you rely on ⌃A for beginning-of-line in readline, or as a tmux prefix, pick another leader.
