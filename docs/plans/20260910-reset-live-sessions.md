# Reset Live Sessions

## Overview

Panes created before v0.28.0, or without the session host, lose their macOS responsible-process
attribution when the agterm that created them exits. Every process inside such a pane becomes its own
responsible process, so a TCC-gated request is charged to that process: each new Claude Code version asks
for the microphone again and adds a per-path row to the Microphone list. Responsibility is decided at
spawn and cannot be reassigned (`responsibility_set_pid_responsible_for_pid` is EPERM; a re-exec keeps the
existing children self-responsible, measured 2026-09-10), so the only repair is a new process under the
host. Today that means recreating each pane by hand, or a Fresh shells relaunch followed by a switch back
to Live and a second relaunch.

This plan adds one user-facing action, Help ▸ Reset Live Sessions…, and its control command `zmx.reset`.
The action shows how many live sessions it resets and that agterm quits and reopens itself; on confirm the
app quits cleanly, ends only the confirmed daemons at the next launch, and the existing Live restore
recreates those panes through the session host with their quit-captured commands started again. Nothing
is automatic: no upgrade notice, no launch-time detection, only this dialog or an explicit `--force`
control request.

Measured on the maintainer's Mac on 2026-09-10: 95 daemons, 93 leaders resolve to themselves, 2 resolve to
the host started on 2026-09-09; the tree reads them correctly. That Mac is the sizing case: one reset
covers about 93 panes.

## Context (from discovery)

- `agterm/agtermApp+Menus.swift:400` Help group holds the installers; the new item joins it.
- `agterm/AppDelegate.swift:303` quit confirmation alert; `:317` `applicationWillTerminate` runs
  `captureOnExit`, `finalizeAllPendingCloses`, unchecked `saveAllOpen`, `saveIndex`.
  `WindowLibrary.saveAllOpenChecked()` (`WindowLibrary.swift:556`) reports snapshot write success.
  `ExitCapture` is `([Session]) -> Int` (`AppDelegate.swift:6`): a count of slots written, best effort
  under a 500 ms budget; zero is not failure.
- `GhosttyApp.capturesForegroundOnExit` includes Live; `AppDelegate.makeExitCapture` reads the CONFIGURED
  mode, not the launch latch (`GhosttyApp.swift:65-73`).
- `agterm/agtermApp.swift:272-300` `restoredRuntime` runs from `agtermApp.init()` on the main thread
  before any scene body, is skipped entirely under `isHostedUnitTest`, builds `ZmxClient` (`@MainActor`,
  synchronous invocations, 3 s default timeout, `captureInvocationTimeout = 0.1`) and passes a
  `launchInventorySink` that `WindowLibrary.init` invokes INSIDE the initializer
  (`WindowLibrary.swift:144-145`); that closure reaps and then calls
  `foregroundResolver.noteLifecycleChange()`. `ZmxReapPolicy.namesToKill` (`ZmxLifecycle.swift:101`)
  kills only zero-client daemons and, in Live, only unclaimed ones, in ONE `zmx kill … --force` invocation.
- `ZmxClient.killConfirmed(name:)` classifies zmx's exact output; a zero exit is not a kill. zmx prints
  `killed session` when connections close, before its own 500 ms HUP/KILL cleanup finishes, and may
  unlink the socket while the leader still runs, so leader exit is the only real confirmation.
  `ZmxClient.sessionLeaderPIDs` returns nil on a failed listing and `ZmxLeaderMap.leaders` drops rows
  without a leader pid, so a name-to-pid map cannot tell absent from unreadable; `ZmxListParser.parse`
  records keep that distinction.
- `SessionHost.classify(leader:responsible:hostPid:appPid:)` in agtermCore is the attribution classifier.
  `LiveAttributionProbe` (`ControlServer+Zmx.swift:359`, internal, visible across the app target)
  supplies responsible/host/app pids. The tree wrapper enumerates only realized `backedByZmx` surfaces
  and cannot serve pre-restore discovery or closed windows.
- `WindowLibrary.paneClaims()` (`WindowLibrary.swift:816`) walks open and saved window claims, including
  split panes, each carrying `sessionID`, and reports `complete`.
