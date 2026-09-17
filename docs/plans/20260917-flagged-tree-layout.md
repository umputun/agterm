# Flagged view tree layout

## Overview

The sidebar's flagged view renders every flagged session as one flat list labelled `session : workspace`.
This adds a second form: the ordinary workspace tree restricted to flagged sessions, with workspace parent
rows and disclosure triangles. The choice is one global preference, flat by default, set in
Settings > Interface or through a `sidebar.flagged-layout` control command.

It also fixes a gap both forms share with the existing tree/flagged view toggle: a structure switch under
an unchanged selection can leave the active session hidden under a collapsed workspace.

## Context (from discovery)

- `SidebarMode` (`agtermCore/Sources/agtermCore/SidebarMode.swift`) stays `tree | flagged`. About fifteen
  `sidebarMode == .flagged` checks in `agtermCore` mean "the flagged set is what is visible"; the layout is
  an orthogonal axis so none of them change meaning.
- `AppStore.flaggedSessions` is `workspaces.flatMap(\.sessions).filter(\.flagged)`, already in tree order.
- Rendering lives in `agterm/Views/WorkspaceSidebar.swift`: `currentShape` (417), `rebuildAndReload` (493),
  `rowContent(forWorkspace:)` (473), `syncSelection` (651), `appearanceChanged` (268),
  `applySidebarFontSizeIfChanged` (289, the tracked-global precedent); labels in
  `WorkspaceSidebar+RowRendering.swift`.
- Global settings follow `AppSettings` raw `String?` plus `effectiveX` (`effectiveToolbarMode`,
  `AppSettings.swift:414`), `SettingsModel.persistAndApply`, a `GhosttyApp.shared` mirror, and an
  object-nil `.agtermAppearanceChanged` post that every sidebar Coordinator observes.
- Workspace-row gates that stop being true once flagged mode can render workspace rows:
  `WorkspaceSidebar.swift` 321, 340, 600; `AppActions.swift:521`; `AppActions+Palette.swift:27` feeding
  `PaletteCatalog.swift:171-175`; the `expandSidebar` doc in `ControlServer+AppCommands.swift`;
  `ControlProjection.swift:327`.
- `Workspace.unseenCount` (`Workspace.swift:30`) sums every session, flagged or not.
- `sidebar.mode` is the wiring template: `ControlProtocol.swift:58`, `ControlModes.swift:62`,
  `ControlDispatcher.swift:78,204,720`, `ControlServer.swift:539`, `ControlServer+AppCommands.swift:35`,
  `agtermctlKit/MiscCommands.swift:641`. `ControlServer` already holds `settingsModel`.

## Development Approach

- **testing approach**: regular (code, then tests) per task; Task 5 is a defect fix and is TDD: write the
  failing regression tests first and confirm they fail before the fix.
- complete each task fully before the next; every task ends with its tests passing
- scope test runs to what changed: `swift test --filter <Suite>` in `agtermCore`, and
  `-only-testing:<Target>/<Class>/<test>` for hosted and UI tests. The full gates run once, in Task 9.
- start Swift work with the `swiftui-expert`, `swift-testing-expert` and `swift-concurrency` skills as relevant
- update this plan when scope changes

## Testing Strategy

- **host-free** (`agtermCore/Tests/agtermCoreTests`): setting decode and resolution, palette predicates,
  control parse and dispatch, `ControlTree` encoding.
- **agtermctl** (`agtermCore/Tests/agtermctlKitTests/CommandsTests.swift`): the new subcommand's request.
- **hosted** (`agtermTests`): sidebar Coordinator structure, badge sum, reveal rule, multi-window update,
  late-mounted sidebar, control server setter.
- **XCUITest** (`agtermUITests/FlaggedViewUITests.swift`): one end-to-end case through the control socket.

## Solution Overview

- The layout is global app state, not window state: no `Snapshot` field, no `AppStore` field, no View-menu
  item. `agtermCore` never reads `GhosttyApp`; the app target passes the layout in where core needs it
  (`PaletteContext`), and the badge and shape builders already live in the app target.
