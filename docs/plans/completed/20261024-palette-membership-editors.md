# Edit Flagged Sessions and Edit Focused Workspaces palettes

## Overview
- Adding a session to the flagged set while the sidebar shows the flagged view takes three steps today:
  switch to the tree, flag the row, switch back. Workspace focus has the same friction.
- Two new `CommandPalette` modes edit membership in place: Edit Flagged Sessions lists every session of the
  window with a live flag mark, Edit Focused Workspaces lists every workspace with a live focus mark.
  Return or click toggles the highlighted row and the palette stays open; Esc closes.
- Changes apply immediately through the existing store setters, so the sidebar updates behind the palette.
  There is no draft and no rollback.

## Context (from discovery)
- Palette: `agterm/Views/Palette.swift` (`PaletteItem`, `PaletteMode`, `CommandPalette`, `PaletteRow`).
  `runItem` dismisses after any row runs; `filtered` is cached on appear, query and mode change;
  `PaletteItem.indicator`/`isEnabled` are live closures; a row click calls `runItem` without moving
  `selection`; the empty query skips ranking only for `.attention` and explicit picks.
- Palette sources and dispatch: `agterm/AppActions+Palette.swift`. `dispatch(_:)` is an exhaustive switch
  over `PaletteCommand`, shared by the action-palette row and keymap `perform(_:in:)`, which applies
  `isEnabled(in:)` first. `.showAttention` dispatches to the next-runloop `openAttentionPalette()`, the
  pattern the editors copy. `paletteLessHandler` must stay disjoint from catalog commands
  (`AppActionsPaletteTests` partitions `BuiltinAction.allCases`).
- Catalog and built-ins: `agtermCore/Sources/agtermCore/PaletteCatalog.swift` (`PaletteCommand`,
  `PaletteContext`, `isVisible`/`isEnabled`/`title`/`builtinAction`), `BuiltinAction.swift` (keyless list).
- Mutations: `AppStore.setFlag(_:forSession:)`, `AppStore.setFocusMembership(_:member:)` (marks only, never
  enables the filter, disables it when the last member leaves).
- `addSession(select: false)` (`session.new --no-select`) leaves `selectedSessionID` untouched, so a window
  can hold sessions with none active; `currentWorkspaceID` falls back to `workspaces.last`.
- Menus: `agterm/agtermApp+Menus.swift` View menu flagged/focus block (lines ~260-300).
- Flagged empty-state hint: `WorkspaceSidebar.Coordinator.installEmptyState` / `updateEmptyState`
  (`agterm/Views/WorkspaceSidebar.swift`, 901 lines; the Coordinator holds `actions`). Marked workspace rows
  use `square.grid.2x2` at `.black` weight (lines ~787-792).
- Focus guard: `AppActions.focusActiveSession` returns while any palette mode is open, and
  `TerminalView.focusIfNeeded` yields to a field editor, so reselection behind an open editor does not steal
  the keyboard.
- Rules: `.claude/rules/menu-actions.md` (palettes, `isEnabled` single owner, keep-in-sync exemption for
  palette opening), `.claude/rules/sidebar.md` (flagged view, workspace focus contracts).

## Development Approach
- **testing approach**: Regular (code first, then tests in the same task)
- complete each task fully before moving to the next
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- new or changed tests run scoped (`swift test --filter`, `-only-testing:<Target>/<Class>/<test>`); the full
  gates (`swift test`, `make test-app`, `make lint`) run once, in the verification task

## Testing Strategy
- **unit tests** (`agtermCore`, Swift Testing): catalog titles, visibility, enablement and built-in mapping;
  built-in raw names and keyless defaults.
- **hosted tests** (`agtermTests`): editor item sources (order, scope, live mark, toggle effect, inert row
  after removal, focus filter never enabled), the stay-open decision, the built-in partition.
- **UI tests** (`agtermUITests`): open each editor, Return toggles and keeps the palette open, click then
  Return hit the clicked row, unflagging the active session keeps the editor and its search field working,
  Esc closes; the flagged empty-state link and View menu items open the editors.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope

