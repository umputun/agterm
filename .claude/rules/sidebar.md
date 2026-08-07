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

- `WorkspaceSidebar` is an AppKit `NSOutlineView`, chosen over SwiftUI `List` for native
  cross-workspace drag-and-drop. Its `@MainActor` Coordinator caches reference-type `SidebarNode`s so
  reloads retain identity, expansion, and selection.

## Drag and row actions

- Session drops honor `proposedChildIndex`; `SidebarDrop.resolveSession` applies the same-parent
  downward `childIndex - 1` adjustment. A selected-row drag writes all `sidebarSelectionIDs` in visual
  order; an unselected-row drag writes only itself. `resolveSessions` removes the entire mixed-source
  block before inserting it atomically in visual order.
- Workspace rows use pasteboard type `com.umputun.agterm.workspace`, which must remain registered or
  AppKit will not call validate/accept. Do not use AppKit's proposed item/index for workspace moves:
  expanded session rows make every gap appear inside a workspace. Instead, count workspace-row midpoints
  above `draggingLocation`, ignoring sessions.
- Under a focus filter, that cursor slot is in visible space. Map it through
  `workspaceInsertIndex(visibleIndices:slot:)`: before the first visible row uses that row's full index;
  otherwise insert after the last visible row above the cursor. Give the visible slot to
  `setDropItem` for highlighting and the full-array index to `resolveWorkspace`.
- Keep all remove/insert, drop-on-row, no-op, and index-space arithmetic host-free in `SidebarDrop`;
  the Coordinator only maps pasteboard IDs and store locations. `SidebarDropTests` table-test it, and
  `testReorderWorkspaceOntoSessionRow` covers the expanded-workspace failure.
- The footer provides workspace creation and New Session/Open Directory. Workspace row menus repeat the
  session actions. Hover shows `workspace-add-session` only when `InterfaceElement.workspaceAddSession`
  is enabled.
- A workspace-row click toggles expansion through the outline action, excluding the disclosure frame.
  Defer by `NSEvent.doubleClickInterval` and cancel on double-click so rename does not flicker through a
  toggle. This click routing is keep-in-sync exempt. `GhosttyApp.workspaceRowClickExpands` (default on)
  gates the whole-row target only; the disclosure triangle toggles natively and stays unconditional.
  The deferred item re-reads that mirror when it fires, so turning the setting off inside the deferral
  window cancels the pending toggle. Control expansion instead persists through
  `AppActions.setWorkspaceExpanded`, then posts `.agtermSetWorkspaceExpanded` to synchronize a live outline.
- A session-row click selects, then asynchronously calls `revealActiveBlockedPane` with the captured
  pre-reset indicator. Blocked/completed pane tags reveal split, scratch, or primary; idle and active use
  ordinary focus and never dismiss a merely shown scratch. `testSidebarClickRevealsBlockedSplitPane`
  covers the split case.
- Accessibility IDs are `session-row`, `workspace-row`, `edit-field`, and `add-session`. Rename appears
  as `TextField` for sessions but `StaticText` for workspaces, so tests match the identifier across types.

## Multi-selection and flagged view

- `selectedSessionID` remains the active terminal. Transient `sidebarSelectionIDs` is normalized to
  visible order. Shift/Command selection mirrors from AppKit; `allowsEmptySelection` must stay true
  because filtered views can contain no sessions.
- Right-click inside a selection preserves it; outside narrows to the clicked row.
  `sidebarSelectionTargets` filters through the visible projection. Batch move, soft close, flag, and
  clear-status operate on all targets.
- Copy Name writes `Session.displayName`, or the workspace name, to `NSPasteboard.general`. A blank
  workspace name and a vanished row both count as absent, and nothing to copy leaves the pasteboard
  untouched rather than clearing it. No control form — see `control-api.md`.
- Rename, Copy Name, Duplicate Session, and Reveal in Finder appear only for one target. Duplicate inserts a fresh
  login-shell session immediately after the source in the same workspace, using only
  `Session.focusedCwd`. It does not copy name, command, panes, status, flag, font size, or watermark.
  `session.duplicate` provides the control form; its `tree.cwd` can differ from focused cwd when a split's
  non-primary pane is focused.
- `SidebarMode` is per-window `.tree` or `.flagged`. `flaggedSessions` is the derived tree-order
  projection; sessions keep one owning workspace and flags survive moves but not deletion.
