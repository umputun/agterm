---
paths:
  - "agterm/Views/WorkspaceSidebar*.swift"
  - "agterm/Views/SidebarRowViews.swift"
  - "agterm/Views/SidebarRenameController.swift"
  - "agtermCore/Sources/agtermCore/SidebarDrop.swift"
  - "agtermCore/Sources/agtermCore/SidebarMode.swift"
  - "agtermCore/Sources/agtermCore/Reorder.swift"
  - "agtermUITests/SidebarUITests.swift"
  - "agtermUITests/ReorderUITests.swift"
  - "agtermUITests/FlaggedViewUITests.swift"
  - "agtermUITests/FocusWorkspaceUITests.swift"
---

## Sidebar

- The sidebar is an AppKit `NSOutlineView` (`WorkspaceSidebar`, an `NSViewRepresentable`),
  not a SwiftUI `List` — chosen for native cross-workspace drag-and-drop.
  Its `@MainActor` `Coordinator` is the data source/delegate, backed by `AppStore`.
  Outline items are cached reference-type `SidebarNode`s, reused across reloads for stable identity (expansion/selection
  survive `reloadData`).
- **Drag reorder (sessions AND workspaces).**
  The Coordinator's `validateDrop`/`acceptDrop` now HONOR `proposedChildIndex` for sessions and feed the
  host-free `SidebarDrop` helpers so validate and accept agree exactly instead of force-retargeting every
  drop to `NSOutlineViewDropOnItemIndex` — enabling intra-workspace SESSION reorder (drop between rows for
  a precise slot) AND precise cross-workspace placement (a cross-workspace drag now lands at the drop
  position, no longer always-append).
  Workspace ROWS are draggable too: a second pasteboard type `com.umputun.agterm.workspace` is added
  to `registerForDraggedTypes` (LOAD-BEARING — without it AppKit never delivers validate/accept for workspace
  drags) and `pasteboardWriterForItem` emits it (carrying the workspace UUID) for workspace nodes.
  **Workspace reorder is a TOP-LEVEL move, but it does NOT use AppKit's proposed `item`/`childIndex`.**
  With workspaces expanded their sessions fill the gaps between workspace rows,
  so `NSOutlineView` only ever proposes drops INTO a workspace's children (`proposedItem != nil`) — never
  the clean root between-rows slot — so the old `proposedItem == nil`-only gate rejected EVERY drop and
  made workspace drag impossible once any workspace held sessions (the real-world state).
  `resolveWorkspaceMove` therefore IGNORES the proposed item/index and derives the insert slot from the
  CURSOR Y against the workspace ROWS' midpoints (`info.draggingLocation` → `rect(ofRow:).midY`,
  sessions ignored): the slot is the count of RENDERED workspace rows whose midpoint sits above the cursor,
  so the top half of a row drops before it and the bottom half after it — reachable everywhere.
  **That slot counts VISIBLE rows, so it is NOT a `store.workspaces` index once the focus filter hides
  workspaces** — with a non-contiguous marked set the two spaces diverge, and using the slot raw would drop
  the dragged workspace at a full-array index no visible row corresponds to (aiming above the first visible
  row resolved to 0, jumping it ahead of every hidden workspace before that row).
  `SidebarDrop.workspaceInsertIndex(visibleIndices:slot:)` maps it back: above the first rendered row it
  takes that row's own full index, otherwise the index just after the last rendered row above the cursor —
  so a drop always lands ADJACENT to the row it was aimed at, and with nothing filtered
  (`visibleIndices == Array(0..<count)`) it returns the slot unchanged.
  The mapped index feeds the host-free `SidebarDrop.resolveWorkspace` for the post-removal/no-op math,
  while `validateDrop`'s `setDropItem(nil, dropChildIndex:)` gets the VISIBLE-space slot — the outline's
  root children are only the rendered workspaces, so the highlight and the store move deliberately travel in
  different index spaces (identical only on an unfiltered tree).
  Covered by `ReorderUITests.testReorderWorkspaceOntoSessionRow` (drag a workspace onto a session row
  — the case the `proposedItem == nil` gate broke).
  The session helper still HONORS `proposedChildIndex` (sessions are real same-level siblings,
  so the outline proposes precise between-rows slots). It supports single-row and multi-row drags:
  dragging from a selected session writes the full `sidebarSelectionIDs` block to the pasteboard in visual
  order; dragging an unselected session writes just that row.
  Both session and workspace drops feed `SidebarDrop`. For a single session, `resolveSession` applies the
  same-parent downward `childIndex - 1` post-removal adjustment (only when `sourceIndex < childIndex`).
  For a multi-selection, `resolveSessions` removes every dragged session first and inserts the whole block
  at the post-removal slot, preserving the selected visual order and handling same-workspace / cross-workspace
  mixes atomically. Workspace reorders use `resolveWorkspace` with the same remove-then-insert convention.
  The PURE index arithmetic (drop-on-row `sessionIndex + 1` redirect, source-removal adjustment,
  cross-workspace vs same-parent index spaces, batch block insertion, and no-op checks) lives host-free in
  `agtermCore.SidebarDrop` (`resolveSession`/`resolveSessions`/`resolveWorkspace`), table-tested in
  `SidebarDropTests`; the Coordinator helpers only do the AppKit/store glue (read the pasteboard, resolve
  ids → indices via `AppStore.sessionLocation(ofSession:)`) and feed `SidebarDrop`, so the trickiest part
  is unit-covered without the fragile XCUITest drag.
