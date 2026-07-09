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
  under the control keep-in-sync rule), so it adds NO control command — the ALL-workspaces
  `sidebar.expand`/`sidebar.collapse` stay the control surface.
  Covered by `SidebarUITests.testClickWorkspaceRowTogglesExpansion`.
- **A session ROW click reveals a blocked session's pane-tagged pane.**
  `Coordinator.outlineViewSelectionDidChange` selects the clicked session (`selectSession`) then — async,
  after the selection + the sidebar's own focus-restore settle — calls `AppActions.revealActiveBlockedPane()`,
  so clicking a session whose agent blocked in its split (right) or scratch pane lands you on THAT pane,
  not the plain focused pane.
  It is a no-op (plain `focusActiveSession`) for an IDLE session (no status set),
  so ordinary clicks are unaffected — the reveal never dismisses a merely-shown scratch (a non-idle
  nil-tagged block is treated as `left`/main).
  This matches attention-nav, plain session nav, the command palettes, and idle auto-follow,
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
  focused workspace can intentionally hide the active session and `syncSelection` must be able to
  `deselectAll(nil)` in that state.
  Right-click follows standard Mac list behavior: inside the current multi-selection it keeps the whole
  selection for the context menu, outside it narrows to the clicked row. Context menu target resolution
  is `AppStore.sidebarSelectionTargets(forContextSession:)`, which filters through the visible projection.
  Batch row actions: move uses `AppStore.moveSessions`, close uses `AppActions.closeSessions(_:in:)` →
  `AppStore.softCloseSessions`, flag uses `AppActions.toggleFlags(_:in:)` → `setFlag(_:forSessions:)`,
  and clear-status loops `setAgentIndicator` once per selected session (loop-equivalent to `session status idle`).
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
- **Focus filter (`AppStore.focusedWorkspaceID`).**
  A per-workspace toggle collapses the `.tree` to a single root: `visibleWorkspaces` is the focused workspace
  when `focusedWorkspaceID` is set AND still present, else ALL workspaces — the source of truth the tree
  filters on (the data source maps `store.visibleWorkspaces` in `.tree`).
  Focus is ORTHOGONAL to flagged: the flat flagged view ignores focus (it always shows the full cross-workspace
  set).
  `setFocusedWorkspace(_:)` (delta-guarded so callers stay idempotent, nil unfocuses,
  saves) is driven by the workspace-row context-menu Focus/Unfocus → `AppActions.focusWorkspace(_:)`,
  the bottom-bar `focus-pill` ("<name> ✕" — the focused workspace name with no "Focused:" prefix,
  shown only while focused, ✕ unfocuses), `AppActions.focusActiveWorkspace()` (targets `currentWorkspaceID`,
  analogous to `deleteActiveWorkspace`) wired to `BuiltinAction.focusWorkspace` + a View-menu/palette
  "Focus Workspace", and `AppActions.clearFocus()` (a plain menu/palette "Clear Focus",
  NOT a `BuiltinAction`).
  `removeWorkspace` clears focus when the removed workspace was the focused one.
- **Scoped session navigation (the VISIBLE/FILTERED set).**
  Session navigation operates over `AppStore.navigableSessions`, NOT the whole tree:
  `sidebarMode == .flagged ? flaggedSessions : visibleWorkspaces.flatMap(\.sessions)` — i.e. the flagged
  set in `.flagged` mode, the focused workspace's sessions when a workspace is focused (tree mode),
  else ALL sessions.
  Computed LIVE (`visibleWorkspaces` already collapses to the focused workspace or the full tree,
  including the stale-focus-id fallback), so clearing the flag/focus naturally restores the full set.
  `navigateSession(_:)` flattens `navigableSessions` for EVERY direction — next/prev/first/last AND attention-nav
  (next-attention/prev-attention scope to the filtered set too) — keeping the same "no/invalid selection
  → first of the filtered list", "next/prev WRAP within the filtered set (like attention-nav)" semantics
  over the filtered list.
  This is shared by `session.go` (control, no ControlServer change — it already routes through `navigateSession`),
  the ⌥⌘↑/↓ + ⌃⌥↑/↓ menu/palette nav, the Ctrl-Tab MRU switcher (`SessionSwitcher.begin()` scopes its
  candidate set to `store.navigableSessions.map(\.id)`; the MRU ORDER still comes from `sessionRecency`),
  AND the ⌃P fuzzy session palette (`AppActions.paletteSessions()` lists `store.navigableSessions`,
  so the searchable set matches the visible sidebar — in a focused workspace ⌃P shows only that workspace's
  sessions, in flagged mode only the flagged ones).
  This SUPERSEDES the earlier "global nav reveals its target" behavior.