## Solution Overview
- Reuse `CommandPalette` rather than the `ask` checkbox dialog (no fuzzy search, and its draft-then-submit
  model would add a second commit model) or a sidebar edit mode (new outline state for a transient task).
- Stay-open is a property of the two editor modes only. `runItem` keeps `guard item.runIfEnabled()` first,
  so an inert row neither acts nor closes; after a successful run the editor modes skip `dismiss()`.
  Explicit picks and every other mode keep their completion and dismissal unchanged.
- Each row's toggle closure captures the item id and the owning `AppStore`, never `activeSession`,
  `currentWorkspaceID` or the sidebar batch selection, which reselection can move behind the open editor.
  Membership is read live in both the row render and the toggle, since `filtered` caches `PaletteItem`s.
- The focus editor only changes membership (`setFocusMembership`). It never turns the filter on, also not
  after removing and re-adding the last member, and works in every sidebar mode, matching the
  mode-agnostic focus controls in `menu-actions.md`.
- One opener per editor serves every entry point: `dispatch` (action-palette row and keymap, both behind
  `isEnabled(in:)`), the View menu and the empty-state link. The View menu items carry
  `.keyboardShortcut(shortcut(for:))` like every menu-backed keyless built-in: a `map` line's primary chord
  becomes a menu-owned override, and only alternatives reach the key monitor, so without it a mapped chord
  does nothing.
- No new control command: `session.flag` (`on|off|toggle|clear`) and `workspace.focus` (`on|off|toggle|add`)
  already script both mutations with read-back in `tree`, and palette opening is keep-in-sync exempt.

## Technical Details
- `PaletteMode` gains `.flaggedEditor` and `.focusEditor`; a computed `keepsOpenOnRun` is true for exactly
  those two.
- `PaletteItem` gains `mark: (() -> PaletteMark)?`, nil for every existing row. `PaletteMark` is a small
  app-target enum, `.flag(Bool)` / `.focus(Bool)`, so `PaletteRow` knows which glyph and accessibility
  vocabulary to draw. The row draws a fixed-width leading mark column only when `mark` is non-nil:
  `flag.fill` / `flag` for sessions, the sidebar's `square.grid.2x2` at `.black` / regular weight for
  workspaces (fill means flagged, weight means focus member). The mark image carries its own identifier
  `palette-mark` and value (`flagged`/`unflagged`, `focused`/`unfocused`), like `palette-subtitle` and
  `palette-badge`, because palette identifiers propagate to text children. The trailing status glyph is
  unchanged.
- `AppActions.paletteFlaggedEditor()`: every session of the frontmost store in tree order
  (`store.workspaces` then their sessions), including sessions hidden by the focus filter. Title
  `displayName`, subtitle the workspace name, indicator as in `paletteSessions`. `mark` reads
  `store.session(withID:)?.flagged`; `isEnabled` requires `uiActionsEnabled` and the session still present;
  `run` calls `store.setFlag(!liveFlag, forSession: id)`.
- `AppActions.paletteFocusEditor()`: `store.workspaces` in tree order. Title the workspace name, subtitle the
  session count. `mark` reads `store.focusedWorkspaceIDs.contains(id)`; `isEnabled` requires
  `uiActionsEnabled` and the workspace still present; `run` calls
  `store.setFocusMembership(id, member: !liveMember)`.
- `CommandPalette.updateFiltered`: the empty-query rank skip extends to both editor modes so rows stay in
  tree order. Toggling never re-runs `updateFiltered`, so query, order and highlight hold; no auto-advance.
- Row click: set `selection = index` before `runItem(item)`, so the next Return targets the clicked row.
- Footer hint under the results for editor modes: `Return toggles · Esc closes · Changes apply immediately`.
  The focus editor appends the live filter state, worded for where it applies: `Filter on` / `Filter off`,
  plus `applies in tree view` while the sidebar shows the flagged view.
