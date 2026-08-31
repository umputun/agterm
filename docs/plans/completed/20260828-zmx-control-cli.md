# zmx control commands and restore mode read/set

## Overview

Live sessions mode leaves the user with no way to see or manage the daemons behind their panes. The
docs mention "manual zmx kill" five times — README, `site/docs.html`, and the installed skill's
`SKILL.md`, `reference.md` and `troubleshooting.md` — as a cause of a pane coming back fresh, and never
say how to do it: no binary path, no `ZMX_DIR`, no naming scheme. The restore mode itself is a Settings-only
picker whose active value no control surface reports.

This adds a `zmx` command group over the control socket — `list`, `prune`, `kill` — plus a
`restore mode` read/set, so a user can answer "which daemons exist, who owns them, which are leaked"
and act on the answer without learning zmx's own CLI.

The group is deliberately named `zmx`, making the backend part of the CLI compatibility surface. The
accepted cost is a misnamed group if a future remote backend is not zmx. The benefit is that a user who
sees an `agterm-3f2a…` process in `ps` can search one word and land on our docs.

## Context (from discovery)

- protocol: `agtermCore/Sources/agtermCore/ControlProtocol.swift` (`Command` enum, `ControlArgs`,
  `ControlResponse`), dispatch in `ControlDispatcher.swift` (`ControlActions` protocol at `:7`, app-command
  switch at `:725`)
- app arms: `agterm/Control/ControlServer.swift` and its `+*Commands` extensions;
  `clearRestoreCommands`/`captureRestoreCommands` at `:515`/`:536` are the closest precedent
- CLI: `agtermCore/Sources/agtermctlKit/Commands.swift:91` registers the subcommand list;
  `MiscCommands.swift` holds `Restore` (`:60`) and `Theme` (`:112`)
- daemon side: `agterm/Ghostty/ZmxClient.swift` — today it exposes only `reap`, `kill(paneIdentities:)`
  and `sessionLeaderPIDs()`, always appends `--force`, and is a local in `restoredRuntime` captured by
  the finalizer/reap/resolver closures; `ControlServer` has no reference to it
- host-free lifecycle: `ZmxLifecycle.swift` (`ZmxListParser`, `ZmxReapPolicy`, `PaneIdentityInventory`),
  `ZmxSupport.swift` (`daemonName(for:)`, `socketDirectory(forStateDirectory:)`)
- window state: `WindowLibrary.swift` — `bootstrap()` at `:589`, `prepareLaunchPaneInventory()`,
  `closeWindow` at `:445` (keeps daemons), `removeWindow` at `:482` (kills them)
- pending close: `AppStore+PendingClose.swift` — `softCloseSession` at `:58`, 3s
  `pendingCloseGraceInterval`; `PendingSessionClose` already holds the `Session` objects and metadata
- exit path: `GhosttySurfaceView.didHandleProcessExit` (`:171`, guard at `:498`) is the existing
  idempotence bit; `agtermApp.handlePaneExit` (`:360-381`) runs the model transition *and* the promoted
  survivor's font callback, `DashboardController.promoteSplitMember`, and the refocus
- settings: `AppSettings.restoreMode`, `SettingsModel.setRestoreMode` at `:222` (swallows save failure
  with `try?`); `AppStore.setRestoreCommand` (`AppStore+Restore.swift:27`) is the rollback-on-failure
  precedent; latch `GhosttyApp.restoreLaunchDecision` at `:65`
- targeting: `ControlTargetResolver` searches OPEN stores only
- docs surfaces: `README.md`, `.claude/rules/control-api.md`, `site/commands.html`, `site/docs.html`,
  `plugins/agterm/skills/agterm/{SKILL.md,reference.md,troubleshooting.md,examples.md}`

## Development Approach

- **testing approach**: TDD — write the failing test first for each task
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - the inventory join is host-free `agtermCore` logic with many state combinations; test it there
  - cover success and error paths, and every state a row can take
- **CRITICAL: all tests must pass before starting the next task**
- **CRITICAL: update this plan file when scope changes during implementation**
- `agtermCore` stays free of AppKit and GhosttyKit; app-target code is the side-effect adapter
- run the gates ONCE at the end (`make build`, `swift test`, `make test-app`, `make lint`), and scope
  everything else to what changed via `-only-testing:`