- A layout change reaches open sidebars through the existing `.agtermAppearanceChanged` reconcile. Only a
  sidebar currently in flagged mode rebuilds; an ordinary-tree sidebar's structure is unchanged, and it reads
  the current value whenever it next enters flagged mode or mounts.
- Collapse state is shared with the ordinary tree through `Workspace.isExpanded`. Collapsing a flagged group
  also collapses that workspace in tree mode. Deliberate: the control read-back has one `collapsed` field per
  workspace, and a second folding memory would make every script that reads it mode-aware.
- One reveal rule covers both structure switches (view mode, effective flagged layout).

## Technical Details

- `FlaggedViewLayout: String, Codable, Sendable, CaseIterable { case flat, tree }` in `AppSettings.swift`.
  `AppSettings.flaggedViewLayout: String?`; `effectiveFlaggedViewLayout` resolves missing or unknown to `.flat`.
- "Renders workspace rows" = `sidebarMode == .tree || (sidebarMode == .flagged && layout == .tree)`.
  "Effective flagged layout" = the layout while `sidebarMode == .flagged`, else nil; a change to it is what
  counts as a transition, so a dormant change under the ordinary tree is not one.
- Flagged tree structure: `store.workspaces` (not `visibleWorkspaces`; the focus filter is ignored) filtered to
  those with a flagged session, children filtered to flagged. Labels drop the `: workspace` suffix. Drag
  reorder stays off, the filled flag icon stays suppressed, the `soleFocusedWorkspaceID` force-expansion does
  not apply, the empty-state hint is unchanged.
- Control: `sidebar.flagged-layout` with `args.mode` = `flat | tree | toggle` (default `toggle`), parsed by a
  new `ControlFlaggedLayoutMode`. Global: no `activeStore` guard, no window targeting. `toggle` resolves from
  the effective setting; an unchanged value skips the write and the broadcast.
- Read-back: `ControlTree.sidebarFlaggedLayout: String?`, the effective global value on every tree response,
  ordinary-tree windows included. The control tree payload stays the unfiltered workspace/session model.
- Workspace-row visibility contract becomes
  `sidebarVisible && ((sidebarMode == "tree" && (!workspaceFilter || focused)) ||
  (sidebarMode == "flagged" && sidebarFlaggedLayout == "tree" && workspace has a flagged session))`.
  Focus restricts only the ordinary tree. `sessions[].flagged` supplies membership from the same call.

## What Goes Where

- **Implementation Steps**: code, tests and docs in this repo.
- **Post-Completion**: manual check in an isolated Debug instance.

## Implementation Steps