- Placeholders: `Flag or unflag sessions…`, `Add or remove focused workspaces…`.
- Openers: `openFlaggedEditor()` / `openFocusEditor()` open the mode on the next runloop tick with the guards
  of `openAttentionPalette()`, so a launch from the action palette survives its `runItem` close.
- Catalog: `PaletteCommand.editFlaggedSessions` ("Edit Flagged Sessions…") and
  `.editFocusedWorkspaces` ("Edit Focused Workspaces…"). Always visible. Enabled on the modal cover term
  plus a new `PaletteContext.hasSessions` (any session in the store, selected or not) /
  `hasCurrentWorkspace`. Built-ins `edit_flagged_sessions` and `edit_focused_workspaces`, both keyless.

## What Goes Where
- **Implementation Steps**: code, tests and docs in this repository.
- **Post-Completion**: manual checks in an isolated Debug instance.

## Implementation Steps

### Task 1: Editor commands, palette modes and dispatch

**Files:**
- Modify: `agtermCore/Sources/agtermCore/BuiltinAction.swift`
- Modify: `agtermCore/Sources/agtermCore/PaletteCatalog.swift`
- Modify: `agterm/Views/Palette.swift`
- Modify: `agterm/AppActions+Palette.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/BuiltinActionTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/PaletteCatalogTests.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/SocketClientTests.swift`
- Modify: `agtermTests/AppActionsPaletteTests.swift`
- Modify: `agtermTests/PaletteTests.swift`
- Modify: `agtermUITests/PaletteUITests.swift`

- [x] `BuiltinAction.editFlaggedSessions = "edit_flagged_sessions"` and
      `.editFocusedWorkspaces = "edit_focused_workspaces"` exist in the keyless default-chord list
- [x] `PaletteContext.hasSessions`; `PaletteCommand.editFlaggedSessions` / `.editFocusedWorkspaces` with
      titles, always visible, enabled on the modal term plus `hasSessions` / `hasCurrentWorkspace`, mapped to
      the new built-ins; `paletteContext` fills `hasSessions` from the store
- [x] `dispatch` routes both commands to `openFlaggedEditor()` / `openFocusEditor()`; nothing new goes into
      `paletteLessHandler`
- [x] `PaletteMode.flaggedEditor` / `.focusEditor` with `keepsOpenOnRun`; `allItems`, placeholder and the
      empty-query source-order skip cover both; the `PaletteMode` doc comment names the two editors
- [x] `PaletteMark` and `PaletteItem.mark`; `PaletteRow` draws the fixed-width leading mark and its
      accessibility value; existing rows render unchanged
- [x] `runItem` keeps the enablement guard first and skips dismissal for editor modes; a row click moves
      `selection` before running; `runIfEnabled`'s doc comment says dismissal also depends on the mode
- [x] editor footer hint, with the focus editor's live filter state
- [x] `paletteFlaggedEditor()` / `paletteFocusEditor()` capture id and store, read membership live in mark
      and run, and go inert when their target is gone
- [x] core tests: raw names parse and round-trip, both default chords are nil, the `allCases` count moves
      from 50 to 52; the byte-identical `keymap list` fixture in
      `SocketClientTests.formatsAPipeFreeKeymapByteIdenticallyToThePreAlternativesOutput` gains both rows;
      titles, visibility in tree and
      flagged contexts, disabled under a modal cover, the flagged editor enabled with sessions but none
      active and disabled with zero sessions, the focus editor disabled without a current workspace,
      built-in mapping
- [x] hosted tests: the built-in partition test still covers both actions; `perform(.editFlaggedSessions,
      in:)` / `perform(.editFocusedWorkspaces, in:)` open their mode after one runloop tick; session editor
      lists every
      session in tree order including focus-hidden ones; running a row twice flips the flag on and off and
      the mark follows; a removed session's row is inert; focus editor toggles membership, never enables the
      filter (including remove-then-re-add of the last member), and leaves an enabled filter on while members
      remain; `keepsOpenOnRun` is true only for the two modes
- [x] UI tests: open Edit Flagged Sessions from the action palette, Return flags the highlighted row, the
      palette stays open with the same query, the flagged sidebar shows the session, Esc closes; the same
      round trip for Edit Focused Workspaces