## Testing Strategy

- **unit tests**: required for every task. Host-free logic in `agtermCore/Tests/agtermCoreTests/`, CLI
  request shaping in `agtermCore/Tests/agtermctlKitTests/`, app-target behavior in `agtermTests/`
- **one test file per source file**: `ZmxInventory.swift` → `ZmxInventoryTests.swift`, never a third file
- **protocol round-trip**: every new command and payload gets a case in `ControlProtocolTests.swift`
- **dispatcher**: every new `ControlActions` member gets a `MockControlActions` entry and a
  `ControlDispatcherTests` case, including the refusal paths
- **hosted tests are required for the kill path**: store-only tests cannot prove that the queued
  `onExit` callback was actually suppressed, nor that the dashboard follow-up ran. The refocus stays
  unproven either way: it needs a first responder no hosted test has
- **UI tests**: only where a live daemon is genuinely required. `ZmxLiveUITests.swift` already carries the
  opt-in (`AGTERM_UITEST_ENABLE_ZMX=1`); add at most one end-to-end case there and never re-run the whole
  `ControlAPIUITests` suite to verify a narrow change

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- keep the plan in sync with the work actually done

## Solution Overview

One authority: every command goes over the control socket, so a running instance joins five sources into
one answer — live stores, pending-close records, checked closed-window snapshots, the
directory-versus-index comparison, and the observed daemon list. With agterm stopped the commands fail
with "no instance"; there is no standalone path and no hybrid fallback, because a second authority would
report a weaker truth (it can see neither pending-close nor live-model state) under the same command name.

`zmx list` is the primitive. `prune` and `kill` are actions over rows it has already explained, so a user
can always see why a row is eligible before acting on it.

Safety is conjunctive, not a single predicate. `prune` acts on a daemon only when the inventory is
complete, ownership is conflict-free, the identity is unmatched by any claim, and the daemon was observed
detached. None of those terms is incidental: a closed-but-remembered window's panes are claimed with zero
clients, which is the normal steady state, so "zero clients" alone can never imply orphan. Explicit
ownership is the primary guard; the detached check is independently load-bearing on top of it.

The gate is checked and revalidated, not atomic, and the plan says so rather than implying otherwise. Pinned zmx has no
kill-if-detached operation — `--force` is consulted only when the connection FAILS (`main.zig:1008`), and
a successful connection sends `.Kill` unconditionally while the daemon breaks its loop with no client
check (`loop.zig:469-471`). So a client attaching between the listing and the kill is not caught. That
window is narrowed rather than closed, because closing it needs an upstream zmx capability and the
project pins zmx and runs no fork. Prune narrows it by re-listing immediately before it mutates anything
and dropping any candidate no longer observed at zero clients, with model resolution held on the main
actor so agterm's own claims cannot move underneath the operation.

What remains is an external attach between that second listing and the kill. It is narrow — the
candidates are daemons no pane claims, so someone must reach an unclaimed daemon by name from outside
agterm — but it stops being far-fetched once `zmx list` prints daemon names and the docs make the word
user-facing, so the docs must say plainly that such a client can be terminated.

`kill --force` is the escape hatch, and it requires an explicit target and pane. Not because other close
commands are recoverable — control `session.close` is already immediate and `session split close` has no
Reopen path — but because kill destroys a backend process rather than a model object. It can reach a
claim that no window currently shows, and it takes down every client attached to that daemon, so there is
no useful default for who is affected.

## Technical Details

### Restore status object

Shared by `restore mode` and the `zmx list` header, so there is one definition rather than three
reporting surfaces:

```swift
public struct ControlRestoreStatus: Codable, Sendable, Equatable {
    public let configured: String        // settings.json value, what the NEXT launch will request
    public let requestedAtLaunch: String // what THIS process requested
    public let active: String            // what it actually got after eligibility
    public let restartRequired: Bool     // configured != requestedAtLaunch
    public let unavailableReason: String? // ONLY on an actual requested-live fallback

    public init(configured: RestoreMode, requestedAtLaunch: RestoreMode, active: RestoreMode,
                unavailableReason: String?)
}
```