- Flagged mode renders one flat, non-expandable outline using `session : workspace`, base terminal/split
  icons, status, and badge. It ignores workspace focus, disables drag reorder, and shows the tinted
  non-scrolling hint `No flagged sessions. / Right-click a session → Flag.` when empty.
- Mode flips call `reselectIfSelectionHidden` only when the active session would disappear. Mutators
  no-op without saving on unknown/unchanged IDs and prune transient selection when rows disappear.
- GUI surfaces are `flagged-view-toggle`, row Flag/Unflag, View-menu Show Flagged/Show All, Flag Session,
  Clear Flagged, palette entries, and keyless built-ins `toggleFlaggedView`/`toggleFlag`. Clear Flagged
  is not a built-in and confirms unless under XCUITest.
- In tree mode, flagged rows swap to `terminal.fill` or `rectangle.split.2x1.fill`; flagged mode retains
  unfilled base icons because every row is flagged. This same-size symbol swap avoids layout shift.
  `RowContent.flagged` limits reload to the changed row.

## Workspace focus

- Focus state is `focusedWorkspaceIDs: Set<UUID>` plus `focusEnabled`; turning the filter off preserves
  the marked set. `visibleWorkspaces` returns tree-order members only while enabled, with a defensive
  full-tree fallback. Flagged mode ignores focus.
- Route every mutation through `commitFocus(ids:enabled:)`, which clamps empty sets, avoids unchanged
  writes/saves, prunes sidebar selection, and saves:
  - `setFocusedWorkspace` replaces the set with one ID and enables it. It backs row Focus/Unfocus,
    `focusActiveWorkspace`, `BuiltinAction.focusWorkspace`, and `workspace.focus on/toggle`.
  - `clearFocus` empties and disables; it backs the plain Clear Focus menu/palette item.
  - `setFocusMembership` changes one member without disturbing others.
  - `setFocusEnabled` changes only the flag; it backs the footer, menu, built-in, and `workspace.filter`.
- Reject nonexistent IDs when adding or replacing; always allow removal. Keep both fields
  `public internal(set)`.
- `soleFocusedWorkspaceID` is the only predicate for an applied one-workspace zoom. Use it for
  `isSoleFocus`, force expansion, and empty-space Finder-drop fallback. Keep target-resolution helpers
  and lifecycle helpers in `AppStore+Focus.swift`.
- Marking never enables the filter. Preserve `focusEnabled` while members remain; disable only when the
  last member leaves. This lets users build a set while the full tree stays visible.
- `focusEnabled && focusedWorkspaceIDs.isEmpty` is forbidden:
  1. enabling an empty set is a no-op and the footer toggle is disabled;
  2. removing the last member disables;
  3. restore prunes stale IDs and disables if none remain.
- The complete row-visibility contract is
  `sidebarVisible && sidebarMode == "tree" && (!workspaceFilter || focused)`. Do not shorten it:
  `focused && workspaceFilter` fails when filtering is off, while `!workspaceFilter || focused` ignores
  hidden-sidebar and flagged-mode rendering.
- Selecting outside the applied set disables filtering but preserves membership. Creating a visible
  workspace while filtering adds it to the set. Background `session.new --no-select --create-workspace`
  and `workspace.new --collapsed` opt out. Removal prunes membership and disables on empty.
- Pending-close undo and Reopen Closed Item restore membership but never `focusEnabled`; the flag is
  current window state, not restored-item state. This avoids a three-second pending snapshot overriding
  a newer toggle and a shared, indefinitely persisted `RecentClosedWorkspace` from window A changing
  window B. Restoring the last removed member therefore returns with filtering off until explicitly enabled.
- Both `PendingWorkspaceClose` and `RecentClosedWorkspace` store only `focusMember`. The recent field is
  optional because missing required keys would make `RecentClosedStore.load()` discard the entire legacy
  list; nil means unmarked. Keep both restore legs because pending state expires after three seconds.
- `foldingPendingCloses` ORs absorbed `focusMember` values into a replacement close. The live set has
  already lost the first membership, and recent-close deduplication overwrites by workspace ID.
  `rebuiltWorkspaceShell` lacks membership input and also serves session reopen, so it must not restore it.
  `reClosingAWorkspaceRebuiltByASessionUndoKeepsItsMembership`, focus undo/reopen tests, and legacy recent
  decode tests pin this contract.
