# Flagged view reorder

## Overview
- The flagged view refuses every drag (`WorkspaceSidebar+DragDrop.swift:13`) because it is a derived, tree-order
  projection with no order of its own. Users treat its flat and plain layouts as a cross-workspace working set
  and want to arrange it.
- Flat and plain layouts get a per-window saved flagged order, reorderable by drag across workspaces.
- The flagged tree layout gets drag with ordinary-tree semantics: reorder inside a workspace and move between
  workspaces, written to the real tree, with hidden unflagged siblings left where they are.
- Navigation follows the order the current layout shows. The control API gains a flagged-order move and
  read-back.

## Context (from discovery)
- membership: `Session.flagged`, mutators in `agtermCore/Sources/agtermCore/AppStore+SessionState.swift`
  (`setFlag(_:forSession:)`, `setFlag(_:forSessions:)`, `clearFlags()`); `workspace.flag` for Flag All.
- projection: `AppStore.flaggedSessions` (`AppStore.swift:895`, tree order), read for order by
  `WorkspaceSidebar.swift:428,517` and `navigableSessions` (`AppStore+Focus.swift:199`); other readers use
  emptiness or count only.
- flagged tree rows: `Coordinator.workspaceProjection` (`WorkspaceSidebar+FlaggedLayout.swift`).
- drag: `WorkspaceSidebar+DragDrop.swift` (source guard :13, `resolveSessionMove` :124 rejects a nil item,
  spring expansion guard :201); host-free arithmetic in `agtermCore/Sources/agtermCore/SidebarDrop.swift`
  (`resolveSessions`, `workspaceInsertIndex` as the visible-to-full precedent).
- observation: `WorkspaceSidebar.updateNSView` (:101-114) is the only observation registration site; it reads
  the store fields the sidebar renders from.
- arrivals of a flagged session outside `setFlag`: `AppStore+RecentClosed.swift` (session reopen :34, workspace
  reopen :57, merge :121-122), all through `session(from:)` (`AppStore+Snapshot.swift:91`); pending-close undo
  in `AppStore+PendingClose.swift`.
- close reselection: `closeSession` removes the session before `closeReselectionTarget`, passing its old tree
  location (`AppStore.swift:565-583`); `nearestInScopeTarget` walks tree order (`AppStore+CloseReselection.swift:37-45`).
- per-window state: `WindowLibrary.stores` holds one `AppStore` per window; only `FlaggedViewLayout` is app-wide.
  `restoredRuntime` builds a `WindowLibrary` at `agtermApp.swift:379` (hosted-test branch) and `:391`; the
  convenience init is `WindowLibrary.swift:133`.
- control: `session.flag` (`ControlProtocol.swift:27`); the dispatcher passes `mode` raw
  (`ControlDispatcher.swift:437-438`) and the app parses it (`ControlServer+SessionActions.swift:642-646`);
  `ControlArgs.before/after` exist (`ControlProtocol.swift:258,260`); fallbacks in `ControlActionsDefaults.swift`.
- line budget (`make lint`: 1000 per source file, 2000 per test file, zero findings): `AppStore.swift` 998,
  `WindowLibrary.swift` 990, `ControlDispatcher.swift` 991, `ControlServer+SessionActions.swift` 951,
  `CommandsTests.swift` and `ControlProtocolTests.swift` 2000 each.

## Development Approach
- **testing approach**: Regular (code first, then tests in the same task)
- complete each task fully before moving to the next; tests for every change in the task that makes it
- during a task run only what it changed: `swift test --filter <Suite>` for core, and the exact added or
  changed hosted/UI methods with `-only-testing:<Target>/<Class>/<test>`; each full gate (`swift test`,
  `make test-app`, `make lint`) runs once, in Task 6
- keep the flagged-dashboard recipe as is: it reads `workspaces[].sessions[]` and stays tree-ordered

## Testing Strategy
- **unit tests** (`agtermCore` swift-testing): order model, arrivals, persistence round trip and legacy seed,
  lifecycle, close reselection, `SidebarDrop` table tests for both layouts, dispatcher and CLI parsing,
  projection read-back
