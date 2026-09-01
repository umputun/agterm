# Remote session picker

Pick a session running on another Mac and attach it here, marked remote in the sidebar.

## What it does

Lists what another Mac has to offer, shows it in agterm's native picker, and attaches whatever you
choose. The row is the session's name; underneath it sits the far side's window and workspace, the
session's own note of what it is for when its owner set one, its working directory, and what its panes
are running.

A picked session appears in your current workspace as an ordinary session with a remote marker. Its
split comes with it. Closing it here ends only your side's connection: the far-side processes keep
running, and nothing this recipe does can kill them.

## Requirements

agterm 0.26.0 or later, which added `zmx tree` and `zmx attach`, plus `jq`.

The far side needs more than the near side does:

- it is running agterm 0.26.0 or later too, since the discovery call runs `zmx tree` over there and an
  older build does not have it;
- its restore mode is **Live sessions**, which is what puts a daemon behind each pane. Without it there
  is nothing to attach to. The empty list does not say so, though: it reads the same as a machine that is
  in Live sessions mode with nothing eligible. Run `agtermctl zmx list` on that machine to tell them apart;
- it has `agtermctl` installed, from the cask or Help ▸ Install, because a machine merely running agterm
  has no CLI an ssh command can find;
- ssh key auth to it already works from this Mac. The connection is non-interactive, so a password or
  host-key prompt is a failure rather than a question.

Check that last one before binding the chord, using the same non-interactive form agterm uses:

```sh
ssh -o BatchMode=yes <remote-host> true
```

Exiting silently means agterm can reach the host. A password or host-key prompt means it cannot, and
agterm will fail the same way.

One difference the check cannot show: agterm runs ssh from the app, which inherits the launch environment
rather than your shell's. An agent exported in `.zshrc` passes the check above and still fails here, so
put `IdentityAgent` and key settings in `~/.ssh/config`, which both paths read.

## Setup

Copy `attach-remote.sh` somewhere on your PATH and make it executable:

```sh
mkdir -p ~/bin
install -m 755 attach-remote.sh ~/bin/attach-remote
```

Then bind it in `~/.config/agterm/keymap.conf`, one line per machine you want to reach. Replace
`<remote-host>` with the machine as ssh would take it:

```
command "Attach Remote" cmd+shift+r ~/bin/attach-remote <remote-host>
```

The host can come from the environment instead, which suits a single machine:

```
command "Attach Remote" cmd+shift+r AGT_REMOTE_HOST=<remote-host> ~/bin/attach-remote
```

## Usage

Press the chord. The picker opens with one row per attachable session; type to filter, Return to attach,
Esc to cancel. Cancelling does nothing at all.

Run it from a shell to see the same list without the picker's filtering:

```sh
agtermctl zmx tree <remote-host>
```

## How it works

`zmx tree HOST` is the discovery half. The local agterm runs one ssh to the far side, which runs its own
bare `zmx tree` there and answers with a single document: every open window's sessions, filtered to the
ones whose every pane still has a live daemon. A session with a missing daemon is omitted rather than
offered, because attaching to a name that no longer exists would create a fresh shell wearing it.

The script turns that answer into picker items, using the session `id` rather than its name: remote
names are editable and repeat across workspaces, so only the id addresses one session. The subtitle shows
the window and workspace *names*; the rows also carry `windowID` and `workspaceID`, which is what to group
by if you extend this, since neither name is unique.

Running `agtermctl zmx tree` with no host asks the same question of your own agterm. That is the exact
form the remote call runs on the far side, so it is the quickest way to see what another machine would
answer before you point the recipe at it.

`zmx attach HOST ID` opens it. The attach resolves the remote again before touching anything local, so a
session that disappeared between the listing and your keypress fails cleanly instead of handing back a
fresh shell.

Both halves report through `agtermctl notify` rather than stdout, because a keymap command runs with its
output on `/dev/null` and an error printed there is an error nobody sees.

## Limits

An attached session is never written to disk, so it does not come back after a relaunch whatever your
restore mode is. If the connection drops, the pane holds on a press-any-key prompt showing the host,
session, pane and exit status; reconnecting means running this recipe again.

The attached view arrives at the far side's window geometry and does not reflow until you press a
classified key into it: a printable character, Return, Tab or Backspace. Before that keystroke your
mouse, focus reporting and Ctrl-L do not reach the remote, so a mouse-driven full-screen program can look
frozen.

Leadership is per pane, so a session whose primary you have typed into can sit beside a split still at
the far side's geometry until you type in that one too. After you detach, each far-side pane you led
keeps your geometry until something gives it input or resizes it there; panes you never typed into are
unaffected.
