# Remote group attach

## Overview

Attach a session from another Mac together with all its companions in one action. Today a remote attach
imports one row: attaching a parent brings none of its companions, a companion attached by id lands as a
standalone top-level row, and a page companion can be attached only by CLI after its parent.

- New wire command `zmx.attach.group`, CLI `zmx attach HOST ID --companions`, attaches the parent and then
  every companion under it, in the origin's sidebar order, from one discovery read.
- File ▸ Attach Remote uses it for every top-level session picked; companion rows stay pickable for a
  single attach.
- Plain `zmx.attach` of a terminal companion nests under its parent's row when that parent is attached here.
- Companions created on the origin after the attach are not followed, the same rule as a later split.
- Whole-workspace attach stays out of scope: `docs/backlog/remote-workspace-attach.md`.

## Context (from discovery)

- Far-side listing: `agtermCore/Sources/agtermCore/RemoteTree.swift` (`RemoteTreeMerger.candidates`,
  `remoteSession`) builds terminal rows, then page rows (`terminals + pages`), and drops a session whose
  panes are not all backed by a running claimed daemon.
- Wire types: `ControlRemoteSession`, `ControlRemoteTree`, `ControlResult` in
  `agtermCore/Sources/agtermCore/ControlPayloads.swift` / `ControlProtocol.swift`; synthesized Codable, so a
  new optional field is additive and ignored by an older reader.
- Dispatch: `ControlDispatcher+Zmx.swift` validates `zmx.attach` (host, plain remote id, window) and calls
  `ControlActions.attachRemoteSession`.