- **hosted tests** (`agtermTests`): settings propagation of the layout, the app-side `session.flag move` action
- **UI tests** (`agtermUITests`): the drag adapter is covered here, not by simulated hosted drags:
  a flat-layout between-row drop (nil-item gap) and a collapsed flagged-tree target with hidden siblings in
  `ReorderUITests`, plus a control round trip asserting `flaggedOrder` and sidebar row order

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- keep plan in sync with actual work done

## Solution Overview
- **Saved order** is an observable ordered `[UUID]` on each `AppStore`, persisted in `Snapshot`.
  `Session.flagged` stays the membership truth; the list orders it. Rank fields on sessions were rejected:
  Recent Closed reopens into other windows and undo after a reorder would revive stale ranks.
- **Arrivals are written when they happen**: every path that makes a flagged session present appends it to the
  live list at that mutation, so later arrivals and flags land after it. A read-time fallback only covers
  ids the list lacks after a legacy or damaged load.
- **Two orders, by layout**: flat and plain render and navigate in saved order; the flagged tree renders and
  navigates in tree order. A tree-layout move never rewrites the saved order.
- **Tree-layout drag** reuses the ordinary session move (`moveSessions`), which already handles ownership,
  flags, selection, persistence and tree events. Only the index translation is new.

## Technical Details
- **Order maintenance** (new `AppStore+FlaggedOrder.swift`; only the stored property lives in `AppStore.swift`):
  - the list is observable (not `@ObservationIgnored`, unlike `sessionRecency`)
  - flag on appends; Flag All keeps existing positions and appends the newly flagged in tree order; flag-on of
    an already flagged session changes nothing
  - unflag and Clear Flagged remove ids; Recent Closed reopen (session and workspace) and pending-close undo of
    a session no longer in the list append it at that mutation
  - a pending close leaves its id in the list, so undo puts it back in place; finalization of the close prunes
    it, so a later Recent Closed reopen really appends
  - the immediate deletion paths, `closeSession` and `removeWorkspace`, bypass pending-close finalization, so
    each prunes its ids itself, after capturing the close-reselection neighbours
  - a move reorders only live ids and keeps parked pending-close ids where they are
  - the ordered projection is the list filtered to flagged sessions present in the tree, followed by any
    flagged tree session the list lacks, in tree order (legacy and repair fallback only)
  - save writes the projection; a legacy snapshot without the key seeds from flagged sessions in tree order
- **Layout-aware projection**: `flaggedSessions` keeps tree order (membership readers and the flagged tree);
  the ordered projection serves flat and plain. Each store carries a non-persisted mirror of the effective
  layout, and `navigableSessions` picks the ordered projection under flat and plain.
- **Close reselection**: `closeSession` and soft close capture the closing session's flagged-order neighbours
  before removal, and `nearestInScopeTarget` uses them under flat and plain, keeping its same-workspace-first
  scope policy.
- **Mirror seeding**: `ContentView.resolveStore` applies window settings only after `WindowLibrary.loadStore`
  has restored, and restore ends in `reselectIfSelectionHidden`, which reads `navigableSessions`. So
  `WindowLibrary` holds the effective layout and copies it onto each store at creation, BEFORE restore, on
  launch, new window and closed-window reopen alike. Its initial value is a `WindowLibrary.init` parameter
  assigned before `bootstrap()` (`WindowLibrary.swift:156`), defaulting to flat in the convenience init: launch
  restores windows inside `init`, called from `agtermApp.restoredRuntime` (`agtermApp.swift:114`, both library
  constructions at :379 and :391), and `SettingsModel` is built only after it (`:123`), so `agtermApp` passes
  `settingsStore.load().effectiveFlaggedViewLayout` through `restoredRuntime`. Later changes go through
  `SettingsModel.applyFlaggedViewLayout`, which sets both the `GhosttyApp` copy the sidebar renders from and the
  `WindowLibrary` mirror, before the appearance notification. Nothing else sets either copy.
