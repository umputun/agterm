---
worth: later
where: agterm/agtermApp.swift:makeOverlaySurface
added: 2026-11-16
---
# a running program overlay stays behind when the lead moves

Since #1023 an open ask, pick or page follows the pane lead between attached Macs and the origin, but a
running program overlay stays on the Mac it started on. A split's program lives in a zmx daemon on the
origin, so its pane follows the person; an overlay's program is a child of one terminal: a local overlay is
a ghostty surface spawning `/bin/sh -c` in the app (`makeOverlaySurface`), a remote one runs under the
viewer's ssh pty (`OverlayRunJob`, `run-job`), where a hangup counts as a cancel. On screen the two look
alike, so the person moving to another Mac cannot tell which one comes along. Today the user guide and the
skill say a program overlay stays where it started.

Raised by the #1017 reporter on https://github.com/umputun/agterm/pull/1023, who offered to test on two
Macs. Direction: one origin-owned job hosted in zmx where the pane is Live, with local and remote
attach-only presentations, so a move changes who shows the program, never who runs it. Never relaunch the
command to move it, never let an attach recreate a vanished job, and keep the job/token boundary so a
viewer only attaches to the offered job. Non-Live panes and the HUD keep today's surface child.

Contracts the change must keep (codex review, 2026-11-16):

- Exit status: `GhosttySurfaceView.finishDestroy` reads and deletes the `OverlayCapture` code file on
  surface teardown, and the zmx `ZMX_EXIT_FILE` patch writes only `exited`. The origin must record the
  program's own code at its exit; a detach is not an outcome. `overlay result`, `--block` and the `--wait`
  held display stay as they are.
- Close vs move: `closeOverlay`/`closePaneOverlay` tie slot release to surface teardown, and `run-job`
  cancels on hangup. A move needs a detach that is not a cancel, an explicit cancel that still ends the
  whole process group, and refusal of stale replies from the old presentation.
- Idle daemon: zero attached clients is normal mid-move, so the stop rule needs a grace period and an
  owner, like the held-ask deadline, on Mac and Linux origins alike.
- Slot admission at the destination stays as it is, including a HUD yielding to a session-wide program.
- Reparenting a local command into zmx needs a TCC attribution check and the same cwd and environment.

A local overlay also does not survive an app restart, which a Live pane beside it does. That is outside
this item: a surviving daemon alone restores nothing, because `openOverlay` is deliberately ephemeral and
its job and slot metadata are not in the session snapshot.
