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
  sessions ignored): the slot is the count of workspace rows whose midpoint sits above the cursor,
  so the top half of a row drops before it and the bottom half after it — reachable everywhere.
  It still feeds that slot to the host-free `SidebarDrop.resolveWorkspace` for the post-removal/no-op
  math, and `validateDrop` highlights it via `setDropItem(nil, dropChildIndex:)`.
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
  mirrors it through `AppStore.setSidebarSelection(_:)`. `allowsEmptySelection` stays TRUE because a
  focus filter can intentionally hide the active session and `syncSelection` must be able to
  `deselectAll(nil)` in that state.
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
  A row click routes through the existing `selectSession`; the mode switch is VIEW-ONLY (never re-selects/refocuses).
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
  Three delta-guarded mutators (no write, no `save()`, when nothing changes, so every caller stays idempotent):
  - `setFocusedWorkspace(_ id: UUID?)` REPLACES the set with `{id}` and enables; nil clears and disables.
    This is the unchanged single-workspace zoom — the row menu's Focus/Unfocus, `AppActions.focusWorkspace(_:)`,
    `focusActiveWorkspace()` (targets `currentWorkspaceID`, wired to `BuiltinAction.focusWorkspace` +
    a View-menu/palette "Focus Workspace"), `AppActions.clearFocus()` (a plain menu/palette "Clear Focus",
    NOT a `BuiltinAction`), and `workspace.focus on`.
  - `setFocusMembership(_ id: UUID, member: Bool)` marks or unmarks ONE workspace, leaving the other members
    alone — the row menu's "Add to Focus"/"Remove from Focus" and the View-menu "Add Workspace to Focus".
  - `setFocusEnabled(_ on: Bool)` flips the flag WITHOUT touching the set — the bottom-bar toggle,
    the View-menu "Toggle Workspace Filter", `BuiltinAction.toggleWorkspaceFilter`, and `workspace.filter`.
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
  The documented control read-back contract is "a workspace is visible iff `focused && workspaceFilter`";
  an enabled-but-empty filter would make it lie (`workspaceFilter` true while no workspace reports `focused`,
  yet the whole tree on screen).
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
  `revealNewWorkspace: Bool = true` gates the insert), preserving the "a new workspace is immediately visible"
  contract WITHOUT blowing the filtered view open; mutating the set is acceptable here because the user
  initiated the creation, unlike the passive reveal above.
  `removeWorkspace` and the `AppStore+PendingClose` soft-remove path prune the id and disable when the set
  empties.
- **Membership is drawn on the row, and the bottom-bar toggle replaced the pill.**
  A marked workspace row draws the cached `focusedWorkspaceIcon` (`square.grid.2x2.fill`) instead of the
  outline `workspaceIcon` — the same filled-SF-Symbol idiom as the flagged session rows, so it is a
  same-size swap and inherently layout-shift-free.
  The choice is on MEMBERSHIP alone, independent of `focusEnabled`, so a marked row reads filled while the
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
  The contract is ONE-DIRECTIONAL by design: an explicit cross-set select disables the filter (reveal),
  but marking a workspace that does NOT contain the active session deliberately does NOT reselect or
  switch the active terminal — focus is a pure view filter, never a terminal switch,
  so the active session's terminal keeps rendering while the sidebar shows no selection until the next
  select (the bottom-bar toggle signals the state, and it self-heals on the next `selectSession`/`addSession`).
  This stranded-selection state is intentional, not a bug.
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
  re-apply, the `syncSelection` reveal, and the marked-set force-expand
  (`focusEnabled ? focusedWorkspaceIDs : []`) — so those update the VISUAL `expandedWorkspaceIDs`
  (needed for the flagged-mode round-trip) WITHOUT touching the persisted `isExpanded`.
  This is what makes a deliberate collapse durable: revealing a session inside a collapsed workspace (nav,
  notification click, or the launch-time active-session reveal) or focusing it shows the row but does NOT
  un-collapse it on disk — the collapse survives until the user expands the row themselves.
  The active session is still force-revealed on launch (`syncSelection`), so it is never hidden inside a
  collapsed workspace; the row just re-collapses on the next launch (its persisted state is untouched).
  Round-trips + legacy-decode (incl. explicit `collapsed:false`) covered in `PersistenceTests`,
  per-workspace + whole-tree mutators / no-op-no-write in `AppStoreOrganizationTests`, and the
  collapse-survives-relaunch + reveal-does-not-repersist end-to-end cases in `SidebarUITests`.