Raw `String` on the wire, typed `RestoreMode` at the producer. `RestoreMode`'s decoder is deliberately
lossy — `RestoreMode(rawValue: raw) ?? .none` at `RestoreMode.swift:11`, so a settings file written by a
newer build is not discarded — and reusing it on the wire would make a stale CLI silently print a future
mode as `none`. Every other evolvable enum on a control node (`status`, `statusPane`, `splitAxis`,
`sidebarMode`) is already projected as a raw string; this follows that.

`configured` is not merely "requested": once Settings can change after launch there are two distinct
requested values, and collapsing them hides exactly the case a user hits when they flip the picker and
nothing happens. Fallback is explained by `active` plus `unavailableReason`, not by a separate flag.

`RestoreLaunchDecision` stores the probed eligibility reason even when the requested mode was `none` or
`rerun`, so the status must publish `unavailableReason` only when live was requested AND fell back.
Reporting the raw probe otherwise tells a `rerun` user their shell is unsupported for a mode they never
asked for.

### Inventory row

```swift
public enum ZmxClaimState: String, Codable, Sendable {
    case claimed, orphan, unknown, conflicted, pendingClose, foreign
}

public enum ZmxDaemonObservation: String, Codable, Sendable {
    case running      // observed, client count known
    case unreadable   // observed, but zmx reported err= for it
    case absent       // claimed by a pane, not present in the listing
}

public enum ZmxOwnerWindowState: String, Codable, Sendable {
    case open, closed, unindexed
}

public struct ControlZmxEntry: Codable, Sendable, Equatable {
    public let daemon: String
    public let state: String            // ZmxClaimState.rawValue
    public let observation: String      // ZmxDaemonObservation.rawValue
    public let clients: Int?            // nil unless observation is "running"
    public let leaderPID: Int32?
    public let windowID: String?
    public let windowName: String?
    public let windowState: String?     // ZmxOwnerWindowState.rawValue
    public let workspaceID: String?
    public let workspaceName: String?
    public let sessionID: String?
    public let sessionName: String?
    public let pane: String?            // "left" | "right"

    public init(daemon: String, state: ZmxClaimState, observation: ZmxDaemonObservation,
                windowState: ZmxOwnerWindowState?, ...)
}
```

The enums stay typed inside `ZmxInventory` and at the producer initializer; the wire carries their raw
strings, for the same reason as the restore status above. A strict enum on the wire would make a future
state fail the WHOLE response rather than one field, which is worse than an unrecognized string.

`observation` exists because `clients == nil` alone is ambiguous today: it means both "claimed but the
daemon is gone" and "zmx reported `err=` for this row". Prune must treat those differently, so the wire
shape has to separate them.

IDs and names both: the names make the human table readable, the IDs make `--target` stable across a
rename.

No `cwd` field. `ZmxListParser` reads only `name=`, `clients=`, `pid=` and `err=`, so a cwd column would
mean extending `ZmxSessionRecord` and the parser first. That is a separate change and not needed to
answer "who owns this daemon"; add it later if a user asks.

`unreadable` rows are reported but neither pruneable nor killable in v1, for the socket-unlink reason
above. `foreign` covers a daemon in the namespace whose name is not `agterm-<compact uuid>`. It is
reported so the user can see it, and it is never pruneable — the namespace is derived from the state directory, not
owned exclusively by us.

**Deliberate departure from the earlier design discussion**: `daemon` is exposed. The argument for
hiding it was that zmx should stay an implementation detail, and naming the group `zmx` retired that
premise. The name is the correlation key for `ps`, logs and prune output. It is NOT `kill`'s input:
mutation is addressed by owner, which is the safer contract.

### Join and gate

```swift
public enum ZmxInventory {
    public static func join(observed: [ZmxSessionRecord], claims: [ZmxPaneClaim],
                            inventoryComplete: Bool) -> ZmxInventoryResult
}

public enum ZmxPrunePolicy {
    /// Nil when no prune is safe. Every term is required: complete inventory, conflict-free ownership,
    /// unmatched identity, and a daemon observed detached. Never returns a `foreign` name.
    public static func namesToPrune(_ result: ZmxInventoryResult) -> [String]?
}
```