### Task 1: Add the global flagged-view layout setting

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppSettings.swift`
- Modify: `agterm/SettingsModel.swift`
- Modify: `agterm/Ghostty/GhosttyApp.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppSettingsTests.swift`
- Create: `agtermTests/SettingsModelTests.swift`

- [x] add `FlaggedViewLayout` beside `ToolbarMode` in `AppSettings.swift` (the file's convention for
      raw-stored mode enums) and `AppSettings.flaggedViewLayout` with `effectiveFlaggedViewLayout`,
      including the memberwise init parameter; `flat` is the nil case so `settings.json` stays minimal
- [x] add `SettingsModel.setFlaggedViewLayout(_:)` with a delta guard ahead of `persistAndApply()`, and apply
      the mirror in `SettingsModel.apply` next to `setAutoHideSidebarInactiveWindows`
- [x] add `GhosttyApp.shared.flaggedViewLayout` (`private(set)`) and its setter
- [x] write host-free tests: missing, `flat`, `tree` and unknown raw values resolve as specified; round-trip
- [x] write a hosted `SettingsModel` test on a temporary `SettingsStore` (the model lives in the app target):
      the setter persists, updates the effective mirror, posts `.agtermAppearanceChanged`, and an unchanged
      value does none of those
- [x] run `swift test --filter AppSettingsTests` and `-only-testing:agtermTests/SettingsModelTests`

### Task 2: Render the flagged tree in the sidebar

**Files:**
- Modify: `agterm/Views/WorkspaceSidebar.swift`
- Modify: `agterm/Views/WorkspaceSidebar+RowRendering.swift`
- Create: `agterm/Views/WorkspaceSidebar+FlaggedLayout.swift`
- Create: `agtermTests/SidebarFlaggedLayoutTests.swift`

- [x] branch `currentShape` and `rebuildAndReload` on the layout in flagged mode: workspace parents with a
      flagged session, flagged children only, no `soleFocusedWorkspaceID` force-expansion. `nodeCache` holds
      only nodes in the current projection, as today
- [x] restore expansion from the tracked `expandedWorkspaceIDs`, never straight from `Workspace.isExpanded`:
      keep the existing intersection with ALL extant workspace ids and the union with model-expanded ids, so
      a view-only reveal (tracked open, persisted collapsed) survives a later shape rebuild. Keep the
      unconditional mirror `didSet`, empty-over-empty included (`SidebarExpansionMirrorTests` pins it)
- [x] drop the `: workspace` suffix in both `rowLabel` paths when the layout is tree; keep the unfilled icon
- [x] track the last rendered layout, initialised in `makeNSView` alongside the first rebuild, so `reconcile`
      rebuilds a flagged-mode sidebar when it changes and leaves an ordinary-tree sidebar alone
- [x] confirm drag reorder and Finder-drop resolution stay disabled/unchanged in flagged tree
- [x] put new Coordinator code in a `WorkspaceSidebar+FlaggedLayout.swift` extension: `Coordinator` is about
      686 lines against SwiftLint's 800-line type limit, which binds before the 1000-line file limit, and an
      extension's body does not count toward it. Widen a member from `private` only as far as the extension
      needs
- [x] correct the `rebuildAndReload` comment calling flagged mode "flat, non-expandable ... no workspace nodes"
- [x] write hosted tests on a real outline + Coordinator fixture (the `SidebarCopyNameTests.buildSidebar`
      shape): structure and order, omitted empty workspaces, labels per layout, focus filter ignored, a dormant
      change under the ordinary tree causes no rebuild, a sidebar mounted after the change reads the current
      value, a group disappearing when its last flag is removed and returning when reflagged. Restore the
      global `GhosttyApp` mirror and tear down observers after each test
- [x] run the new class with `-only-testing:agtermTests/SidebarFlaggedLayoutTests`

### Task 3: Sum only flagged children in the flagged-tree workspace badge

**Files:**
- Modify: `agterm/Views/WorkspaceSidebar.swift`
- Modify: `agterm/Views/WorkspaceSidebar+RowRendering.swift`
- Modify: `agtermTests/SidebarFlaggedLayoutTests.swift`

- [x] add one Coordinator method returning a workspace row's displayed unseen count (flagged children in
      flagged tree, `workspace.unseenCount` otherwise) and use it in `rowContent(forWorkspace:)` and the
      workspace cell builder, so the render and content-diff paths cannot drift
- [x] write tests: unread on an unflagged sibling does not reach the header; unread on a flagged child does;
      the ordinary tree still sums everything; a flag flip updates the header (a shape rebuild in flagged
      mode); and, separately, an unseen-count change with flags and ids unchanged updates the live header,
      which is the only case that exercises the content-diff builder
- [x] run the affected tests

### Task 4: Enable workspace collapse in the flagged tree

**Files:**
- Modify: `agterm/Views/WorkspaceSidebar.swift`
- Modify: `agterm/AppActions.swift`
- Modify: `agterm/AppActions+Palette.swift`
- Modify: `agterm/agtermApp+Menus.swift`
- Modify: `agtermCore/Sources/agtermCore/PaletteCatalog.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+Focus.swift`
- Modify: `agterm/Control/ControlServer+AppCommands.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/PaletteCatalogTests.swift`
- Modify: `agtermTests/AppActionsPaletteTests.swift`
- Modify: `agtermTests/SidebarFlaggedLayoutTests.swift`

- [x] replace the tree-mode guards in `expandWorkspacesNotified`, `setWorkspaceExpandedNotified`,
      `collapseOthers` and `toggleActiveWorkspaceCollapse` with the "renders workspace rows" predicate
- [x] add `PaletteContext.sidebarShowsWorkspaceRows`; `expandWorkspaces`, `collapseWorkspaces` and
      `toggleWorkspaceCollapse` become visible on it; `previousWorkspace`/`nextWorkspace` keep
      `sidebarShowsWorkspaceTree` visibility and `canStepWorkspaces` enablement
- [x] state the stepping limit where `canStepWorkspaces` is defined: `navigateWorkspace` steps the focus
      projection, which can land on a workspace the flagged tree does not show
- [x] correct every comment this task makes false, not only the control docs: `expandSidebar`/
      `collapseSidebar` in `ControlServer+AppCommands.swift`; `AppActions.swift` 493, 506, 515;
      `WorkspaceSidebar.swift` 318-319 and 597-598; `PaletteCatalog.swift` 172-174;
      `agtermApp+Menus.swift` 239-240
- [x] audit the workspace-row context menu and hover add button in flagged tree; Delete Workspace keeps
      whole-workspace behaviour and its confirmation
- [x] keep Expand All / Collapse Others at their existing all-workspace persistence scope: they write every
      workspace, groups the flagged tree omits included, because collapse state is shared
- [x] write tests: palette visibility per mode and layout; collapse commands act in flagged tree and persist
      `Workspace.isExpanded`; a fold made in flagged tree shows in the ordinary tree; Collapse Others in
      flagged tree also collapses an omitted workspace
- [x] run the affected suites

### Task 5: Reveal the selected session after a sidebar structure switch (TDD)

**Files:**
- Modify: `agterm/Views/WorkspaceSidebar.swift`
- Modify: `agtermTests/SidebarFlaggedLayoutTests.swift`

- [x] write failing regression tests first, driven through the REAL entry paths (the store mutation plus
      `updateNSView`'s reconcile-then-sync for the view toggle; the `SettingsModel` setter and its
      `.agtermAppearanceChanged` post for the layout switch), never a hand-placed `syncSelection` call that
      would hide its absence: flagged to tree view toggle with the active session under a collapsed
      workspace; flat to tree layout switch in the same state; confirm both fail
- [x] in `reconcile`, compute the transition against the previously RENDERED mode and effective layout before
      overwriting them, and clear `lastRevealedSelection` only for that transition, so the next
      `syncSelection` expands the owner with persistence suppressed and scrolls. Not on other shape rebuilds,
      not on unrelated appearance notifications, not on collapse-driven notification/update traffic
- [x] call `syncSelection` from `appearanceChanged` after a layout transition, since that path does not pass
      through `updateNSView`
- [x] initialise the tracked mode and layout where `makeNSView` does its first rebuild, so the first unrelated
      notification is not mistaken for a structure switch
- [x] write tests: `Workspace.isExpanded` stays collapsed on disk after the reveal; a revealed
      persisted-collapsed parent stays open when ANOTHER workspace's flagged membership changes; the first
      unrelated appearance notification after mount, and a title/badge update, leave a deliberate fold alone;
      selection and multi-selection survive flat to tree and tree to flat; two fixtures with distinct stores
      both update from ONE `SettingsModel` setter call, and a third mounted afterwards reads the current value
- [x] run the affected tests

### Task 6: Add the Settings picker

**Files:**
- Modify: `agterm/Views/SettingsView.swift`

- [ ] add a full-width "Flagged view layout" picker (Flat list / Workspace tree) inside the Interface tab's
      existing Sidebar section, below the two-column toggle rows, extracting the row builder from
      `twoColumnSection` if the section needs mixed content; accessibility id `settings-flagged-view-layout`
- [ ] confirm the Interface tab still fits the fixed 540x680 settings window
- [ ] the SwiftUI binding itself is exercised by Task 7's UI case or the manual check; `SettingsModel` is
      covered by Task 1's hosted test
- [ ] build the app target

### Task 7: Add the `sidebar.flagged-layout` control command and read-back

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlModes.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlActionsDefaults.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProjection.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`
- Modify: `agterm/Control/ControlServer.swift`
- Modify: `agterm/Control/ControlServer+AppCommands.swift`
- Modify: `agtermCore/Sources/agtermctlKit/MiscCommands.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/MockControlActions.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlModesTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherSidebarTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/CommandsTests.swift`
- Modify: `agtermTests/ControlServerTests.swift`
- Modify: `agtermUITests/FlaggedViewUITests.swift`

