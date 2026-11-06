# Flag recent agents

One chord lists the sessions whose agents reported a status lately, lets you untick any, and flags the rest.

## What it does

With a dozen sessions open, the ones that matter right now are the ones an agent touched in the last half hour: the one working, the one that just finished, the one waiting on you. `agt-flag-recent.sh` finds them and shows them in a checkbox dialog, all ticked, with each session's status, how long ago it was set, and its title-bar context line when it has one. Press Return to accept, or untick what you do not care about first. OK replaces the window's flagged set with the ticked sessions and switches the sidebar to the flagged view; Cancel or Esc changes nothing.

A session counts when its status is `active` now, or when its status was last written within `FLAG_RECENT_MINUTES` (30 by default), whatever that status was.

It pairs with the [flagged-dashboard](../flagged-dashboard/) recipe: press this chord to pick the recent sessions, then that one to grid the panes among them that are running something. Recently touched sessions now sitting at a shell prompt get no cell there.

## Requirements

- agterm 0.38.0 or later. That release added the checkbox form to `agtermctl ask` (`--choice`, `--multiple`, `--checked`). The recency rule also relies on 0.31.0, which stamps `statusChangedAt` on every accepted status write, idle included.
- `jq`

## Setup

Copy the script somewhere stable and make it executable:

```sh
mkdir -p ~/bin
cp agt-flag-recent.sh ~/bin/
chmod +x ~/bin/agt-flag-recent.sh
```

Then add an entry to `~/.config/agterm/keymap.conf`:

```
command "Flag Recent" ctrl+shift+u --error-hud ~/bin/agt-flag-recent.sh
```

Apply the file with File ▸ Reload Keymap or `agtermctl keymap reload`. Any free chord works, a leader sequence such as `ctrl+a>u` included. `--error-hud` puts a panel over the session when the script fails, since a chord otherwise throws its stderr away.

This is a keymap or palette command, not a shell command: the custom-command runner supplies `AGT_SOCKET` and `AGT_WINDOW_ID`, and the script refuses to run without the socket.

Custom commands do not load your shell profile. agterm prepends its bundled CLI directory and adds `/usr/local/bin` and `/opt/homebrew/bin` to `PATH`. Override these variables in the keymap line when needed:

- `FLAG_RECENT_MINUTES`: how far back a status write counts. Default `30`.
- `JQ`: path to `jq`. Default `jq`.
- `AGTERMCTL`: path to `agtermctl`. Default `agtermctl`.

```
command "Flag Recent" ctrl+shift+u --error-hud FLAG_RECENT_MINUTES=60 ~/bin/agt-flag-recent.sh
```

## Usage

Press the chord, untick anything you want left out, and press Return. Press it again later to rebuild the set; switch back to the full tree with the flagged-view footer button or `agtermctl sidebar mode tree`.

## How it works

One `agtermctl tree --json --window` read gives every session node its `status`, `statusChangedAt` (the epoch second its status was last written) and `context`. A `jq` filter keeps the `active` ones and those stamped after the cutoff, and turns each into a dialog row.

`agtermctl ask open --multiple` with one `--choice`, `--choice-subtitle` and `--checked` per row draws the checkbox list. A form like this gets OK and Cancel buttons with OK as the default, and blocks until answered. OK prints `{"result":"answered","id":"ok","selected":[...]}`; Cancel and Esc exit 3, and a cancel from elsewhere exits 2, which the script treats as "leave the flags alone" so `--error-hud` stays quiet. Only after an OK does it run `session flag clear` for the window, `session flag on` for each ticked id, and `sidebar mode flagged`.

`statusChangedAt` records when a status was written, not when it changed, so a hook re-asserting `active` on every tool call keeps refreshing it. That is what makes a plain cutoff enough.

## Limits

**OK replaces every flag in the window, including flags you set by hand.** Unticking every row and pressing OK clears the set and leaves an empty flagged view. With no recent sessions at all, the script shows a short notice and changes nothing.

The set is a snapshot. A session that starts working after the run is not added, and one whose blocked or completed status is older than the cutoff drops out on the next run even though nobody has dealt with it.

Any accepted status write counts, a cleared or idle one included, so the rule is status recency rather than proof that an agent did work.

Status and its timestamp are not saved. After agterm restarts every local session starts with no status and no stamp, so nothing matches until agents report again.

The dialog holds at most 50 rows. More recent sessions than that and `ask` refuses before any flag changes, which `--error-hud` shows.

The flags go to the window the chord fired in, but `sidebar mode` acts on whichever window is frontmost when that last call runs. Switching windows during the run switches the wrong window's sidebar.