- **Flat and plain drop** (`SidebarDrop`, host-free): rows are one list in saved order; a gap's slot is a
  position in that list; a drop ON a session row lands after it; a multi-row drag moves the dragged ids as one
  block in their saved order; a drop that leaves the order unchanged is a no-op. A nil-item gap resolves against
  the flat group, never rejected.
- **Flagged-tree drop** (`SidebarDrop`, host-free):
  - full pre-removal source indexes and a translated full pre-removal destination go into `resolveSessions`;
    removals are subtracted once there; visible highlight indexes stay separate
  - a gap before a visible flagged row anchors immediately before that row; the gap after a group's last
    flagged row anchors immediately after that row; a drop ON a session row lands immediately after it
  - a drop ON a workspace row appends after the workspace's last real session (ordinary-tree semantics)
  - no-op compares per-session ownership plus each group's flagged order, never flattened ids, since moving
    X's last row to Y's first can keep flat order while changing owner
  - workspace rows stay non-draggable in the flagged tree, since unflagged workspaces are hidden there
- **Spring expansion**: `scheduleSpringLoadedExpansion` gates on `rendersWorkspaceRows`, not `.tree`, so a
  collapsed flagged-tree group opens under a drag and the moved row can be revealed.
- **Sidebar observation**: `updateNSView` reads the saved order; `currentShape()` (:428) and the flat roots
  (:517) use the ordered projection, so a CLI move redraws the flat list.
- **Control API**:
  - `session.flag` mode `move` with `--before ID` or `--after ID`, reusing `ControlArgs.before/after`
  - the dispatcher (new `ControlDispatcher+SessionFlag.swift`) checks: `move` needs exactly one anchor, and
    `--before`/`--after` outside `move` are refused; `on`, `off`, `toggle`, `clear` and bare toggle pass
    through unchanged
  - a new `ControlActions` requirement performs the move, with an unsupported fallback in
    `ControlActionsDefaults` so outside conformers (the agterm-linux fork) still build; the app action checks
    that source and anchor are flagged and in the same window, and reorders the saved list only
  - tree read-back: top-level `flaggedOrder` reports the ordered projection (omitted when empty);
    `workspaces[].sessions[]` order is unchanged
  - the core move calls `scheduleTreeChanged()` on a real change, so drag and CLI share it, and stays silent on
    a no-op. `tree.changed` is a payload-free refresh signal the library coalesces per window
    (`WindowLibrary.swift:973-979`), so no event arguments or `EventFormatter` change
  - tree-layout moves need no new command: `session.move` already covers them

## What Goes Where
- **Implementation Steps**: code, tests and docs in this repository
- **Post-Completion**: manual checks and the downstream fork note

## Implementation Steps

