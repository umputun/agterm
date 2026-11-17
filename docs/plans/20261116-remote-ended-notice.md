# Remote session end and disconnect notices

## Overview

When a viewer Mac shows a session attached from another Mac or from agterm-server, and the origin closes that
session through its API or CLI, the viewer pane is left with the wrapper's printed line
`agterm: <session> (<pane>) on <host> disconnected, exit 0` and Ghostty's "Process exited. Press any key to close
the terminal." A removal the origin made on purpose must leave nothing behind: the viewer row closes silently.

A disconnect that does deserve a notice (ssh lost the link, or the attach ended while the origin still has the
session) is shown as pane chrome over the terminal, not as text printed into it. The wrapper prints no notice
text at all.

Decisions already made by Eugene:
- the origin tells the viewer with an explicit `ended` presentation frame at irreversible finalization;
- notices render as a pane overlay on the `PaneLeadCover` / `RemoteReconnectNote` seam, not the session HUD slot;
- a session the origin closed for good disappears from the viewer in every case: live through `ended`, and after a
  viewer relaunch through the #999 origin check, which closes the row in place of keeping it with "Ended on HOST";
- work happens on branch `remote-ended-notice` in its own worktree.

Out of scope: rows of a remote window (`binding.catalogOwned`) keep their catalog-driven behavior, since their exit
reattaches and the catalog removes them; their wrapper is `attachPaneCommand` too, so they lose the printed text
along with everyone else and gain the reconnecting notice through the shared reconnect state.

## Context (from discovery)

- Wrapper: `RemoteSession.attachPaneCommand` (`agtermCore/Sources/agtermCore/RemoteSession.swift` ~172-215) prints the
  disconnect label on non-255 and a yellow "Connection to HOST lost · reconnecting…" bar on 255, then exits with
  ssh's status. `commandWait` holds the surface on Ghostty's press-any-key prompt.
- Held exit: `GhosttyCallbacks` `GHOSTTY_ACTION_SHOW_CHILD_EXITED` returns false for waiting surfaces and calls
  `onExitHeld`. Its `exit_code` is always 0 under the login wrapper (`GhosttySurfaceView.swift:90`), so no notice
  or read-back carries an exit status. A 255 with a nonce never exits: it parks on `cat` and reports through
  `RemoteLinkNotice` into `RemoteReconnectBook`.
- Window delete: `WindowLibrary.removeWindow` → `finalizeWindowPanes` (~813) calls `paneFinalizer` directly, for a
  loaded store and for a snapshot-only window.
- Relaunch check: `ControlServer+AttachedRestore.swift` ~47 calls `AppStore.endAttachedRow`
  (`AppStore+AttachedRestore.swift` ~87), which keeps the row, sets `Session.ended` and prints
  `RemoteSession.endedCommand` ("Ended on HOST").
- Scratch: an origin scratch attaches through the same wrapper (`PaneLead.swift` ~129); `PaneLeadCover` draws the
  reconnect note only for left/right because `OverlayPane` has no scratch case.