- [ ] add the command case, `ControlFlaggedLayoutMode.parse`, the dispatcher branch and the
      `ControlActions.setFlaggedViewLayout` requirement; route it in `ControlServer`'s command lists
- [ ] implement the server setter through `settingsModel.setFlaggedViewLayout`: no window guard, `toggle` from
      the effective value, unchanged value skips the write
- [ ] add `ControlTree.sidebarFlaggedLayout`; `AppStore.controlTree` (which builds the immutable tree at
      `AppStore.swift:351`) takes the effective layout as a parameter like the other app-wide facts, never
      as `AppStore` state, and `ControlServer.buildTree` passes it; rewrite the workspace-row visibility doc at
      `ControlProjection.swift:327` to the predicate in Technical Details
- [ ] add `agtermctl sidebar flagged-layout [flat|tree|toggle]` with validation and no `--window`
- [ ] record the new requirement in `MockControlActions`; correct the `setSidebarViewMode` doc's "the flat
      flagged list"; if `ControlDispatcher.swift` (992 lines) would pass 1000, put the branch's handler in a
      `ControlDispatcher+*.swift` extension as the file's siblings do
- [ ] write tests: parse (known, default, unknown); dispatch and bad-argument error; tree encoding carries the
      field; CLI request; hosted setter with no open window, toggle, and no-op; app-produced read-back through
      the server in BOTH ordinary-tree and flagged modes (an encoding test cannot catch an omitted server
      argument); one XCUITest driving the command and asserting the actual accessibility workspace and
      session rows as well as the read-back, since the unfiltered tree response cannot show what the GUI draws
