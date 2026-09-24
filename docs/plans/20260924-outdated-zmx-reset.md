# Reset Live Sessions covers sessions on an outdated zmx

## Overview
- Live sessions keep their zmx processes through app upgrades, so a session keeps running the zmx it was
  created with. After a zmx change (a new `ZMX_REV` or an edited patch) those sessions miss the new
  behavior; after 0.32.0 they ignore the attach-time lead claim, so an attached pane still needs a key press.
- Agterm ▸ Reset Live Sessions… and `zmx.reset` today select only panes whose leader is not supervised
  (`orphaned`/`app`). They skip every supervised pane, which is every pane affected here.
- This extends the selection with a second reason, `outdated`: the pane's zmx session was created before this
  state directory first launched the installed zmx build. No zmx patch; detection uses `created=` from
  `zmx list` and a build id the app ships.

## Context (from discovery)
- `scripts/setup.sh` writes `.zmx-build-stamp` = `$ZMX_REV $ZMX_TARGET $ZMX_PATCH_DIGEST`; `project.yml`'s
  build phase copies the staged zmx into `Contents/MacOS/zmx` and its license into `Resources/zmx/`.
- `zmx list` prints `created=<epoch>` per session; `ZmxListParser` (`agtermCore/.../ZmxLifecycle.swift`)
  reads only `name`, `clients`, `pid`, `err`.
- `LiveReset.select` / `LiveReset.narrow` (`agtermCore/.../LiveReset.swift`): select keeps `orphaned`/`app`,
  narrow kills only a target still `orphaned`. `Marker` is version 1 with `Target(paneIdentity, sessionID,
  daemon, leaderPID)`.
- App side: `ControlServer+Zmx.liveResetSelection`, `LiveResetCoordinator` (dialog, refusals),
  `LiveResetConsumer` (next-launch narrowing and kill), `ControlLiveResetStatus` read-back.
- Tests: agtermCore `LiveResetTests`, `ZmxLifecycleTests`; hosted `LiveResetConsumerTests`,
  `LiveResetCoordinatorTests`, `ControlServerLiveResetTests`, `ControlServerZmxTests`.

## Development Approach
- **testing approach**: Regular (code first, then tests within the same task)
- complete each task fully before moving to the next
- every task includes new/updated tests for its code; all tests pass before the next task starts
- update this plan when scope changes
- a v1 marker written by an older build must still decode and behave as before

## Testing Strategy
- host-free: `cd agtermCore && swift test --filter <suite>` while working, full `swift test` once at the end
- hosted: targeted `-only-testing:agtermTests/<Class>` runs while working, `make test-app` once at the end
- no XCUITest: the reset quits the app, and control-api.md already exempts it (hosted, package and the
  isolated acceptance run)

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix

## Solution Overview
- The app bundles the zmx build id as `Contents/Resources/zmx/BUILD`, copied from `.zmx-build-stamp` by the
  same build phase that copies zmx.
- At launch, before `LaunchOrchestration.run` consumes the reset marker, the app compares the
  bundled id with `zmx-build.json` in the state directory. A different or missing record is replaced with
  `{id, changedAt}`, where `changedAt` is now floored to whole seconds. Unchanged records keep their
  `changedAt`, so an app update that ships the same zmx build flags nothing.
- zmx's `created` is whole seconds (`created_at` from `Timestamp.now().toSeconds()`), so the cutoff is whole
  seconds too and the test is strict `<`. A daemon the new build creates in the same second as the record
  is current; an old daemon created in that same second cannot be told apart and is accepted as current.
- A daemon whose `created` is before `changedAt` is `outdated`, whatever its leader's attribution,
  `unknown` and `supervisor` included. The first launch with this feature has no record, so every existing
  session counts as outdated once, which matches the state after 0.32.0.
- Selection is the union of the two reasons. A pane that qualifies for both is recorded as `outdated`:
  its next-launch check (claim, same leader, created before the cutoff) holds across the relaunch, while an
  app-attributed leader must have become orphaned. Narrowing kills an `outdated` target when it is still
  claimed, still listed with the same leader, and still created before the recorded `changedAt`;
  `unsupervised` narrowing is unchanged, as is survivor suppression.