- App: `agterm/Control/ControlServer+Zmx.swift` (`attachRemoteSession`, `RemotePlacement`, `attach(_:from:host:placement:)`),
  `agterm/Control/ControlServer+RemoteCompanions.swift` (`attachRemotePage`, `attachRemotePageRow`,
  `attachCreatedCompanion`, which already re-resolves the parent's store and workspace after each wait).
- Picker: `agterm/AppActions+RemoteAttach.swift` (`attachRemote`, `RemoteAttachHud`, `RemoteAttaching`).
- CLI: `agtermCore/Sources/agtermctlKit/ZmxCommands.swift` (`Attach`); the older-app mapping precedent is
  `companionSend` / `runCompanionRequest` in `Session+Companions.swift` (`refusesUnknown`).
- Command lists that name `.zmxAttach` and need the new case beside it: `ControlDispatcher.swift` category
  switch, `HtmlBridge.placedLocally`, `ControlServer.swift` network-waiting set and the
  dispatcher-handled fallback list.
- Precedent for a separate wire command over a flag: `.claude/rules/control-api.md` Companions (an older app
  drops an unknown `ControlArgs` key and runs the plain command; an unknown command fails to decode and
  mutates nothing).
- Persistence: `Session.isPersistable` excludes remote rows, unchanged by this work.

## Development Approach

- **testing approach**: Regular (code first, tests in the same task)
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - write tests for new and modified functions and methods
  - add cases for new code paths, success and error alike
  - update existing tests where behavior changes
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- scope test runs to what changed (`swift test --filter`, `-only-testing:<Target>/<Class>/<test>`); each
  full gate (`swift test`, `make test-app`, `make lint`) runs once, in the acceptance task
- before the first build in this worktree, symlink the ignored GhosttyKit/zmx artifacts and stamps from the
  main checkout per CLAUDE.md "Worktrees and local builds", after checking the stamps match
- `ControlActions` is public and consumed by `agterm-linux`: every new requirement gets a defaulting
  implementation in the public extension that refuses with the unsupported-host message
- maintain backward compatibility: plain `zmx.attach` keeps its wire shape; an older origin and an older
  local app each degrade as described below

## Testing Strategy

- **package tests** (`agtermCore`, `swift test`): payload round-trips, `RemoteTreeMerger` membership,
  dispatcher validation, CLI request building and output formatting
- **hosted tests** (`make test-app`): `ControlServer` group attach and companion nesting against the
  existing fake `RemoteCommandRunner`; `AppActions` picker flow against the existing picker/HUD fakes. These
  are the end-to-end coverage: a real attach needs a second Mac, which no automated test has
- no XCUITest: no existing UI test drives remote attach, and the picker flow is covered hosted

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview

The far side already holds the whole workspace model when it answers `zmx tree`, so it states group
membership there: each top-level terminal row lists every companion in sidebar order, attachable or not.
The requester then knows the real order (pages and terminals interleaved) and can name a member it could
not bring. Attaching walks that list against the same snapshot, reusing the existing single-row
`attach(_:placement:)` and `attachRemotePage` paths, so presentation streams, pane lead and respawn
bookkeeping stay keyed per local row exactly as today (codex checked: no same-host collisions).

A separate wire command, not a flag on `zmx.attach`, so a newer CLI against an older running app fails
before creating anything instead of silently attaching one row.

Partial failure keeps what attached. Rolling back rows whose ssh panes are already starting is worse than a
named gap, and the caller can retry a single member with plain `zmx attach`.

## Technical Details

**Far-side membership** (`ControlRemoteSession`):

- `companions: [ControlRemoteMember]?`, `ControlRemoteMember { id, name }`.
- Set only on a top-level terminal row (`parent == nil`, `content == nil`): every companion of that session
  in the origin's sidebar order, from the unfiltered workspace sessions, terminal and page, attachable or not.
- `[]` means known to have none. Absent means unknown: an older origin, or a companion/page row.

**Wire command**: `Command.zmxAttachGroup = "zmx.attach.group"`, same `target` (remote session id),
`args.host`, `args.window` as `zmx.attach`, validated by the same dispatcher code path.
`ControlActions.attachRemoteGroup(host:session:window:)`, defaulted to a refusal.

**Requester flow** (`ControlServer.attachRemoteGroup`):

1. One `remoteTree(host:)` read; find the target by id.
2. Refuse before creating anything: target missing, target with `parent != nil` (terminal or page
   companion: `"\(id) is a companion, not a group's parent"`), target that is a page.
3. Resolve the window as `attachRemoteSession` does; attach the parent with `select: true`.
4. Members: from `companions` when present (`membershipKnown: true`); else the listed rows whose `parent`
   is the target, in returned order (`membershipKnown: false`).
5. For each member, in order: re-resolve the parent's current store and workspace
   (`library.store(forSession:)`, `store.workspace(forSession:)`); a parent closed here stops the loop and
   marks every remaining member `parent row was closed`. A member with no row in `sessions` is
   `unavailable on <host>`. A terminal member attaches through `attach(_:from:host:placement:)` with
   `RemotePlacement(parent: parentID, select: false)`; a page member through
   `attachRemotePage(_:host:parent:select: false)`.
6. Never rereads the origin for later members, and attaches each companion once.

**Receipt**:

- `result.id`: the local parent row, present on ok and on partial failure.
- `result.remoteGroup`: `{ membershipKnown: Bool, companions: [{ origin, id?, error? }] }`, members in order.
- `ok: true` only when every member attached. Otherwise `ok: false`, `result` still set, and `error` text:
  - members failed while the group stays: `kept <parent name> (<parent id>) and N companion(s); not
    attached: <name> (<reason>), ...`;
  - the parent closed here mid-attach (closing a parent closes its group): `parent row <parent id> was
    closed; not attached: <name>, ...`.
- A member `id` in the receipt records that the row was created, not that it still exists. Created means the
  row and its pane commands or page channel exist, not that ssh connected; same meaning as `zmx.attach`.

**CLI**: `zmx attach HOST ID --companions` sends `zmx.attach.group`.

- An older app answers with its unknown-command refusal; the CLI maps exactly that (`refusesUnknown`) to
  `error: the running app is too old for group attach`, and passes the raw reply through under `--json`.
- Human success prints the parent id like `zmx attach`, then one line per companion `origin -> local id`.
- Human failure prints the server's error line, which already names the parent and missing members.
- Either outcome adds `note: <host> does not report group membership; unlisted companions cannot be
  detected` whenever the receipt says `membershipKnown: false`.

**Single attach of a companion** (`attachRemoteSession`): a terminal row with `parent` set is placed under
the single row in the chosen window's store with `parentID == nil`, the same `remoteHost`, and a binding
whose `remoteSessionID == parent` and `origin.endpoint == tree.endpoint`. With none or several it stays top
level, as today. Page rows keep `attachRemotePageRow` and its refusal.

**Picker** (`AppActions.attachRemote`):

- Every picked row with `parent == nil` goes through `attachRemoteGroup`; a picked companion through
  `attachRemoteSession`.
- `RemoteAttachHud` gains a way to move to the new parent once `result.id` is known: it closes the progress
  HUD it owns on the starting row and posts the partial report on the parent row, timed as failures are now.

## What Goes Where

- **Implementation Steps**: code, tests and docs in this repo.
- **Post-Completion**: the two-Mac manual check.

## Implementation Steps

### Task 1: Far-side group membership in `zmx tree`

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlPayloads.swift`
- Modify: `agtermCore/Sources/agtermCore/RemoteTree.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/RemoteTreeTests.swift`

- [x] add `ControlRemoteMember` and optional `companions` on `ControlRemoteSession`
- [x] fill it in `RemoteTreeMerger.candidates` for top-level terminal rows from the unfiltered workspace
  sessions in sidebar order; `[]` for none; nil on companion and page rows
- [x] write tests: mixed page/terminal order kept, an unattachable companion still listed, `[]` for no
  companions, companion rows carry none
- [x] write tests: decoding a payload without the field reads nil (older origin)
- [x] run `swift test --filter RemoteTreeTests` - must pass before task 2

### Task 2: `zmx.attach.group` wire command, dispatcher and CLI

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlPayloads.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift`
- Create: `agtermCore/Sources/agtermCore/ControlActions.swift` (the protocol, moved unchanged)
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher+Zmx.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlActionsDefaults.swift`
- Modify: `agtermCore/Sources/agtermCore/HtmlBridge.swift`
- Modify: `agtermCore/Sources/agtermctlKit/ZmxCommands.swift`
- Modify: `agtermCore/Sources/agtermctlKit/SocketClient.swift` (pure `formatRemoteGroup` beside `formatRemoteTree`)
- Modify: `agtermCore/Sources/agtermctlKit/Session+Companions.swift` (`companionSend` takes the too-old message)
- Modify: `agterm/Control/ControlServer.swift` (`waitsOnNetwork`, dispatcher-handled list)
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherZmxTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/MockControlActions.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/HtmlBridgeTests.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/ZmxCommandsTests.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/SocketClientTests.swift`

- [x] first, as its own step, move the `ControlActions` protocol unchanged from `ControlDispatcher.swift`
  (exactly 1000 lines, the strict lint limit) into a new `ControlActions.swift`; a pure move, approved by Eugene
- [x] add `Command.zmxAttachGroup`, `ControlActions.attachRemoteGroup` as a real protocol requirement with a
  refusing default (`zmx.attach.group is not supported on this platform`), and the `remoteGroup` receipt
  types on `ControlResult`; add the case to every command list that names `.zmxAttach`
- [x] dispatch it through the same host/id/window validation as `zmx.attach`, with pinned error texts
- [x] CLI `--companions` on `zmx attach` builds the new command; `Attach.run()` sends through the
  reply-returning `companionSend` wrapper, given a configurable too-old message, so it holds the
  `SocketReply` before any formatting or failure exit. Under `--json` it prints the raw line; otherwise it
  prints `formatRemoteGroup`'s lines, then the unknown-membership note to stderr on either outcome from the
  decoded `result.remoteGroup` (`printResponse` never reads `result` on a failure), then exits nonzero on
  `!ok`
- [x] write tests: dispatcher validation and routing with pinned errors; the default refusal through a
  conformer lacking the method, as `anOlderAttachHostRefusesExplicitWindowPlacement` does; receipt round-trip
- [x] write tests (`ZmxCommandsTests`): request shape with and without `--companions`; `formatRemoteGroup`
  for success, partial failure, and the unknown-membership note on both
- [x] write tests (`SocketClientTests`, beside the companion too-old cases): too-old mapping sends nothing
  else; raw reply under `--json` with no note; an actual `Attach.run` against a stub server answering a
  partial failure with `membershipKnown: false` prints the note to stderr and exits nonzero
- [x] write tests: `HtmlBridge` keeps the group attach's ids and window (beside
  `attachAndDashboardKeepTheirIdsAndLandInThePagesWindow`)