- Marked workspace rows use the same `square.grid.2x2` at `.black` weight, not a fill: fill identifies a
  flagged session, weight identifies focus membership. The 16x15 black image and 15x14 regular image sit
  in a fixed 16x16 `NSImageView`, so the 1pt size difference does not move layout. Render membership even while filtering
  is off. `RowContent.focusMember` limits reload to that row.
- `focus-filter-toggle` replaces the deleted single-workspace pill. It uses a filled grid when active,
  manual 0.35 opacity and disabled state when the set is empty, and accessibility value `on`/`off`.
  It remains usable while filtering is off and is gated by `InterfaceElement.focusFilter`.

## Navigation and selection

- `navigableSessions` is flagged sessions in flagged mode, sessions of visible workspaces in filtered
  tree mode, otherwise all sessions. All next/previous/first/last and attention navigation use this live
  set; next/previous wrap, and missing/invalid selection chooses its first item.
- The same scope drives `session.go`, menu/palette navigation, Ctrl-Tab candidates (while preserving MRU
  order), and the Ctrl-P session palette. This supersedes global navigation that revealed hidden targets.
- `selectSession` calls `disableFocusIfSelectionOutsideSet`. An explicit hidden selection, notification,
  move, or close disables filtering but keeps the set, keeping active session and
  `currentWorkspaceID` visible. It is a no-op while filtering is off, selection is nil/in-set, or mode is
  flagged; flagged mode is cross-workspace and sticky.
- Narrowing calls `reselectIfSelectionHidden` from `commitFocus`, `setSidebarMode`, both flag setters, and
  the end of restore after MRU seeding. Choose the most recent navigable session, then the first. Nil
  selection and an empty visible set remain unchanged.
- Known gaps are intentional: background `addSession(select: false)` and non-active `moveSession` can
  populate an empty visible set without selecting it. Explicit selection of an unflagged session while
  flagged also remains invisible rather than forcing a mode change.
- Terminal focus needs no app bridge: `TerminalView.updateNSView` resigns inactive surfaces and
  `focusIfNeeded` claims the active one. Auto-follow alone posts a pane-specific notification.

## Reconciliation and expansion

- `TreeShape` reflects visible workspace/session roots in tree mode and one stable `flaggedShapeID` group
  in flagged mode. Mode changes always rebuild. Observation must read mode, both focus fields, and every
  session flag: membership redraws icons; enabled state reshapes the tree.
- Track expansion independently in `expandedWorkspaceIDs`. `NSOutlineView` drops expansion when items
  leave the data source, so expand/collapse delegate callbacks and `expandAll` update the set and
  `rebuildAndReload` reapplies it after flagged-mode round trips.
- Expand Workspaces opens all. Collapse Workspaces closes all except the active workspace and scrolls it
  visible. Scope notifications by the target `AppStore` object so only that window's Coordinator acts.
  Both no-op in flagged mode. Menus/palette target frontmost; `sidebar.expand`/`sidebar.collapse` resolve
  `--window` and can target background windows.

## Persistence

- Optional snapshot fields preserve legacy decode without a version bump: `SessionSnapshot.flagged`
  defaults false, `sidebarMode` tree, focus IDs empty, focus disabled, and `WorkspaceSnapshot.collapsed`
  false/expanded.
- `focusedWorkspaceID` remains decode-only. When the new IDs key is absent, migrate a legacy ID to a
  one-member enabled set; the new key wins. Encode IDs in tree order, then intersect them with restored
  workspaces through `restoreFocus`.
- Store `collapsed` as the inverse of `isExpanded` and only encode true, keeping all-expanded snapshots
  byte-compatible. Seed `expandedWorkspaceIDs` from the model in `makeNSView`.
- Persist only genuine user toggles through per-workspace `setWorkspaceExpanded` or one
  `setWorkspacesExpanded` save. Wrap programmatic expansion/collapse during restore, rebuild, selection
  reveal, and sole-focus force expansion in `suppressExpansionPersist`.
- Force expansion only for a sole focused workspace. For a multi-workspace set, repeatedly expanding
  every member after tree changes would undo deliberate collapses and diverge from `tree` read-back.
  Revealing a session may expand visually without changing disk state; launch still reveals the active
  session, and its row may re-collapse next launch.
