# Companion Reparenting

## Overview
- A companion cannot leave its parent today: not by drag, not from the row menu, not over the control API
  (`session.move` answers `a companion moves only among its siblings`).
- This adds one operation: a companion joins a different top-level session of the same window, in any
  workspace, at a chosen slot in that session's group or at its end.
- The `Session` object moves as it is, so its panes, split, scratch, overlays, pages and daemons are untouched.
- The same operation serves the sidebar, the row menu, `agtermctl`, a server window's rows and rows attached
  from another Mac.

## Context (from discovery)
- `Session.parentID` is the only link; nesting is one level; a group is stored contiguously right after its
  parent in `workspace.sessions` (`AppStore+Companions.swift` `groupEnd`, `companions(of:)`).
- `AppStore+SessionMoves.swift`: `moveSession`/`moveSessions`/`canMoveSessions` refuse a companion leaving
  its group; `companionDestination` derives the group from the SOURCE's `parentID`.
- `AppStore.nest(_:under:)` only re-points links (used by the attached Convert follow-up); it does not relocate.
- `SidebarDrop.swift`: a drop ON a session row maps to `sessionIndex + 1` ("land right after this row");
  `companionChildIndex` maps a gap among a parent's companions.
- `agterm/Views/WorkspaceSidebar+DragDrop.swift`: `validateDrop`/`acceptDrop`/`outlineSlot` infer the
  highlighted group from the dragged row's own parent; a selected-row drag writes every selected id.
- Companions nest only in the tree mode (`WorkspaceSidebar+Companions.swift` `nestsCompanions`); the flagged
  tree shows them unindented.
- `agterm/Views/WorkspaceSidebar+ContextMenu.swift`: the existing "Move to" submenu lists workspaces and is
  empty for a companion.
- `syncSelection` (`WorkspaceSidebar.swift`) reveals a selected row only when the selected id changes;
  `.claude/rules/sidebar.md` lets only a mode or layout switch clear `lastRevealedSelection`.
- `session.companion.convert` is the pattern to follow end to end: own wire command, CLI verb routed to it,
  one GUI seam `AppActions.convertToCompanion` (`performRemote`, then `forwardAttached`, then the store, with a
  refusal HUD), `RemoteOperation.convertCompanion` for a server window, `AttachedForward` origin forwarding.
- `ControlServer.remoteRoute` runs `attachedRoute` before the dispatcher; `attachedRoute` already consults
  `ControlDispatcher.refusesArguments` so a request with bad arguments reaches the dispatcher's own error.
- `RemoteCatalogActions.run` turns an older server's argument refusal (exit 64, empty stdout) into `.lost`,
  which reports "outcome unknown".
- agterm-server runs the same `AppStore` code; its catalog carries `parent` and `AppStore+Catalog.swift`
  applies it on the Mac. A server window can detach a single companion (`RemoteCatalogMirror+Detach.swift`),
  so a group visible here can be shorter than the server's.

## Development Approach
- **testing approach**: regular (code first, then tests in the same task)
- complete each task fully before moving to the next; tests are part of every task
- run only the tests a change touches while working (`-only-testing:` for hosted and UI tests); the full gates
  (`swift test`, `make test-app`, `make lint`) run once, in the last task
- **CRITICAL: update this plan file when scope changes during implementation**

## Testing Strategy
- host-free: `agtermCore` tests for the store operation, validators, drop resolution, dispatcher, CLI, remote
  operation and server actions
- hosted: `agtermTests` for `AppActions`, `ControlServer` routing (local, server window, attached) and the sidebar
- UI: `agtermUITests/ControlCompanionsUITests` gets an end-to-end case for the command and its `tree` read-back

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix

## Solution Overview
- One store operation, `AppStore.moveCompanion`, owns validation and relocation, and `AppStore.canMoveCompanion`
  answers the same validation without moving, so a drop indicator or menu entry never offers a destination the
  move refuses. The drop and the row menu go through one GUI adapter, `AppActions.moveCompanion`, which routes
  like Convert (server window, then attached origin, then the store) and reports through a refusal HUD.
  `ControlServer` does not use that adapter, since it returns nothing: control runs the store operation, or
  awaits the existing server-window and attached routes, and returns the real result.
- New wire command `session.companion.move`, not a field on `session.move`: an app predating it drops an
  unknown `ControlArgs` field and would run a plain move, while an unknown command fails to decode and changes
  nothing. The CLI maps that decode error to `the running app is too old for companion moves`.
- In the tree mode the sidebar keeps its one drop rule, "the row lands where the indicator is", for companions:
  - on a top-level row: the dragged companion becomes that session's FIRST companion (folded and childless
    parents included);
  - in a gap among another session's companions: that slot;
  - on another companion's row: right after it, in that companion's group;
  - in a gap between top-level groups or on a workspace row: refused (no promotion).