- Control: `ControlProtocol.swift` commands `zmx.list/prune/kill`, `force` arg; dispatch in
  `ControlDispatcher+Zmx.swift`; actions in `ControlDispatcher.swift:150-155` (file at 978 lines against
  the 1000-line lint limit), defaults in `ControlActionsDefaults.swift`, app implementation in
  `ControlServer+Zmx.swift`; `ControlTree` in `ControlProjection.swift:351`. CLI in
  `agtermctlKit/ZmxCommands.swift`. `restoreStatus()` carries configured/requestedAtLaunch/active.
  `ControlServer.swift:417-419`: `handleConnection` runs the dispatch on the main actor through
  `runBlocking`, then the static `writeResponse` writes the reply on the accept thread with no
  per-request state, so a termination scheduled during dispatch can run before the reply is written.
- Notifications: `NotificationManager.start()` runs in the window task (`agtermApp.swift:210`), after
  `restoredRuntime`; keymap and config diagnostics recorded at boot are posted there behind the
  `hasReopened` gate (`agtermApp.swift:214-224`).
- Live replay: `ZmxLaunch.surfaceSeed` (`ZmxLaunch.swift:100-115`) takes the pending replay and, when
  nil, falls back to `initialCommand`/`splitInitialCommand`; a missing daemon runs the payload, a
  surviving one ignores it and reattaches. Replay is consumed only at `provider.resolve` during the real
  spawn. `ZmxReplayScript.render` adds no resume flags and the denylist still applies.
- `/usr/bin/open` on this Mac documents `--env VAR=value`.
- Test frameworks: `agtermCoreTests` and `agtermctlKitTests` are swift-testing (`@Test func
  descriptiveName()`, `#expect`); `agtermTests` is XCTest (`testXxx`). Zmx CLI coverage lives in
  `ZmxCommandsTests.swift`.
- Docs listing zmx commands: `plugins/agterm/skills/agterm/{SKILL,reference,examples,troubleshooting}.md`,
  `site/commands.html`, `docs/troubleshooting.md:270-289`, `.claude/rules/control-api.md` zmx section,
  `.claude/rules/windows.md` quit section.
