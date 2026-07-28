# Status announcer

Speak agent status changes out loud from a dedicated session, as a worked example of wiring the event stream to something.

## What it does

This one is a demonstration rather than a tool. Talking terminals get old within the hour, and nothing here is meant to survive on your machine past the afternoon you try it. What it is good for is showing the shape of a non-trivial event-driven flow end to end, because every piece of it is a piece you would need for something you did want to keep: subscribing to the stream, filtering it, resolving the ids an event carries into names, and running the whole thing somewhere that survives you switching sessions.

"Toggle Status Announcer" in the command palette creates a session named `status-announcer` running an event loop, and closes it when one is already running. While it runs, every session that goes `blocked`, `completed` or `idle` is announced through `say`, naming the workspace and the session: "umputun dev, api fix blocked".

Starting it does not pull you into it. The session is created in the background, so your selection and focus stay where they were. It also keeps a log of what it heard, one line per event, which is what you look at when you want to know whether it is working:

```
status announcer: listening for blocked completed idle
run the toggle again to stop

13:57:52  umputun.dev / api-fix  blocked
13:57:56  far.side / remote-agent  completed
```

The log keeps the real names; only the spoken copy is flattened for pronunciation.

`active` is not announced. The agent-status hooks re-assert it on every tool call, so a loop that spoke it would never stop talking.

If you want the shape without the voice, replace `say` with a `curl` to ntfy or Telegram, an append to a journal file, or a Stream Deck key. The rest of the script stays as it is.

## Requirements

- agterm 0.16.0 or later. Event subscription through `agtermctl events` shipped in that release.
- `jq`
- `say` and `/bin/zsh`, both of which come with macOS

## Setup

Copy the script somewhere on your `PATH` and make it executable:

```sh
mkdir -p ~/bin
cp agt-announce.sh ~/bin/
chmod +x ~/bin/agt-announce.sh
```

Add one entry to `~/.config/agterm/keymap.conf`:

```
command "Toggle Status Announcer"  /bin/zsh -lc '~/bin/agt-announce.sh'
```

No chord, so the entry is palette-only, which suits something you turn on once and forget. Add one if you want it on a key: the token after the quoted name is a chord when it carries a modifier.

The login shell in that line is load-bearing. A custom command runs under the app's `PATH` rather than yours, which is the launchd default: `/usr/local/bin` plus the system directories, with no `/opt/homebrew/bin`. `agtermctl` resolves there because **Help ▸ Install Command Line Tool…** symlinks it into `/usr/local/bin`, but a Homebrew `jq` does not, and a custom command's output goes nowhere, so it would fail with nothing on screen to say why. `/bin/zsh -lc` sources your profile and puts your own `PATH` back.

Apply the file with File ▸ Reload Keymap or `agtermctl keymap reload`.

Two variables at the top of the script are worth knowing about. `ANNOUNCER_NAME` is the session name the toggle matches on, and `SPOKEN` is the space-separated list of statuses to announce.

## Usage

Press ⌃⇧P, type "announcer", hit Enter. ⌃⇧O opens a palette holding the custom commands alone, which is the shorter route. Run it again to close the session and stop.

To hear it do something without waiting for an agent:

```sh
agtermctl session status blocked --target <some-session-id>
agtermctl session status idle --target <some-session-id>
```

The script also runs from a shell, `agt-announce.sh` to toggle, which is where error text goes when something is wrong.

## How it works

`agtermctl events --json --kind status` prints one JSON object per status change and keeps printing. Each carries the session id, the window id, the workspace id, and a payload holding the session name and the new status. One `jq` filters the whole stream in a single pass: it drops the announcer's own session by comparing against `$AGTERM_SESSION_ID`, drops statuses outside `SPOKEN`, and emits the four fields it kept as a tab-separated line for a plain `read` loop.

`--unbuffered` on that `jq` is what makes announcements arrive per event. Without it jq buffers, and the voice waits for a block to fill.

The workspace name is the interesting part, because the event does not carry it. It carries the workspace id, so the loop reads `agtermctl tree --json --window <window>` and matches the id against `.result.tree.workspaces[]`. The `--window` matters: a bare `tree` projects the frontmost window, so an agent blocking in a background window would resolve to no workspace at all, and that only shows up once you have a second window open. Looking it up per event rather than caching a map and invalidating it on `tree.changed` costs nothing here, since these events fire only on real transitions.

The toggle searches every open window for the announcer, walking `agtermctl window list --json` and reading each window's tree, rather than looking only at the frontmost one. A frontmost-only search would fail to find an announcer started from another window and start a second one talking over the first.

It creates the session with `--no-select`, which leaves your selection and focus untouched. Without it, turning the announcer on drops you into a session you have no reason to be looking at.

There are two login-shell wrappers, in two different places, for one reason. The keymap line wraps the toggle because a custom command runs under the app's `PATH`. The toggle wraps the loop, in the `--command` it hands to `session.new`, because that command is exec'd by the app under the same `PATH` and does not inherit anything from the toggle that asked for it.

`say` pronounces punctuation, so the phrase goes through `tr '._-' '   '` first. Otherwise a workspace named `umputun.dev` is announced as "umputun dot dev".

## Limits

**Toggling off closes the announcer session and kills the shell running in it.** The toggle matches by name, so if you already have a session called `status-announcer`, that is the one it closes. Change `ANNOUNCER_NAME` at the top of the script if the name is taken.

It is a demonstration, and the voice wears out its welcome quickly. Nothing here is worth keeping on for a working day.

The announcer session closes itself if the event stream ends, taking its log with it. `agtermctl events` exits non-zero on a cursor, transport, or server error, and a session created with `--command` closes when its command exits, so the session simply disappears. The script prints no parting message, because a session created that way is torn down before anything written on the way out could be read. Expected when agterm quits, confusing when a transient error takes it out while agterm keeps running: the announcer is gone and nothing said so. Toggle it back on.

Bursts are announced late, not dropped. `say` blocks until it finishes talking, so three sessions blocking at once are spoken one after another while the events queue behind them.

A session set to `completed --auto-reset` is announced twice: once when it completes, and again as `idle` when you visit it and the status clears. That falls out of announcing `idle` at all. Drop `idle` from `SPOKEN` if it bothers you.

Starting the announcer does not replay what it missed. The stream subscribes from the moment it starts, so anything that happened while it was off is gone.