### Task 1: Make room in the files at the line limit

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`, `AppStore+Snapshot.swift`

- [x] move `restore(from:)` (`AppStore.swift:910-951`) into `AppStore+Snapshot.swift`, with the internal access
      it needs: `freshWorkspaceID` (private, :238) and the `sessionRecency` setter (`public private(set)`, :125)
      become `internal`-reachable through a helper or relaxed access, never a public setter
- [x] no behavior change: run `swift test --filter` over the restore and snapshot suites - must pass before task 2

### Task 2: Saved flagged order in the core model

**Files:**
- Create: `agtermCore/Sources/agtermCore/AppStore+FlaggedOrder.swift`, `WindowLibrary+FlaggedLayout.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift` (stored properties only),
  `AppStore+SessionState.swift`, `Snapshot.swift`, `AppStore+Snapshot.swift`, `AppStore+PendingClose.swift`,
  `AppStore+RecentClosed.swift`, `AppStore+CloseReselection.swift`, `WindowLibrary.swift` (stored mirror and
  init parameter only)
- Create/Modify: tests in `agtermCore/Tests/agtermCoreTests/` (new `AppStoreFlaggedOrderTests.swift`,
  `SnapshotRoundTripTests.swift`, `AppStorePendingCloseTests.swift`, `RecentClosedTests.swift`,
  new `WindowLibraryFlaggedLayoutTests.swift`, since `WindowLibraryTests.swift` is at 1963 of 2000 lines)

- [x] add the observable list, maintained by every flag mutator and Clear Flagged
- [x] append at every other arrival: Recent Closed session reopen, workspace reopen and merge, pending-close
      undo of an id the list no longer holds; keep parked pending-close ids on move and prune them at
      finalization; prune on hard close and workspace delete, after capturing reselection neighbours
- [x] add the move operation (block of ids before or after an anchor, both flagged, same store) and the ordered
      projection with its legacy fallback; emit `scheduleTreeChanged()` on a real move only
- [x] persist the projection in `Snapshot`, seed legacy snapshots in tree order
- [x] add the layout mirror on `AppStore` and `WindowLibrary` (init parameter assigned before `bootstrap()`,
      flat default in the convenience init, copied onto each store at creation before restore, propagation in
      the extension); `navigableSessions` stays tree-ordered until Task 4
- [x] write tests: append, Flag All keeping positions, idempotent flag-on, unflag/clear pruning, move (before,
      after, block, no-op, parked ids kept, unknown or unflagged ids rejected), tree event on move and none on a
      no-op, round trip, legacy seed
- [x] write tests: arrivals keep append order (reopen B then A placed earlier in the tree gives [C,B,A]; flag D
      after reopening B gives [C,B,D]), workspace reopen, hard close of B in [A,B,C] then reopen gives
      [A,C,B], workspace delete then reopen appends its flagged sessions, undo after an intervening reorder,
      undo after Clear Flagged, Recent Closed reopen into another window, mirror seeded before restore and
      propagated to two open stores
- [x] run the new and changed suites with `swift test --filter` - must pass before task 3

### Task 3: Drop arithmetic for both flagged layouts

**Files:**
- Modify: `agtermCore/Sources/agtermCore/SidebarDrop.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/SidebarDropTests.swift`

- [x] add the flat/plain resolver: visible slot or on-row drop in saved order to a block move, nil-item gaps
      included, no-op detection in saved order
- [x] add the flagged-tree translation: visible slot, on-session-row and on-workspace-row drops to full
      pre-removal destination for `resolveSessions`, with the anchor rules and the ownership-plus-group-order
      no-op
- [x] write table tests for the flat resolver: up, down, top, bottom, on a row, multi-row block, no-op, empty
- [x] write table tests for the tree translation: hidden siblings before and after the anchor, end-of-group gap,
      on a session row, on a workspace row, cross-workspace move, the owner-change case that keeps flat order,
      no-ops
- [x] run `swift test --filter SidebarDropTests` - must pass before task 4

### Task 4: Sidebar drag, rendering and navigation

**Files:**
- Modify: `agterm/Views/WorkspaceSidebar+DragDrop.swift`, `agterm/Views/WorkspaceSidebar.swift`,
  `agterm/Views/WorkspaceSidebar+FlaggedLayout.swift`, `agterm/SettingsModel.swift`, `agterm/agtermApp.swift`,
  `agtermCore/Sources/agtermCore/AppStore+Focus.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreNavigationTests.swift`, `agtermTests/SettingsModelTests.swift`,
  `agtermTests/SidebarFlaggedLayoutTests.swift`, `agtermTests/SidebarWorkspaceFlagTests.swift`,
  `agtermTests/AppActionsPaletteTests.swift`, `agtermUITests/ReorderUITests.swift`

- [x] allow session drags in flagged mode; keep workspace rows non-draggable under the flagged tree
- [x] route flat/plain drops to the saved-order move and flagged-tree drops through the translation into
      `moveSessions`; highlight in visible space
- [x] read the saved order in `updateNSView`; render flat and plain from the ordered projection
      (`currentShape`, flat roots) and switch `navigableSessions` to it in the same step
- [x] close reselection under flat and plain walks the saved order: deletion paths prune after the reselection
      block, so the raw list still holds the removed id's position when `nearestInScopeTarget` runs
- [x] switch spring expansion to `rendersWorkspaceRows`
- [x] pass the loaded layout through both `restoredRuntime` library constructions; make
      `SettingsModel.applyFlaggedViewLayout` the only setter of both layout copies, and convert the touched tests
      that call `GhosttyApp.shared.setFlaggedViewLayout` directly
- [x] write tests: navigation per layout (flat order vs tree order), close reselection without MRU in a saved
      order that differs from tree order, two open windows switching layouts, closed-window reopen, a library
      initialized with a saved non-default layout, a custom flat order, a hidden selection and no eligible MRU
- [x] write UI tests: a flat between-row drop across workspaces; a collapsed flagged-tree target with hidden
      siblings, asserting visible order, ownership, selection and an unchanged saved flat order
- [x] run the added and changed methods with `-only-testing` and `swift test --filter` - must pass before task 5

### Task 5: Control API and CLI

**Files:**
- Create: `agtermCore/Sources/agtermCore/ControlDispatcher+SessionFlag.swift`,
  `agtermCore/Tests/agtermctlKitTests/SessionMetadataCommandsTests.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift` (one dispatch line), `ControlActionsDefaults.swift`,
  `ControlProjection.swift`, `AppStore+FlaggedOrder.swift` (read-back), `agtermCore/Sources/agtermctlKit/SessionMetadataCommands.swift`,
  `agterm/Control/ControlServer+SessionActions.swift` (or a new extension if it nears the limit)
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherSessionMetadataTests.swift`, `MockControlActions.swift`,
  `agtermTests/ControlServerFlaggedLayoutTests.swift`, `agtermUITests/ControlSidebarStatusUITests.swift`