- Chat review with codex and a plan-review pass settled: marker armed only after capture ran and the
  checked save succeeded; explicit selection by name regardless of client count; one batched kill and a
  group leader poll under one budget; launch narrows the confirmed set and never widens it; an
  unconfirmed pane starts neither its replay nor its durable command; a partial reset is reported; item
  shown only when configured AND launched mode are both Live (Eugene's choice: hidden, not disabled);
  replay promises no agent resume.

## Development Approach

- **testing approach**: TDD. Each task writes the failing test first, runs it, then implements.
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional; a new function gets a test, a new branch gets a case
  - cover success and error scenarios
- **CRITICAL: all tests must pass before starting next task**
- **CRITICAL: update this plan file when scope changes during implementation**
- gates run ONCE at the end (task 7): build, `cd agtermCore && swift test`, `make test-app`, `make lint`;
  every intermediate run names the tests that task created, with `--filter` or
  `-only-testing:<Target>/<Class>/<test>` per method
- host-free logic (marker codec and store, selection, narrowing, outcome shaping, protocol, CLI, text)
  lives in `agtermCore`; the app target holds the alert, quit path, waiter spawn and zmx invocations
- no `public` symbol without a caller outside its module; `agtermCore` is consumed by `agterm-linux`, so
  new public surface is minimal and Darwin-free
- no sleeps in unit tests: the consumer is generic over its clock and takes an injected liveness check;
  real waits use disposable child processes
- no comments that narrate code; the sketches below carry none

## Testing Strategy

- **unit tests**: `agtermCoreTests` for `LiveReset` (selection, narrowing, marker store, text, menu
  predicate), `ControlDispatcherZmxTests` for `zmx.reset`, `ControlProtocolTests` for payload round trips,
  `agtermctlKitTests/ZmxCommandsTests` for the CLI
- **hosted tests** (`make test-app`, `agtermTests`): the control action gating and acknowledgement written
  before termination, the quit ordering, the relauncher with a disposable child, the launch orchestration
  through an injected seam, and the seed suppression
- **no XCUITest**: the alert is chrome, the command quits the app, and the Help item's visibility predicate
  is host-free; the exemption is recorded in `control-api.md` in task 8
- manual verification on an isolated Debug instance is Task 7; the deployed reset is Post-Completion

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix

## Solution Overview

Three moments, one selection that only narrows:

1. **Confirm (running app).** The action builds the reset set: every pane claim from
   `WindowLibrary.paneClaims()` whose daemon leader classifies as `orphaned` or `app`. `unknown` and
   `supervisor` are excluded. `app` is included because this quit turns it into `orphaned`. The dialog
   counts SESSIONS (distinct `sessionID` among the targets) and says agterm quits and reopens. On confirm
   the pane targets are held in memory, the quit alert is bypassed, and the app terminates normally.
2. **Quit (`applicationWillTerminate`).** The existing best-effort capture runs, then the CHECKED snapshot
   save. Capture is invoked, not judged: its count is not a success signal. Only when the checked save
   returns true is the marker written atomically to `<stateDir>/live-reset.json` with the confirmed
   targets (pane identity, session id, daemon name, observed leader pid). Then the detached waiter is
   spawned. If the waiter cannot be spawned the marker is removed and the quit proceeds as an ordinary
   quit.
3. **Launch (`restoredRuntime`, after the library is built, before reap and any surface).** The marker is
   consumed (renamed away) BEFORE the first kill, so a crash mid-reset never repeats it. The consumer
   lists daemons fresh, joins the marker targets against current pane claims, and keeps only targets that
   are still claimed, still listed with the SAME leader pid, and still classify as `orphaned`. It sends
   ONE batched `zmx kill <names…> --force` for exactly those, then polls the leaders as a group until each
   exits, all under one 15 s operation budget. A target no longer listed is `gone` and restores normally;
   one no longer claimed, with a changed leader, unreadable, or no longer orphaned is `skipped`. The
   batch's exit status is not consulted: zmx processes names sequentially, so a failed or timed-out
   invocation may already have reached some daemons, and every selected leader is polled regardless. A
   leader still alive at the deadline is `unconfirmed`. Unconfirmed panes get a
   transient suppression for this launch, keyed by pane identity on `LaunchSpawnContext`, that makes
   `surfaceSeed` attach with NEITHER the captured replay NOR the durable
   `initialCommand`/`splitInitialCommand`, without deleting either from the model: the attach reconnects
   to the old process if its endpoint is still reachable, yields a plain shell only when it is gone, and
   in neither case starts a second copy of the command. The ordinary reap and restore then run, and the
   consumed marker file is deleted once the outcome is recorded. The outcome is recorded on
   `GhosttyApp.shared`, logged, exposed on the tree, and posted as one notification from the window task
   once `NotificationManager` has started, behind the same `hasReopened` gate as the diagnostics. The
   notification counts SESSIONS, derived from the targets' `sessionID`: a session is reset only when every
   one of its targets was killed and confirmed or was gone; a session with any `skipped` or
   `unconfirmed` target is partially reset. A partial reset is never silent.

Design decisions:

- **Kill at launch, not at quit.** The exiting app is still attached to the daemons and the replay is
  only safe once the checked snapshot exists. Launch already owns the reap seam; the app-side closure
  stops reaping inside `WindowLibrary.init` and reaps after the consumer, so claims exist before the
  reset runs. Replay is consumed only at `provider.resolve` during the real spawn, so a consumer that
  runs before `restoredRuntime` returns is always ahead of it.
- **One batched kill, then leader liveness.** Per-name `killConfirmed` would cost one subprocess per
  target on a cold launch with no window on screen, about 93 on the sizing case. The existing reap
  already kills in one invocation; exit status and per-name output are not the oracle, leader exit is.
  The batch invocation runs under a 5 s timeout; leader polling takes the rest of the budget and runs
  whatever the invocation returned, because a sequential client that fails midway has already killed
  some names and possibly unlinked their sockets, and restoring those panes normally would start the
  duplicate command the suppression exists to prevent.
- **Reply before quit is tied to the reset reply.** The connection thread quits only after it has
  written the reply to a successful `zmx.reset` request, decided from that request and that response,
  never from a shared flag: remote workers write other replies in parallel and an unrelated completion
  must not quit the app while the reset reply is still held.
- **Marker carries targets, not a flag.** A boolean would re-select at launch, when every `app` pane and
  any pane whose host died has become orphaned, killing panes the dialog never counted. Launch narrows.
- **Detached shell waiter, standard launch.** `NSWorkspace` after termination cannot run in the exiting
  process, and opening before exit reaches the running instance. The waiter gets pid, bundle path and
  the state directory as positional arguments, never interpolated into shell text, streams to
  `/dev/null`, polls `kill -0` in 0.2 s steps for at most 60 s, then runs
  `/usr/bin/open -n <bundle> --env AGTERM_STATE_DIR=<state>` (the `--env` only when the variable is set).
  It exits without launching when the old pid never goes away.
- **Reply before quit.** The action sets a main-actor flag on `ControlServer`; `handleConnection` checks
  it only after `writeResponse` reports the full frame written, then hops to the main actor without
  blocking the accept thread and calls `NSApp.terminate`. A held or failed write never quits.
- **Gate on both modes.** Item and command require `configured == .live && active == .live`; a pending
  switch away from Live would clear captures at quit and relaunch non-Live.
- **Wording.** No zmx, daemon or attribution words in the menu, dialog, or notification.

## Technical Details

`agtermCore/Sources/agtermCore/LiveReset.swift` (new, host-free):

```swift
public enum LiveReset {
    public struct Target: Codable, Hashable, Sendable {
        public let paneIdentity: UUID
        public let sessionID: UUID
        public let daemon: String
        public let leaderPID: Int32
    }
    public struct Marker: Codable, Equatable, Sendable {
        public static let currentVersion = 1
        public let version: Int
        public let createdAt: Date
        public let targets: [Target]
    }
    public struct Selection: Equatable, Sendable {
        public let targets: [Target]
        public let inventoryComplete: Bool
        public var sessionCount: Int { get }
    }
    public static func select(claims: ZmxClaimWalk, records: [ZmxSessionRecord],
                              classify: (String, Int32) -> SessionHost.Attribution) -> Selection
    public enum Disposition: String, Codable, Equatable, Sendable {
        case kill, gone, skipped
    }
    public static func narrow(marker: Marker, claimed: Set<UUID>?, records: [ZmxSessionRecord]?,
                              classify: (String, Int32) -> SessionHost.Attribution) -> Narrowed
    public struct Narrowed: Equatable, Sendable {
        public let dispositions: [Target: Disposition]
        public let inventoryFailed: Bool
        public var kill: [Target] { get }
    }
    public struct Outcome: Codable, Equatable, Sendable {
        public let panes: PaneCounts          // confirmed, killed, gone, skipped
        public let unconfirmed: [UUID]        // pane identities to suppress
        public let sessions: SessionCounts    // affected, reset, partial (distinct sessionID)
        public let inventoryFailed: Bool
    }
    public static func outcome(narrowed: Narrowed, survivors: Set<Int32>, inventoryFailed: Bool) -> Outcome
    public static let markerFilename = "live-reset.json"
    public static func dialogText(sessionCount: Int) -> (title: String, body: String)
    public static func notificationText(outcome: Outcome) -> String?
    public static func menuVisible(configured: RestoreMode, active: RestoreMode) -> Bool
}

public struct LiveResetMarkerStore {
    public init(directory: URL)
    public func write(_ marker: LiveReset.Marker) throws
    public func consume() throws -> LiveReset.Marker?
    public func removeConsumed()
    public func remove()
}
```

`write` is temp file plus rename. `consume` renames the marker to `live-reset.consumed.json` and decodes
it; a missing file is nil; an undecodable file or a version other than `currentVersion` is removed and
reported as `.invalid`; a rename failure is thrown and the caller must not kill anything. `removeConsumed`
deletes the consumed file after the outcome is recorded; `remove` deletes both on the quit-failure path.
The version field guards a hand-edited or interrupted-upgrade marker at the cost of two lines.

Dialog text, one source for the alert and the control acknowledgement:

- title: `Reset Live Sessions?`
- body: `N live sessions will be reset. Agterm quits and reopens itself right away with your sessions
  and layout. Commands that were running in those sessions are started again where possible; other work
  running in them stops, and agent conversations may need to be resumed by hand.`
- buttons: `Cancel` (default), `Reset`

Notification text, nil only when `sessions.partial == 0` and the inventory did not fail. Counts are
sessions; a session with one confirmed and one unconfirmed pane is one partial session:

- `The reset covered M of N live sessions. Run Help ▸ Reset Live Sessions… again for the rest.` followed,
  when `unconfirmed` is non-empty, by `Previous processes in K sessions may still be running, and commands
  in those sessions were not restarted.`
- inventory failed: `Live sessions were not reset: the session list could not be read.`

Control:

- `ControlCommand.zmxReset = "zmx.reset"`, app-global, no target. The dispatcher refuses without
  `--force` by name, exactly like `zmx.kill`, and never reaches the action. The app action then refuses,
  in order: not Live in both modes; inventory incomplete; zero targets.
- Response `result.liveReset: ControlLiveResetStatus { sessions: Int, panes: Int, pending: Bool }` plus
  `result.text` from `dialogText`. The reply is written before termination is requested.
- Read-back: `ControlTree` and the `zmx list` header gain `liveReset: ControlLiveResetReadback { pending:
  Int?, last: LiveReset.Outcome? }`, both omitted when nil. `pending` is the in-memory confirmed pane
  count from confirmation until quit; `last` is the outcome of the launch that consumed a marker.
- Events: none added; the action is a quit and the existing lifecycle events cover it.
- XCUITest exemption: `zmx.reset` quits the app, so it has no end-to-end UI test; recorded in
  `control-api.md` beside the catalog entry, as for `restore.mode` and `surface.cursor`.

App target:

- `ZmxClient.sessionRecords(timeout:) -> [ZmxSessionRecord]?` beside `sessionLeaderPIDs`, returning the
  parsed rows so absent and unreadable stay distinct. `ZmxClient.killBatch(names: [String], timeout:)
  -> Bool` is the existing private `kill(names:)` with an explicit timeout, exposed to the consumer.
  `ZmxClient.leadersExited<C: Clock>(_ pids: Set<pid_t>, deadline: C.Instant, clock: C, isAlive: (pid_t)
  -> Bool) -> Set<pid_t>` where `C.Duration == Duration` polls the group every 100 ms and returns the pids
  still alive at the deadline.
- `AppActions+LiveReset.swift`: `resetLiveSessions(confirmed: Bool) -> LiveResetRequestOutcome` builds the
  selection from `library.paneClaims()` and `zmxClient.sessionRecords()`, refuses per the order above,
  shows the alert unless `confirmed`, then stores `pendingLiveReset` on `AppDelegate`, sets
  `quitConfirmed`, and calls `NSApp.terminate` through the supplied `terminate` closure.
- `ControlServer`: `writeResponse` returns whether the full frame was written. `handleConnection` decides
  from the request and response it holds: when `request.cmd == .zmxReset` and `response.ok`, and only
  after `writeResponse` returned true, it schedules `DispatchQueue.main.async { server.terminateForLiveReset() }`,
  which terminates when `pendingLiveReset` is still set. No shared flag exists, so a remote worker
  finishing an unrelated reply cannot quit the app. On a false return the failure is logged and
  `pendingLiveReset` stays set so the menu or a later request can retry.
- `AppDelegate.applicationShouldTerminate` returns `.terminateNow` when `quitConfirmed`.
- `AppDelegate.applicationWillTerminate`: after capture and `finalizeAllPendingCloses`, when a pending
  reset exists use `saveAllOpenChecked()`; on `true` write the marker, then
  `LiveResetRelauncher.spawn(pid:bundle:stateDirectory:)`; on any failure remove the marker and log.
  Without a pending reset the path is unchanged.
- `LiveResetRelauncher` (app target): `Process` running `/bin/sh -c '<script>' _ <pid> <bundle> [<state>]`
  with injectable script, executable and `open` path so a hosted test can point it at a disposable child
  and a fake `open`. Returns `false` when the process cannot be launched.
- Launch orchestration, app side only (the `WindowLibrary` callback contract is unchanged):
  `LaunchOrchestration.run(library:client:probe:clock:isAlive:budget:context:)` in
  `agterm/Ghostty/LiveResetConsumer.swift`, called by `restoredRuntime` right after `WindowLibrary`
  returns and testable from `agtermTests` with injected parts. The sink closure only stores
  `prepareLaunchPaneInventory()` on `LaunchSpawnContext`. `run` then: consumes the marker; narrows against
  `library.paneClaims()` and `client.sessionRecords()`; sends the batched kill; polls leaders; records the
  unconfirmed pane identities on `LaunchSpawnContext.suppressedLaunchPayloads`; records the outcome on
  `GhosttyApp.shared.liveResetOutcome`; deletes the consumed marker; runs the ordinary
  `client.reap(knownPaneIdentities:launchDecision:)` with the stored inventory; then calls
  `foregroundResolver.noteLifecycleChange()`. Budget: 15 s for the whole operation, of which the kill
  invocation gets at most 5 s.
- `ZmxLaunch.surfaceSeed` takes the suppression set and, for a suppressed pane identity, consumes the
  pending replay without using it and passes no creation command, so hidden splits and saved windows
  loaded later follow the same rule.
- Menu: `Button("Reset Live Sessions…")` in the Help group after a divider, rendered only when
  `LiveReset.menuVisible(configured: settings.effectiveRestoreMode, active: launchRestoreMode)`.
- `ControlDispatcher.swift` sits at 978 lines: the new protocol method and its godoc must stay within the
  1000-line lint limit, otherwise the zmx block of the protocol moves to `ControlDispatcher+Zmx.swift`.

## What Goes Where

- **Implementation Steps**: everything below
- **Post-Completion**: the deployed Release reset on the maintainer's Mac

## Implementation Steps

### Task 1: LiveReset selection, narrowing, marker store, text and menu predicate

**Files:**
- Create: `agtermCore/Sources/agtermCore/LiveReset.swift`
- Create: `agtermCore/Tests/agtermCoreTests/LiveResetTests.swift` (swift-testing)

- [x] write failing tests for `select`: orphaned and app claims selected, supervisor and unknown
      excluded, a claim whose record has no leader pid excluded, a claim with no record excluded, split
      panes counted as their own target, `sessionCount` counts a split session once, `inventoryComplete`
      mirrors the walk
- [x] write failing tests for `narrow`: same name and leader still orphaned is `kill`; no record is
      `gone`; unclaimed, changed leader, unreadable row, supervisor, app or unknown is `skipped`; nil
      records yields no kills and `inventoryFailed`; nil claims yields no kills; a daemon absent from the
      marker is never added even when orphaned
- [x] write failing tests for `LiveResetMarkerStore` in a temporary directory: write then consume returns
      the marker and leaves only the consumed file; a second consume returns nil; an undecodable marker is
      removed and reported invalid; a version mismatch is invalid; `removeConsumed` deletes only the
      consumed file; `remove` clears both files
- [x] write failing tests for `outcome`: a session whose every target was confirmed or gone counts as
      reset; a session with one confirmed and one surviving pane counts as partial once; two surviving
      panes in one session count as one partial session; survivors are the `unconfirmed` pane identities
- [x] write failing tests for `dialogText` (one session, several, a split session counted once),
      `notificationText` (nil when every session reset; partial with and without unconfirmed; the
      split-session partial case; inventory failed) and `menuVisible` (true only for live/live)
- [x] implement `LiveReset` and `LiveResetMarkerStore` per Technical Details
- [x] run `swift test --filter LiveResetTests` - must pass before task 2

### Task 2: Protocol, payloads, dispatcher and CLI for `zmx.reset`

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlPayloads.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProjection.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher+Zmx.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlActionsDefaults.swift`
- Modify: `agtermCore/Sources/agtermctlKit/ZmxCommands.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherZmxTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/ZmxCommandsTests.swift`

- [x] write failing dispatcher tests `resetRefusesWithoutForce` (refused by name, action never called)
      and `resetWithForceReachesAction`; the unsupported default answers the standard message
- [x] write failing protocol tests `liveResetStatusRoundTrips`, `liveResetReadbackRoundTrips`,
      `liveResetOutcomeRoundTrips` and `liveResetIsOmittedWhenNil` for both the tree and the zmx list
      header
- [x] write failing CLI tests `resetEncodesForce` and `resetRefusesWithoutForce` in `ZmxCommandsTests`,
      with the same wording as `zmx kill`
- [x] add the command, the payloads and read-back fields, the action protocol method and default, and
      the dispatch case with the `--force` refusal first; keep `ControlDispatcher.swift` under 1000 lines
- [x] add the `Reset` subcommand with an abstract and discussion that avoid zmx internals beyond the
      group name, and print `result.text`
- [x] run `swift test --filter 'ControlDispatcherZmxTests/reset|ControlProtocolTests/liveReset|ZmxCommandsTests/reset'`
      - must pass before task 3

### Task 3: Session records, batched kill and group liveness polling

**Files:**
- Modify: `agterm/Ghostty/ZmxClient.swift`
- Modify: `agterm/Control/ControlServer+Zmx.swift`
- Create: `agtermTests/ZmxClientLiveResetTests.swift`
- Create: `agtermTests/ControlServerLiveResetTests.swift`

- [ ] write failing hosted tests `testSessionRecordsKeepUnreadableRows` and
      `testSessionRecordsNilOnFailedListing` with the fake runner
- [ ] write failing hosted tests `testKillBatchSendsOneInvocationUnderTimeout` and
      `testKillBatchReportsFailure` (the Bool is logged by the consumer, never used to skip polling)
- [ ] write failing hosted tests `testLeadersExitedReturnsEmptyWhenAllExit` and
      `testLeadersExitedReturnsSurvivorsAtDeadline` with an injected test clock and `isAlive`, no real
      sleep
- [ ] write a failing hosted test `testLiveResetSelectionJoinsClaimsAndRecords` in
      `ControlServerLiveResetTests` for `ControlServer.liveResetSelection()` with injected records and probe
- [ ] add `sessionRecords`, `killBatch`, the generic `leadersExited` and `liveResetSelection()`
- [ ] run `-only-testing:agtermTests/ZmxClientLiveResetTests -only-testing:agtermTests/ControlServerLiveResetTests/testLiveResetSelectionJoinsClaimsAndRecords`
      - must pass before task 4

### Task 4: Confirm path, reply-before-quit, quit ordering and relauncher

**Files:**
- Create: `agterm/AppActions+LiveReset.swift`
- Modify: `agterm/AppDelegate.swift`
- Modify: `agterm/Control/ControlServer.swift`
- Modify: `agterm/Control/ControlServer+Zmx.swift`
- Create: `agterm/LiveResetRelauncher.swift`
- Create: `agtermTests/LiveResetQuitTests.swift`
- Create: `agtermTests/LiveResetRelauncherTests.swift`
- Modify: `agtermTests/ControlServerLiveResetTests.swift`

- [ ] write failing hosted tests in `LiveResetQuitTests` with an injected capture, checked save and
      spawner: `testCaptureRunsBeforeCheckedSave`, `testMarkerWrittenOnlyAfterCheckedSave`,
      `testNoMarkerWhenSaveFails`, `testMarkerRemovedWhenSpawnerFails`, `testOrdinaryQuitWritesNothing`
- [ ] write failing hosted tests in `LiveResetRelauncherTests` using a disposable `/bin/sleep` child as
      the old app and a fake `open` script that records its argv and environment to a temp file:
      `testLaunchWaitsForChildExit`, `testLaunchCarriesBundleAndStateEnv`, `testNoLaunchOnTimeout`,
      `testWaiterSurvivesSpawnerExit`
- [ ] write failing hosted tests in `ControlServerLiveResetTests` through the real socket:
      `testResetRefusedOutsideLive` (configured or launched), `testResetRefusedOnIncompleteInventory`,
      `testResetRefusedWhenEmpty`, `testResetReplyCarriesCountsAndText`,
      `testTerminationWaitsForReplyWrite` with a held write, `testUnrelatedReplyDuringHeldWriteDoesNotTerminate`
      (a `zmx.tree` worker completes while the reset reply is held), `testFailedReplyWriteDoesNotTerminate`
      leaving `pendingLiveReset` set
- [ ] implement `resetLiveSessions(confirmed:)`, the `quitConfirmed` bypass, the pending set on
      `AppDelegate`, `writeResponse` reporting the write, the request-specific post-write
      `terminateForLiveReset` hop, the checked-save branch in `applicationWillTerminate`, and the relauncher
- [ ] run `-only-testing:agtermTests/LiveResetQuitTests -only-testing:agtermTests/LiveResetRelauncherTests -only-testing:agtermTests/ControlServerLiveResetTests`
      - must pass before task 5

### Task 5: Launch orchestration, consumer and seed suppression

**Files:**
- Create: `agterm/Ghostty/LiveResetConsumer.swift`
- Modify: `agterm/agtermApp.swift`
- Modify: `agterm/Ghostty/GhosttyApp.swift`
- Modify: `agterm/Ghostty/ZmxLaunch.swift`
- Modify: `agterm/Notifications/NotificationManager.swift` (`notifyLiveResetOutcome(_:)` beside
  `notifyKeymapDiagnostics`)
- Create: `agtermTests/LiveResetConsumerTests.swift`
- Modify: `agtermTests/LaunchSeedTests.swift`

- [ ] write failing hosted tests in `LiveResetConsumerTests` against `LaunchOrchestration.run` with a fake
      `ZmxClient` runner, injected probe, test clock and `isAlive`: `testMarkerConsumedBeforeFirstKill`,
      `testOnlyNarrowedTargetsKilledInOneInvocation`, `testUnclaimedTargetSkipped`,
      `testChangedLeaderSkipped`, `testFailedListingKillsNothing`,
      `testFailedBatchStillPollsEveryLeader` (the batch returns false, one leader exited and restores
      normally, the other survives and is suppressed with neither replay nor durable payload),
      `testSurvivingLeaderIsUnconfirmedAndSuppressed`, `testInvalidMarkerRemovedAndKillsNothing`,
      `testNoMarkerMeansNoZmxInvocation`, `testConsumedMarkerDeletedAfterOutcome`,
      `testOrderingInventoryThenConsumerThenReap` (reap runs with the stored inventory and
      `noteLifecycleChange` follows it, no seed resolved before the consumer)
- [ ] write failing seed tests in `LaunchSeedTests`: `testSuppressedPrimaryAttachesWithoutReplayOrCommand`
      (captured argv AND non-nil `initialCommand`), `testSuppressedSplitAttachesWithoutReplayOrCommand`
      (`splitInitialCommand`), `testSuppressionConsumesReplayAndKeepsDurableCommand`,
      `testConfirmedPaneKeepsReplayInSameRun`
- [ ] implement the app-side sink closure, `LaunchOrchestration.run`, its call in `restoredRuntime`, the
      suppression set on `LaunchSpawnContext`, the `surfaceSeed` change, the outcome on
      `GhosttyApp.shared`, and the deferred notification in the window task behind the `hasReopened` gate
- [ ] run `-only-testing:agtermTests/LiveResetConsumerTests -only-testing:agtermTests/LaunchSeedTests/testSuppressedPrimaryAttachesWithoutReplayOrCommand -only-testing:agtermTests/LaunchSeedTests/testSuppressedSplitAttachesWithoutReplayOrCommand -only-testing:agtermTests/LaunchSeedTests/testSuppressionConsumesReplayAndKeepsDurableCommand -only-testing:agtermTests/LaunchSeedTests/testConfirmedPaneKeepsReplayInSameRun`
      - must pass before task 6

### Task 6: Help menu item and read-back population

**Files:**
- Modify: `agterm/agtermApp+Menus.swift`
- Modify: `agterm/Control/ControlServer.swift` (tree top level)
- Modify: `agterm/Control/ControlServer+Zmx.swift` (`zmx list` header)
- Modify: `agtermTests/ControlServerLiveResetTests.swift`

- [ ] write failing hosted tests `testTreeLiveResetReadback` (pending after a confirmed reset, last after
      a recorded outcome, omitted with neither) and `testZmxListLiveResetReadback`
- [ ] add the item after a divider in the Help group behind `LiveReset.menuVisible`, and wire the
      read-back
- [ ] run `-only-testing:agtermTests/ControlServerLiveResetTests/testTreeLiveResetReadback -only-testing:agtermTests/ControlServerLiveResetTests/testZmxListLiveResetReadback`
      - must pass before task 7

### Task 7: Verify acceptance criteria

- [ ] verify all requirements from Overview are implemented: session count and wording, reply before
      quit, quit ordering, launch narrowing, unconfirmed never replays, partial reset reported, no
      automatic trigger, gating on both modes, item hidden outside Live
- [ ] verify edge cases: empty selection, incomplete inventory, marker present without daemons, marker
      target removed from the layout, host dead between confirm and relaunch, relauncher failure, listing
      failure at launch, a kill invocation that fails midway with about 90 targets (every leader still
      polled, survivors suppressed)
- [ ] build the app, run `cd agtermCore && swift test`, `make test-app`, `make lint` once each
- [ ] run one isolated Debug instance with an isolated `AGTERM_STATE_DIR` and three panes whose daemons
      were created by a bare `zmx attach` outside the host, one of them a split of another: the Help item
      is present, the dialog counts two sessions, the app reopens into the same state directory, all three
      panes read `supervisor` afterwards, a fourth pane created through the host is untouched
- [ ] in the same instance, drive `agtermctl zmx reset --force --socket <isolated>` from outside the app
      and confirm the acknowledgement arrives before the socket closes and the relaunch happens
- [ ] the surviving-leader case cannot be staged against the real kill path, because zmx follows SIGHUP
      with SIGKILL after 500 ms; it stays in the injected consumer and seed tests, and the isolated run
      checks only that a fully reset launch posts no notification

### Task 8: Update documentation

- [ ] `.claude/rules/control-api.md`: `zmx.reset` in the catalog, refusal order, the read-back fields,
      the reply-before-quit rule, the launch-narrowing rule, and the XCUITest exemption
- [ ] `.claude/rules/windows.md`: the quit-confirmation bypass, the marker ordering and the launch
      orchestration seam
- [ ] `site/commands.html` and `plugins/agterm/skills/agterm/{SKILL,reference,examples}.md`: the command
- [ ] `docs/troubleshooting.md` and `plugins/agterm/skills/agterm/troubleshooting.md`: replace "create a
      new Live pane to replace it" with Help ▸ Reset Live Sessions… and what it does, including that a
      session which could not be reset gets no command restarted and its old process may still run, and
      that a partial reset says so and can be run again
- [ ] `site/docs.html` Live sessions section: one paragraph on the reset
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification:**

- Deploy Release, run Help ▸ Reset Live Sessions… on the maintainer's Mac with the 93 orphaned panes,
  confirm every pane reads `supervisor` afterwards and a microphone request from a Claude Code pane adds
  no new Microphone row.
- Re-check the second alert path: a control `zmx.reset --force` from an agent inside a pane kills that
  agent's own pane; the CLI discussion says so, as `zmx kill` does.

Smells pre-check: skipped — non-Go project