- Add affordances live in a bottom bar in `WindowContentView`: a workspace button and a session menu (New Session
  / Open Directory…).
  The two session actions are also on each workspace row's right-click menu.
  Each workspace ROW additionally carries a hover-revealed `+` (New Session) affordance (`SidebarCellView`'s
  `addButton`, id `workspace-add-session`, shown on `mouseEntered`, same action as the footer New Session)
  — a SEPARATE toggleable Interface element (`workspaceAddSession`, gated in `mouseEntered`; see [[settings]]).
- **A single click anywhere on a workspace ROW toggles its expansion** (not just the disclosure triangle),
  so the whole row is the hit target.
  Wired via the outline's `action` (`Coordinator.handleSingleClick`) — which fires on a genuine click,
  NEVER during a drag, so workspace drag-reorder is untouched — and guarded against the disclosure-triangle
  region (`frameOfOutlineCell`) so a triangle click doesn't double-toggle.
  The toggle is DEFERRED by `NSEvent.doubleClickInterval` and CANCELED by `handleDoubleClick`,
  so a double-click (rename) doesn't flip the workspace open/closed on its way into edit mode
  (instant-toggle was tried and rejected: AppKit commits the first click of a double before it knows a
  second is coming, so instant forces a visible toggle-then-revert flicker on rename).
  This is pure click-routing over the existing per-workspace `expandItem`/`collapseItem` (an exempt case
  under the control keep-in-sync rule): the row click itself adds NO control command.
  The per-workspace collapse/expand IS driven over the socket by `workspace.collapse`/`workspace.expand`
  (distinct from the ALL-workspaces `sidebar.expand`/`sidebar.collapse`), but by a SEPARATE path that does
  NOT route through this click handler: `AppActions.setWorkspaceExpanded` persists `isExpanded` on the
  store DIRECTLY (source of truth, so it survives a hidden sidebar whose Coordinator is torn down), THEN
  posts `.agtermSetWorkspaceExpanded` for the Coordinator's `setWorkspaceExpandedNotified` to sync only the
  live outline row + tracked set (see the Control API rule).
  Covered by `SidebarUITests.testClickWorkspaceRowTogglesExpansion`.
- **A session ROW click reveals a blocked session's pane-tagged pane.**
  `Coordinator.outlineViewSelectionDidChange` selects the clicked session (`selectSession`) then — async,
  after the selection + the sidebar's own focus-restore settle — calls `AppActions.revealActiveBlockedPane(captured:)`
  with the pre-reset indicator `selectSession` returned,
  so clicking a session whose agent blocked in its split (right) or scratch pane lands you on THAT pane,
  not the plain focused pane.
  It is a no-op (plain `focusActiveSession`) for an IDLE or ACTIVE session, so ordinary clicks and
  informational working-state tags are unaffected — the reveal never dismisses a merely-shown scratch
  (a blocked/completed nil-tagged status is treated as `left`/main).
  This matches attention-nav, plain session nav, the command palettes, a Dock-menu session row, the title-bar
  bell popover, and idle auto-follow,
  which all route through the same helper (see the Menu/actions + Notifications rules).
  Covered by `PaneAwareStatusUITests.testSidebarClickRevealsBlockedSplitPane`.
- Accessibility identifiers `session-row`, `workspace-row`, `edit-field`,
  and `add-session` back the XCUITests.
  Note the rename field surfaces as a `TextField` for sessions and a `StaticText` for workspaces,
  so UI tests match `edit-field` by identifier across element types.
- **Sidebar multi-selection.**
  `AppStore.selectedSessionID` remains the durable active terminal. The broader sidebar selection is
  a private transient array in host-free `AppStore`, exposed through `sidebarSelectionIDs` normalized to
  the current visible session order so batch actions are deterministic in tree and flagged modes.
  AppKit Shift-click and Command-click update the outline selection; `outlineViewSelectionDidChange`
  mirrors it through `AppStore.setSidebarSelection(_:)`. `allowsEmptySelection` stays TRUE because the
  visible set can hold NO sessions at all — a marked workspace with none, or the flagged view emptied —
  and `syncSelection` must be able to `deselectAll(nil)` in that state, which the gaps listed with
  `reselectIfSelectionHidden` below can also reach.
  Right-click follows standard Mac list behavior: inside the current multi-selection it keeps the whole
  selection for the context menu, outside it narrows to the clicked row. Context menu target resolution
  is `AppStore.sidebarSelectionTargets(forContextSession:)`, which filters through the visible projection.
  Batch row actions: move uses `AppStore.moveSessions`, close uses `AppActions.closeSessions(_:in:)` →
  `AppStore.softCloseSessions`, flag uses `AppActions.toggleFlags(_:in:)` → `setFlag(_:forSessions:)`,
  and clear-status loops `setAgentIndicator` once per selected session (loop-equivalent to `session status idle`).
  SINGLE-selection-only row actions (shown only when the context menu resolves to exactly ONE session, since
  they have no sensible batch meaning): Rename, **Duplicate Session** (right after Rename), and Reveal in Finder.
  **Duplicate Session** creates a fresh session — a plain new login shell — in the SAME workspace, inserted directly
  AFTER the source, rooted at the source's focused-pane cwd (`Session.focusedCwd`, the same directory the row
  shows and Reveal in Finder opens), then selects + focuses it.
  ONLY the directory carries over: the duplicate does NOT inherit the source's custom name, initial command,
  split, scratch, status, flag, font size, or watermark — it is "New Session seeded with the source's cwd",
  not a clone of state.
  Its control half is `session.duplicate` (`agtermctl session duplicate [--target]`), which reads back off
  `tree` as a new node right after its source carrying the source's focused-pane cwd — equal to the source
  node's `tree.cwd` unless the source is a split focused off its primary pane (then `tree.cwd` reports the
  primary and the two differ), see the Control API rule.
