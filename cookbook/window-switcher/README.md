# Window switcher

Jump straight to a window by number, or pick one from a list that shows which windows have sessions waiting for you.

Grew out of [discussion #592](https://github.com/umputun/agterm/discussions/592).

## What it does

`window-switcher.sh goto 3` raises window number 3. One keymap line per number turns ⌘1…⌘9 into addresses: a window's number is its position in `agtermctl window list`, the library order File ▸ Open Window shows, closed windows included. So ⌘3 is always the same window no matter which one is frontmost, the numbers do not shift when a window closes, and ⌘N on a closed window opens it again. They move only when a bundle is deleted for good.

`window-switcher.sh pick` opens a native picker over every window. Each row carries its ⌘N shortcut on the left, a ● in place of the number on the window you are in, the window name, and a `◆ N` badge when the window has sessions needing attention. The subtitle says where the window stands, `general › api` for the workspace and the session selected there, or spells out up to two of the attention sessions with how long they have waited, `◆ api blocked 2m, worker done 5m, +1`. Type to filter by name, Return raises the window.

Nothing is closed or changed. The only thing either command does is raise a window.

## Requirements

- agterm 0.28.0 or later. The picker marks the current window with `window list`'s `active` flag, and 0.28.0 is where that flag stopped naming the previous window after another one was revealed; everything else the script uses, `window select`, `tree --window`, `pick` with subtitles and `statusChangedAt` on the tree, is older. With the release that ships `pick --select` (after 0.29.1) the picker opens on the current window; until then it opens on the first row.
- `jq`

## Setup

Copy the script somewhere on your `PATH` and make it executable:

```sh
mkdir -p ~/bin
cp window-switcher.sh ~/bin/
chmod +x ~/bin/window-switcher.sh
```

Add the picker and one line per number to `~/.config/agterm/keymap.conf`:

```
command "Pick Window"  cmd+opt+=  ~/bin/window-switcher.sh pick
command "Window 1"     cmd+1      ~/bin/window-switcher.sh goto 1
command "Window 2"     cmd+2      ~/bin/window-switcher.sh goto 2
command "Window 3"     cmd+3      ~/bin/window-switcher.sh goto 3
command "Window 4"     cmd+4      ~/bin/window-switcher.sh goto 4
command "Window 5"     cmd+5      ~/bin/window-switcher.sh goto 5
command "Window 6"     cmd+6      ~/bin/window-switcher.sh goto 6
command "Window 7"     cmd+7      ~/bin/window-switcher.sh goto 7
command "Window 8"     cmd+8      ~/bin/window-switcher.sh goto 8
command "Window 9"     cmd+9      ~/bin/window-switcher.sh goto 9
```

Bind as many numbers as you have windows; the picker shows ⌘N for the first nine either way, so a number without a line is a shortcut that does nothing. Apply the file with File ▸ Reload Keymap or `agtermctl keymap reload`.

Fired from a key chord or the palette, the script runs under the app's `PATH` rather than your shell's. That is the launchd default: `/usr/local/bin` plus the system directories, with no `/opt/homebrew/bin` and nothing else your profile adds. Every binary the script calls has to resolve there or be written in full, `jq` as much as `agtermctl`. `agtermctl` normally does, because **Help ▸ Install Command Line Tool…** symlinks it into `/usr/local/bin`. `jq` does only if it is a system one; recent macOS ships `/usr/bin/jq`, but a Homebrew `jq` is out of reach and needs its absolute path written into the script. Set `AGTERMCTL` to the binary's full path if yours sits somewhere unusual.

The gutter before the window name is made of spaces, since the picker has no columns, and the counts are tuned for the default palette font. If the names do not line up on your setup, set `PAD_SHORTCUT` (after `⌘N`), `PAD_CURRENT` (after `●`) and `PAD_NONE` (windows past the ninth) in the keymap line, `PAD_CURRENT='    ' ~/bin/window-switcher.sh pick`, and check the rows with `window-switcher.sh items` until they do.

## Usage

Press ⌘3 and window 3 comes forward, or comes back on screen if you had closed it. Press ⌘⌥= for the list, type part of a name or just look at the badges, Return raises the row, Escape leaves everything as it was.

From a shell:

```sh
window-switcher.sh goto 3
window-switcher.sh pick
window-switcher.sh items | jq .
```

`items` prints the rows the picker would show, so you can read the attention summary without opening it, or check the gutter after changing the padding.

The picker is for looking before you leap. For stepping, `previous_window` and `next_window` are built in since 0.29.0, keyless in the keymap and in Navigate ▸ Previous Window and Next Window. For going straight to a session that asked for you, ⌃⇧I is the attention list, and in the release after 0.29.1 it covers every open window.

## How it works

`agtermctl window list --json` returns every window with its `id`, `name`, `open` and `active`, in library order. The index in that array is the window's number, and `goto` is a lookup followed by `window select`, which raises an open window and opens a closed one, the same verb either way.

For the picker the script reads `agtermctl tree --window <id> --json` for each open window. A session node's `status` is `blocked`, `completed` or `active` when an agent has reported one, and `statusChangedAt` is the epoch second it was last written, so `now - statusChangedAt` is the age shown in the subtitle. Sessions in `blocked` or `completed` make up the badge, the same set ⌃⌥↑/↓ walk within a window; `active` is not waiting for anyone and is left out. The session on screen in the current window is left out of its window's badge too, since you can already see it. Closed windows have no tree and get no round trip. An auto-named session is named after its working directory, which does not fit a picker row, so a path-like name is cut down to its last component.

The rows go to `agtermctl pick` as JSON with `id`, `label` and `subtitle`. The picker matches the query against labels only, so the attention text in a subtitle never filters a row in or out, and an empty query keeps the supplied order, which is what makes the row order the window order. When the CLI knows `--select`, the picker opens on the current window's row, so Return on an untouched list stays put and ↑/↓ read as the window above and below. The script checks for the flag with `agtermctl pick open --help`, because an older CLI rejects an unknown option before it opens anything; the check costs no socket round trip and lets the same script run on either side of that release.

`pick` has no columns, so the shortcut gutter is spaces, counted so that `⌘N` plus its padding, `●` plus its padding and the no-shortcut padding come out the same width in the palette font. The subtitle is set in a smaller font, so no whole number of spaces would line it up with the name, and it is deliberately not indented; a near miss looks worse than none.

From a chord the script's output goes nowhere, so a missing `jq` shows up as a picker that never opens rather than as an error. Run the script from a shell to see what it says.

## Limits

Nothing here closes or deletes anything. The one thing to know before pressing a number is that ⌘N on a closed window opens it again, exactly as File ▸ Open Window would, and its sessions start along with it.

Numbers are stable across closing and reopening but not across deletion: `delete_window` on a bundle shifts every window after it down by one. Nine chords cover nine windows; the rest are in the picker without a shortcut.

The gutter is tuned by hand for the default palette font. Change the font size in Settings and the names stop lining up until the padding is retuned. The subtitle line cannot be aligned at all.

Until the release that ships `pick --select`, the picker opens on the first row, so Return on an untouched list goes to window 1 rather than staying where you are.

Attention is the agent status as reported over `session status`, so only sessions whose agent reports it get a badge. The age is the age of the last write, not of the first: a hook that re-asserts `blocked` on every event keeps the counter fresh. Status is never persisted, so right after a restart every badge is gone. The notification badge on the sidebar row is a different thing and is not counted.

The picker opens after one `tree` read per open window. With a handful of windows that is not noticeable; with a couple of dozen it is a pause before the list appears.