- Removal join: `agtermApp+RemoteLayout.swift` (`handleRemotePaneHeld`, `closeRemovedRemotePane`) and
  `AppStore+RemoteLayout.swift` (`canCloseRemovedRemotePane`, `heldPanes`) close a replica once both the origin's
  layout dropped it and its ssh exited, in either order. The last replica keeps its screen until ssh exits (#636).
- Why the reported case leaks: a `PresentationLayout` needs 1-2 panes, so whole-session removal is never
  expressed. The origin's `dropOrphanedPresentationStreams` (`PresentationStream.swift` ~148) and the hello guard
  (~85) only shut the stream; `RemotePresentationClient.linkClosed` → `fail` retries forever.
- Origin finalization: hard `AppStore.closeSession` (`AppStore.swift` ~670), hard `removeWorkspace` (~710) and
  `hardFinalizePendingSessions` (`AppStore+PendingClose.swift` ~621, reached from `finalizePendingClose` for sessions,
  workspaces and members). All three, and nothing else, call `finalizePaneIdentities` (`AppStore+Panes.swift:29`),
  whose `paneFinalizer` kills the daemons synchronously.
  Soft close removes the row at once but keeps surfaces and daemons until grace ends.
- Open Recent rebuilds a closed session from its snapshot with the SAME id (`AppStore+RecentClosed.swift` ~37).
- Admission: `openPresentation` (`ControlServer+Presentation.swift:8`, `ServerActions+Remote.swift:36`) refuses an id
  it cannot resolve before any stream exists; `RemotePresentationClient.accept` takes only a hello as the first frame.
- Liveness: the hub answers a viewer's `ping` with `ack` on the same ordered stream (`PresentationHub` ~280).
- Source check counts only visible rows: `ControlServer+Presentation.swift:115`,
  `AgtermServerKit/ServerStreams.swift:82`. A closed reopenable window also leaves its sessions out of the live
  stores while their daemons survive, so absence is not removal.
- Stream end: `ControlStreamOwner.sendFinal` (`ControlStreamFraming.swift:112`) writes a last line, then closes.
- Older viewers decode an unknown frame kind as `PresentationFrame.Body.unknown`, so a new kind needs no version bump.
- Reconnect UI: `PaneLeadCover.swift` draws `RemoteReconnectNote` from `RemoteReconnectBook` (last failed probe
  reason); pane read-back already has `reconnect` (`ControlProjection.swift:21`).

## Development Approach

- **testing approach**: TDD (bug fix): write the failing test, run it, fix, run again.
- complete each task fully before moving to the next; small, focused changes.
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task, success and error paths.
- **CRITICAL: all tests must pass before starting the next task.**
- **CRITICAL: update this plan file when scope changes during implementation.**
- scoped runs while working (`swift test --filter`, `-only-testing:`); full gates once at the end.
- the visible notice is shown to Eugene in a running Debug instance before its tests are written.

## Testing Strategy

- **unit tests** (`agtermCore`, Swift Testing): frame codec, hub/stream finalization, client handling of `ended`,
  store removal predicates, wrapper script output, read-back projection.
- **hosted tests** (`agtermTests`): `RemoteLayoutCloseTests` both arrival orders, local split survival, notice state
  set/cleared, `ControlServer` presentation source through undo grace.
- No XCUITest suite runs for this; targeted `-only-testing` only if a UI test is added.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- keep the plan in sync with the work

## Solution Overview

1. **Origin side.** `finalizePaneIdentities` fires a store callback with the finalized session ids BEFORE it runs
   `paneFinalizer`, which covers hard session close, hard workspace removal and grace expiry (session, member,
   workspace); `WindowLibrary.finalizeWindowPanes` fires the same callback before its own `paneFinalizer` call, for
   a loaded and a snapshot-only window. Both queue `ended` ahead of the daemon kill that ends the viewer's ssh. The presentation
   layer sends `ended` to those sessions' streams with `sendFinal` and records the ids in an in-process set of
   finalized sources.
   A pending-close session still counts as a source, so undo keeps the stream and grace expiry sends `ended`.
   Reconnect: `openPresentation` admits a live, pending-close or finalized id; the stream answers the viewer's hello
   with its own hello (fixing the generation the client requires), then `sendFinal(ended)` for a finalized id.
   A live or pending-close incarnation always wins over the finalized set, so a session reopened through Open Recent
   under the same id presents normally. An id the origin simply does not have (never existed, closed window, not
   loaded yet after relaunch) keeps today's refusal, so absence never reads as removal.
2. **Viewer side.** `ended` stops the presentation client for good (no retry) and marks the row's presentation as
   ended. `canCloseRemovedRemotePane` treats every mapped replica of an ended row as removed, so the existing
   join closes them: at once when already held, otherwise when ssh exits; the last replica still waits for its
   exit. Local replacements and a pending local split are kept by the existing guards. No viewer soft close.
   The relaunch check closes the row (`closeSessionRow`, the row alone; each attached companion settles through its
   own check) where it called `endAttachedRow`, and `endAttachedRow` goes. A saved attached (non-catalog) row with
   `ended=true`, written by #999 before this change, is not restored at all, so no old "Ended on HOST" row
   survives the upgrade. `RemoteSession.endedCommand` and `Session.ended` stay for catalog rows and agterm-server's
   headless rows, which keep their behavior.
3. **Notices.** The wrapper keeps the terminal-mode reset, the `RemoteLinkNotice` title OSC and the 255 `cat`
   wait, and prints no text. For an attached pane replica agterm consumes `SHOW_CHILD_EXITED` (no Ghostty fallback
   text). An origin scratch keeps today's lifecycle: its exit parks it through `remoteScratchStopped` for automatic
   reattach, it shows the reconnecting notice while parked, and the origin's layout or the row's close ends it, so it
   never shows the ended notice. A held pane exit the removal join does not already close
   is settled before any notice paints: with the stream connected to an origin that agreed the `ended` kind
   (`originSupports`), the viewer sends `ping`; `ended` (queued on the origin before the daemon kill, so ahead of
   the `ack` on the ordered stream) closes the pane silently, while an `ack` with no `ended`, or the stream failing,
   paints the ended notice. With the stream down, or an origin that never sends `ended`, the notice paints at once.
   A later `ended`, on the live stream or a reconnect, closes the row whatever is painted: the daemon can die
   before `ended` is queued (`zmx kill`, or the origin's shell exiting into `closePrimaryPane` → `closeSession`),
   and then the notice shows briefly before the row closes. The reconnecting notice follows `RemoteReconnectBook`,
   as the ssh reason note does today, for left, right and an origin scratch.
   Notice texts: "SESSION on HOST ended · any key closes" and "Connection to HOST lost · reconnecting… · any key
   retries now", the latter keeping the ssh reason line under it once a probe failed. `PaneLeadCover` draws both;
   they clear on reattach or removal and never touch the session HUD slot.

## Technical Details

- Frame: `PresentationFrame.Body.ended`, wire kind `"ended"`, no payload, listed in the hello's agreed kinds, sent
  through the hub so it carries the stream's next `rev` (the client drops a non-advancing one).
- Snapshot during grace: `ControlServer.presentationSnapshot` resolves a pending-close session too, or a viewer
  reconnecting inside the undo window gets an empty snapshot.
- Store hook: one callback fired at the top of `finalizePaneIdentities` with the finalized session ids, before
  `paneFinalizer`; the presentation layer (app `ControlServer` and `ServerStreams`) consumes it.
- Source check and admission: live row, then pending-close member, then the finalized set, in both hosts.
- Viewer settle: a held non-255 exit with no removal known puts the pane in a pending-settle state that paints
  nothing; the client's next `ack`, `ended` or failure resolves it.
- Viewer state: `RemotePresentationConnection` gains `ended`; `rowNotice` returns nil for it.
- Read-back: the pane surface node gains `attachEnded: true` next to `reconnect`, omitted otherwise (named apart from
  the session node's `ended`). A scratch has no ended state; its parked state already reads back through
  `reconnect`. No new event, so `EventFormatter.human` is unaffected.

## What Goes Where

- **Implementation Steps**: code, tests and docs in this repo.
- **Post-Completion**: two-Mac and agterm-server manual checks.

## Implementation Steps

### Task 1: Origin sends `ended` at final removal

**Files:**
- Modify: `agtermCore/Sources/agtermCore/PresentationFrames.swift`
- Modify: `agtermCore/Sources/agtermCore/PresentationStream.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+Panes.swift` (callback in `finalizePaneIdentities`)
- Modify: `agtermCore/Sources/agtermCore/WindowLibrary.swift` (callback in `finalizeWindowPanes`)
- Modify: `agterm/Control/ControlServer+Presentation.swift` (admission, source check, grace snapshot, sink)
- Modify: `agtermCore/Sources/AgtermServerKit/ServerStreams.swift`, `ServerActions+Remote.swift`
- Modify tests: `agtermCore/Tests/agtermCoreTests/PresentationFramesTests.swift`, `PresentationHubTests.swift`,
  `AppStorePendingCloseTests.swift`, `WindowLibraryTests.swift`, `agtermCore/Tests/AgtermServerTests/ServerStreamsTests.swift`,
  `ServerActionsRemoteTests.swift`, `agtermTests/ControlServerPresentationTests.swift`

- [x] failing tests first: `ended` round-trips through the codec; an older decoder sees `unknown` (the existing `future.kind` decode case covers it)
- [x] failing tests: the callback fires before `paneFinalizer` for hard session close, hard `removeWorkspace`,
      grace expiry of a session, a member and a workspace, and window delete (loaded and snapshot-only); it never
      fires for soft close, undo, window close or a pane close
- [x] failing tests: a live stream gets `ended` then closes; soft close keeps it and undo keeps it; through the real
      open/adopt/client path, a reconnect to a finalized id gets hello then `ended` and the client stops, a
      reconnect during grace presents normally, an unknown id is still refused; hard close then Open Recent under the
      same id presents normally, for a session and a workspace
- [x] add the frame kind and the callback; presentation layer sends `sendFinal(ended)`, records finalized ids,
      admits live, pending-close and finalized ids in that precedence in both hosts
- [x] run the scoped tests - must pass before task 2

### Task 2: Viewer closes an ended row silently

**Files:**
- Modify: `agtermCore/Sources/agtermCore/RemotePresentationClient.swift`, `RemotePresentationState.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+RemoteLayout.swift`, `AppStore+RemotePresentation.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+AttachedRestore.swift` (`endAttachedRow` goes, saved ended rows
  are not restored; `RemoteSession.endedCommand` stays for catalog rows)
- Modify: `agterm/agtermApp+RemoteLayout.swift`, `agterm/Control/ControlServer+AttachedRestore.swift` (and the client
  effects wiring in the app)
- Modify tests: `agtermCore/Tests/agtermCoreTests/RemotePresentationClientTests.swift`,
  `RemotePresentationStateTests.swift`, `AppStoreRemoteLayoutTests.swift`, `AppStoreAttachedRestoreTests.swift`,
  `agtermTests/RemoteLayoutCloseTests.swift`

- [ ] failing tests: client stops retrying after `ended` and reports it; `rowNotice` is nil for it
- [ ] failing tests: ended before ssh exit and ssh exit before ended both close the replicas and then the row; a
      local replacement and a pending local split survive; the last replica waits for its exit
- [ ] failing tests: the relaunch check closes a row whose origin lost the session, companions untouched, and
      leaves a listed or inconclusive one attaching as before; a saved attached snapshot with `ended=true` is not
      restored, while a catalog or headless ended row is
- [ ] handle `ended` in the client and the store; widen `canCloseRemovedRemotePane` for an ended row; on `ended`,
      run the existing `closeRemovedRemotePane` seam for each mapped replica
- [ ] relaunch check: close the row in place of `endAttachedRow`; remove `endAttachedRow`; skip saved ended
      attached rows at restore
- [ ] run the scoped tests - must pass before task 3

### Task 3: Pane notices replace the printed text

**Files:**
- Modify: `agtermCore/Sources/agtermCore/RemoteSession.swift`
- Modify: `agterm/Ghostty/GhosttyCallbacks.swift`, `agterm/Ghostty/GhosttySurfaceView.swift`, `agterm/agtermApp.swift`
- Modify: `agterm/Views/PaneLeadCover.swift` (reconnecting notice for a scratch too), `agterm/agtermApp+Scratch.swift`
  and the scratch host that mounts the cover (scratch stays on `onExit` → `remoteScratchStopped`)
- Modify: `agtermCore/Sources/agtermCore/ControlProjection.swift` (`attachEnded`) and its producer
- Modify tests: `agtermCore/Tests/agtermCoreTests/RemoteSessionTests.swift`, `RemotePresentationClientTests.swift`,
  `AppStoreTreeProjectionTests.swift`, `agtermTests/RemoteLayoutCloseTests.swift`, `agtermTests/PaneLeadTests.swift`

- [ ] probe first, in an isolated Debug instance: whether a key still closes a surface whose `SHOW_CHILD_EXITED`
      the host consumed; the result picks the key path (Ghostty's own, or the notice routing the key to close)
- [ ] failing tests: the wrapper prints no notice text on any status, still exits with ssh's status, still emits
      the title OSC, mode reset and 255 wait
- [ ] wrapper: drop the label and the bar printf; consume `SHOW_CHILD_EXITED` for attached (non-catalog) remote
      replica surfaces, keeping the held, respawn and removal bookkeeping
- [ ] settle a held exit before painting: pending-settle state, client `ping` when the origin agreed `ended`,
      resolve on `ended` (silent close), `ack` or failure (notice); paint at once otherwise; a later `ended` closes
      a painted row; clear on reattach and removal; draw both notices in `PaneLeadCover` for left and right, and
      the reconnecting notice for a parked origin scratch; show the rendered notices to Eugene in a Debug instance
      before tests
- [ ] tests: exit first then `ended` never paints (assert the state right after the exit, not only the final one);
      `ended` first then exit paints nothing; exit then `ack` paints the ended notice; a late `ended` closes a
      painted row; stream down or an origin without `ended` paints at once; a parked reconnect shows the reconnecting
      notice on a pane and on a scratch parked through the real scratch factory and `onExit` path, which still
      reattaches by itself; read-back `attachEnded`; the session HUD slot is untouched
- [ ] run the scoped tests - must pass before task 4

### Task 4: Docs and gates

**Files:**
- Modify: `.claude/rules/control-api.md` (Remote sessions bullets), `site/docs.html`, `site/commands.html`,
  `plugins/agterm/skills/agterm/reference.md`

- [ ] update the remote-session bullets: `ended` semantics, the relaunch check closing rows, pane notices, wrapper
      prints nothing
- [ ] user guide: what a viewer shows when an origin closes a session or the link drops
- [ ] commands reference and skill reference: the replaced "reconnecting bar" and "Ended on HOST" wording, and the
      `attachEnded` read-back
- [ ] gates once: `cd agtermCore && swift test`, `make test-app`, `make lint`
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification:**
- two Macs: close an attached session on the origin with `agtermctl session close` (plain and `--undoable`, undo
  and expiry); the viewer row closes with no text when final and survives undo
- pull the network on a viewer: the reconnecting pane notice shows and clears on reattach
- agterm-server origin: the same close and drop checks against a Linux host
- the viewer asleep or offline during an origin close: on reconnect the row closes

Smells pre-check: skipped — non-Go project