`ZmxReapPolicy` stays as it is — it answers the launch question against persisted names only. The new
join answers the richer runtime question and does not replace it.

### Claim walk must not mutate

`PaneIdentityInventory.upgrade` mints missing pane identities and every current caller saves the result.
A read command must not write snapshots, so the claim walk needs its own non-mutating pass rather than a
flag on the existing one — a flag leaves the mutating default one careless caller away from `zmx list`
rewriting window files.

A snapshot that is missing a pane identity therefore makes the inventory **incomplete** rather than being
silently upgraded. That is the honest answer for a read: something is unaccounted for, so prune refuses.

### Window enumeration

`prepareLaunchPaneInventory` walks the index. `bootstrap()` only calls `recoverOrphanedWindows()` when
`loadIndex()` returns nil, so a valid-but-stale `windows.json` missing a surviving `windows/<uuid>.json`
leaves that file unscanned. The claim walk must therefore enumerate `windows/*.json` itself and compare
against the index: an extra checked snapshot contributes `claimed` rows marked `unindexed`, and an
unreadable one makes the inventory incomplete so `prune` refuses.

This does not fix the underlying gap — that is
`docs/backlog/stale-window-index-orphans-a-window-file-silently.md`, filed 2026-08-20 from the PR #452
review and out of scope here. It stops the new commands from inheriting it.

### App-side zmx dependency

There is nothing for `ControlServer` to call today. `ZmxClient` must gain a parsed listing and an
**unforced** kill, and the instance must be handed to `ControlServer` rather than living only inside
`restoredRuntime`'s closures, injected so hosted tests can substitute a runner:

```swift
// ZmxClient
func listSessions() -> [ZmxSessionRecord]?        // parsed, distinguishing err= rows
func killObservedOrphan(names: [String]) -> [String: ZmxKillOutcome] // per-name, never passes --force
```

`kill(paneIdentities:)` keeps `--force`, because semantic deletion means the pane is gone whatever the
daemon is doing. Prune must NOT reuse it, for a reason that is NOT the detached gate: on a connection
failure, `--force` unlinks the socket, prints `cleaned up stale session` and exits zero, which can leave a
live but unresponsive daemon running, orphaned and unreachable by name, while reporting success. So prune
never passes `--force`, invokes names individually, and counts success ONLY from the exact confirmed
`killed session <name>` line — which zmx prints after draining the connection to EOF, so it means the
daemon actually hung up (`main.zig:1042`). `cleaned up stale session`, unresponsive, absent and
not-found are all NOT kills, and none of them triggers a model change.

The name is `killObservedOrphan`, not `killIfDetached`: it kills what the listing observed as an orphan
and guarantees nothing about detachment at the moment of the kill. A method name that promises the gate
zmx cannot provide is how this design got its blocker in the first place.

The per-name outcome matters for the response: a single `Bool` cannot say which names died, so a batch
either reports per daemon or defines its partial-failure semantics explicitly. An empty namespace is a
successful empty listing, not an error.

### Kill orchestration

`ZmxClient.kill` runs synchronously on the main actor while the surface's `onExit` is queued behind it,
so returning `ok` immediately would leave the next `tree` or `zmx list` briefly stale. Two wrong fixes to
avoid:

- a new suppression flag on the view. `didHandleProcessExit` already IS that state; a second flag is
  parallel state that will drift.
- a store-only transition. `AppStore` alone bypasses `agtermApp.handlePaneExit`, which also rewires the
  promoted survivor's `onFontSizeChange`, calls `DashboardController.promoteSplitMember`, and refocuses
  the surviving or reselected surface.

What the plan requires instead is one shared app-level exit coordinator, reached by both the natural
`onExit` and the kill path:

- mark the exit handled **after** a successful kill and before the main queue drains, through a method on
  the view's existing idempotence state. Marking it before the kill strands a later natural exit if the
  kill fails.
- then run the same model transition plus the dashboard and focus follow-ups `handlePaneExit` runs.
- the store transition must exclude the already-killed identity from `paneFinalizer`, or the finalizer
  re-kills a dead name and, on a session close, reaches the sibling pane's daemon too.

Outcomes, which are guarded rather than flat:

| Target | Result |
|---|---|
| Attached split, both surface slots live | that split closes, primary untouched |
| Attached split, either slot nil | `closeSplitPane` closes the SESSION (`AppStore+Panes.swift:203-209`) |
| Attached primary with a realized survivor | survivor promoted, font callback and dashboard membership move with it |
| Attached primary with no realized survivor | `closeSession`, which finalizes every remaining claimed identity including an unrealized sibling |
| Claimed daemon, detached (closed window, unrealized surface, fallback) | no `onExit` fires; the persisted pane starts fresh on its next attach |
| Claimed pane whose daemon is `absent` | refused: nothing to kill, so neither suppression nor model transition runs |
| Row observed `unreadable` | refused in v1: a forced kill there may only unlink the socket and exit zero, leaving the daemon alive |
| Any daemon with more than one client | every attachment dies |

Either the plan states these guarded outcomes, or implementation proves an invariant that makes the
defensive branches unreachable for a kill target. It must not flatten them again.

A `zmx kill` invoked from the very pane it targets can kill the calling `agtermctl` before it reads the
server's reply. `session close` has the same shape; this command's help must say so.

### Kill targeting

`ControlTargetResolver` searches open stores only, and `zmx kill` is designed to reach closed and
unindexed claims. So the dispatcher validates that target, pane and force are all PRESENT, and the
app-side inventory resolver does the resolution and names the owner. The dispatcher cannot both refuse
before calling the host and name the resolved owner; owner naming belongs where the inventory is.

## What Goes Where

- **Implementation Steps** (`[ ]` checkboxes): protocol, dispatcher, app arms, CLI, tests, docs
- **Post-Completion** (no checkboxes): manual verification against a live daemon, and the decisions that
  stay deferred

## Implementation Steps

### Task 1: Host-free inventory model and join

**Files:**
- Create: `agtermCore/Sources/agtermCore/ZmxInventory.swift`
- Create: `agtermCore/Tests/agtermCoreTests/ZmxInventoryTests.swift`

- [x] write failing tests for `ZmxInventory.join`: claimed, orphan, unknown, conflicted, pendingClose,
      foreign, and a claimed pane whose daemon is absent
- [x] write failing tests separating the three `ZmxDaemonObservation` cases, especially `unreadable`
      (an `err=` row) from `absent`
- [x] write failing tests proving `unknown` rather than `orphan` when `inventoryComplete` is false
- [x] write failing tests for duplicate pane identities producing `conflicted` for every row involved,
      never an arbitrary owner
- [x] add the state enums, `ZmxPaneClaim`, `ZmxInventoryResult` and `ZmxInventory.join`
- [x] add `ZmxPrunePolicy.namesToPrune` with the conjunctive gate, and tests that each term alone blocks,
      including that a `foreign` name is never returned
- [x] run tests - must pass before task 2

### Task 2: Non-mutating claim walk over windows

**Files:**
- Modify: `agtermCore/Sources/agtermCore/WindowLibrary.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/WindowLibraryTests.swift`

- [x] write a failing test: a valid index missing one `windows/<uuid>.json` yields that file's panes as
      `claimed` with `windowState: .unindexed`
- [x] write a failing test: an unreadable extra snapshot marks the inventory incomplete
- [x] write a failing test: a snapshot with a missing pane identity marks the inventory incomplete and
      leaves the file byte-identical on disk — the read path mints nothing and saves nothing
- [x] write a failing test capturing `windows.json` as well, so a future helper calling `saveIndex()`
      cannot satisfy the narrower `windows/*.json` assertion
- [x] add a read-only `paneClaims()` that enumerates `windows/*.json`, compares against the index, and
      returns claims plus a completeness flag, with its own non-mutating walk rather than a flag on
      `PaneIdentityInventory.upgrade`
- [x] carry window id and name, and mark each claim's owner window state open, closed or unindexed
- [x] run tests - must pass before task 3

### Task 3: Pending-close panes in the claim set

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore+PendingClose.swift`
- Create: `agtermCore/Tests/agtermCoreTests/AppStorePendingCloseTests.swift`

- [x] write a failing test: a soft-closed session's panes appear as `pendingClose` claims, not absent
- [x] write a failing test: after the grace expires they are gone from the claim set
- [x] add an accessor over the existing `PendingSessionClose` records, which already hold the `Session`
      and workspace metadata — no restructuring
- [x] run tests - must pass before task 4

### Task 4: ControlRestoreStatus and the restore.mode command

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/MockControlActions.swift`