- [x] add `session.flag move` with `--before`/`--after`: dispatcher checks, new `ControlActions` requirement with
      an unsupported default, app action checking flagged and same window
- [x] add top-level `flaggedOrder` to the tree read-back
- [x] write tests: dispatcher parsing and refusals, existing modes unchanged, `flaggedOrder` populated through
      `AppStore.controlTree` and omitted when empty, CLI argument mapping
- [x] write a hosted test of the app action: success, unknown anchor, unflagged anchor, anchor in another window
- [x] write one UI round trip: move via CLI, read `flaggedOrder` back and assert the sidebar row order
- [x] run the added and changed suites and methods - must pass before task 6

### Task 6: Verify acceptance criteria
- [x] verify flat and plain reorder across workspaces, tree-layout moves, navigation per layout, arrivals and
      lifecycle, control move and read-back
- [x] run `cd agtermCore && swift test`
- [x] run `make test-app`
- [x] run `make lint`
- [x] build and launch an isolated Debug instance and drag in all three layouts

### Task 7: [Final] Update documentation
- [x] `site/docs.html` flagged view section; `site/commands.html` for `session flag move` and `flaggedOrder`
- [x] `plugins/agterm/skills/agterm/` reference and SKILL.md pointer
- [x] `.claude/rules/sidebar.md`: drag in the flagged view, the saved order and two orders by layout, the
      observation sentence, and the layout-ownership note at :98-99 (the store now mirrors the layout;
      `rendersWorkspaceRows(flaggedLayout:)` keeps its signature)
- [x] `.claude/rules/menu-actions.md` close reselection order; `.claude/rules/control-api.md`
- [x] move this plan to `docs/plans/completed/`

## Post-Completion
**Manual verification**:
- drag in flat, plain and flagged tree with hidden unflagged siblings; restart and confirm the saved order
- undo a close after reordering; reopen a flagged session from Recent Closed into a different window

**Downstream**:
- melonamin/agterm-linux conforms to `ControlActions`; the unsupported default keeps it building, and its flat
  list stays tree-ordered until it adopts the projection

Smells pre-check: skipped — non-Go project