- **Flagged working-set view (`AppStore.sidebarMode` `.tree`/`.flagged`).**
  `SidebarMode` (`agtermCore/SidebarMode.swift`, `String`-backed `Codable`/`Sendable`) drives a per-window
  MODE toggle between the normal two-level tree and a FLAT list of just the flagged sessions.
  A session is flagged via the observed `Session.flagged: Bool`; the flat list is the PURE derived projection
  `AppStore.flaggedSessions` (`workspaces.flatMap(\.sessions).filter(\.flagged)`,
  already in tree order — workspace-then-session).
  No second container: a session always has exactly one home workspace, the flag dies with the session
  and survives a workspace move (the projection re-sorts).
  The ONE `NSOutlineView` renders either source — `numberOfChildrenOfItem`/`child`/`isItemExpandable`
  branch on `store.sidebarMode`; in `.flagged` the root's children are `flaggedSessions` as flat,
  non-expandable rows labeled `session : workspace` (the session `displayName`,
  then the owning workspace name) with the base leading icon — a plain terminal for a single session,
  the split-rectangle for a split one so a split stays distinguishable (the FILLED flag variant is suppressed;
  every row here is flagged) — plus the usual `StatusIconView` + `BadgeView`.
  A row click routes through the existing `selectSession`.
  BOTH mode flips re-select when they would hide the active session (`reselectIfSelectionHidden`, below):
  into the flagged view when it is not flagged, and back to the tree when an applied workspace filter
  excludes a session that was selected in the flagged view.
  Otherwise view-only: an active session visible in the destination mode is left exactly where it is.
  Drag-reorder is DISABLED in `.flagged` mode.
  An empty flagged set shows a centered, non-scrolling empty-state hint ("No flagged sessions. / Right-click
  a session → Flag.") overlaid in the scroll view, re-tinted on `.agtermAppearanceChanged` and toggled
  by `updateEmptyStateHint` (visible only in `.flagged` with `flaggedSessions.isEmpty`).
  Mutators: `AppStore.setFlag(_:forSession:)` / `setFlag(_:forSessions:)` (clean no-op + no save on
  unknown ids or unchanged values, prune the transient selection when the current sidebar mode hides the
  changed rows), `clearFlags()` (single save + prune), `setSidebarMode(_:)` (save).
  GUI half: the bottom-bar `flagged-view-toggle` button (right of the trailing `Spacer()`,
  2-state flag/checkmark glyph, tinted `chromeText`, flips `sidebarMode` and animates via `WindowContentView`'s
  `.animation(value:)`), the row context-menu Flag/Unflag → `AppActions.toggleFlags(_:in:)`,
  the View-menu Show Flagged/Show All + Flag Session + Clear Flagged, the ⌃⇧P palette entries,
  and the two `BuiltinAction`s `toggleFlaggedView`/`toggleFlag` (expressible/keyless).
  **Clear Flagged** is a plain menu/palette item (NOT a `BuiltinAction`,
  mirroring Reload/Edit Keymap) → `AppActions.clearFlags()` with a light confirm alert when the set is
  non-empty (skipped under the XCUITest launch, like the quit-confirm).
- **Tree-mode flagged indicator (filled-icon variant).**
  In `.tree` mode a flagged session's row swaps its leading icon to the FILLED SF Symbol variant of its
  base glyph — `terminal.fill` for a single session, `rectangle.split.2x1.fill` for a split (the same
  filled split symbol the titlebar shows for a SHOWN split; outline = unflagged,
  filled = flagged) — via the cached `flaggedSessionIcon`/`flaggedSplitSessionIcon`
  template images, tinted with the chrome/theme color.
  It is a pure SF Symbol swap (`Self.rowIcon(...)`), NOT a composited corner badge — same-size,
  so it is inherently layout-shift-free.
  `flagged` is folded into the row's `RowContent` (Equatable), so a flag/unflag re-renders ONLY that
  row (per-row `reloadItem`).
  The filled variant is tree-mode only — the flat flagged view shows the unfilled base icon,
  so a split session still gets the split-rectangle to stay distinguishable;
  only the FILLED flag variant is suppressed there (every row is flagged).
- **Focus filter — a marked SET plus an on/off flag (`AppStore.focusedWorkspaceIDs` + `focusEnabled`).**
  Two stored fields on the class replace the old single `focusedWorkspaceID: UUID?`:
  `focusedWorkspaceIDs: Set<UUID>` is the marked set, `focusEnabled: Bool` is whether the filter applies —
  so the set survives being switched off and peeking at the whole tree costs one flip.
  Everything else lives in `AppStore+Focus.swift`.
  `visibleWorkspaces` is `guard focusEnabled else { return workspaces }` then the members in TREE order —
  the source of truth the tree filters on (the data source maps `store.visibleWorkspaces` in `.tree`).
  Its empty-result fallback to the full tree is defensive belt-and-braces, not a reachable path (see the
  invariant below).
  Focus is ORTHOGONAL to flagged: the flat flagged view ignores focus (it always shows the full cross-workspace
  set).
  Four mutators, all routed through ONE private write point, `commitFocus(ids:enabled:)`, which owns the
  empty-set clamp, the delta guard (no write, no `save()`, when nothing changes, so every caller stays
  idempotent), the sidebar-selection prune and the save — so a fifth mutator cannot reimplement any of them:
  - `setFocusedWorkspace(_ id: UUID)` REPLACES the set with `{id}` and enables.
    This is the single-workspace zoom — the row menu's Focus/Unfocus, `AppActions.focusWorkspace(_:)`,
    `focusActiveWorkspace()` (targets `currentWorkspaceID`, wired to `BuiltinAction.focusWorkspace` +
    a View-menu/palette "Focus Workspace"), and `workspace.focus on`.
    It is INTERNAL: `on`/`toggle` reach it from inside `agtermCore`, and the app target has no caller.
  - `clearFocus()` empties the set and disables — `AppActions.clearFocus()` (a plain menu/palette
    "Clear Focus", NOT a `BuiltinAction`) and the clearing half of the replace-toggle.
    It is the ONLY public half of the old `setFocusedWorkspace(_ id: UUID?)`, whose optional argument
    encoded two unrelated operations.
  - `setFocusMembership(_ id: UUID, member: Bool)` marks or unmarks ONE workspace, leaving the other members
    alone — the row menu's "Add to Focus"/"Remove from Focus" and the View-menu "Add Workspace to Focus".
  - `setFocusEnabled(_ on: Bool)` flips the flag WITHOUT touching the set — the bottom-bar toggle,
    the View-menu "Toggle Workspace Filter", `BuiltinAction.toggleWorkspaceFilter`, and `workspace.filter`.

  Both MARKING mutators refuse an id that names no workspace (the `setWorkspaceExpanded` rule), so a caller
  that skipped its own existence check cannot persist a phantom member; un-marking is never gated, so a
  stale id already in the set stays removable.
  Both stored fields are `public internal(set)`, so only `agtermCore` can write them directly — the
  invariant below cannot be broken from the app target at all.
  Everything the surfaces need on top of those is a helper in the SAME file, so no menu/arm re-spells it.
  **`soleFocusedWorkspaceID` is the ONE predicate for "the workspace the tree is zoomed to"** — the sole
  marked workspace while the filter APPLIES, else nil — and the three consumers that used to spell it out
  independently all read it now: `isSoleFocus(_:)` is `soleFocusedWorkspaceID == id` (the semantic
  definition of "Unfocus" — the row menu's label, the View-menu label and the replace-toggle),
  `WorkspaceSidebar`'s force-expand of a zoomed-to workspace, and the empty-space Finder-drop fallback
  (`SidebarDrop.resolveDirectoryWorkspace`'s `fallbackWorkspaceID`, which the accessor was originally named
  `dropFallbackWorkspaceID` for).
  Three spellings of one predicate is how the `focusEnabled` term goes missing from one of them.
  The rest: `toggleFocusedWorkspace(_:)` (the replace-toggle itself, shared by `AppActions.focusWorkspace`
  and `workspace.focus toggle`), `isCurrentWorkspaceSoleFocus` / `isCurrentWorkspaceFocusMember` (the same
  two facts for the keyless View-menu items, which target `currentWorkspaceID`), `applyFocusMode(_:to:)`
  and `applyWorkspaceFilter(_:)` (the host-free halves of the two control arms, leaving them only target
  resolution), and the internal lifecycle set `dropFocusMember(_:)` / `revealNewFocusMember(_:)` /
  `markFocusMember(_:)`, which is where the remove/add/restore paths get the invariant from instead of
  writing the two fields inline.
- **Marking MARKS ONLY — an add never switches the filter on.**
  `setFocusMembership`'s `wantEnabled` is `wantIDs.isEmpty ? false : focusEnabled`, i.e. the flag is carried
  through untouched while the set is non-empty.
  This is load-bearing, not a detail: an add that enabled would collapse the tree onto the first marked
  workspace, so the rows of every workspace still to be marked are gone and each extra member costs a toggle
  off and back — three toggles to build a three-workspace set, exactly the friction the set exists to remove.
  So a set is built member by member with the whole tree on screen and applied ONCE.
  Removal still disables as the set empties, and `setFocusedWorkspace` (the REPLACING Focus) still enables
  immediately, so the single-workspace zoom is unchanged.
  Pinned by `AppStoreFocusTests.addingToTheSetNeverTurnsTheFilterOn` (both polarities).
- **`enabled + empty` is UNREPRESENTABLE, and three guards keep it that way.**
  The documented control read-back contract is "a workspace ROW is visible iff
  `sidebarVisible && sidebarMode == "tree" && (!workspaceFilter || focused)`" — every term on the same `tree`
  response, so a script evaluates it in one read.
  Enumerated: the sidebar hidden renders nothing; `flagged` mode renders a flat flagged-session list and NO
  workspace rows whatever the filter says; `tree` mode with the filter OFF renders the whole tree regardless
  of membership; `tree` mode with the filter ON narrows to the members.
  Write it in FULL — neither shorter form is safe.
  `focused && workspaceFilter` claims nothing is visible whenever the filter is off, and a script correcting
  for it reaches for `workspace.focus on`, which REPLACES the marked set.
  A bare `!workspaceFilter || focused` claims rows are visible in flagged mode and behind a hidden sidebar,
  where no workspace row renders at all.
  The guards below make the filter-ON term exact; the `!workspaceFilter` term is unconditional, and the
  sidebar-visible / tree-mode terms are the view's, not the store's.
  An enabled-but-empty filter would make the ON half lie (`workspaceFilter` true while no workspace reports
  `focused`, yet the whole tree on screen).
  The guards: (1) `setFocusEnabled(true)` is a no-op on an empty set, matching the bottom-bar toggle, which
  is disabled in exactly that state, so the GUI and the control path agree;
  (2) `setFocusMembership` disables as the set empties;
  (3) `restoreFocus(from:)` PRUNES member ids absent from the restored tree and disables when the pruned set
  comes back empty, so an all-stale set collapses instead of restoring as an invisible filter.
  Covered by `setFocusEnabledRefusesAnEmptySet`, `restorePrunesAnAllStaleSetToEmptyAndDisabled`, and
  `workspaceFilterOnAnEmptySetLeavesTheFilterOffThroughTheControlPath` (driven through
  `ControlDispatcher.dispatch` so the mode parse and the refusal are both exercised, not the mutator alone).
- **Two focus lifecycle rules.**
  A cross-set select DISABLES the filter but KEEPS the set (`disableFocusIfSelectionOutsideSet`, see the
  contract bullet below) — the tree reveals exactly as the old auto-unfocus did, but a hand-curated working
  set is not destroyed by a passive notification click, and re-enabling is one click.
  Creating a workspace while the filter is ON ADDS it to the set (`addWorkspace`/`ensureWorkspace`'s
  `revealNewWorkspace: Bool = true` gates the insert, via `revealNewFocusMember`), preserving the "a new
  workspace is immediately visible"
  contract WITHOUT blowing the filtered view open; mutating the set is acceptable here because the user
  initiated the creation, unlike the passive reveal above.
  The two BACKGROUND creates opt out — `session.new --no-select --create-workspace` and
  `workspace.new --collapsed` (which passes `revealNewWorkspace: !collapsed`): a quiet build must not widen
  a script's marked set, and `--collapsed` exists precisely to say "build this without it opening".
  `removeWorkspace` and the `AppStore+PendingClose` soft-remove path prune the id and disable when the set
  empties (`dropFocusMember`), and BOTH restore paths — the soft-remove's UNDO and Reopen Closed Item —
  re-mark the workspace through the SAME `markFocusMember(_:)`.
  **They are twins on purpose: both MARK ONLY, and neither touches `focusEnabled`.**
  Membership belongs to the closed workspace and is restored with it; the filter FLAG is CURRENT WINDOW
  STATE, not a property of the thing being restored, so no restore may set it.
  Two independent reasons, one per leg.
  The undo's `PendingWorkspaceClose` lives on THIS `AppStore` and dies with the 3-second grace, which looks
  like it makes a captured flag safe — but the user can suspend the filter INSIDE that grace with one click
  on the bottom-bar toggle (which stays enabled while the set is non-empty), and a flag-restoring undo then
  switched it back on, a 3-second-old snapshot beating his most recent explicit action.
  It was also one-directional (it only ever set `true`, never cleared), so it could override him in exactly
  one direction.
  Reopen Closed Item's `RecentClosedWorkspace` is neither window-scoped nor time-scoped — `WindowLibrary`
  builds ONE `RecentClosedStore` shared by every window's store, the list is never partitioned by window,
  and an entry survives indefinitely — so a stored flag would let a record written in window A under an
  applied filter switch window B's filter on, collapsing B's own curated set onto `B's members + this one`,
  and would do the same single-window from a days-old entry.
  Marking without enabling also honors the marking rule above (an add never applies the filter) and keeps
  `enabled + empty` unreachable, since an insert-only path can never enable.
  The trade-off is deliberate: undoing the close of the LAST member brings the set back with the filter
  still off (`dropFocusMember` disabled it as the set emptied), so the restored workspace renders alongside
  everything else until one flip of the toggle re-applies the set.
  That is the same end state Reopen Closed Item has always had, and it is preferred over an undo that can
  contradict a toggle the user just made.
  The two legs cover disjoint windows: the pending record dies at grace expiry, after which the
  recent-closed entry (written by the same `softRemoveWorkspace`, and by `removeWorkspace`) is the ONLY
  route back, so fixing one alone leaves the defect live for every restore past three seconds.
  Without the leg an empty member workspace came back unmarked while the filter still applied, so its row
  never reappeared and the restore looked like a no-op; a non-empty one instead dropped the whole filter
  through `disableFocusIfSelectionOutsideSet`.
  Neither record carries a filter flag: `PendingWorkspaceClose` and `RecentClosedWorkspace` both hold
  `focusMember` ALONE.
  On `RecentClosedWorkspace` it is OPTIONAL because the struct is persisted in `recent-closed.json` and
  `RecentClosedStore.load()` maps a decode failure onto an EMPTY list — a required key would silently wipe
  the user's recent list on the first launch after the upgrade (the `Snapshot.focusedWorkspaceIDs` rule);
  nil restores unmarked.
- **A superseded pending close carries its membership into the record that absorbs it.**
  `foldingPendingCloses(of:)` exists because undoing a session close rebuilds a missing workspace as a
  SHELL, so re-closing that shell while the earlier workspace record still waits out its grace would leave
  two pending records — and one Open Recent entry — on a single workspace id.
  It therefore returns the absorbed records' `focusMember` ORed together, and `softRemoveWorkspace` ORs
  that into its own `focusedWorkspaceIDs.contains(id)` read.
  The OR is load-bearing, not defensive: by the time the fold runs the LIVE set no longer holds the
  membership (the first close's `dropFocusMember` took it, and `rebuiltWorkspaceShell` does not re-mark),
  so the absorbed record is its only surviving copy.
  Losing it killed BOTH recovery routes at once, because `RecentClosedStore.record` dedupes on the
  workspace snapshot id and the newer entry overwrites the older one.
  `rebuiltWorkspaceShell` is deliberately NOT the place to fix this: its inputs are an id and a name, it
  has no membership to restore, and it also serves a recent-closed SESSION reopen whose entry carries none
  — the pending record that does know is still live, and its own undo re-marks correctly.
  Pinned by `reClosingAWorkspaceRebuiltByASessionUndoKeepsItsMembership`.
  The restore contract as a whole is pinned by the `undoing…`/`suspendingTheFilterDuringTheGrace…` group
  and the six `reopening…` tests in `AppStoreFocusTests` (which cover a reopen with the target window's
  filter OFF and a record carrying a foreign applied flag), plus `workspaceEntryWithoutFocusFieldsStillDecodes`
  and `workspaceEntryWithALegacyFocusEnabledKeyStillDecodes` in `RecentClosedTests`.
- **Membership is drawn on the row, and the bottom-bar toggle replaced the pill.**
  A marked workspace row draws the cached `focusedWorkspaceIcon` instead of the outline `workspaceIcon`.
  It is the SAME `square.grid.2x2` symbol at `.black` weight, NOT the `.fill` variant — deliberately
  unlike the flagged session rows, which do use the filled-SF-Symbol idiom.
  Weight rather than fill keeps ONE identity on every workspace row (a workspace always reads as an
  outlined grid, marked or not) and keeps the two markers distinguishable: fill means a flagged SESSION,
  black means a marked WORKSPACE.
  `rowIcon(_:weight:)` takes the weight, defaulting to `.regular`, so this is still a plain cached
  template image `setColors` tints.
  The black variant renders 1pt larger than the regular one (16x15 vs 15x14 — the same size `.heavy`
  gave, so the weight bump is pure stroke), but the cell's icon
  `NSImageView` is pinned to a fixed 16x16 box with `scaleProportionallyUpOrDown`, so the swap moves
  nothing — layout-shift-free for the same reason the `.fill` swaps are, not because the images match.
  The choice is on MEMBERSHIP alone, independent of `focusEnabled`, so a marked row reads black while the
  filter is off — which is what makes a set visible while it is being built.
  Membership rides `RowContent.focusMember` (Equatable, a SEPARATE field from the session-only `flagged`),
  so marking/unmarking re-renders just that row via `reloadItem`.
  The single-workspace `focus-pill` is DELETED: with a set it would have to render "N workspaces",
  duplicating what the tree already shows.
  The bottom-bar `focus-filter-toggle` replaces it and is both the indicator and the control — a 2-state grid
  glyph (filled while the filter applies), `.disabled` + `.opacity(0.35)` on an empty set (the explicit
  `chromeText` foregroundStyle defeats SwiftUI's default disabled dimming, so it is muted by hand — the
  flagged toggle's rule), and `accessibilityValue` `"on"`/`"off"`, which is the only accessibility-observable
  read of the filter state now that the pill is gone.
  It is the only affordance that also works while the filter is OFF.
  Host-free-gated by `InterfaceElement.focusFilter` ("Workspace filter"), so Settings ▸ Interface can hide it.
- **Scoped session navigation (the VISIBLE/FILTERED set).**
  Session navigation operates over `AppStore.navigableSessions`, NOT the whole tree:
  `sidebarMode == .flagged ? flaggedSessions : visibleWorkspaces.flatMap(\.sessions)` — i.e. the flagged
  set in `.flagged` mode, the MARKED workspaces' sessions while the focus filter is on (tree mode),
  else ALL sessions.
  Generalizing `visibleWorkspaces` to the set is what made the multi-workspace case free here: nav walks
  every marked workspace in tree order and skips the unmarked ones, with no count term anywhere
  (`AppStoreNavigationTests.navigateScopesToEveryMemberOfAMultiWorkspaceSet` and its attention-nav twin
  pin a NON-contiguous 2-of-3 set).
  Computed LIVE (`visibleWorkspaces` already collapses to the marked set or the full tree), so clearing the
  flag or switching the filter off naturally restores the full set.
  `navigateSession(_:)` flattens `navigableSessions` for EVERY direction — next/prev/first/last AND attention-nav
  (next-attention/prev-attention scope to the filtered set too) — keeping the same "no/invalid selection
  → first of the filtered list", "next/prev WRAP within the filtered set (like attention-nav)" semantics
  over the filtered list.
  This is shared by `session.go` (control, no ControlServer change — it already routes through `navigateSession`),
  the ⌥⌘↑/↓ + ⌃⌥↑/↓ menu/palette nav, the Ctrl-Tab MRU switcher (`SessionSwitcher.begin()` scopes its
  candidate set to `store.navigableSessions.map(\.id)`; the MRU ORDER still comes from `sessionRecency`),
  AND the ⌃P fuzzy session palette (`AppActions.paletteSessions()` lists `store.navigableSessions`,
  so the searchable set matches the visible sidebar — with the filter on ⌃P shows only the marked
  workspaces' sessions, in flagged mode only the flagged ones).
  This SUPERSEDES the earlier "global nav reveals its target" behavior.
- **Focus×selection contract (load-bearing, the cross-set safety net).** Because nav
  is scoped, its targets are ALWAYS in-set, so nav never crosses the focus boundary.
  `selectSession` calls `disableFocusIfSelectionOutsideSet` (renamed from `autoUnfocusIfOutsideFocus`),
  which switches the filter OFF — KEEPING the marked set — when the newly selected session's workspace is
  not a member (`focusedWorkspaceIDs.contains(owner)` fails → `focusEnabled = false`).
  Keeping the set is the deliberate change from the old clear-everything behavior: the visual result is the
  same (the tree reveals) but a hand-curated working set is not destroyed by a passive reveal, and one flip
  of the bottom-bar toggle brings it back.
  It fires only for an EXPLICIT cross-set select: `session.select <id>` of a hidden session,
  a notification reveal, or a move/close that reselects elsewhere.
  This keeps the active session inside the visible set for those cases, which also keeps `currentWorkspaceID`
  (new-session placement) consistent with NO special-case.
  No-op when the filter is off, when nothing is selected, or when the selection sits in a member workspace.
  **Also a no-op in `.flagged` mode** (load-bearing, not defensive): the flat flagged list is
  cross-workspace and ignores the marked set, so a selection landing outside the set there has not
  navigated past the filter and there is nothing to reveal. Without the term, entering the flagged view
  with the only flagged session in an unmarked workspace silently switches the filter off.
  Returning to `.tree` re-applies it, and the reselect moves the selection back inside.
  Pinned by `switchingToTheFlaggedViewNeverDisablesTheWorkspaceFilter`.
  The contract is SYMMETRIC: a cross-set SELECT widens the view to reveal its target
  (`disableFocusIfSelectionOutsideSet`, above), and a NARROWING that hides the active session moves the
  selection into the view (`reselectIfSelectionHidden`, below).
  **Invariant: the mutators below keep the active session inside a non-empty visible set** — the gap
  those mutators do not cover is named there.
- **`reselectIfSelectionHidden` — the selection half.**
  Runs in `commitFocus`, `setSidebarMode`, both `setFlag` overloads, and at the END of `restore(from:)` —
  after `sessionRecency` is re-seeded, since the pick is MRU.
  Every GUI and control entry point funnels through those mutators, so nothing needs per-caller wiring and
  the socket inherits it; the read-back is the existing `ControlSessionNode.active`.
  Target: the most recent session within `navigableSessions` (`navigableRecentSessions`), else the first
  visible one — MRU rather than positional keeps a filter-off-then-on round trip in place.
  No-op on a nil selection (a restore clears a dangling one on purpose) and on an empty visible set.
  Because the empty set is a no-op rather than a permanent exemption, one of these mutators running while
  the set is empty DOES move the selection: flagging into an empty flagged view, or marking a populated
  workspace while only session-less ones are marked.
  `clearFlags` needs no call — it empties the list, so nothing is visible to move to.
  KNOWN GAP: `addSession(select: false)` and `moveSession` of a non-active session grow the visible set
  without reselecting, leaving a row rendered with nothing selected. `--no-select` promising not to touch
  the selection wins over the invariant; the `addSession` half is pinned by
  `aBackgroundInsertionIntoAnEmptyVisibleSetDoesNotRepairIt`, the `moveSession` half by nothing.
  Every EXPLICIT select in `.flagged` mode is a third: `selectSession` of an unflagged session — from
  `session.select`, a notification reveal, or an `addSession(select: true)` — only runs
  `disableFocusIfSelectionOutsideSet`, which returns early there, so the session goes active while the
  flagged list renders no row for it.
  Deliberate: the flagged view has no set to suspend, so revealing would mean leaving the mode, and a
  notification click would drop the user out of the working set they are in. Flagged mode stays sticky.
  **Keyboard focus needs no app-target bridge**: `TerminalView.updateNSView` drops first responder from the
  surface going inactive and `focusIfNeeded` takes it for the new one. Auto-follow posts a notification
  because it reveals a specific PANE, which the deck cannot infer; a narrowing has no pane to reveal.
- **Mode/focus-aware reconcile signal.**
  The reconcile `TreeShape` is computed from the MODE-selected/filtered roots:
  in `.tree` it is `visibleWorkspaces` → `(workspaceID, sessionIDs)` (so a focus flip re-shapes),
  in `.flagged` it is a SINGLE flat group keyed on a stable pseudo-id (`flaggedShapeID`,
  so within flagged mode only a change to the flagged list — not a fresh per-call id — rebuilds).
  A `lastMode` flip swaps the whole data source and forces a `rebuildAndReload` regardless of the shape
  diff; `sidebarMode`, BOTH focus fields, and each session's `flagged` are folded into the `updateNSView`
  dependency read so a mode/focus/flag change is seen.
  The focus dependency is DUAL and both halves are load-bearing: `updateNSView` reads
  `store.focusedWorkspaceIDs` (a mark/unmark must redraw the row icon) AND `store.focusEnabled` (a filter
  flip must re-shape the tree).
  With only one read the other change is invisible to `@Observable` and the sidebar does not redraw.
  **Task 9 expansion-restore fix:** `NSOutlineView` discards the expansion state of items DROPPED from
  the data source during a flagged-mode reload, so expanded workspace ids are tracked independently in
  `expandedWorkspaceIDs` via the `outlineViewItemDidExpand`/`outlineViewItemDidCollapse` delegate callbacks
  (and `expandAll`) and re-applied in `rebuildAndReload` (`expandItem` for each tracked id),
  surviving the round-trip through flagged mode.
- **Expand / collapse all workspaces (per-window).**
  Two sidebar tree operations: **Expand Workspaces** (`AppActions.expandAllWorkspaces(in:)` → the Coordinator's
  existing `expandAll`, every workspace open) and **Collapse Workspaces** (`collapseOtherWorkspaces(in:)`
  → the Coordinator's `collapseOthers`, every workspace collapsed EXCEPT the active session's `currentWorkspaceID`,
  kept expanded + `scrollRowToVisible`'d).
  Both keep `expandedWorkspaceIDs` in sync (so the state survives a flagged-mode round-trip).
  Per-window scoping rides a notification (`.agtermExpandWorkspaces`/`.agtermCollapseWorkspaces`) posted
  with the TARGET window's `AppStore` as the object; each Coordinator registers its observer with `object: store`,
  so only the matching window's sidebar acts (unlike the rename notifications,
  which self-scope via the selected-session guard).
  This object-scoping is what lets the control path target ANY open window.
  Graceful no-op in `flagged` mode (no workspace rows).
  GUI surfaces (frontmost window): View ▸ Expand/Collapse Workspaces (plain keyless items,
  disabled with no store or in flagged mode) + the ⌃⇧P palette (tree-mode only).
  Control: `sidebar.expand`/`sidebar.collapse` resolve the target store via `resolvePlacementStore(window)`
  (frontmost by default, the global `--window` selector for any open window) and call the `(in:)` variants
  — so unlike the frontmost-only `sidebar`/`sidebar.mode`, these can drive a background window's tree
  (see the Control API catalog).
- **Persistence (per-window, no version bump).**
  `Session.flagged` persists via `SessionSnapshot.flagged: Bool?` (decode → `false`),
  `sidebarMode` via `Snapshot.sidebarMode: SidebarMode?` (→ `.tree`), the focus filter via
  `Snapshot.focusedWorkspaceIDs: [UUID]?` (→ `[]`) + `Snapshot.focusEnabled: Bool?` (→ `false`), and each
  workspace's expand/collapse state via `WorkspaceSnapshot.collapsed: Bool?` (decode → `false` → expanded).
  All Optional fields, so legacy JSON with none of the keys decodes to the unflagged / `.tree`
  / unfiltered / expanded defaults without throwing (the load-fresh-on-decode-failure contract) — no `Snapshot`
  version bump.
  `Snapshot.focusedWorkspaceID: UUID?` survives as a DECODE-ONLY legacy key, dropped from the memberwise init
  and never populated, so the synthesized `encodeIfPresent` omits it automatically: a snapshot written by an
  older release migrates inside the existing custom `init(from:)` to `[legacy]` with `focusEnabled = true`
  ONLY when the new `focusedWorkspaceIDs` key is absent, so the set always wins.
  The set is written in TREE order rather than `Set` order, so the on-disk list does not follow the hash seed.
  `AppStore.restore(from:)` then calls `restoreFocus(from:)` once the tree is rebuilt, which intersects the
  restored ids with the present workspaces — the third `enabled + empty` guard above.
  `collapsed` is stored as the INVERSE of `Workspace.isExpanded` and only WRITTEN when collapsed (`true`);
  an expanded workspace omits it, so an all-expanded tree serializes byte-identically to a legacy snapshot,
  and "lack of the field = expanded" holds.
  The sidebar Coordinator seeds `expandedWorkspaceIDs` from `Workspace.isExpanded` in `makeNSView`
  (`seedExpansionFromModel`, replacing the old unconditional `expandAll`) so a collapsed workspace restores
  collapsed.
  **Only a GENUINE user toggle persists.**
  The `outlineViewItemDidExpand`/`DidCollapse` callbacks write back via `AppStore.setWorkspaceExpanded(_:expanded:)`
  (a PER-workspace mutator, so toggling one row never rewrites another's saved state), and `expandAll`/`collapseOthers`
  persist the whole tree once via `setWorkspacesExpanded(_:)`.
  A `suppressExpansionPersist` flag is set around every PROGRAMMATIC `expandItem`/`collapseItem` — the launch/`rebuildAndReload`
  re-apply, the `syncSelection` reveal, and the SINGLE-member force-expand
  (`focusEnabled && focusedWorkspaceIDs.count == 1 ? focusedWorkspaceIDs : []`) — so those update the
  VISUAL `expandedWorkspaceIDs`
  (needed for the flagged-mode round-trip) WITHOUT touching the persisted `isExpanded`.
  The force-expand STOPS at one member on purpose: a one-workspace filter is a "zoom in", so its sessions
  must show even from a collapsed row, but with a working SET the tree is a list of workspaces and
  re-expanding every member on each `rebuildAndReload` (any session add/close/move re-shapes the tree)
  would undo the user's collapse of a member over and over while `tree` still reported it `collapsed` — a
  visible read-back divergence.
  This is what makes a deliberate collapse durable: revealing a session inside a collapsed workspace (nav,
  notification click, or the launch-time active-session reveal) or focusing it shows the row but does NOT
  un-collapse it on disk — the collapse survives until the user expands the row themselves.
  The active session is still force-revealed on launch (`syncSelection`), so it is never hidden inside a
  collapsed workspace; the row just re-collapses on the next launch (its persisted state is untouched).
  Round-trips + legacy-decode (incl. explicit `collapsed:false`) covered in `PersistenceTests`,
  per-workspace + whole-tree mutators / no-op-no-write in `AppStoreOrganizationTests`, and the
  collapse-survives-relaunch + reveal-does-not-repersist end-to-end cases in `SidebarUITests`.
