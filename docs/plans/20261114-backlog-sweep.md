# Backlog sweep: attached-row mail counts, link hover target, async test waits, spawn lock

## Overview

One PR closing four `docs/backlog/` items:

- `pending-counts-on-attached-rows`: a session attached alone (`zmx attach`, `zmx attach group`) or from another
  Mac gets the `message` event but reads nil `pendingMessages`/`scratchPendingMessages` in `tree`. Carry the
  counts in the presentation stream.
- `osc8-link-target-not-shown-on-hover`: show where a hovered link goes, in a bottom-left label on the pane, as
  Ghostty's macOS app does. A session link shows the session's name.
- `blocking-test-waits-hold-concurrency-workers`: test waits that park Swift concurrency worker threads during
  the Linux startup stall become async.
- `other-flock-locks-close-without-unlocking`: `ClientConnector.startHost` unlocks its spawn lock before
  closing it, like the other two lock sites.

It also corrects stale text in `zmx-live-ui-tests-leave-their-session-host-running` (a `stop` entry point now
exists; the leak remains because `HostRetirement` excludes the current endpoint) and `server-user-event-hooks`
(the event ring landed with #999; hooks remain undecided).

## Context (from discovery)

- Codex source map for mail counts: `/tmp/agterm-pending-counts-source-map.md` (bb843406).
- Mail: `MessageBus` (`@MainActor`, process-wide `shared`, four mutators), `AppStore+Messages.swift`
  (`publishMessageQueued`, `emitRemoteMessage`, `applyCatalogMail`, `pendingMessages(_:pane:token:)`,
  `scratchPendingMessages`), `Session.catalogMail`.
- Presentation: `PresentationFrames.swift` (`PresentationSnapshot`, `PresentationFrame.Body`, unknown kinds
  decode to `.unknown`; `PresentationRespawns.generations` is `[String: Int]`), `PresentationHub.swift` (one hub
  per process, shared by every Mac store; subscribe registers, holds publications, then sends hello, snapshot,
  held frames), `AppStore+Presentation.swift:presentationSnapshot`, `RemotePresentationClient.swift:apply` (the
  only exhaustive `Body` switch), `ControlServer+RemotePresentation.swift:remoteEffects`,
  `RemotePresentationState.swift:RemoteBinding`, `Session+PaneDirectory.swift` (`originScratch`,
  `scratchClientIdentity`).
- Hover: `GhosttyCallbacks.action` handles `MOUSE_SHAPE` and `OPEN_URL`, not `MOUSE_OVER_LINK`
  (`ghostty_action_mouse_over_link_s`: pointer plus length, not NUL-terminated). `GhosttySurfaceView` is a plain
  `NSView`; surface slots are `@ObservationIgnored`. 12 `TerminalView` call sites (Detail 4, Zoom 6, Dashboard 2)
  plus the separate `QuickTerminalPane` representable. `WindowLibrary+SessionLink.swift:sessionLinkTarget`.
- Tests: `HudHelperTests.Run`, `OverlayRunJobTests.FakeOrigin`, `ClientConnectorTests.Starter` (a `HostStarter`
  double), `StateDirectoryLockTests` (realpath fd lookup pattern).

## Development Approach

- **testing approach**: TDD for the spawn lock and for the mail convergence regressions; features get tests in
  the same task as their code.
- complete each task fully before moving to the next; every task ends with its tests passing.
- run only the tests a task touches (`swift test --filter`, `-only-testing:`); the full gates run once, in the
  last task.
- keep the `message` event contract unchanged: immediate per-delivered-pane publication, origin pane UUID in the
  payload, never replayed or emitted from mail state.

## Testing Strategy

- core: `PresentationFramesTests`, `PresentationHubTests`, `RemotePresentationClientTests`, `AppStoreMessagesTests`,
  `ServerActionsMessagesTests`, `ClientConnectorTests`, `HudHelperTests`, `OverlayRunJobTests`, `LinkHoverTests`.
- hosted: `ControlServerRemotePresentationTests` through the real `remoteEffects` wiring (a callback-only test
  misses a disconnected closure), `ControlServerMessagesTests` for Mac-origin publication.
- waits assert state with a bound (`.claude/rules/tests.md`): the deferred mail flush is awaited by polling the
  subscriber's received frames with a bound, never a fixed sleep.

## Progress Tracking

- mark completed items `[x]` immediately; new tasks get a ➕ prefix, blockers a ⚠️ prefix.
- update this plan when scope changes.

## Solution Overview

**Mail counts.**

- Source rule: a catalog-owned row (`RemoteBinding.catalogOwned`) keeps the server catalog as its only count
  source, unchanged. Every other attached row reads a new presentation cache. The two never write one cache, so
  their independent ordering cannot let an older value overwrite a newer one.
- Wire: `PresentationMail { panes: [String: Int] }`, keyed by ORIGIN pane `uuidString` (main, split, origin
  scratch), zeros omitted, a full replacement of one session's unacked counts. String keys match
  `PresentationRespawns.generations` and give one JSON object shape on Darwin and Linux. It travels as a new
  optional `PresentationSnapshot.mail` and a new top-level `mail` frame. An empty map means "supported, no mail"
  and clears; an absent snapshot field means the origin predates it and resets the viewer to unsupported (today's
  nil). Additive under protocol version 1: older peers ignore the unknown frame kind and key. `mail` joins
  `PresentationHub.supportedKinds` for hello accuracy; `publish` does not filter by kind.
- Origin scheduling: `MessageBus` notifies observers from its four mutators (send, read with ack, ack, dispose)
  through one removable token. The hub owner registers once with a weak callback: `ControlServer` on the Mac
  (idempotent, guarded in `attachPresentationHub`, removed before `stop`'s listener guard and restored on
  `start`), `ServerStreams` on the server (init/shutdown). It coalesces to the next main-queue turn and, for every
  store's sessions with subscribers, asks `AppStore.presentationMail(forSession:)` for the map and hands it to the
  hub. Deferring past the mutation means identities are settled (PaneObserver drops membership before disposal;
  `promoteSplit` disposes before reassigning) and natural exits are covered, with no hook at the eleven disposal
  sites.
- Dedup per subscriber: each `PresentationHub` subscriber keeps the last mail map it was sent, set only after the
  sink accepts the snapshot's mail or a `mail` frame. `publishMail` sends to each subscriber whose baseline
  differs. While a subscriber's held queue is open, mail is queued without dedup; hello, snapshot and held
  delivery then advance the baseline in wire order, with no reseed after the drain. Each subscriber converges to
  the current map; a transient value it never saw need not be delivered.
- Viewer: stores the map as received, keyed by origin id. The read path maps at read time. Main and split go
  through `RemoteBinding.remotePane(forLocal:)`. A pane equal to the row's `scratchClientIdentity` or
  `originScratch` reads `presentationMail[originScratch]`; `originScratch`, not `scratchDaemon.identity`, so a
  scratch local to the viewing Mac is never read as the origin's. This survives an origin split added after attach.
- Security: the untrusted input is the origin's frame. It carries only integers keyed by pane id, is read back
  only into `tree`, and grants no capability; a malformed frame fails the stream as any bad frame does today.

**Hover label.**

- Handle `GHOSTTY_ACTION_MOUSE_OVER_LINK`: copy the length-delimited URL synchronously, hop to main, write it into
  the surface's hover model (empty length clears).
- Observable path: `TerminalView` becomes a SwiftUI view that owns a `@State` `@Observable` hover model, wraps the
  existing representable (renamed), and hands the model to the surface in `makeNSView` and `updateNSView`. The
  body overlays the label bottom-leading with `.allowsHitTesting(false)`, so the four cursor writers'
  `ownsPointer` gate never sees chrome there. A surface moving to another host (zoom, dashboard) clears the model
  of the host it left. The overlay is a modifier inside each arranged subview, which the constant-shape rule
  allows; no call site changes. `QuickTerminalPane` gets the same wrapper. Remote panes render through the local
  surface and get it unchanged.
- Label text from a host-free function in agtermCore (`LinkHover.swift`): control and bidi-format scalars
  neutralized, one line, middle-truncated to a fixed length, and for a resolving `agterm://session/<uuid>` link
  the target session's name. The input is terminal-controlled text drawn in chrome, and the feature's purpose is
  showing the real target of a mislabeled link, so spoofing through format characters is the defect to prevent.
  It grants no capability: the label is display only.
- The label clears on mouse exit, surface hide and surface teardown so it never outlives its link. Check before
  building whether libghostty at `83fb956` honors `link-previews` before emitting the action; if it does not,
  the label respects that setting itself.
- No control API: pointer-only chrome with nothing to drive, a visual-only exemption to record in the PR.

**Async test waits.** Every wait in `HudHelperTests` and `OverlayRunJobTests` that parks a pool thread becomes
async: `Run.wait`/`paints`/`waitForExit`/`stop`/`missEvidence`, the polling at `HudHelperTests.swift:493` and
`:522`, `OverlayRunJobTests.swift:78-80`, `:103` and `:189`, and `FakeOrigin.frames`, which keeps its 5 s bound.
The 37 `defer { run.stop() }` sites use `defer { await run.stop() }` if both pinned toolchains (Xcode 26 and
`swift:6.3.2-noble`) compile it, else a scoped `withRun { }` helper. Measured before and after in the container
pinned to 4 CPUs, several runs each.

**Spawn lock.** `defer { flock(spawnLock, LOCK_UN); close(spawnLock) }`; unlocking an unheld lock is harmless.

## Technical Details

- `PresentationMail { panes: [String: Int] }`, Codable, Equatable, Sendable; frame kind `"mail"`.
- `PresentationSnapshot.mail: PresentationMail?` (nil = origin predates mail state).
- `Session.presentationMail: PresentationMail?`, `@ObservationIgnored`, not persisted; nil = unsupported; cleared
  in `withdrawRemoteReplicas`.
- `RemotePresentationEffects.mail: (PresentationMail?) -> Void`, defaulted `{ _ in }` like its peers; the snapshot
  passes its field (nil resets), the frame passes its value.
- `AppStore.presentationMail(forSession:) -> PresentationMail`, used by `presentationSnapshot` and the flush.
- `pendingMessages(_:pane:token:)`: local row reads the bus; catalog-owned row reads `catalogMail`; any other
  remote-bound row reads `presentationMail` through the read-time mapping above.

## Implementation Steps

### Task 1: Spawn lock unlocks before close

**Files:**
- Modify: `agtermCore/Sources/SessionHostRuntime/ClientConnector.swift`
- Modify: `agtermCore/Tests/SessionHostRuntimeTests/ClientConnectorTests.swift`

- [x] write the failing regression: inside `Starter.spawnDisclaimed`, find the spawn-lock descriptor by comparing
  open fds against the `realpath` of `paths.spawnLock` (as `StateDirectoryLockTests` does) and `dup` it; after
  `startHost` returns, assert another descriptor can take `LOCK_EX | LOCK_NB`; close the dup in cleanup
- [x] run it and confirm it fails
- [x] unlock in the existing `defer` before `close`
- [x] run `swift test --filter ClientConnectorTests`; must pass

### Task 2: Async test waits

**Files:**
- Modify: `agtermCore/Tests/agtermCoreTests/HudHelperTests.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/OverlayRunJobTests.swift`
- Modify: `docs/ci-flakes.md`

- [x] record the baseline: the startup stall (first trivial `@MainActor` test durations) in `swift:6.3.2-noble`
  with 4 pinned CPUs, several runs
- [x] settle the cleanup shape: `defer { await ... }` on both toolchains, else a scoped helper
- [x] convert every pool-blocking wait listed above; `FakeOrigin.frames` keeps a 5 s bound
- [x] run both suites on macOS and in the container; every test passes
- [x] repeat the stall measurement; put both sets of numbers in the commit message and update the
  `SshConnectionPoolTests` entry in `docs/ci-flakes.md`

### Task 3: Mail counts on attached rows

One task because the new `mail` frame case breaks `RemotePresentationClient.apply`'s exhaustive switch until the
viewer handles it; no temporary ignore case.

**Files:**
- Modify: `agtermCore/Sources/agtermCore/PresentationFrames.swift`, `PresentationHub.swift`, `MessageBus.swift`,
  `AppStore+Presentation.swift`, `AppStore+Messages.swift`, `RemotePresentationClient.swift`, `Session.swift`,
  `AppStore+RemotePresentation.swift`
- Modify: `agterm/Control/ControlServer.swift`, `ControlServer+Presentation.swift`,
  `ControlServer+RemotePresentation.swift`, `agtermCore/Sources/AgtermServerKit/ServerStreams.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/PresentationFramesTests.swift`, `PresentationHubTests.swift`,
  `AppStoreMessagesTests.swift`, `RemotePresentationClientTests.swift`,
  `agtermCore/Tests/AgtermServerTests/ServerActionsMessagesTests.swift`
- Modify: `agtermTests/ControlServerRemotePresentationTests.swift`, `agtermTests/ControlServerMessagesTests.swift`
- Modify: `plugins/agterm/skills/agterm/reference.md`, `site/commands.html`, `.claude/rules/control-api.md`

Origin side:

- [ ] write the convergence regressions first: (a) publish 1, all subscribers leave, ack, a new subscriber's
  snapshot is empty, a send brings it 1; (b) subscriber A has 1, an ack to empty is pending, B subscribes and
  snapshots empty, the count returns to 1 before the flush, both end at 1; (c) an unchanged map sends nothing
- [ ] `PresentationMail`, the snapshot field, the `mail` frame kind (encode/decode), `supportedKinds`; codec test
  pinning the JSON object shape and an old snapshot decoding with nil mail
- [ ] `MessageBus` observer token fired by send, read with ack, ack and dispose
- [ ] hub-owner registration and coalesced flush (`ControlServer` with stop/start, `ServerStreams` with
  init/shutdown); snapshot and flush share `presentationMail(forSession:)`
- [ ] per-subscriber baseline in `PresentationHub`, advanced after the sink accepts, held frames not deduped
- [ ] tests: send, read with ack, ack, split close, primary promotion, scratch drop and ended row each converge
  to the right map on a server origin; run the regressions; must pass

Viewer side:

- [ ] `effects.mail` callback with a default; snapshot applies its field (absent resets), frame replaces
- [ ] `Session.presentationMail`, cleared in `withdrawRemoteReplicas`
- [ ] read rule in `pendingMessages(_:pane:token:)` and `scratchPendingMessages`
- [ ] tests: counts on a standalone attached row for main, split, an origin split added after attach, the
  scratch on the session (`scratchPendingMessages`) and on its `surfaces[]` node; reconnect with a cleared
  mailbox reads nil; an origin without the field reads nil; a catalog-owned row still reads the catalog
- [ ] hosted: count read-back through the real `remoteEffects` wiring; Mac-origin publication after ack
- [ ] docs: read-back notes in `reference.md` and `site/commands.html` (counts now on rows attached alone and
  from another Mac), the source rule in `control-api.md`; in the same `commands.html` paragraph, correct the
  stale claim that `events read` is not served on agterm-server (`ServerEvents.swift` serves it)
- [ ] run the touched suites; must pass

### Task 4: Link target on hover

**Files:**
- Modify: `agterm/Ghostty/GhosttyCallbacks.swift`, `agterm/Ghostty/GhosttySurfaceView.swift`,
  `agterm/Views/TerminalView.swift`, `agterm/Views/QuickTerminal.swift`
- Create: `agtermCore/Sources/agtermCore/LinkHover.swift`, `agtermCore/Tests/agtermCoreTests/LinkHoverTests.swift`
- Modify: `site/docs.html`

- [ ] check whether libghostty at `83fb956` gates `MOUSE_OVER_LINK` on `link-previews`; record the answer here
- [ ] handle `GHOSTTY_ACTION_MOUSE_OVER_LINK`; write the hovered link into the surface's hover model
- [ ] `TerminalView` wrapper with the `@Observable` hover model and the non-hit-testing bottom-leading label;
  `QuickTerminalPane` gets the same; clears on mouse exit, hide, host move and teardown
- [ ] `LinkHover` label text: neutralized control and bidi-format scalars, one line, middle truncation, session
  name for a resolving `agterm://session/` link
- [ ] build and launch an isolated Debug instance and show Eugene the label (http link, session link, split pane,
  zoomed pane, scratch, quick terminal, HUD, remote pane) before writing tests
- [ ] `LinkHoverTests`: plain URL, session link resolving and not, each neutralized scalar class, truncation;
  hosted test that the action sets and clears the hover model
- [ ] `site/docs.html`: one line where links are described
- [ ] run the touched tests; must pass

### Task 5: Backlog, verification and gates

- [ ] `git rm` the four fixed items; correct the two stale item texts
- [ ] verify every Overview item is implemented
- [ ] `cd agtermCore && swift test`, `make test-app`, `make lint`, each once
- [ ] `lsappinfo list | grep -A4 agterm.debug` after the hosted run
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

- After merge, confirm the Linux CI core run's startup stall against the Task 2 numbers.

Smells pre-check: skipped — non-Go project