- [x] add `.zmxAttachGroup` to `ControlServer.waitsOnNetwork` here; its accept-loop test lands in Task 3,
  once the app method can reach ssh
- [x] build the app target, then run the package filters above - must pass before task 3

### Task 3: Group attach in the app

**Files:**
- Create: `agterm/Control/ControlServer+RemoteGroup.swift`
- Create: `agtermTests/ControlServerRemoteGroupTests.swift`
- Modify: `agtermTests/ControlServerRemoteCompanionsTests.swift` (move `ScriptedRunner` out)
- Modify: `agtermTests/RemotePageFakes.swift` (shared, non-private `ScriptedRunner` with its `beforeCall` hook)
- Modify: `agtermTests/ControlServerTests.swift` (accept-loop case)

- [x] move `ScriptedRunner` into `RemotePageFakes.swift` and make `beforeCall` async and awaited before the
  scripted reply, so a test's main-actor mutation (move or close the parent) has finished when the page wait
  returns; existing callers' synchronous closures keep working
- [x] implement `attachRemoteGroup` per the requester flow: one tree read, refusals before any row, parent
  then members in order, parent re-resolved before each member and once more after the last, so a parent
  closed during the final page wait reports the closed-parent error; page members through `attachRemotePage`
- [x] build the receipt and the partial-failure error text; `ok: false` with `result.id` kept
- [x] older-origin fallback from listed rows with `membershipKnown: false`
- [x] write tests: full group in mixed order lands under the parent with only the parent selected; known-empty
  group is one row and ok; companion target refused with no row created