- **Focus×selection auto-unfocus contract (load-bearing, now the cross-set safety net).** Because nav
  is scoped, its targets are ALWAYS in-set, so nav never crosses the focus boundary.
  `selectSession` still AUTO-CLEARS focus when the newly selected session is NOT in the focused workspace
  (`workspace(forSession:)?.id != focusedWorkspaceID` → `focusedWorkspaceID = nil`) — but this now only
  fires for an EXPLICIT cross-set select: `session.select <id>` of a hidden session,
  a notification reveal, or a move/close that reselects elsewhere.
  This keeps the active session inside the visible set for those cases, which also keeps `currentWorkspaceID`
  (new-session placement) consistent with NO special-case.
  No-op when unfocused or nothing selected.
  The contract is ONE-DIRECTIONAL by design: an explicit cross-set select auto-unfocuses (reveal),
  but focusing a workspace that does NOT contain the active session deliberately does NOT reselect or
  switch the active terminal — focus is a pure view filter, never a terminal switch,
  so the active session's terminal keeps rendering while the sidebar shows no selection until the next
  select (the focus pill signals the state, and it self-heals on the next `selectSession`/`addSession`).
  This stranded-selection state is intentional, not a bug.
- **Mode/focus-aware reconcile signal.**
  The reconcile `TreeShape` is computed from the MODE-selected/filtered roots:
  in `.tree` it is `visibleWorkspaces` → `(workspaceID, sessionIDs)` (so a focus flip re-shapes),
  in `.flagged` it is a SINGLE flat group keyed on a stable pseudo-id (`flaggedShapeID`,
  so within flagged mode only a change to the flagged list — not a fresh per-call id — rebuilds).
  A `lastMode` flip swaps the whole data source and forces a `rebuildAndReload` regardless of the shape
  diff; `sidebarMode`, `focusedWorkspaceID`, and each session's `flagged` are folded into the `updateNSView`
  dependency read so a mode/focus/flag change is seen.
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
  `sidebarMode` via `Snapshot.sidebarMode: SidebarMode?` (→ `.tree`), `focusedWorkspaceID` via `Snapshot.focusedWorkspaceID: UUID?`
  (naturally Optional → nil), and each workspace's expand/collapse state via `WorkspaceSnapshot.collapsed: Bool?`
  (decode → `false` → expanded).
  All four Optional fields, so legacy JSON with none of the keys decodes to the unflagged / `.tree`
  / unfocused / expanded defaults without throwing (the load-fresh-on-decode-failure contract) — no `Snapshot`
  version bump.
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
  re-apply, the `syncSelection` reveal, and the focused-workspace force-expand — so those update the VISUAL
  `expandedWorkspaceIDs` (needed for the flagged-mode round-trip) WITHOUT touching the persisted `isExpanded`.
  This is what makes a deliberate collapse durable: revealing a session inside a collapsed workspace (nav,
  notification click, or the launch-time active-session reveal) or focusing it shows the row but does NOT
  un-collapse it on disk — the collapse survives until the user expands the row themselves.
  The active session is still force-revealed on launch (`syncSelection`), so it is never hidden inside a
  collapsed workspace; the row just re-collapses on the next launch (its persisted state is untouched).
  Round-trips + legacy-decode (incl. explicit `collapsed:false`) covered in `PersistenceTests`,
  per-workspace + whole-tree mutators / no-op-no-write in `AppStoreOrganizationTests`, and the
  collapse-survives-relaunch + reveal-does-not-repersist end-to-end cases in `SidebarUITests`.
