# Window per project

Give each project its own window, then switch between them by parking the rest in the Dock.

Ported from [discussion #293](https://github.com/umputun/agterm/discussions/293).

## What it does

`agt-win.sh "Project A"` minimizes every other open window to the Dock and raises the one named `Project A`. One entry per project turns a set of windows into a switcher: whichever project you pick is the only one on screen, and the others sit in the Dock until you pick them.

A window is a named bundle of workspaces and sessions with its own sidebar, persisted and reopened at the next launch. Nothing is closed here, so shells keep running in the parked windows.

## Requirements

- agterm 0.17.1 or later. `window minimize` and the `minimized` read-back on `window list` shipped in that release.
- `jq`
- one window per project, each with a distinct name. Create them from the File menu (New Window, then Rename Window…) or with `agtermctl window new "Project A"`.

## Setup

Copy the script somewhere on your `PATH` and make it executable:

```sh
mkdir -p ~/bin
cp agt-win.sh ~/bin/
chmod +x ~/bin/agt-win.sh
```

Add one entry per project to `~/.config/agterm/keymap.conf`:

```
command "go A"  ctrl+alt+1  ~/bin/agt-win.sh "Project A"
command "go B"              ~/bin/agt-win.sh "Project B"
```

The token after the quoted name is a key chord when it carries a modifier. Leave it out and the entry is palette-only. Apply the file with File ▸ Reload Keymap or `agtermctl keymap reload`.

Fired from a key chord or the palette, the script runs under the app's `PATH` rather than your shell's. That is the launchd default: `/usr/local/bin` plus the system directories, with no `/opt/homebrew/bin` and nothing else your profile adds. Every binary the script calls has to resolve there or be written in full, `jq` as much as `agtermctl`. `agtermctl` normally does, because **Help ▸ Install Command Line Tool…** symlinks it into `/usr/local/bin`. `jq` does only if it is a system one; recent macOS ships `/usr/bin/jq`, but a Homebrew `jq` is out of reach and needs its absolute path written into the script. Set `AGTERMCTL` to the binary's full path if yours sits somewhere unusual.

A binary that does not resolve shows up here as a wrong answer rather than an error: with no `jq` the name lookup returns nothing and the script stops with `no window named …`, which is also what a genuine typo produces. Run it from a shell to see which one it is.

## Usage

```sh
agt-win.sh "Project A"
```

Or press ⌃⇧P and pick the entry by name. Custom commands appear in the action palette marked `custom`.

The script is optional convenience. File ▸ Open Window already lists every window by name with a checkmark on the open ones, and ⌘` cycles them. What the script adds is the parking: the others go to the Dock instead of staying stacked behind the one you raised.

## How it works

`agtermctl window list --json` returns every window with its `id`, `name`, `open` and `minimized` state. The script finds the target id by name, minimizes every other open window with `window minimize <id> on`, then raises the target with `window select <id>`.

The mode word on `minimize` is explicit rather than the default `toggle`, so repeated runs are idempotent: a window already in the Dock stays there instead of popping back out.

`window select` deminiaturizes, so a project parked last week comes back from the Dock with the same command. It also opens a window you had closed entirely, which is why the target is not filtered on `open`.

Closed windows are skipped when parking, because `window minimize` requires an open window and answers `window not open — window.select it first` otherwise. A window that cannot be parked is written to stderr and the script carries on, so one awkward window does not stop the switch. Expect that message only in a shell run: agterm sends a custom command's output to `/dev/null`, and the `||` that keeps the loop going also keeps the exit status at zero, so from a chord or the palette a skipped window produces nothing at all, not even a failure banner.

Read the result back from `window list --json`: `minimized` says which windows are in the Dock, and `geometry` still reports the frame a minimized window will come back to.

## Limits

Minimize is rejected on a window in native full screen. AppKit does nothing on `miniaturize` there, so agterm answers `cannot minimize a full-screen window — window.fullscreen it first` rather than claiming success. Exit full screen, or use `agtermctl window fullscreen` first.

The minimized state is never persisted. Every window reopens un-minimized after a restart, so a script that parks windows has to run again once agterm is back.

Windows are matched by name, and the first match wins if two windows share a name. A name that matches nothing is an error, reported before anything is parked.

Sessions and workspaces cannot be moved between windows. Reorganizing across projects means recreating, not dragging.

Ctrl-Tab, the ⌃P session palette, attention navigation and auto-follow are per window, so splitting projects across windows splits those too.