- [x] write failing round-trip tests for `ControlRestoreStatus` and the `restore.mode` request/response,
      proving the wire carries raw strings and that an UNKNOWN mode string decodes without collapsing to
      `none` the way `RestoreMode`'s own lossy decoder would
- [x] write failing dispatcher tests for read (no argument) and set (each of the three modes), plus an
      invalid mode string
- [x] add `case restoreMode = "restore.mode"` and the `ControlRestoreStatus` payload
- [x] add `readRestoreMode()` / `setRestoreMode(_:)` to `ControlActions` and the dispatcher arm
- [x] run tests - must pass before task 5

### Task 5: App-side restore mode with rollback on save failure

**Files:**
- Modify: `agterm/Control/ControlServer.swift`
- Modify: `agterm/SettingsModel.swift`
- Modify: `agtermTests/ControlServerRestoreCaptureTests.swift`

- [x] write a failing test: a settings save failure answers `ok: false` with the reason AND the following
      read still reports the OLD configured mode — memory must not claim a value the disk rejected
- [x] write a failing test: the read reports all five fields from the latch and settings
- [x] write a failing test: `unavailableReason` is nil when the requested mode is `none` or `rerun`, even
      though `RestoreLaunchDecision` holds a probed reason
- [x] rework `SettingsModel.setRestoreMode` on the `AppStore.setRestoreCommand` pattern: keep the old
      value, save, restore memory on failure, return the result instead of swallowing it
- [x] implement both arms on `ControlServer`, reading the latch via `GhosttyApp.restoreLaunchDecision`
- [x] run tests - must pass before task 6

### Task 6: zmx client control surface and zmx.list

**Files:**
- Modify: `agterm/Ghostty/ZmxClient.swift`
- Modify: `agterm/agtermApp.swift`
- Modify: `agterm/Control/ControlServer.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift`
- Create: `agterm/Control/ControlServer+Zmx.swift`
- Modify: `agtermTests/ZmxClientTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/MockControlActions.swift`
- Create: `agtermCore/Tests/agtermCoreTests/ControlDispatcherZmxTests.swift`
- Create: `agtermTests/ControlServerZmxTests.swift`

- [x] write failing `ZmxClient` tests for `listSessions()`, including an `err=` row and an empty
      namespace returning a successful empty list rather than an error
- [x] write failing round-trip tests for `ControlZmxEntry` and the `result.zmx` payload
      (`restore`, `inventoryComplete`, `entries`)
- [x] add `listSessions()` to `ZmxClient`; hand the client to `ControlServer` from `restoredRuntime`
      instead of leaving it captured only by the finalizer/reap/resolver closures, injected so hosted
      tests can substitute a runner
- [x] write a failing dispatcher test for `zmx.list`, conforming `MockControlActions` to the new member —
      the shared mock must compile or `swift test` fails for every other suite too
- [x] add `case zmxList = "zmx.list"`, the payload, the `ControlActions` member and the dispatcher arm
- [x] implement the app arm: listing plus claims from tasks 2 and 3, join from task 1, status header from
      task 4
- [x] write a failing test proving a listing failure reports an error rather than an empty inventory
- [x] run tests - must pass before task 7

### Task 7: zmx.prune

**Files:**
- Modify: `agterm/Ghostty/ZmxClient.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift`
- Modify: `agterm/Control/ControlServer+Zmx.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/MockControlActions.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherZmxTests.swift`
- Modify: `agtermTests/ZmxClientTests.swift`
- Modify: `agtermTests/ControlServerZmxTests.swift`

- [x] write a failing test: prune refuses an incomplete inventory and says so, killing nothing
- [x] write a failing test: prune refuses when any row is `conflicted`, and never touches a `foreign` or
      `unreadable` name
- [x] write a failing test: prune leaves claimed, pendingClose and attached rows alone
- [x] write a failing test: `cleaned up stale session` on stdout is reported as NOT killed, since that
      path unlinks a socket and can leave a live unresponsive daemon running while exiting zero
