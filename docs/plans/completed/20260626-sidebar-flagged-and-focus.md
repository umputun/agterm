# Flagged & Focus sidebar views

## Overview

Two independent, related per-window sidebar features that help narrow a crowded sidebar down to what the user is actively working on:

1. **Flagged working-set** — the user flags a few sessions from across different workspaces; a sidebar **mode toggle** flips the whole sidebar between the normal tree and a **flat list** of just the flagged sessions, each labeled `session : workspace` (e.g. `agterm : ai-thingz`). Durable (a flag persisted on the session). Solves "I have many workspaces but work with a few sessions across them."
2. **Focus / unfocus a workspace** — a per-workspace toggle collapses the sidebar's tree to a single workspace (its sessions only), hiding the others, with an always-visible escape hatch. Single-workspace zoom; **orthogonal** to flagged.

Both follow agterm's HARD four-surface keep-in-sync convention (GUI affordance + menu bar + ⌃⇧P palette/keybind + agtermctl control command + the bundled agent-skill docs), both are per-window, both carry host-free `agtermCore` unit tests plus a focused XCUITest.

This design is the product of a brainstorm; the decisions below are settled — do not re-derive them during implementation.

## Context (from discovery)

- **Project:** native macOS SwiftUI terminal on libghostty. Two targets: host-free `agtermCore` (Foundation-only, `swift test`) and the app target (SwiftUI + AppKit + GhosttyKit). Build with `make build`; host-free tests `cd agtermCore && swift test`.
- **Sidebar:** an AppKit `NSOutlineView` (`agterm/Views/WorkspaceSidebar.swift`, `NSViewRepresentable` + `@MainActor Coordinator`), backed by `AppStore`. Cached reference-type `SidebarNode`s; reconcile splits SHAPE (`TreeShape` → `rebuildAndReload`) from CONTENT (`RowContent` Equatable → per-row `reloadItem`). `TreeShape` is currently derived from `store.workspaces` only. Custom cell drawing: `StatusIconView` (agent-status glyph) + `BadgeView` (unseen-count pill). `syncSelection` deselects when the selected id has no cached node.
- **Model (`agtermCore`):** `Session.swift` (observed fields like `unseenCount`/`agentIndicator`; `@ObservationIgnored` like `splitRatio`), `Snapshot.swift` (`Snapshot` + `SessionSnapshot` Codables — **every added persisted field is declared Optional** so legacy JSON decodes, e.g. `isSplit: Bool?`, `fontSize: Double?`, `sidebarWidth: Double?`, `sidebarVisible: Bool?`), `AppStore.swift` (per-window store; `selectSession`, `navigateSession`, `removeWorkspace`, `currentWorkspaceID`). `BuiltinAction.swift` (rebindable actions + default chords). Control protocol in `ControlProtocol.swift` / `ControlResolve.swift`. `Command` is NOT `CaseIterable`.
- **Persistence load contract (load-bearing):** `PersistenceStore.load()` treats a `Codable` decode failure as "start fresh" — a non-Optional new key whose value is absent in legacy JSON would THROW and silently wipe the saved tree. New persisted fields MUST be Optional in the Codable structs and default on read; do NOT bump `Snapshot` version (a version bump also wipes state).
- **Tests:** snapshot/legacy-decode round-trips live in `agtermCore/Tests/agtermCoreTests/PersistenceTests.swift` (precedents: `legacyFileWithRemovedKeysLoadsAndKeepsWorkspaces`, `sessionSplitStatePersistsAndRestores`). `BuiltinActionTests.swift` has EXHAUSTIVE assertions that any new case breaks: `#expect(BuiltinAction.allCases.count == 30)` and `defaultChordMatchesShippedTable` (asserts `expected.count == allCases.count`, iterates every case) plus a `keylessActionsHaveNilDefault` set.
- **Control seam:** `agterm/Control/ControlServer.swift` (dispatch arms), `agtermCore/Sources/agtermctlKit/Commands.swift` (CLI), bundled agent-skill docs at `agterm/Resources/agent-skill/{SKILL.md,reference.md,examples.md}` (catalog currently **39 commands**). Mode-bearing precedent: `session.scratch`/`session.split` (`on|off|toggle`), and the existing `sidebar show|hide|toggle`.
- **Bottom bar:** `ContentView.bottomBar` is `HStack { [New Workspace] [Add Session] Spacer() }` — left add affordances, right side empty (the new toggle + focus pill go right). It lives in `sidebarColumn` via `.safeAreaInset`, NOT in the `detailPane`/`sessionDetail` HSplitView subtree, so the documented NSSplitView-overrun rules are not in play.
- **Patterns to mirror:** `Clear Status` row-menu action, the scratch 2-state toolbar glyph, `deleteWorkspace`'s confirm alert, the `sidebar` control command, `deleteActiveWorkspace`/`currentWorkspaceID` for an "active workspace" entry point, the plain (non-`BuiltinAction`) menu items Reload/Edit Keymap in `agtermApp.swift`.