- A multi-row drag that would change any row's parent is refused; moves are one companion at a time.
- The flagged tree and the flat flagged list keep today's rule, a companion reorders among its siblings only,
  since neither shows the grouping; the row menu's "Move to" is the reparenting path there (Eugene's decision).
- The row menu's existing "Move to" submenu lists, for a single companion, the other top-level sessions of
  the window under per-workspace section headers.
- A moved companion that is selected stays selected and is revealed under its new parent, even when that
  parent or its workspace is folded.
- `session.move` on a companion leaving its group answers
  `a companion moves only among its siblings; use --parent to move it under another session` (Eugene's decision).
- Remote rows follow Convert to Companion:
  - a server window's row: the server runs the move with the slot mapped to its own group; the catalog brings
    `parent` and order back;
  - a row attached from another Mac: both rows must come from the same origin (host and endpoint); the origin
    moves first (append in its own tree), then this Mac moves its own row to the requested slot. A move to the
    row's current parent is a local reorder and does not reach the origin, as sibling reorders of attached rows
    stay local today.
- Out of scope (confirmed): batch moves, companion to top-level, top-level into companion, moving between
  windows (no session can do that today).
- Known limit, approved by Eugene: another Mac attached to the same origin keeps its old grouping until it
  reattaches, as with Convert to Companion today; the origin's presentation stream carries no grouping.

## Technical Details
- Wire: `session.companion.move`, `target` = the companion, `args.parent` = destination parent (id/prefix),
  optional `args.index` = 0-based slot among the destination's companions counted with the moving companion
  removed; omitted appends. Negative is refused; past the end lands at the end of the group.
- `ControlArgs` gains `parent` and `index`; `ControlResult.parent` already exists.
- Reply: `result.id` = the companion, `result.parent` = the destination parent. Read-back: the existing
  `parent` field on the `tree` session node, and the node order.
- The parent is resolved only in the companion's own window, as `session.move` resolves its anchor: a
  window-wide search could make a valid short prefix ambiguous. A parent in another window reads as
  `no such session`.
- `CompanionMoveRefusal` (one `message` each, shared by the GUI and control, as `ConvertRefusal.message` is):
  - `noSuchSession`;
  - the target is not a companion;
  - the destination is a companion, or is the target itself;
  - one row is attached from another Mac and the other is local, or they come from different origins.
- Moving to the current parent is allowed: it is a reorder to `index` (or to the end).
- Store, `AppStore+SessionMoves.swift`:
  - `public func canMoveCompanion(_ id: UUID, under parentID: UUID) -> Result<Void, CompanionMoveRefusal>`;
  - `public func moveCompanion(_ id: UUID, under parentID: UUID, at index: Int? = nil) -> Result<Void, CompanionMoveRefusal>`,
    which runs the same check first, removes the row, sets `parentID`, inserts it at `parent + 1 + min(index, count)`
    in the destination workspace (end of group when nil), prunes the sidebar selection and focus set as
    `relocate` does, saves, and schedules `tree.changed` only on a real change.
  - The origin check reads `AttachedOrigin`, so the store refuses a mixed pair on every surface.
- Arguments: one static `ControlDispatcher.companionMoveArguments(_ args:)` validates `parent` and `index`; the
  dispatcher uses it, and `ControlDispatcher.refusesArguments` lists the command so `attachedRoute` and the
  server-window route hand a bad request to the dispatcher's own error before any network call.
- `ControlActions` gains `moveCompanion(_ target: String?, parent: String, index: Int?, window: String?) async -> ControlResponse`;
  its default in `ControlActionsDefaults.swift` refuses by name, so the agterm-linux conformer owes no change.
- GUI adapter: `AppActions.moveCompanion(_ id: UUID, under parentID: UUID, at index: Int?, in store: AppStore)`
  in `agterm/AppActions+Companions.swift`, modeled on `convertToCompanion`; drop and menu only. The control
  handler calls `AppStore.moveCompanion` directly for a local row and relies on `remoteRoute` (server window)
  and `attachedRoute` (attached row) for the rest, both awaited, so its reply carries the actual outcome.
- CLI: `agtermctl session move --target C --parent P [--index N]`. `--parent` excludes the workspace
  positional, `--to`, `--after`/`--before` and a repeated `--target`; `--index` needs `--parent`. The branch
  that builds the request lives in `agtermctlKit/Session+Companions.swift` (`SessionCommands.swift` is near the
  1000-line limit) and keeps `operation.stamp`, since the server path passes `--op-id`/`--epoch`.
- Server window: `RemoteOperation.moveCompanion(UUID, parent: UUID, index: Int?)`, label "Move Companion",
  argv `session move --target <id> --parent <parent> [--index N]`; `ServerCommandPolicy`,
  `ServerActions+Receipts` and `RemoteOperation+Request` list the command; `ServerActions+Companions`
  implements it with the same store operation. The GUI's visible slot is mapped to the destination group in
  `mirror.catalog` (which includes detached rows) at the GUI-to-catalog boundary only, so a control request's
  index, already in server terms, is never translated twice. An older server's argument refusal is a final
  outcome for this operation: it clears the pending entry and answers
  `the agterm-server on HOST is too old for companion moves`; other operations keep today's handling.
- Attached row: `AttachedForward` gains a move case carrying both ORIGIN session ids. The route checks
  `canMoveCompanion` here first; a destination equal to the row's current parent is a local reorder with no
  origin call; otherwise the origin runs the move without `index`, then this Mac re-checks both rows and runs
  `moveCompanion(row, under: localParentRow, at: index)`. An origin success followed by a local failure is
  reported as such ("moved on HOST, but ..."), never retried; an origin too old for the command gets the
  too-old text through the existing `AttachedForward` mapping.
- Selection reveal: the sidebar records the selected row's owner chain (parent and workspace) when it reveals
  it, and reveals again, persistence suppressed, when that chain changes while the id stays the same; this is
  the second exception beside the mode/layout switch in `sidebar.md`.

## What Goes Where
- **Implementation Steps** (`[ ]` checkboxes): code, tests and docs in this repository
- **Post-Completion** (no checkboxes): manual checks with a real attached Mac and a real agterm-server host

## Implementation Steps

### Task 1: Store operation, validators, protocol, dispatcher and CLI

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore+SessionMoves.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`, `ControlErrors.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift`, `ControlDispatcher+Companions.swift`,
  `ControlDispatcher+Restore.swift` (`refusesArguments`)
- Modify: `agtermCore/Sources/agtermCore/ControlActions.swift`, `ControlActionsDefaults.swift`
- Modify: `agtermCore/Sources/agtermctlKit/SessionCommands.swift`, `Session+Companions.swift`
- Modify: `agterm/Control/ControlServer.swift` (exhaustive `Command` switch, so the app target builds)
- Modify: `agtermCore/Tests/agtermCoreTests/MockControlActions.swift`, `AppStoreCompanionsTests`,
  `ControlDispatcherCompanionsTests`, `SessionCompanionsCommandsTests`

- [x] `CompanionMoveRefusal`, `AppStore.canMoveCompanion` and `AppStore.moveCompanion` as in Technical
      Details, same-workspace and cross-workspace, keeping the `Session` object
- [x] `session.companion.move` command case, `ControlArgs.parent`/`index`, `companionMoveArguments` used by
      the dispatcher and listed in `refusesArguments`, the `ControlActions` requirement with its refusing default
- [x] CLI `session move --parent/--index` routed to the new command with `operation.stamp` and the too-old
      mapping; the existing `companionMoveError` text gains the `--parent` hint (app and agterm-server)
- [x] store tests: same and other workspace, first/middle/end slot, past-the-end, current-parent reorder,
      each refusal leaves the tree unchanged, `canMoveCompanion` agrees with `moveCompanion` on every case,
      object and pane identity kept, selection kept, `tree.changed` only on a real change, page companion and
      page-root destination, save then reload keeps parent and order
- [x] dispatcher and CLI tests: argument validation, `refusesArguments`, conflicting options, request shape
      and stamp, too-old text, the new `companionMoveError` text
- [x] run the touched `agtermCore` tests - must pass before task 2

### Task 2: Local app path: GUI seam, control handler, sidebar drop and row menu

**Files:**
- Modify: `agterm/AppActions+Companions.swift`, `agterm/Control/ControlServer+Companions.swift`
- Modify: `agtermCore/Sources/agtermCore/SidebarDrop.swift`
- Modify: `agterm/Views/WorkspaceSidebar+DragDrop.swift`, `WorkspaceSidebar+ContextMenu.swift`, `WorkspaceSidebar.swift`
- Modify: `agtermCore/Tests/.../SidebarDropTests.swift`, `agtermTests/AppActionsCompanionsTests.swift`,
  `agtermTests/ControlServerCompanionsTests.swift`, `agtermTests/WorkspaceSidebarCompanionsTests.swift`,
  `agtermUITests/ControlCompanionsUITests.swift`

- [x] `AppActions.moveCompanion` as the drop/menu adapter (store path now, remote branches filled by tasks 3
      and 4); a separate `ControlServer` handler on `AppStore.moveCompanion`, replying `id`/`parent`
- [x] `SidebarDrop` resolution carrying the destination parent and group slot for the tree-mode drop cases;
      `validateDrop` asks `canMoveCompanion`, `acceptDrop` calls `AppActions.moveCompanion`, `outlineSlot`
      stops inferring the group from the source; multi-row parent changes refused; flagged layouts unchanged
- [x] row menu "Move to" for a single companion: other top-level sessions under per-workspace headers,
      offered only where `canMoveCompanion` succeeds, disabled where a server window blocks marks
- [x] selection reveal on an owner-chain change, as in Technical Details
- [x] show Eugene the drop indicator, the menu and the reveal in an isolated Debug instance, before the UI tests
- [x] tests: `SidebarDropTests` for each tree drop case, the refused gaps, multi-row and flagged layouts;
      `AppActionsCompanionsTests` for the seam and its refusal HUD; hosted control and sidebar tests including a
      GUI move and a `session move --parent` move into a folded parent; one UI test driving the command and
      reading `parent` back from `tree`
- [x] run the touched tests (`-only-testing:` for hosted and UI) - must pass before task 3

### Task 3: Server window rows

**Files:**
- Modify: `agtermCore/Sources/agtermCore/RemoteCatalogActions.swift` (operation, label, target, argv, too-old outcome),
  `RemoteOperation+Request.swift`
- Modify: `agtermCore/Sources/AgtermServerKit/ServerActions+Companions.swift`, `ServerCommandPolicy.swift`, `ServerActions+Receipts.swift`
- Modify: `agterm/AppActions+Companions.swift` (server branch)
- Modify: `RemoteCatalogActionsTests`, `RemoteOperationRequestTests`, `ServerActionsCompanionsTests`

- [ ] `RemoteOperation.moveCompanion` with its label, target and argv; the server runs the store operation and
      resolves the parent only in its own catalog
- [ ] the Mac-side route checks `canMoveCompanion` on the mirror and the arguments through `refusesArguments`
      before sending; the GUI maps its visible slot to the server's group at the GUI-to-catalog boundary only
- [ ] an older server's argument refusal is a final outcome for this operation, clearing the pending entry,
      with the too-old text
- [ ] a drop or menu pick on a server window's row sends to the server; nothing moves locally before the
      catalog reports it
- [ ] tests: argv and request parsing, server success and each refusal, a detached companion in the
      destination group, a too-old server, catalog reconciliation of `parent` and order on the Mac store
- [ ] run the touched tests - must pass before task 4

### Task 4: Rows attached from another Mac

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AttachedForward.swift`
- Modify: `agterm/Control/ControlServer+AttachedForward.swift`, `agterm/AppActions+Companions.swift` (attached branch)
- Modify: `AttachedForwardTests`, `agtermTests/ControlServerAttachedForwardTests.swift`

- [ ] forward case carrying both origin session ids, added to the forwarded set behind `refusesArguments`
- [ ] the route checks `canMoveCompanion` here before any network call: a row attached alone can be top-level
      here while a companion on the origin, and is refused before the origin moves it
- [ ] destination equal to the current parent: local reorder, no origin call
- [ ] otherwise origin first, without `index`; after its success re-check both rows here, then `moveCompanion`
      with the requested slot; an origin success with a local failure is reported as such, no retry
- [ ] sidebar drop and menu on an attached row go through the same seam
- [ ] tests: id translation; zero runner calls for a negative raw `index`, a top-level-here/companion-there
      row, mixed or different-origin pairs, and a current-parent reorder; origin failure leaves this Mac
      unchanged; origin too old (exit 64 and `refusesUnknown`); origin success then local move; origin success
      with a row gone meanwhile
- [ ] run the touched tests - must pass before task 5

### Task 5: Docs, acceptance and gates
- [ ] `site/docs.html` (companions: drag rules in the tree, Move to, the flagged layouts, the attached-viewer
      limit) and `site/commands.html` (command, arguments, read-back, refusals)
- [ ] `.claude/rules/control-api.md`: catalog list, a Companions bullet, and the `companionMoveError` line
- [ ] `.claude/rules/sidebar.md`: the companion-move rule ("moves only among its siblings"), the "Convert is
      the one path that changes a `parentID`" line, the row-menu list, and the owner-chain reveal exception
- [ ] bundled skill `plugins/agterm/skills/agterm/` reference entry and a SKILL.md trigger for moving a companion
- [ ] verify every Overview requirement and each refusal end to end
- [ ] gates once: `cd agtermCore && swift test`, `make test-app`, `make lint`
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion
**Manual verification:**
- a real attached Mac: move an attached companion under another row from the same origin; check the origin's
  sidebar and this Mac's, and that a second attached Mac keeps the old grouping (documented limit)
- a real agterm-server window: drag a companion into another session's group with a detached sibling there,
  and check the slot survives the next catalog update

Smells pre-check: skipped — non-Go project