- [x] write a failing test: prune refuses an `unreadable` row rather than forcing it
- [x] write a failing test: a candidate that gains a client between the first listing and the
      revalidation listing is dropped, not killed
- [x] add `killObservedOrphan(names:)` to `ZmxClient` — invokes names individually, never passes
      `--force`, counts only the exact `killed session <name>` line as success — leaving
      `kill(paneIdentities:)` forced for semantic deletion
- [x] re-list immediately before mutating, with model resolution on the main actor so agterm's claims
      cannot change during the operation
- [x] write failing round-trip and dispatcher tests for `zmx.prune`, extending `MockControlActions`
- [x] add `case zmxPrune = "zmx.prune"`, the `ControlActions` member and the dispatcher arm
- [x] implement the app arm over `ZmxPrunePolicy`, reporting per-daemon outcomes
- [x] run tests - must pass before task 8

### Task 8: zmx.kill through a shared exit coordinator

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+Panes.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`
- Modify: `agterm/Ghostty/GhosttySurfaceView.swift`
- Modify: `agterm/agtermApp.swift`
- Modify: `agterm/Control/ControlServer+Zmx.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/MockControlActions.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherZmxTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStorePaneTests.swift`
- Modify: `agtermTests/ControlServerZmxTests.swift`

- [x] write a failing round-trip test for the `zmx.kill` request and response in `ControlProtocolTests`
- [x] write a failing dispatcher test: a missing target, pane or force is refused before the host is
      called, and the refusal does NOT claim to name an owner
- [x] write a failing app test: the owner is named by the inventory resolver, including for a closed or
      unindexed claim that `ControlTargetResolver` cannot see
- [x] write a failing test: pendingClose, `unknown`, `conflicted`, `foreign` and `unreadable` rows refuse
      even forced
- [x] write failing tests for every row of the outcomes table, including the two guarded branches
- [x] write a failing HOSTED test: after a successful kill the queued `onExit` is a no-op, and primary
      promotion still rewires the font callback and moves dashboard membership. The refocus is NOT
      asserted: `focusAfterReparent` needs a real first responder, which a hosted test has no window for,
      so it rides `handlePaneExit` unproven rather than being claimed as covered
- [x] write a failing HOSTED test: a FAILED kill leaves the natural exit path enabled
- [x] extract the exit coordinator both `handlePaneExit` and the kill path call; mark the exit handled
      through the view's existing `didHandleProcessExit` state AFTER a successful kill, never before
- [x] write failing tests for the observation cases: an `absent` row refuses with a failure and runs
      NEITHER the suppression nor the model transition, since there is no daemon to kill; an
      `unreadable` row is REFUSED in v1, because forcing it can unlink a live daemon's socket and still
      exit zero, leaving the process running and unreachable by name
- [x] add a close seam in `AppStore.swift` that accepts a pre-finalized identity, so the no-survivor
      path reaches `closeSession` without `finalizePaneIdentities` re-killing the dead name — and
      without copying the close implementation into `AppStore+Panes.swift`
- [x] exclude the already-killed identity from `paneFinalizer` in the store transition
- [x] add `case zmxKill = "zmx.kill"`, the `ControlActions` member, the dispatcher arm and the app arm
- [x] run tests - must pass before task 9

### Task 9: agtermctl surface

**Files:**
- Create: `agtermCore/Sources/agtermctlKit/ZmxCommands.swift`
- Modify: `agtermCore/Sources/agtermctlKit/Commands.swift`
- Modify: `agtermCore/Sources/agtermctlKit/MiscCommands.swift`
- Create: `agtermCore/Tests/agtermctlKitTests/ZmxCommandsTests.swift`

- [x] write failing tests for the request each subcommand builds, including force and pane validation
- [x] add the `Zmx` group with `List`, `Prune` and `Kill`, and register it in `Commands.swift:91`
- [x] add `Mode` to the existing `Restore` group for the read/set
- [x] implement human output: a status header above the table, with owner window state and observation as
      their own columns so "closed / detached" reads as expected rather than suspicious
- [x] document in `Kill`'s help that it destroys a backend process reaching every attached client, and
      that killing the pane you are typing in can kill the calling `agtermctl` before it reads the reply
- [x] run tests - must pass before task 10

### Task 10: Documentation across every mirrored surface

**Files:**
- Modify: `README.md`
- Modify: `.claude/rules/control-api.md`
- Modify: `site/commands.html`
- Modify: `site/docs.html`
- Modify: `plugins/agterm/skills/agterm/SKILL.md`
- Modify: `plugins/agterm/skills/agterm/reference.md`
- Modify: `plugins/agterm/skills/agterm/troubleshooting.md`
- Modify: `plugins/agterm/skills/agterm/examples.md`

- [x] add the four commands, their arguments and read-back fields to `control-api.md` and
      `site/commands.html`
- [x] record in `control-api.md` why `restore.mode` reports its result through its own read and the
      `zmx list` header rather than a tree node, as the state-setting read-back rule requires
- [x] replace all five bare "manual zmx kill" mentions with the real mechanism, now that the word is
      user-facing — README included, since it carries the same unsupported escape hatch
- [x] document that these commands need a running instance, and why there is no app-down path
- [x] state that prune's gate is observed-and-revalidated rather than atomic, and that a client which
      attaches from outside agterm in the remaining window can be terminated
- [x] state the kill outcomes and that the reason for explicit addressing is backend-process destruction,
      not a recovery difference from other close commands
- [x] state no total command count on any surface, per the catalog rule

### Task 11: Verify acceptance criteria
- [x] `zmx list` reports every pane of every window — open, closed and unindexed — joined against the
      observed daemons, with `pendingClose` rows present during a soft close and `foreign` rows visible
- [x] a `zmx list` run leaves every `windows/*.json` AND `windows.json` byte-identical
- [x] `zmx prune` acts only on complete, conflict-free, unmatched, observed-detached rows, revalidates by
      re-listing before it mutates, never passes `--force`, reports per daemon, and counts only the exact
      `killed session <name>` line as a kill
- [x] `zmx kill` refuses without explicit target, pane and force, and each row of the outcomes table
      matches; a failed kill leaves the natural exit path working
- [x] `restore mode` reads all five fields, reports a save failure as a failure, and rolls memory back
- [x] every command fails with a clear "no instance" error when agterm is not running
- [x] run the gates once: `make build`, `cd agtermCore && swift test`, `make test-app`, `make lint`

### Task 12: [Final] Update documentation
- [x] `README.md` was updated in task 10; the product synopsis itself did not change
- [x] no new `CLAUDE.md` pattern emerged; the contract lives in `.claude/rules/control-api.md`
- [x] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification** (needs a live daemon, in an isolated Debug instance with a short
`AGTERM_STATE_DIR` and an explicit socket — never the default socket):

- close a window with live panes, confirm `zmx list` shows them claimed / closed / detached and that
  `prune` leaves them alone
- soft-close a session and confirm the pending-close rows during the 3s window
- force-kill an attached split and an attached primary with a survivor, and confirm the dashboard cell
  and focus follow the promotion
- remove a window's entry from `windows.json` by hand while leaving its `windows/<uuid>.json` in place,
  and confirm the `unindexed` row rather than a false orphan

**Deferred, deliberately** (do not fold into this plan):

- per-creation restore mode — rejected as scoped. A restored hidden split holds armed pending slots with
  no factory call yet, so a factory reading the current setting consumes launch-armed replay state on an
  old pane. A later design needs per-pane birth provenance, the symmetric split `backedByZmx` capture
  guard, capture fixes and its own status wording.
- pane restart as a safe alternative to kill — needs the exit coordinator above plus coordinated surface
  replacement, which is more than this plan's kill transition.
- a `cwd` column on inventory rows — needs `ZmxListParser` and `ZmxSessionRecord` extended first.
- closing prune's check-then-act window, and force-killing an `unreadable` row safely — both need an
  atomic kill-if-detached in zmx itself, which is an upstream change against a pinned rev.
- the stale-index root cause in `docs/backlog/stale-window-index-orphans-a-window-file-silently.md` —
  either a checked `saveIndex` whose failure surfaces, or an orphan scan that runs even when the index
  loads cleanly. Task 2 works around it for these commands only.

Smells pre-check: skipped — non-Go project