## Development Approach

- **Testing approach:** Regular (implement each task's code, then write its tests in the same task before moving on). TDD is reserved for bug fixes; this is new functionality.
- Complete each task fully before the next. Small, focused changes. **Backward compatibility is load-bearing:** existing saved state with no `flagged`/`sidebarMode`/`focusedWorkspaceID` MUST decode to the unflagged / `.tree` / unfocused defaults — declare the persisted Codable fields Optional (see Context). No `Snapshot` version bump.
- **CRITICAL: every task includes tests for its code.** Two realities shape what "tests" means per task:
  - **Host-free logic** (model state, mutations, derived lists, persistence round-trips, control-protocol round-trips, the `BuiltinAction` enum) → `agtermCore` unit tests, run via `cd agtermCore && swift test` (fast; the per-task gate).
  - **App-side AppKit/SwiftUI glue** (outline data source, cells, bottom-bar buttons, menus) has no host-free unit test; its observable behavior is covered by a **dedicated XCUITest task** per feature (`FlaggedViewUITests`, `FocusWorkspaceUITests`). For the intermediate GUI tasks the per-task gate is: `make build` succeeds AND `cd agtermCore && swift test` stays green (no model regression). Cell-badge/pill rendering that the AX tree can't observe is **manual-visual** verification (Task 14). This mirrors the project's documented cadence.
- **CRITICAL: all tests pass before starting the next task.** Run `cd agtermCore && swift test` after every model/control task; `make build` after every GUI task.
- **CRITICAL: update this plan file when scope changes during implementation.**

## Testing Strategy

- **Unit tests (`agtermCore`):** state defaults, mutations, derived `flaggedSessions` ordering, **legacy-decode + round-trip** for `flagged`/`sidebarMode`/`focusedWorkspaceID` (in `PersistenceTests.swift`), focus clear-on-delete, the focus×selection auto-unfocus rule, the `BuiltinActionTests` exhaustive-count/table updates, and `ControlProtocol` round-trips for `session.flag`/`sidebar.mode`/`workspace.focus`.
- **XCUITests (`agtermUITests`):** `FlaggedViewUITests` and `FocusWorkspaceUITests` drive the real app via the accessibility tree; plus the control-channel e2e in `ControlAPIUITests`. XCUITests are slow — run only the affected target/case, and never while the user is interacting with a handed-off build.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix; blockers with ⚠️ prefix
- keep the plan in sync with actual work

## Solution Overview

- **Flagged membership is a boolean on the session, not a second container.** No aliasing — a session always has exactly one home workspace. The flagged list is a pure derived projection (`workspaces.flatMap(\.sessions).filter(\.flagged)`, already in tree order). The mode toggle never shows a session in two places at once (flagged mode hides the tree, tree mode hides the flat list), so there is no two-rows-one-id problem. Auto-cleanup is free (flag dies with the session; survives a workspace move).
- **One outline, mode-switched data source.** The same `NSOutlineView` renders either the tree or the flat flagged list based on `AppStore.sidebarMode`; a mode change forces a `rebuildAndReload`. The reconcile shape signal (`TreeShape`) is made **mode/focus-aware** (computed from the mode-selected/filtered roots, or by tracking the last mode/focus) so a mode or focus flip actually rebuilds.
- **Focus is a tree filter, with an explicit navigation contract.** `focusedWorkspaceID` restricts the *tree* to one root; it is orthogonal to flagged (flagged mode shows the full cross-workspace set regardless of focus). Global selection/navigation (`navigateSession`/`session.go`, Ctrl-Tab MRU, attention-nav) operate over all sessions; to avoid a "hidden active session, nothing selected in the sidebar" state, **selecting a session outside the focused workspace auto-clears focus** so the sidebar reveals it. This keeps the active session always inside the visible set, which also keeps `currentWorkspaceID` (new-session placement) consistent without a special-case.
- **All three states persist per-window** in `Snapshot` (Optional Codable fields), defaulting to unflagged / `.tree` / unfocused so existing saved state is unaffected.

## Technical Details

New host-free types/fields (`agtermCore`):
- `Session.flagged: Bool = false` — observed (live); folded into the sidebar's `RowContent` so a toggle reloads only that row. Persisted via `SessionSnapshot.flagged: Bool?` (decode → `false`).
- `enum SidebarMode: String, Codable, Sendable { case tree, flagged }` — new file `agtermCore/Sources/agtermCore/SidebarMode.swift`. (Trivial enum; its round-trip is covered by the Persistence tests rather than a separate `SidebarModeTests.swift`.)
- `AppStore.sidebarMode: SidebarMode = .tree` (live) persisted via `Snapshot.sidebarMode: SidebarMode?` (decode → `.tree`).
- `AppStore.focusedWorkspaceID: UUID?` (live) persisted via `Snapshot.focusedWorkspaceID: UUID?` (naturally Optional, safe).
- Mutators: `setFlag(_:forSession:)`, `clearFlags()`, derived `flaggedSessions: [Session]`, `setSidebarMode(_:)`, `setFocusedWorkspace(_:)`, and a `visibleWorkspaces` filter (focused workspace if set+exists, else all).

New control commands (mode-bearing, mirroring `session.scratch`): `session.flag` (`on|off|toggle|clear`, target = session, returns id; `clear` ignores target), `sidebar.mode` (`tree|flagged|toggle`), `workspace.focus` (`on|off|toggle`, target = workspace, returns id). Catalog 39 → 42.

New `BuiltinAction`s (3 total, expressible/keyless): `toggle_flagged_view`, `toggle_flag` (Task 7), `focus_workspace` (Task 12). `allCases.count` 30 → 32 → 33. The two **clear** actions (Clear Flagged, Clear Focus) are plain menu/palette items, NOT `BuiltinAction`s (rare; rebinding unwanted — mirrors Reload/Edit Keymap).

## What Goes Where

- **Implementation Steps** (`[ ]`): all model, view, control, and test work.
- **Post-Completion** (no checkboxes): manual visual acceptance in an isolated dev instance, and the `make deploy` + relaunch (left to the user).

## Implementation Steps

### Task 1: Model — `Session.flagged` + persistence

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Session.swift`
- Modify: `agtermCore/Sources/agtermCore/Snapshot.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/PersistenceTests.swift`

- [x] add `public var flagged: Bool = false` to `Session` (observed; near `unseenCount`/`agentIndicator`)
- [x] add `flagged: Bool?` to `SessionSnapshot` (Optional, like the other added fields); capture from `Session.snapshot()` and decode → `false` on restore when absent
- [x] verify legacy `SessionSnapshot` JSON (no `flagged` key) still decodes (does NOT throw) and yields `flagged == false`; no `Snapshot` version bump
- [x] write tests in `PersistenceTests.swift`: round-trip preserves `flagged` true/false; a legacy snapshot without the key loads and keeps its workspaces with `flagged == false`
- [x] run `cd agtermCore && swift test` — must pass before next task

### Task 2: Model — `SidebarMode` + `AppStore.sidebarMode` persistence

**Files:**
- Create: `agtermCore/Sources/agtermCore/SidebarMode.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`
- Modify: `agtermCore/Sources/agtermCore/Snapshot.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/PersistenceTests.swift`

- [x] create `SidebarMode` enum (`.tree`/`.flagged`, `String`-backed `Codable`/`Sendable`)
- [x] add `AppStore.sidebarMode: SidebarMode = .tree` (observed) + `setSidebarMode(_:)` that `save()`s; persist via `Snapshot.sidebarMode: SidebarMode?`, decode → `.tree` when absent
- [x] verify a legacy snapshot (no `sidebarMode` key) decodes without throwing → `.tree`; no version bump
- [x] write tests in `PersistenceTests.swift`: round-trips `sidebarMode` (.tree/.flagged); legacy snapshot restores `.tree`
- [x] run `cd agtermCore && swift test` — must pass before next task

### Task 3: Model — flag mutations + derived flagged list

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreTests.swift`

- [x] add `setFlag(_ on: Bool, forSession id: UUID)` — sets the session's `flagged`, `save()`s; clean no-op on unknown id
- [x] add `clearFlags()` — unflags every session across all workspaces, single `save()`
- [x] add `flaggedSessions: [Session]` computed = `workspaces.flatMap(\.sessions).filter(\.flagged)` (tree order)
- [x] write tests: `setFlag` toggles + persists, unknown id no-op; `clearFlags` empties the set; `flaggedSessions` returns matches in workspace-then-session order; a flagged session moved to another workspace re-sorts (keeps its flag)
- [x] run `cd agtermCore && swift test` — must pass before next task

### Task 4: Sidebar — flagged-mode flat rendering

**Files:**
- Modify: `agterm/Views/WorkspaceSidebar.swift`

- [x] branch the Coordinator data source (`numberOfChildrenOfItem`/`child`/`isItemExpandable`) on `store.sidebarMode`: in `.flagged` mode the root's children are `flaggedSessions` as flat rows with no children (not expandable); rebuild the cached `SidebarNode`s for the mode
- [x] make the reconcile shape signal mode-aware: include `sidebarMode` in `TreeShape` (or track `lastMode`) and fold `sidebarMode` into the `updateNSView` dependency read, so a mode flip takes the `rebuildAndReload` branch (NOT per-row reload)
- [x] render flagged rows with label `session : workspace` (session `displayName` first, then owning workspace name), plain terminal icon (no checkmark badge here), and keep `StatusIconView` + `BadgeView`; route a row click through the existing `selectSession`; keep the active session selected on switch if it is in the set; the mode switch is view-only (never re-selects/refocuses); disable drag-reorder in `.flagged` mode
- [x] show a centered empty-state hint ("No flagged sessions. Right-click a session → Flag.") when `.flagged` and the set is empty
- [x] gate: `make build` succeeds AND `cd agtermCore && swift test` stays green (behavioral coverage in Task 9 `FlaggedViewUITests`)

### Task 5: Sidebar — tree-mode flagged indicator (checkmark-badged icon)

**Files:**
- Modify: `agterm/Views/WorkspaceSidebar.swift`

- [x] (deliberate requested indicator, not optional) in the tree cell, when a session is `flagged`, draw a small checkmark corner-badge composited over the terminal icon (custom cell drawing like `StatusIconView`/`BadgeView`; no native "terminal+checkmark" SF Symbol — overlay a checkmark), tinted with the chrome/theme color, legible ~14pt
- [x] fold `flagged` into the row's `RowContent` (Equatable) so toggling re-badges only that row (per-row `reloadItem`)
- [x] verify the badge reserves no trailing space when unflagged (collapses, like the idle agent-status glyph)
- [x] gate: `make build` succeeds AND `cd agtermCore && swift test` stays green. NOTE: the checkmark badge is **manual-visual** verification (Task 14) — not assertable via the AX tree, so not covered by the Task 9 XCUITest

### Task 6: Flag gesture + Clear Flagged action

**Files:**
- Modify: `agterm/Views/WorkspaceSidebar.swift` (row context menu)
- Modify: `agterm/AppActions.swift`

- [x] add a session row context-menu item **Flag / Unflag** (toggles by current state) → `AppActions.toggleFlag(_ sessionID:)` → `AppStore.setFlag(_:forSession:)`
- [x] add active-session variants in `AppActions`: `toggleFlagActiveSession()` and `clearFlags()` (the latter wraps `AppStore.clearFlags()` with a light confirm alert when the set is non-empty, mirroring `deleteWorkspace`; skip the alert under the XCUITest launch like the quit-confirm)
- [x] gate: `make build` succeeds AND `cd agtermCore && swift test` stays green (behavioral coverage in Task 9)

### Task 7: Mode-toggle GUI surfaces (bottom-bar button + menu + palette + keybind)

**Files:**
- Modify: `agterm/ContentView.swift` (bottomBar)
- Modify: `agterm/agtermApp.swift` (View menu commands)
- Modify: `agterm/Views/Palette.swift` (palette entries)
- Modify: `agterm/AppActions.swift`
- Modify: `agtermCore/Sources/agtermCore/BuiltinAction.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/BuiltinActionTests.swift`

- [x] add a right-side bottom-bar button (after the trailing `Spacer()`) that flips `sidebarMode`: 2-state flag/checkmark glyph (filled in `.flagged`, outline in `.tree`), tinted `chromeText`; animate the sidebar via the existing `ContentView` `.animation(value:)`
- [x] add `BuiltinAction.toggleFlaggedView` and `BuiltinAction.toggleFlag` (expressible, or keyless like `selectTheme`); wire `AppActions.toggleFlaggedView()`. Add **Clear Flagged** as a plain menu/palette item (NOT a `BuiltinAction`)
- [x] add View-menu items ("Show Flagged"/"Show All" via `equivalent(for:)`, "Flag Session", "Clear Flagged") and ⌃⇧P palette entries for the same
- [x] **update `BuiltinActionTests`**: bump `allCases.count` 30 → 32; add both new actions to the `defaultChordMatchesShippedTable` `expected` dictionary; add them to the `keylessActionsHaveNilDefault` set if keyless
- [x] run `cd agtermCore && swift test`; `make build` — must pass before next task

### Task 8: Control — `session.flag` + `sidebar.mode`

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agterm/Control/ControlServer.swift`
- Modify: `agtermCore/Sources/agtermctlKit/Commands.swift`
- Modify: `agterm/Resources/agent-skill/SKILL.md` + `reference.md` + `examples.md`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`
- Modify: `agtermUITests/ControlAPIUITests.swift`

- [x] add `Command` cases `sessionFlag = "session.flag"` (reuse `ControlArgs.mode` = `on|off|toggle|clear`, returns `result.id`) and `sidebarMode = "sidebar.mode"` (reuse `ControlArgs.mode` = `tree|flagged|toggle`)
- [x] add the two `ControlServer` dispatch arms (`session.flag` → `setFlag`/`clearFlags`; `sidebar.mode` → `setSidebarViewMode`, delta-computed/idempotent, unknown mode = error); surface `flagged` on `ControlSessionNode` in the `tree` builder
- [x] add `agtermctl session flag on|off|toggle|clear` and `agtermctl sidebar mode tree|flagged|toggle` (the existing `sidebar [show|hide|toggle]` is now the default `sidebar visibility` subcommand)
- [x] update agent-skill docs: bump the command count 39 → 41; add both commands to SKILL.md summary + `reference.md` detail + an `examples.md` recipe
- [x] write tests: `ControlProtocol` round-trips for both commands; e2e in `ControlAPIUITests` (flag a session over the socket, `sidebar.mode flagged`, assert the flagged row present and an unflagged row absent)
- [x] run `cd agtermCore && swift test`; `make build` — must pass before next task

### Task 9: `FlaggedViewUITests` (XCUITest)

**Files:**
- Create: `agtermUITests/FlaggedViewUITests.swift`

- [x] seed sessions in two workspaces (hermetic `AGTERM_STATE_DIR`), flag two of them via the row context menu
- [x] toggle to flagged mode (bottom-bar button), assert the flat list shows exactly the two flagged rows with `session : workspace` AX labels, and an unflagged session's row is absent
- [x] assert clicking a flagged row selects that session (observable side effect) and toggling back to tree restores the full tree
- [x] assert **Clear Flagged** empties the flagged view (back to the empty-state hint)
- [x] run `xcodebuild test … -only-testing:agtermUITests/FlaggedViewUITests` — must pass before next task

### Task 10: Model — focus state, persistence, clear-on-delete, auto-unfocus, filter

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`
- Modify: `agtermCore/Sources/agtermCore/Snapshot.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/PersistenceTests.swift`

- [x] add `AppStore.focusedWorkspaceID: UUID?` (observed) + `setFocusedWorkspace(_:)` (`save()`s); persist via `Snapshot.focusedWorkspaceID: UUID?` (Optional; decode → nil)
- [x] make `removeWorkspace` clear `focusedWorkspaceID` when the removed workspace was focused; add a `visibleWorkspaces` helper (the focused workspace if set and still present, else all) — the source of truth the sidebar tree filters on
- [x] **focus×selection contract:** in `selectSession`, when the newly selected session is NOT in the focused workspace, clear focus (auto-unfocus) so global nav (`navigateSession`/`session.go`, Ctrl-Tab, attention-nav) always reveals its target. Do NOT special-case `currentWorkspaceID` (auto-unfocus keeps selection inside the visible set, so placement stays consistent)
- [x] write tests: `setFocusedWorkspace` persists (round-trip in `PersistenceTests`, default nil); deleting the focused workspace clears focus; `visibleWorkspaces` returns one when focused, all when unfocused/stale-id; selecting a session outside the focused workspace clears focus; selecting one inside keeps it
- [x] run `cd agtermCore && swift test` — must pass before next task

### Task 11: Sidebar — focus rendering + workspace row Focus/Unfocus

**Files:**
- Modify: `agterm/Views/WorkspaceSidebar.swift`

- [x] in `.tree` mode, render only `visibleWorkspaces` (the focused workspace's root subtree — header + its sessions) when `focusedWorkspaceID` is set; flagged mode ignores focus
- [x] make the reconcile shape signal focus-aware: include `focusedWorkspaceID` in `TreeShape` (or track `lastFocus`) and fold it into the `updateNSView` dependency read so a focus flip takes the `rebuildAndReload` branch
- [x] add a workspace row context-menu item **Focus / Unfocus** (toggles) → `AppActions.focusWorkspace(_ id:)` → `AppStore.setFocusedWorkspace(_:)`; keep add-session/rename/split working on the focused workspace's rows
- [x] gate: `make build` succeeds AND `cd agtermCore && swift test` stays green (behavioral coverage in Task 13)

### Task 12: Focus surfaces — bottom-bar pill + active-workspace entry point + Clear Focus

**Files:**
- Modify: `agterm/ContentView.swift` (bottomBar pill)
- Modify: `agterm/AppActions.swift`
- Modify: `agterm/agtermApp.swift` (View menu)
- Modify: `agterm/Views/Palette.swift`
- Modify: `agtermCore/Sources/agtermCore/BuiltinAction.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/BuiltinActionTests.swift`

- [x] add a bottom-bar **"Focused: <name> ✕"** pill, shown only while `focusedWorkspaceID` is set (right side, near the flagged toggle); clicking ✕ unfocuses; give it an accessibility id for the UITest
- [x] add `AppActions.focusActiveWorkspace()` (targets `currentWorkspaceID`, analogous to `deleteActiveWorkspace`) wired to `BuiltinAction.focusWorkspace`, plus a "Focus Workspace" View-menu + ⌃⇧P palette item — so the keybind has a discoverable, drivable entry point
- [x] add `AppActions.clearFocus()` as a plain **menu/palette** "Clear Focus" item (NOT a `BuiltinAction`; the pill ✕ is the primary affordance)
- [x] **update `BuiltinActionTests`**: bump `allCases.count` 32 → 33; add `focusWorkspace` to the `defaultChordMatchesShippedTable` `expected` dictionary (and the keyless set if keyless)
- [x] run `cd agtermCore && swift test`; `make build` — must pass before next task

### Task 13: Control — `workspace.focus` + `FocusWorkspaceUITests`

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agterm/Control/ControlServer.swift`
- Modify: `agtermCore/Sources/agtermctlKit/Commands.swift`
- Modify: `agterm/Resources/agent-skill/SKILL.md` + `reference.md` + `examples.md`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`
- Create: `agtermUITests/FocusWorkspaceUITests.swift`
- Modify: `agtermUITests/ControlAPIUITests.swift`

- [x] add `Command` case `workspaceFocus = "workspace.focus"` (reuse `ControlArgs.mode` = `on|off|toggle`, target = workspace, returns id); the `ControlServer` arm (delta-computed/idempotent) → `setFocusedWorkspace`; the `agtermctl workspace focus on|off|toggle` subcommand
- [x] update agent-skill docs: bump command count 41 → 42; add `workspace.focus` to SKILL.md + `reference.md` + an `examples.md` recipe
- [x] write `ControlProtocolTests` round-trip for `workspace.focus`; add the `ControlAPIUITests` e2e (focus a workspace over the socket, assert other workspace rows are gone)
- [x] write `FocusWorkspaceUITests`: focus a workspace via the row menu, assert other workspaces' rows leave the AX tree and the "Focused …" pill appears; click the pill ✕ and assert all workspaces return
- [x] run `cd agtermCore && swift test`; `make build`; `xcodebuild test … -only-testing:agtermUITests/FocusWorkspaceUITests` — must pass before next task

### Task 14: Verify acceptance criteria

- [x] verify every Overview requirement is implemented (flag/unflag, mode toggle in all four surfaces, flat `session : workspace` list, tree checkmark badge, Clear Flagged, focus/unfocus, pill escape hatch, focusActiveWorkspace keybind, clear-on-delete, persistence of all three states)
- [x] verify edge cases: legacy state decodes to defaults (no wipe); flagged session closed → leaves the deck; focused workspace deleted → focus clears; flagged mode ignores focus; selecting a session outside the focused workspace auto-unfocuses (Ctrl-Tab / `session.go` / attention-nav reveal their target); `session.new` / `workspace.move --target active` behave sanely while focused
- [x] run the full host-free suite: `cd agtermCore && swift test` — 694 tests in 31 suites, all green
- [x] run the affected XCUITests: `FlaggedViewUITests` (PASS), `FocusWorkspaceUITests` (PASS), `ControlAPIUITests` (68 PASS), and `ReorderUITests` (5 PASS, sidebar regression)
- [x] manual-visual — deferred to user (Post-Completion); not automatable (tree checkmark badge + focus pill under compact/translucent chrome, not AX-assertable)

### Task 15: Update documentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md` (if user-facing enough to warrant a mention)

- [x] update `CLAUDE.md`: the Sidebar section (mode toggle + flagged flat view + checkmark badge + focus filter + the focus×selection auto-unfocus contract + the bottom-bar toggle/pill + the mode/focus-aware reconcile signal), the Control API catalog (39 → 42 + the three new commands with four-point audits), and confirm the agent-skill mirror note
- [x] update `README.md` if the working-set / focus features belong in the user-facing overview
- [x] confirm the agent-skill docs (edited in Tasks 8 & 13) are consistent (command count, all three commands)
- [x] move this plan to `docs/plans/completed/` — move performed by exec finalize step (kept in place for review phases)

## Post-Completion
*Items requiring manual intervention or external systems — no checkboxes, informational only.*

**Manual verification:**
- Visual acceptance of the flagged flat list, the tree checkmark badge, and the focus pill in an isolated dev instance loaded with a copy of the real multi-workspace state (compact toolbar + translucency on) — the cell badge/pill rendering isn't assertable via the AX tree.

**Deployment:**
- The user runs `make deploy` and relaunches their daily-driver on their own schedule (the running deployed app keeps old code until relaunched — never relaunch it for them).

---

Smells pre-check: skipped — non-Go project
