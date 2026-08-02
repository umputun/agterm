# Flagged dashboard

Grid the flagged panes that are actually running something, one chord, and dismiss them with the same key.

## What it does

Flagging marks the sessions you care about right now, and the flagged sidebar view lists them by name. This recipe shows that set as live terminals instead, minus the panes that have nothing to show: `agt-flagged-dashboard.sh` takes the flagged sessions, keeps only the panes running a foreground command, and opens the dashboard grid over those. Flag the three agents you are babysitting, press the chord, and watch all three at once; arrow keys move the highlight, Enter drops into one and closes the grid.

The unit is a pane, not a session, which is what makes the filter worth having. A split session whose left pane sits at a prompt while its right pane runs a build contributes one cell, not two, so the cells go to work you are waiting on rather than to idle shells. A pane whose split is hidden still counts: if it is running something, it earns a cell, and the grid becomes the only place you can see it.

Pressing the chord while the grid already shows that same set closes it, so the key both opens and dismisses. Start something in another flagged pane first and the same press reopens the grid with it included.

⌘⇧D already grids a window's most-recently-used sessions, which is a different question. Recency is what you touched last, not what is working: a build you started twenty minutes ago and have not typed in since is exactly the thing that falls off the recent list while still being the thing you want on screen.

## Requirements

- agterm 0.20.0 or later. The grid itself is older, but naming one pane of a session with an `<id>:left` / `<id>:right` suffix shipped in 0.20.0, and skipping the idle half of a split is the whole point here.
- `jq`

## Setup

Copy the script somewhere on your `PATH` and make it executable:

```sh
mkdir -p ~/bin
cp agt-flagged-dashboard.sh ~/bin/
chmod +x ~/bin/agt-flagged-dashboard.sh
```

Then add an entry to `~/.config/agterm/keymap.conf`:

```
command "Flagged dashboard" ctrl+shift+g ~/bin/agt-flagged-dashboard.sh
```

Apply the file with File ▸ Reload Keymap or `agtermctl keymap reload`. Any free chord works; ⌃⇧G collides with no built-in. Leave the chord out entirely and the entry is palette-only.

Nothing else needs configuring, because the recipe has no list to maintain: flagging is the configuration. ⌘⇧F flags and unflags the selected session out of the box, and View ▸ Flag Session does the same from the menu.

Fired from a chord or the palette, the script runs under the app's `PATH` rather than your shell's. That is the launchd default: `/usr/local/bin` plus the system directories, with no `/opt/homebrew/bin` and nothing else your profile adds. `agtermctl` normally resolves there, because **Help ▸ Install Command Line Tool…** symlinks it into `/usr/local/bin`. `jq` resolves only if it is a system one; recent macOS ships `/usr/bin/jq`, but a Homebrew `jq` is out of reach and needs its absolute path written into the script. Set `AGTERMCTL` to the binary's full path if yours sits somewhere unusual.

## Usage

Flag a few sessions with ⌘⇧F, then press the chord. Press it again to dismiss the grid, or Esc, which closes it the same way.

```sh
agt-flagged-dashboard.sh
```

Run it from a shell when the grid looks wrong. It prints nothing on success and sends its complaints to stderr, so a shell is where you see that nothing flagged is running, or that the set was too big to fit and got trimmed. A chord throws both away.

## How it works

One read and one write. `agtermctl tree --json` returns the frontmost window's tree, and every session node carries what the selection needs: `flagged`, plus `foreground` and `splitForeground`, the live foreground command of the main and split panes. A pane sitting at its shell prompt reports no foreground at all, so `select(.flagged)` combined with a presence test on those two fields is the entire rule — there is no process inspection to do, and no list of "interesting" commands to maintain.

Each surviving pane becomes an `<id>:left` or `<id>:right` reference, and `agtermctl dashboard <ref> <ref> … --auto-size` opens the grid over exactly those. Passing a bare session id instead would take every pane of the session, idle ones included, which is the behavior this recipe exists to avoid.

One `tree` read answers every question the script has. Reading twice would let a command finish in between and produce a decision that matches neither state.

The toggle is a set comparison against the tree's top-level `dashboardMembers`, which reports the grid's cells in the same `<id>:left` / `<id>:right` form the script writes, so the two round-trip without any translation. Equal sets mean the grid is already the one this chord would build, so the chord closes it instead.

A full grid needs a second rule. The grid holds nine cells and drops the rest, so once the set overflows, what is on screen can never equal what the script would open, and a plain equality test would leave the chord unable to ever close it. A grid holding nine cells that are all cells the script wants therefore counts as a match too. Unflagging something that is on screen still fails that test, which is what keeps the refresh working.

`--auto-size` sizes the cells relative to your Settings font, shrinking them as the grid grows. It is what ⌘⇧D uses, so a flagged grid and a recent-sessions grid look alike. Swap in `--font-size N` for an absolute size in points if you would rather the cells stay put whatever the count.

## Limits

Nothing here closes a session, kills a shell, or changes a flag. The grid is an overlay that comes and goes, and everything it shows keeps running whether it is on screen or not.

A pane counts as busy only when agterm can read its foreground command, and there are cases where it cannot. A session started with `session new --command` runs its program under `login` and reports no foreground, so it is treated as idle and left off the grid even while it works. The same applies to a setuid or setgid program such as `sudo` or `top`, whose argv macOS will not expose. Start the program by typing it in a session, or from a shell wrapper, and it reports normally.

Membership is fixed when the grid opens. A command that finishes while you are watching leaves its pane on the grid, now sitting at a prompt, and a pane that starts working is not added. Press the chord again to rebuild the set.

The grid holds nine cells. Past that the extra panes are dropped, the script reports the trim on stderr, and a chord discards it, so the visible symptom is a grid that is short. Overflowing also costs the toggle one press: with the set trimmed, flagging or starting something new leaves the chord closing the grid rather than refreshing it, so seeing the new arrangement takes a second press.

Everything is scoped to the frontmost window. The script reads `tree` and calls `dashboard` without a window selector, so flagged sessions in another window are not part of the set and need a run in that window.

The toggle recognises the set, not who opened it. A ⌘⇧D recent-sessions grid that happens to hold exactly these panes will be closed by the chord rather than reopened.

The grid is view-only, so no cell takes keyboard input. Opening and closing it does resize each pane's pty to its cell, so a full-screen program may redraw as the grid appears and again as it goes.