- [x] write tests: an unavailable member, a failing terminal member and a failing page member each give
  ok false with the rest kept and the parent's id in the error; parent closed during a page wait stops the
  loop and reports the closed-parent error, both with a member after the page and with the page last
- [x] write tests: one request through `ControlDispatcher(actions: server)` reaches the app's group attach,
  as `ControlServerZmxTests` does for `zmx.attach`
- [x] write tests (`ControlServerTests`): a `zmx.attach.group` call held in `BlockingRemoteRunner` does not
  hold the accept loop, following `testARemoteCallDoesNotHoldTheAcceptLoop`
- [x] write tests: the parent moved to another workspace during a suspended page attach, followed by a
  terminal member, leaves both later children with the parent and no row in the old workspace
- [x] write tests: exactly one tree read per group attach, counted apart from the page-attach calls
- [x] write tests: older origin without `companions` attaches listed children and reports membership unknown
- [x] run `-only-testing:agtermTests/ControlServerRemoteGroupTests` - must pass before task 4

### Task 4: Single attach of a companion nests under its parent

**Files:**
- Modify: `agterm/Control/ControlServer+Zmx.swift`
- Modify: `agtermTests/ControlServerZmxTests.swift`
- Modify: `agterm/Control/ControlServer+RemoteCompanions.swift` (`attachRemotePageRow` uses the shared match)

