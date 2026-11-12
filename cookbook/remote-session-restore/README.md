# Remote session restore

Attach again, after a relaunch, the sessions from other Macs that were attached when agterm quit.

Author: [@maxshevelev](https://github.com/maxshevelev), from [discussion #932](https://github.com/umputun/agterm/discussions/932)

## What it does

agterm never writes a session attached from another Mac to disk, so a relaunch brings back your local
sessions and none of the remote ones. This recipe keeps a list of the attached rows while agterm runs and,
at the next launch, attaches each of them again into the window and workspace it was in when agterm quit,
following a row you moved to another workspace. Companions
rejoin their parent, and page rows come back as well.

A row is on the list from the moment it is attached until you close it or close its window. Quitting
agterm, or agterm crashing, leaves the list as it was, which is what the next launch replays.

## Requirements

agterm 0.42.0 or later, which added `remoteSessionID` to the `remote.opened` / `remote.closed` events,
plus `jq`.

The far side needs:

- agterm 0.26.0 or later, since the check before each attach runs `zmx tree` over there;
- its restore mode set to **Live sessions**, which is what puts a daemon behind each pane to attach to;
- `agtermctl` installed, from the cask or Help ▸ Install, because a machine merely running agterm has no
  CLI an ssh command can find;
- ssh key auth to it from this Mac. The connection is non-interactive, so a password or host-key prompt is
  a failure rather than a question. Check it with the same form agterm uses:

```sh
ssh -o BatchMode=yes <remote-host> true
```

agterm runs ssh from the app, which inherits the launch environment rather than your shell's. An agent
exported in `.zshrc` passes the check above and still fails at launch, so put `IdentityAgent` and key
settings in `~/.ssh/config`, which both paths read.

## Setup

Copy the script somewhere on your PATH and make it executable:

```sh
mkdir -p ~/bin
install -m 755 remote-restore.sh ~/bin/remote-restore
```

Add four lines to `~/.config/agterm/hooks.conf`:

```
on remote.opened ~/bin/remote-restore record
on remote.closed ~/bin/remote-restore record
on tree.changed ~/bin/remote-restore sync
on app.launched ~/bin/remote-restore replay
```

Then load them without a restart:

```sh
agtermctl hooks reload
```

The list lives in `~/.local/state/agterm-remote-restore/`. Set `AGT_REMOTE_RESTORE_DIR` in front of the
command in each hook line to keep it elsewhere, for example one list per agterm state directory.

Only a row attached while these hooks run in an agterm that reports `remoteSessionID` gets on the list.
One attached before the hooks were loaded, or by an older agterm, is missing from it however the hooks
were set up, and the first relaunch silently brings nothing back. Check with `remote-restore list`, and
attach a missing row again to put it there.

## Usage

Attach sessions as you normally do, with `agtermctl zmx attach` or a picker such as remote-session-picker.
Nothing else is needed: the next launch attaches them again and posts one notification with how many it
attached and dropped.

When a host does not answer, or an attach fails, the launch asks instead of posting: a dialog titled
**Remote sessions not restored** gives the counts and each host's reason, with **Retry** and **Later**.
Retry tries the waiting rows again at once, and asks again if some still fail. Later keeps them for the
next launch, or for a retry by hand:

```sh
~/bin/remote-restore retry
```

To have that on a key, add a command to `~/.config/agterm/keymap.conf`, for example:

```
command "Restore Remote Sessions" ctrl+shift+cmd+r ~/bin/remote-restore retry
```

To see what the next launch will attach:

```sh
~/bin/remote-restore list
```

Each line is the host, the session's id on that host, the window and workspace it was in, and its id
here, tab-separated.

## How it works

Every `remote.opened` and `remote.closed` event carries the far side's id for the session the row shows,
`remoteSessionID`, along with its `host`, `window` and `workspace`. `record` keys the list by the row's
own session id here, so a closed row leaves the list and an undo of that close puts it back. A quit sends
no `remote.closed`, which is why the list outlives it.

`replay` runs on `app.launched`, once the restored windows are in the tree. Before attaching anything, it
asks each host once with `zmx tree HOST`:

- if ssh fails, the host may simply be switched off, and a refused login looks the same (both are exit
  255), so its rows stay on the list, marked as waiting, and the launch asks whether to retry;
- if the host answers and lists the id, the row is attached again;
- if the host answers and does not list it, the row is dropped. That is a policy, not proof the session is
  gone: the far side also leaves out a session whose window is closed there, or every session after a
  launch that fell back from Live sessions to fresh shells.

Moving a session to another workspace sends no event of its own, only `tree.changed` for its window.
`sync` answers that one: when the window holds a listed row, it reads the window's tree and writes down
each listed row's current workspace. Most tree changes are in windows without a remote row, and for
those it stops before calling `agtermctl`. `record` reads the tree too rather than trusting the event's
workspace, since the row may have moved while its event waited in the hook's queue.

`zmx attach` puts a row in whatever workspace holds the window's selection, which is still settling while
a launch restores its windows. So `replay` attaches first and then moves the row to its recorded
workspace with `session move`, and once every row is in, selects again what each window was showing.
Rows are attached in the order they were opened, so a parent is back before its companions, which join
it on their own and are not moved.

`retry` takes only the rows marked as waiting, the ones with no id here, and leaves the attached ones
alone, so it never attaches a row twice. One restore runs at a time: a `retry` started while the launch's
`replay` is still at work, or still waiting on its dialog, reports that and does nothing.

`replay` moves the list aside before it starts. Each successful attach emits `remote.opened` and records
itself afresh, under its new id; a row kept for later is written back by `replay` itself. The hooks are
separate lines and run concurrently, so each takes a lock while it rewrites the list.

## Limits

At launch every attach selects the session it creates, so the window's selection moves while the recipe
works; it puts back the workspace each window showed when it is done, but not the selected sessions.

A restored row goes to the end of its workspace, so the order of rows inside a workspace is not kept.

The `tree.changed` hook runs a small script on every tree change, in any window. It returns at once for
a window without remote rows, and reads that window's tree otherwise.

Closing a window takes its remote rows off the list, so reopening that window later does not bring them
back. A row whose window did not come back at launch is attached into the frontmost window.

A session the far side does not list at launch is dropped from the list for good, even when it is only
hidden there for the moment; attach it again by hand once it is back.

A host that stays unreachable keeps its rows on the list, and every launch tries it again, which costs
one ssh timeout per such host at launch.

The dialog holds the `app.launched` hook until it is answered, and asks once per pass; nothing retries
without you. agterm gives `zmx tree` 10 seconds, so a far side that is up but slow to answer counts as
unreachable for that pass.