- [x] UI test: click a row that is not highlighted (hittable-first click as in
      `ControlPickUITests.clickPaletteRow`), then press Return; both toggles land on the clicked row, read
      through `palette-mark`
- [x] UI test: in flagged mode with two flagged sessions, unflag the active one from the editor; the selected
      terminal moves to the survivor, the editor stays open, typed text still reaches its search field, and
      the next Return acts on the originally highlighted row
- [x] core suites pass with `swift test --filter`; the new hosted and UI methods pass with `-only-testing`

### Task 2: Menu items and flagged empty-state link

**Files:**
- Modify: `agterm/agtermApp+Menus.swift`
- Modify: `agterm/Views/WorkspaceSidebar.swift`
- Modify: `agtermTests/SidebarFlaggedLayoutTests.swift`
- Modify: `agtermUITests/FlaggedViewUITests.swift`
- Modify: `agtermUITests/FocusWorkspaceUITests.swift`

- [x] View menu gains Edit Flagged Sessions… after Clear Flagged and Edit Focused Workspaces… after Clear
      Focus, each `.disabled(!PaletteCommand.….isEnabled(in: context))` and
      `.keyboardShortcut(shortcut(for: .editFlaggedSessions / .editFocusedWorkspaces))` (nil by default, a
      `map` line's chord when bound), calling the openers
- [x] the flagged empty-state hint reads `No flagged sessions.` with an `Add Sessions…` link
      (accessibility id `flagged-empty-add`), always enabled, whose click calls
      `actions.perform(.editFlaggedSessions, in: window)`, the keymap path that asks
      `PaletteCommand.isEnabled(in:)` at the click, so the link holds no enablement state that can go stale
      and a window with no sessions makes the click inert; tint unchanged
- ➕ [x] hint and link share one `NSStackView` placed by `SidebarScrollView.layout()`: pinned by constraints,
      the empty state stayed at the scroll origin and the link drew over the hint; a hosted test pins
      centering, the top gap and no overlap
- [x] confirm the link does not take first mouse: measured, `NSButton` accepts it by default, so
      `EmptyStateLinkButton` returns false and a background-window click only activates the window
- [x] UI tests: the empty-state link opens the session editor and flagging from it hides the hint; the View
      menu items open each editor
- [x] the new UI methods pass with `-only-testing`

### Task 3: Verify acceptance criteria
- [x] every Overview requirement holds: in-place toggle, stays open, live marks, immediate effect, focus
      filter never enabled, all entry points
- [x] `cd agtermCore && swift test`
- [x] `make test-app`
- [x] `make lint` reports zero findings
- [x] `lsappinfo list | grep -A4 agterm.debug` shows no leaked test instance

### Task 4: [Final] Update documentation
- [x] `site/docs.html`: both editors in the flagged-view and workspace-focus sections, built-in names in the
      keymap action list
- [x] `plugins/agterm/skills/agterm/reference.md`: built-in names
- [x] `.claude/rules/menu-actions.md`: the "empty query skips ranking in two cases" sentence gains the editor
      modes; the "`runIfEnabled` … only thing that dismisses" sentence gains the stay-open exception; the
      trailing-status-glyph session-list roster gains the session editor; the openers join the palette
      keep-in-sync exemption
- [x] `.claude/rules/sidebar.md`: the empty-state link and the GUI surfaces list
- ➕ [x] `.claude/rules/keymap.md`: the `BuiltinAction` case count moves to 52
- [x] move this plan to `docs/plans/completed/`

## Post-Completion
*Manual checks in an isolated Debug instance (short `/tmp` state dir and socket)*

- focus filter on with one member: add a workspace, remove both, re-add one, confirm the filter stays off
- larger interface font: the mark column and hint line do not truncate titles

**Downstream:**
- the `agterm-linux` fork consumes `agtermCore`; the new public `PaletteCommand` and `BuiltinAction` cases
  break its exhaustive switches until it adds arms for them

Smells pre-check: skipped — non-Go project