- [x] extract the parent-row match (top-level row, same host, binding's origin session id and endpoint) from
  `attachRemotePageRow` into one helper both paths use
- [x] in `attachRemoteSession`, place a terminal companion under the single matching parent row in the
  chosen window's store, in the parent's own workspace (`store.workspace(forSession:)`), never
  `currentWorkspaceID`; else top level
- [x] write tests: nests under a matching parent that sits outside the current workspace, landing in the
  parent's workspace with `result.parent` set; stays top level with no match, with two matches, and for a
  parent attached from another host or endpoint
- [x] run `-only-testing:agtermTests/ControlServerZmxTests` - must pass before task 5

### Task 5: Attach Remote picker attaches the group

**Files:**
- Modify: `agterm/AppActions+RemoteAttach.swift`
- Modify: `agtermTests/RemoteAttachTests.swift`
- Modify: `agtermTests/AppActionsCompanionsTests.swift` (`HudRecorder` conforms to `RemoteAttaching`)

- [x] add `attachRemoteGroup` to `RemoteAttaching` and to both test conformers (`FakeAttacher`,
  `HudRecorder`); route a picked top-level row through it and a picked companion through
  `attachRemoteSession`
- [x] let `RemoteAttachHud` move to the new parent row: close its own progress HUD on the starting row and
  post a partial report on the parent. A refusal with no `result.id` stays on the starting row; a parent row
  already closed falls back to `fail()`'s notification banner
- [x] write tests: picking a parent attaches the group, including a parent whose listing shows `companions: []`;
  picking a companion attaches one row; a partial
  failure posts its timed report on the new parent and leaves the starting row without a HUD
- [x] run `-only-testing:agtermTests/RemoteAttachTests` - must pass before task 6

### Task 6: Documentation and agent skill

**Files:**
- Modify: `site/commands.html`
- Modify: `site/docs.html`
- Modify: `plugins/agterm/skills/agterm/SKILL.md`
- Modify: `plugins/agterm/skills/agterm/reference.md`
- Modify: `.claude/rules/control-api.md`
- Modify: `.claude/rules/menu-actions.md`

- [x] `site/commands.html`: `zmx attach --companions`, the `remoteGroup` read-back, `companions` on `zmx tree` rows
- [x] `site/docs.html`: the remote attach section (group attach, picker behavior, partial failure, snapshot
  only) and the companions paragraph (a companion attached alone nests under its attached parent)
- [x] skill: reference entries for both changes and a SKILL.md pointer for group attach
- [x] `control-api.md`: add `zmx.attach.group` to the catalog; update the Remote sessions bullet that says each
  attach imports one session; note the separate-command reason beside the Companions precedent; add
  `zmx.attach.group` to the commands that wait on the network; extend the note that only page rows nest on
  `zmx attach` to terminal companions
- [x] `menu-actions.md`: `attachRemote()` composes the group attach for a top-level pick
- [x] ➕ README.md and site/llms.txt one-line remote summaries mention companions

### Task 7: Verify acceptance criteria

- [x] verify every Overview item is implemented and the backlog item matches what shipped
- [x] run `make build` (Release; `make test-app` builds Debug only)
- [x] run `cd agtermCore && swift test`
- [x] run `make test-app`
- [x] run `make lint` with zero findings
- [x] run `lsappinfo list | grep -A4 agterm.debug` after the hosted run and clear leaked test processes

### Task 8: [Final] Update documentation

- [x] update README.md only if its remote-attach demo needs the new flag (done in Task 6)
- [x] update CLAUDE.md if new patterns were discovered (none: the contracts live in `.claude/rules/control-api.md`)
- [x] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification** (needs a second Mac running a build with this change):

- attach a parent with a terminal companion, a split companion and a page companion from File ▸ Attach Remote
  and confirm order, nesting, and that only the parent is selected
- attach against a far side running the previous release and confirm the membership-unknown note
- `zmx attach --companions` from a CLI against a running app that predates the change prints the too-old error

Smells pre-check: skipped — non-Go project