- [ ] run the affected suites; the XCUITest via `-only-testing:agtermUITests/FlaggedViewUITests/<test>`

### Task 8: Update documentation

- [ ] `site/docs.html`: the flagged view's two layouts, the setting, shared collapse state and that Expand All
      / Collapse Others still write every workspace
- [ ] `site/commands.html`: `sidebar.flagged-layout`, its arguments, `sidebarFlaggedLayout` read-back, the
      revised workspace-row visibility predicate; no command total anywhere
- [ ] `plugins/agterm/skills/agterm/`: the command and read-back in `SKILL.md` and `reference.md`, and every
      existing flat-only or "no-op in flagged mode" claim in `reference.md` and `examples.md` corrected
- [ ] `.claude/rules/sidebar.md`, `control-api.md`, `settings.md`, `menu-actions.md` (line 77's "disabled
      outside tree mode"): the layout axis, the reveal rule, the
      shared-collapse trade, the stepping limit; `site/index.html` and `site/llms.txt` only if they list it
- [ ] no `CHANGELOG.md` entry (release-only)

### Task 9: [Final] Verify acceptance criteria

- [ ] every decision in Overview, Solution Overview and Technical Details is implemented
- [ ] `make build` (Release)
- [ ] `cd agtermCore && swift test`
- [ ] `make test-app`
- [ ] `make lint`, zero findings
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification**: isolated Debug instance (`AGTERM_STATE_DIR` under `/tmp`, `windows/` marker
pre-created): flip the picker with two flagged-mode windows open; collapse a group in flagged tree and check
the ordinary tree; switch flat to tree with the active session under a collapsed workspace.

Smells pre-check: skipped — non-Go project