- The cutoff is injected (`outdatedBefore: Date?`, nil by default) into the control server's selection and
  inventory and into `LiveResetConsumer.Dependencies`, so hosted fixtures that list `created=1` keep their
  current behavior unless a test sets it.
- The heuristic proves only that a session predates the recorded zmx update; the first adoption includes
  current-build sessions and an id change can be a downgrade. User text says the sessions predate the last
  zmx update and will be recreated, never that they run an older zmx.
- Rejected: comparing the process start time with the installed zmx file's mtime (every release re-signs and
  replaces zmx, so every upgrade would flag every session); labelling sessions at creation (zmx applies
  `--labels` on every attach, so a relaunch would relabel old sessions without a daemon preflight, which
  launch rules forbid); patching zmx to report its build.

## Technical Details
- `ZmxSessionRecord.createdAt: Date?` from `created=`. A malformed value and `created=0` (upstream's
  placeholder for an error row) parse as nil, meaning never outdated. It must not throw: the same parser
  feeds the launch reap, list/prune/kill and the session host (`ZmxClient.swift`, `HostBackend.swift`).
- `ZmxBuildRecord: Codable, Equatable { id: String; changedAt: Date }`, encoded with `.secondsSince1970`, with
  a pure `static func advanced(from previous: ZmxBuildRecord?, bundledID: String, now: Date) -> ZmxBuildRecord`
  that floors `now`. The bundled id is read trimmed; the stamp file ends with a newline.
- `LiveReset.Target.reason: Reason` (`unsupervised`, `outdated`), decoded as `unsupervised` when the key is
  absent. `Marker.currentVersion` becomes 2, and `LiveResetMarkerStore.consume()` accepts versions 1 and 2,
  rejecting any other as it does today.
- `LiveReset.select(claims:records:classify:outdatedBefore:)`; `narrow` gains the same cutoff.
- Dialog body counts sessions throughout. When some were selected as outdated it adds, e.g., "3 of them
  predate the last zmx update and are recreated on the current one."
- Read-back: `ControlLiveResetStatus.outdated` counts SESSIONS, matching `sessions`; an `outdated` flag on each
  `zmx list` daemon row, omitted when false, carried through `DaemonFacts`/`ZmxInventoryRow`,
  `ControlZmxEntry.init(row:)` and `formatZmx`.
- No bundled id (a build without the resource, or a failed read) means no cutoff: the outdated reason is off
  and the reset behaves as today.

## What Goes Where
- **Implementation Steps**: code, tests and docs in this repository
- **Post-Completion**: the manual reset on the user's Macs

## Implementation Steps

### Task 1: Ship the zmx build id and record when it changes

**Files:**
- Modify: `project.yml`
- Create: `agtermCore/Sources/agtermCore/ZmxBuildRecord.swift`
- Modify: `agterm/Ghostty/LiveResetConsumer.swift` (`Dependencies.outdatedBefore`), `agterm/agtermApp.swift`
- Create: `agtermCore/Tests/agtermCoreTests/ZmxBuildRecordTests.swift`

- [x] copy `.zmx-build-stamp` to `Contents/Resources/zmx/BUILD` in the zmx build phase, failing the build when
      it is missing, as the zmx copy does
- [x] add `ZmxBuildRecord` with `advanced(from:bundledID:now:)` and load/save of `zmx-build.json` in the state
      directory
- [x] ➕ compute the cutoff (`ZmxBuildRecord.launchCutoff`) in `restoredRuntime` before `LaunchOrchestration.run`
      and pass it in `LiveResetConsumer.Dependencies.outdatedBefore` and `RestoredRuntime`; the call order in
      `restoredRuntime` replaces advancing inside `LaunchOrchestration` plus an ordering test
- [x] write tests: no record, same id keeps `changedAt`, new id resets it, floored seconds, unreadable record
      treated as absent, missing or blank bundled id means no cutoff
- [x] run `swift test --filter ZmxBuildRecordTests` and the app build - must pass before task 2

### Task 2: Select and narrow outdated panes

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ZmxLifecycle.swift`
- Modify: `agtermCore/Sources/agtermCore/LiveReset.swift`
- Modify: `agterm/Control/ControlServer+Zmx.swift`
- Modify: `agterm/Ghostty/LiveResetConsumer.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ZmxLifecycleTests.swift`, `LiveResetTests.swift`
- Modify: `agtermTests/LiveResetConsumerTests.swift`, `agtermTests/ControlServerLiveResetTests.swift`
- Modify: `agterm/Control/ControlServer.swift` (injected `outdatedBefore`)

- [ ] parse `created=` into `ZmxSessionRecord.createdAt`, nil for zero or malformed values
- [ ] add `Target.reason`, bump the marker to version 2, let `consume()` accept versions 1 and 2, and select
      panes created before the cutoff as `outdated` whatever their attribution
- [ ] narrow an `outdated` target by claim, same leader and still before the cutoff; `unsupervised` unchanged
- [ ] pass the recorded `changedAt` from the selection join and from `LiveResetConsumer`
- [ ] write tests: parser (present, absent, zero, malformed, and the other parser callers unaffected), select
      (outdated only, unsupervised only, both recorded as outdated, no cutoff, same-second daemon current),
      narrow (outdated kill, replaced leader, created after cutoff), a v1 marker file consumed from disk
- [ ] write paired tests: a pane with both reasons at confirmation is killed as outdated when its leader reads
      `unknown` or `supervisor` at consumption, while an unsupervised-only or v1 target with that attribution
      is still skipped; an outdated target is skipped when the launch has no cutoff
- [ ] run the touched agtermCore suites and the two hosted classes - must pass before task 3

### Task 3: Say why in the dialog, the reply and the read-back

**Files:**
- Modify: `agtermCore/Sources/agtermCore/LiveReset.swift` (dialog text)
- Modify: `agtermCore/Sources/agtermCore/ControlPayloads.swift`
- Modify: `agterm/LiveResetCoordinator.swift`, `agterm/Control/ControlServer+Zmx.swift` (all four
  `ZmxInventory.join` call sites)
- Modify: `agtermCore/Sources/agtermCore/ZmxInventory.swift` (`DaemonFacts`, `ZmxInventoryRow`, `join`)
- Modify: `ControlZmxEntry.init(row:)`, `agtermCore/Sources/agtermctlKit/SocketClient.swift` (`formatZmx`)
- Modify: matching tests (`LiveResetTests`, `ZmxInventoryTests`, agtermctlKit tests, `LiveResetCoordinatorTests`,
  `ControlServerZmxTests`)

- [ ] dialog body counts sessions and names how many predate the last zmx update; `zmx.reset`'s `text`
      carries the same body
- [ ] `ControlLiveResetStatus.outdated` in sessions, and an `outdated` flag carried from the observed record
      through the inventory join to `zmx list` daemon rows, omitted when false
- [ ] `agtermctl zmx list` human output marks outdated rows
- [ ] write tests: dialog text with and without outdated sessions (a split session counts once), payload
      encoding and omission, and `zmx list` rows built from real `zmx list` output
- [ ] run the touched suites - must pass before task 4

### Task 4: Verify acceptance criteria
- [ ] a supervised pane created before the recorded change is offered by the menu and by `zmx.reset --force`
- [ ] an app update with an unchanged zmx build offers nothing new
- [ ] isolated acceptance run: Debug instance with its own state dir and a session created; quit it, move
      `changedAt` in `zmx-build.json` past the session's creation keeping the same id, relaunch (the cutoff is
      read once at launch), confirm the reset, and the pane comes back on a new zmx session
- [ ] full `swift test`, `make test-app`, `make lint` and the build, once each

### Task 5: [Final] Update documentation
- [ ] `.claude/rules/control-api.md`: the reset section gains the outdated reason, the build record and the
      narrowing rule
- [ ] `site/docs.html` Reset Live Sessions text and `site/commands.html` for `zmx.reset` / `zmx list` fields
- [ ] bundled `plugins/agterm/skills/agterm/` wherever the reset is described
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion
- After deploying, run Agterm ▸ Reset Live Sessions… once on each Mac to move the sessions created before
  0.32.0 onto the current zmx. Running Claude Code and Codex conversations need to be resumed by hand.
- A Debug build pointed at the default state directory with a different zmx build id records its own
  change; isolated state dirs avoid that, as for every other manual run.
