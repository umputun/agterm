# Workspace Focus Set (multi-workspace sidebar filter)

## Overview

Today the sidebar's focus filter holds exactly one workspace: `AppStore.focusedWorkspaceID` is a `UUID?`, so
the tree shows either one workspace or all of them. With seven workspaces in a window that is too coarse —
there is no way to say "show me umputun.dev and ai-thingz, hide the other five".

This plan generalizes focus into a SET plus an on/off flag:

- `focusedWorkspaceIDs: Set<UUID>` — the marked workspaces
- `focusEnabled: Bool` — whether the filter applies, so the set survives being turned off

Focus is not replaced by a second concept; it becomes "a set that today always held one element". Every
existing caller of `setFocusedWorkspace(_:)` keeps working unchanged, and everything downstream of
`visibleWorkspaces` (session nav, attention nav, Ctrl-Tab MRU, the ⌃P palette, the reconcile signal)
inherits the set for free.

**Benefits**

- A working set of N workspaces instead of one-or-all.
- The marked set is remembered while the filter is off, so peeking at the whole tree costs one click.
- Membership is visible at a glance: a marked workspace row draws the filled grid icon.
- Full control-API coverage — a script can build, read, and restore a working set.

**Not in scope**

- Filtering SESSIONS within a workspace (the flagged working-set view already covers that).
- Any change to `sidebarMode` / the flagged flat list, which stays orthogonal and ignores focus.
- `CHANGELOG.md` — release-only, never touched in a feature PR.

## Context (from discovery)

**Files/components involved** — every referencing site, verified by grep, not assumed:

- Model (`agtermCore`): `AppStore.swift`, `AppStore+PendingClose.swift`, `AppStore+RecentClosed.swift`,
  `AppStore+CloseReselection.swift` (doc comment only), `Snapshot.swift`, `SidebarDrop.swift`.
- Control (`agtermCore`): `ControlProtocol.swift`, `ControlModes.swift`, `ControlDispatcher.swift`,
  `PaletteCatalog.swift`; CLI in `agtermctlKit/WorkspaceCommands.swift`.
- App target: `agterm/Control/ControlServer+WorkspaceCommands.swift`, `agterm/AppActions.swift`,
  `agterm/AppActions+Palette.swift`, `agterm/agtermApp+Menus.swift` (TWO sites, lines 242 and 250),
  `agterm/Views/WorkspaceSidebar.swift` (lines 122, 551), `WorkspaceSidebar+ContextMenu.swift` (line 141),
  `WorkspaceSidebar+DragDrop.swift` (line 160), `WindowContentView.swift` (line 781).
- Tests: `AppStoreTests.swift`, `AppStoreOrganizationTests.swift` (incl. a direct field WRITE at line 330),
  `AppStoreCloseReselectionTests.swift`, `AppStoreNavigationTests.swift`, `PersistenceTests.swift`,
  `SnapshotRoundTripTests.swift`, `SidebarDropTests.swift`, `ControlProtocolTests.swift`,
  `ControlDispatcherTests.swift`, `ControlModesTests.swift`, `MockControlActions.swift`,
  `PaletteCatalogTests.swift`, `CommandsTests.swift`, `agtermUITests/FocusWorkspaceUITests.swift`,
  `agtermUITests/ControlSidebarStatusUITests.swift` (incl. a stale comment at lines 171-173).
- Docs: `.claude/rules/sidebar.md`, `.claude/rules/control-api.md`, `.claude/rules/menu-actions.md`
  (line 255 names the renamed helper), `README.md`, `site/docs.html`, `site/commands.html`,
  `agterm/Resources/agent-skill/{SKILL.md,reference.md,examples.md}`.

**Related patterns found**

- The flagged working-set feature is the direct precedent for every UI piece: a filled SF Symbol variant for
  membership (`terminal` → `terminal.fill`), membership folded into `RowContent` for per-row `reloadItem`, a
  2-state bottom-bar button disabled when the set is empty, and an `InterfaceElement` case gating it.
- `StatusShape` / `ReorderDirection` are the precedent for a typed, dispatcher-parsed mode enum whose error
  message derives from `allCases` so it cannot go stale.
- `Snapshot` already has a custom `init(from:)` (its `encode(to:)` is SYNTHESIZED), so legacy-key migration
  slots into the decoder and "stop writing the legacy key" means simply not populating it.
- `sidebar` → `sidebarVisible` and `sidebar.mode` → `sidebarMode` are the precedent for a bare-noun on/off
  command with a top-level `ControlTree` read-back.
- `AppStore+Panes/+Restore/+PendingClose.swift`, `AppActions+Palette.swift`,
  `AppStorePaneTests/AppStoreRestoreTests.swift`, and `ControlDispatcherDashboardTests.swift` are the
  precedents for the four feature-scoped file splits Task 1 performs.

**Dependencies identified**

- `visibleWorkspaces` is read by `navigableSessions`, the sidebar data source, the `TreeShape` reconcile, and
  `AppActions+Palette`. Generalizing it is what makes the rest free.
- `workspace.focus` is dispatcher-ROUTED but its mode string is still validated app-side in
  `ControlServer+WorkspaceCommands.swift` — adding a mode is the moment to hoist that parse, per the
  dispatcher-first rule.

**File-size situation (measured, not estimated)** — the swiftlint caps are 1000 for source, 2000 for tests,
and `--strict` turns the warning into a failure:

| File | Lines | Cap | Headroom |
|---|---|---|---|
| `agtermCore/Sources/agtermCore/AppStore.swift` | **1000** | 1000 | **0** |
| `agtermCore/Tests/agtermCoreTests/AppStoreTests.swift` | 1969 | 2000 | 31 |
| `agtermCore/Tests/agtermCoreTests/ControlDispatcherTests.swift` | 1960 | 2000 | 40 |
| `agterm/AppActions.swift` | 960 | 1000 | 40 |

All four are too tight for this feature, so Task 1 splits the focus code out into its own files FIRST. Every
other touched file has room: `WorkspaceSidebar.swift` 885, `WindowContentView.swift` 832,
`ControlProtocol.swift` 773, `ControlDispatcher.swift` 773, `AppSettings.swift` 526, `agtermApp+Menus.swift`
375, `AppActions+Palette.swift` 346, `MockControlActions.swift` 457, `ControlProtocolTests.swift` 1442,
`CommandsTests.swift` 1403, `AppStoreOrganizationTests.swift` 749, `ControlSidebarStatusUITests.swift` 839.

## Development Approach

**Prerequisite — isolated git worktree (do this before Task 1):**

1. `git fetch origin master` FIRST, so the worktree forks the current remote tip rather than a stale local ref.
2. Create the worktree with Claude Code's native support ("work in a worktree" / `EnterWorktree`), never a
   manual `git worktree add`.
3. Symlink the three gitignored build artifacts before building, using ABSOLUTE targets for the two under
   `Resources/`: `GhosttyKit.xcframework`, `agterm/Resources/ghostty`, `agterm/Resources/terminfo`. With them
   in place `scripts/setup.sh` prints "GhosttyKit and resources already present" and skips the multi-minute
   libghostty rebuild.
4. After the PR merges, remove the worktree from the MAIN checkout (never switch the main checkout's branch).

**Testing approach: Regular** — implement, then write tests within the same task, before the task is marked
complete. Matches project CLAUDE.md ("after writing any new function/method, STOP and write tests before
continuing").

**⚠️ The app target does NOT build between Task 2 and Task 4.** Tasks 2 and 3 remove
`AppStore.focusedWorkspaceID` / `focusedWorkspace`, whose remaining readers live in six app-target files.
Task 4 is a mechanical sweep that restores the build. Tasks 2 and 3 therefore gate on `swift test` ONLY —
this is a deliberate, documented gap, not a skipped gate. Every task from 4 onward gates on the full set.

- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional — they are a required part of the checklist
  - write unit tests for new functions/methods and for modified ones
  - add new test cases for new code paths; MIGRATE existing cases whose behavior changes
  - cover both success and error scenarios
- **CRITICAL: all tests must pass before starting the next task** — no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- maintain backward compatibility: on-disk snapshots written by the current release must still load

**Per-task gate (agterm-specific):**

1. `cd agtermCore && swift test` passes.
2. The app builds (`make build`) — Tasks 4 onward only, per the documented gap above.
3. `make lint` passes (`swiftlint lint --strict`, zero findings — warnings are failures).
4. `make test-app` passes when the task touched app-target code.
5. Source files stay under 1000 lines and test files under 2000; do NOT raise the swiftlint
   `file_length`/`type_body_length` limits to fit new code — Task 1 already made the room.

## Testing Strategy

- **unit tests (`swift test`)**: required for every task touching `agtermCore` — the set mutators, the
  visibility rules, snapshot round-trip and legacy migration, the drop fallback, dispatcher validation and
  routing, protocol round-trip and omit-when-nil, palette catalog arms, and CLI argument mapping.
- **app-hosted tests (`make test-app`)**: for AppKit-level changes where an isolated `agtermTests` case fits.
- **e2e (XCUITest, `agtermUITests/`)**: treated with the same rigor as unit tests and written in the same
  task as the UI code. Two suites are affected:
  - `FocusWorkspaceUITests` — the three `focus-pill` assertions are re-pointed at `workspace-row` visibility
    (the filtering itself, which the pill was only ever a proxy for) plus the new toggle's
    `accessibilityValue` and `isEnabled`. This is a coverage MOVE, not a reduction: the assertions get
    stronger because they test the behavior instead of the indicator.
  - `ControlSidebarStatusUITests` — the new `workspace.filter` command and the `workspace.focus add` mode.
- Task 15 (e2e) is also the coverage for Tasks 11 and 12, whose output (an SF Symbol variant, a menu label
  flip) is not accessibility-observable at the point it is written.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview

**Two fields replace one.** `focusedWorkspaceIDs: Set<UUID>` holds membership; `focusEnabled: Bool` gates
whether it applies. Both are per-window and persisted, like `sidebarMode` and the old `focusedWorkspaceID`.

**`enabled + empty set` is made UNREPRESENTABLE, not merely tolerated.** An earlier draft let that state
exist and relied on `visibleWorkspaces` falling back to the full tree — which silently broke the documented
read-back contract (`workspaceFilter` would report `true` while no workspace reported `focused`, so a script
would conclude nothing was visible while the whole tree was on screen). Two guards close it:

- `setFocusEnabled(true)` is a no-op when the set is empty — matching the bottom-bar button, which is
  disabled in exactly that state, so the GUI and the control path agree.
- `restore(from:)` PRUNES member ids not present in the restored tree, so an all-stale set collapses to
  empty-and-disabled rather than to an enabled-but-invisible filter.

With both in place the empty-result fallback in `visibleWorkspaces` becomes defensive belt-and-braces rather
than a reachable path, and the contract "visible iff `!workspaceFilter || focused`" holds exactly.

⚠️ CORRECTION (review round 3): every task below, and the shipped docs they produced, wrote that contract as
`focused && workspaceFilter`. That form is FALSE whenever the filter is off — `visibleWorkspaces` returns the
whole tree there, while `focused && workspaceFilter` evaluates false for every node. The guards above make
only the filter-ON half exact; the `!workspaceFilter` half is unconditional. Read every `focused &&
workspaceFilter` in this plan as `!workspaceFilter || focused`.

```swift
public var visibleWorkspaces: [Workspace] {
    guard focusEnabled else { return workspaces }
    let visible = workspaces.filter { focusedWorkspaceIDs.contains($0.id) }
    return visible.isEmpty ? workspaces : visible   // defensive: unreachable given the two guards above
}
```

**Existing callers stay untouched.** `setFocusedWorkspace(_ id: UUID?)` survives, re-implemented as "replace
the set with `{id}` and enable; nil clears and disables". The row menu's Focus, `AppActions.focusWorkspace` /
`focusActiveWorkspace` / `clearFocus`, the control arm, and `removeWorkspace`'s cleanup all keep the same
observable behavior at set size 1.

**Adding to the set MARKS ONLY — it never switches the filter on** (`setFocusMembership(_:member:)`'s
`wantEnabled` is just the current `focusEnabled` once the set is non-empty). Marking-that-enables makes the
set unbuildable from the sidebar: the first mark collapses the tree onto that one workspace, so the rows of
every workspace still to be marked are gone and each extra member costs a toggle off and back — three
toggles to build a three-workspace set, exactly the friction multi-select exists to remove. So a set is built
member by member with the whole tree on screen and applied ONCE (the bottom-bar toggle, or
`workspace.filter on`). Removing still disables the filter as the set empties — `enabled + empty` stays
unrepresentable — and `Focus` (the REPLACING `setFocusedWorkspace`) still enables immediately, so the
single-workspace zoom is unchanged. ⚠️ *This is a post-Task-15 correction: Tasks 2/8/9/12 were implemented
with "adding also enables" and the e2e written in Task 15 exposed the friction. Tasks 16, 17 and 18 must
document THIS behavior.*

**Key design decisions and rationale**

| Decision | Rationale |
|---|---|
| Generalize focus rather than add a second filter | A parallel "visible set" beside focus would need precedence rules, two pills, two command families, and doubled read-back fields — the coexistence problem, made permanent. One set answers it by construction. |
| Keep `setFocusedWorkspace(_:)` as a single-id convenience | Collapses the diff: every current call site is behavior-identical, so the risk concentrates in new code rather than spreading across the app. |
| `Focus` = replace with this; a SECOND menu item toggles membership | Preserves today's muscle memory and the meaning of `workspace.focus on` for existing scripts. Making `Focus` itself a membership toggle would silently change what `on` does. |
| No membership-*toggle* control mode | The menu item computes its own direction (its label flips to "Remove from Focus"), so `setFocusMembership(_:member:)` has exactly two call sites mapping to `add` and `off`. A fifth mode would be dead weight. |
| Adding to the set never turns the filter ON | An add that enabled would hide the rows still to be marked, so every extra member costs a toggle off and back. Mark-only keeps the build cost at N marks + one apply. `Focus` (replace) still enables, so the single-workspace zoom is untouched. |
| Cross-set select DISABLES the filter, keeping the set | Same visual result as today's auto-unfocus (the tree reveals), but a hand-curated set is not destroyed by a notification click. Re-enabling is one click. |
| Creating a workspace ADDS it to the set | Preserves today's "a new workspace is immediately visible" contract WITHOUT blowing the filtered view open. Mutating the set is acceptable here because the user initiated the creation — unlike the passive reveal case above. |
| Delete the `focus-pill` entirely | With a set, the pill would have to render "N workspaces", duplicating what the tree already shows. One grid button covers both the single and multi case, and it is the only affordance that also works when the filter is OFF. |
| Command named `workspace.filter`, read back as `workspaceFilter` | Matches the catalog's bare-noun on/off shape (`sidebar` → `sidebarVisible`, `quick` → `quickVisible`). `workspace focus enable off` is not English; `focus-toggle` collides with the existing `--mode toggle`, which means something entirely different. |
| Legacy snapshot key is decode-only | One-way migration keeps the write path simple. Writing both keys would force an arbitrary choice of "which member" when the set holds three. A downgrade losing a per-window view filter is an acceptable trade. |
| NO `focusedWorkspaces: [Workspace]` accessor | It would have zero consumers once the pill is deleted — the View menu needs a membership test and the tree builder needs `contains(id)`. The set is the API. |

**What is FREE — do not "fix" these, they need no changes:**

- `navigableSessions` is `sidebarMode == .flagged ? flaggedSessions : visibleWorkspaces.flatMap(\.sessions)`,
  so ⌥⌘↑/↓ session nav, ⌃⌥↑/↓ attention nav, the Ctrl-Tab MRU switcher, and the ⌃P fuzzy session palette all
  scope to the multi-workspace set automatically. (It MOVES file in Task 1 but its body is untouched.)
- The reconcile `TreeShape` already derives from `visibleWorkspaces`, so a filter flip re-shapes the tree.
- `SidebarDrop.resolveDirectoryWorkspace` itself stays byte-identical — only what the CALLER passes for its
  focus argument changes (Task 6).
- The flagged flat list keeps ignoring focus entirely — the two remain orthogonal.

## Technical Details

**Model (`AppStore` + `AppStore+Focus.swift`)**

```swift
// stored properties must live on the class, so these two stay in AppStore.swift
public var focusedWorkspaceIDs: Set<UUID> = []
public var focusEnabled = false

// everything else lives in AppStore+Focus.swift
public var visibleWorkspaces: [Workspace]
public var navigableSessions: [Session]
public var dropFallbackWorkspaceID: UUID?              // focusEnabled && count == 1 ? member : nil
public func setFocusedWorkspace(_ id: UUID?)           // replace with {id} + enable, or clear + disable
public func setFocusMembership(_ id: UUID, member: Bool)
public func setFocusEnabled(_ on: Bool)                // no-op when enabling an empty set
func disableFocusIfSelectionOutsideSet()               // renamed autoUnfocusIfOutsideFocus
```

All mutators are delta-guarded (no write, no `save()`, when nothing changes) so the control and menu callers
stay idempotent — the existing `setFocusedWorkspace` / `setSidebarMode` convention.

**Persistence (`Snapshot`)**

```swift
public var focusedWorkspaceIDs: [UUID]?   // nil -> []
public var focusEnabled: Bool?            // nil -> false
public var focusedWorkspaceID: UUID?      // LEGACY, decode-only, never populated
```

Migration inside the existing custom `init(from:)`: when `focusedWorkspaceIDs` is absent and the legacy
`focusedWorkspaceID` is present, decode to `[legacy]` with `focusEnabled = true`. Both new fields are
Optional, so legacy JSON decodes to the defaults without throwing — no `Snapshot.currentVersion` bump,
matching the load-fresh-on-decode-failure contract.

`encode(to:)` is SYNTHESIZED and the legacy property is `UUID?`, so synthesized `encodeIfPresent` omits it
automatically once nothing populates it — there is no encode side to hand-write. Dropping the parameter from
the memberwise `init` does break `AppStore.snapshot()` (currently passing `focusedWorkspaceID:`) and existing
test call sites; both are in Task 5's Files.

**Control protocol**

```swift
// ControlModes.swift
public enum WorkspaceFocusMode: String, CaseIterable, Sendable { case on, off, toggle, add }

// ControlProtocol.swift
case workspaceFilter = "workspace.filter"        // new Command case, catalog 66 -> 67
public let workspaceFilter: Bool?                // new ControlTree top-level read-back
```

`ControlWorkspaceNode.focused` keeps its name and type but its MEANING generalizes to "is a member of the
focus set", reported independently of the flag. A workspace is visible iff `!tree.workspaceFilter || focused`
— the filter-ON half exact because `enabled + empty` is unrepresentable (see the correction in Solution
Overview).

Mode semantics (each identical to today at set size 1):

| mode | effect |
|---|---|
| `on` | set := `{X}`, enable |
| `off` | remove X from the set; disable when it empties |
| `toggle` | replace-toggle — clear when the set is exactly `{X}` and enabled, else set := `{X}` and enable |
| `add` | insert X into the set; the filter flag is left exactly as it was (an add never turns it on) |

The mode parse moves INTO `ControlDispatcher` (typed `WorkspaceFocusMode`, invalid value rejected before any
mutation with a message derived from `allCases` so it cannot go stale), per the dispatcher-first rule. The
`ControlActions.focusWorkspace` signature changes from `mode: String?` to `mode: WorkspaceFocusMode`.

**Processing flow (marking a workspace from the sidebar)**

```
row context menu "Add to Focus"
  -> AppActions.setFocusMembership(id, member: true)
  -> AppStore.setFocusMembership -> mutate set (filter flag untouched) + save()
  -> observation fires (updateNSView reads focusedWorkspaceIDs AND focusEnabled)
  -> RowContent diff -> per-row reloadItem  (icon -> square.grid.2x2.fill)
  -> TreeShape diff   -> rebuildAndReload   (no narrowing until the filter is switched on)
```

## What Goes Where

- **Implementation Steps** (`[ ]` checkboxes): code, tests, and documentation changes inside this repo.
- **Post-Completion** (no checkboxes): manual visual verification that is not accessibility-observable, and
  the PR/merge/worktree-cleanup mechanics.

## Implementation Steps

### Task 1: Split the focus code into its own files (pure move, no behavior change)

Makes room before anything is added: `AppStore.swift` is at exactly 1000/1000 and cannot take one more line.
Nothing in this task changes behavior, so every existing test must pass UNMODIFIED — that is the proof the
move was clean.

**Files:**
- Create: `agtermCore/Sources/agtermCore/AppStore+Focus.swift`
- Create: `agterm/AppActions+WorkspaceFocus.swift`
- Create: `agtermCore/Tests/agtermCoreTests/AppStoreFocusTests.swift`
- Create: `agtermCore/Tests/agtermCoreTests/ControlDispatcherWorkspaceTests.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`
- Modify: `agterm/AppActions.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreOrganizationTests.swift`

- [x] move `visibleWorkspaces`, `navigableSessions`, `focusedWorkspace`, `setFocusedWorkspace`, and
      `autoUnfocusIfOutsideFocus` from `AppStore.swift` into a new `AppStore+Focus.swift` extension, verbatim
      (the two stored properties must stay on the class)
- [x] move `focusWorkspace`, `focusActiveWorkspace`, and `clearFocus` from `AppActions.swift` into a new
      `AppActions+WorkspaceFocus.swift` extension, verbatim. ⚠️ the plan's original `AppActions+Focus.swift`
      name is already TAKEN by the SESSION/PANE focus extension, so the workspace-focus file carries the
      disambiguated name; every later task referencing it was updated to match
- [x] move the existing focus/visibility test functions into a new `AppStoreFocusTests.swift`:
      `setFocusedWorkspaceSetsAndClears` + the three `visibleWorkspaces*` cases (which live in
      `AppStoreOrganizationTests.swift`, not `AppStoreTests.swift` as the plan assumed), plus
      `controlTreeReportsFocusedWorkspace` and `workspaceFocusPrunesRowsOutsideFocusedWorkspace` out of
      `AppStoreTests.swift` — the two that make room there and give Task 9's read-back tests a home
- [x] create an empty-but-compiling `ControlDispatcherWorkspaceTests.swift` scaffold for Task 8's tests
      (`ControlDispatcherDashboardTests.swift` is the precedent for the split)
- [x] run `swift test` with NO test edits beyond the move — all must pass, proving the move changed nothing
- [x] run `make build` and `make lint`; confirm `AppStore.swift` ≤ 960 lines, `AppStoreTests.swift` ≤ 1900,
      `AppActions.swift` ≤ 920 — must pass before Task 2. ⚠️ measured after the move: `AppStore.swift` 950 ✓,
      `AppStoreTests.swift` 1938 and `AppActions.swift` 935 — both MISS their targets because the plan
      over-estimated how much focus code those two files held (25 lines in `AppActions.swift`, 31 in
      `AppStoreTests.swift`). Both still gain the headroom the split exists for, and neither is grown by a
      later task: Tasks 12/13/14 add to `AppActions+WorkspaceFocus.swift`, and Task 9's read-back tests move
      to `AppStoreFocusTests.swift` (its Files list updated)

### Task 2: Add the focus set and enabled flag to AppStore

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift` (the two stored properties only)
- Modify: `agtermCore/Sources/agtermCore/AppStore+Focus.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+PendingClose.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreFocusTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreOrganizationTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreCloseReselectionTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreNavigationTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/PersistenceTests.swift` (⚠️ missing from the original list — it
  holds three `AppStore.focusedWorkspaceID` READS that must compile; its `Snapshot` reads are Task 5's)

- [x] replace `focusedWorkspaceID: UUID?` with `focusedWorkspaceIDs: Set<UUID>` + `focusEnabled: Bool`, both
      documented as per-window persisted UI state (mirror the existing doc-comment style)
- [x] rewrite `visibleWorkspaces` with the `guard focusEnabled` + membership filter + defensive empty-result
      fallback, commenting that the fallback is unreachable given the two guards below
- [x] re-implement `setFocusedWorkspace(_ id: UUID?)` as replace-with-`{id}`-and-enable /
      nil-clears-and-disables, keeping it delta-guarded (no `save()` when nothing changed)
- [x] add `setFocusMembership(_ id: UUID, member: Bool)` (delta-guarded; disables when the set empties) and
      `setFocusEnabled(_ on: Bool)` — the latter a NO-OP when enabling an empty set, so `enabled + empty` is
      unrepresentable
- [x] delete `focusedWorkspace: Workspace?` outright (its two callers are rewritten in Tasks 4/13/14; no
      plural replacement — nothing would consume it)
- [x] update `AppStore+PendingClose.swift:175`'s `focusedWorkspaceID == workspaceID` nil-out to prune the id
      from the set (behavior change lands in Task 3; this is the mechanical compile fix)
- [x] update the remaining test call sites. ⚠️ the plan mislocated them: the direct field WRITE moved into
      `AppStoreFocusTests.swift` in Task 1 (it is NOT at `AppStoreOrganizationTests.swift:330`), and
      `AppStoreOrganizationTests.swift` holds 18 READS rather than one write. Translated:
      `AppStoreOrganizationTests.swift` (18), `AppStoreCloseReselectionTests.swift` (4),
      `AppStoreNavigationTests.swift` (2), `PersistenceTests.swift` (3)
- [x] write tests: set/replace/clear via `setFocusedWorkspace`, membership add/remove, empty-set-disables,
      `setFocusEnabled` round-trip, that enabling an empty set is refused, and the delta-guard no-op cases
- [x] write tests for `visibleWorkspaces`: disabled → all, enabled with members → filtered subset in tree
      order, enabled with a partially stale set → the surviving members only
- [x] run `swift test` — must pass before Task 3. **`make build` is NOT gated here** (see Development
      Approach): the app target stays broken until Task 4

### Task 3: Generalize the lifecycle rules (remove, create, cross-set select)

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore+Focus.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift` (`removeWorkspace`, `addWorkspace`/`ensureWorkspace`)
- Modify: `agtermCore/Sources/agtermCore/AppStore+PendingClose.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+RecentClosed.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+CloseReselection.swift` (doc comment naming the helper)
- Modify: `agterm/Control/ControlServer+SessionActions.swift` (⚠️ missing from the original list — it holds
  the only app-target `clearFocus:` caller, renamed here so Task 4's sweep finds it consistent)
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreFocusTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreOrganizationTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreCloseReselectionTests.swift`
- ~~`agtermCore/Tests/agtermCoreTests/AppStoreNavigationTests.swift`~~ — ⚠️ NOT modified: its two focus
  assertions already match the new contract (see the migration checkbox below)

- [x] rename `autoUnfocusIfOutsideFocus` to `disableFocusIfSelectionOutsideSet` and update ALL call sites —
      `AppStore.swift` (7), `AppStore+PendingClose.swift` (5), `AppStore+RecentClosed.swift` (2, at lines 24
      and 45), plus the doc comment in `AppStore+CloseReselection.swift:19`. ➕ one more site the plan
      missed: the comment in `AppStoreCloseReselectionTests.swift:111` names the helper too
- [x] change its behavior to DISABLE the filter while KEEPING the set when the newly selected session's
      workspace is not a member; still a no-op when disabled or when nothing is selected
- [x] `removeWorkspace` and the `AppStore+PendingClose` soft-remove path: prune the id and disable when the
      set empties. ⚠️ already landed in Task 2 as a logged `[decision]` (the mechanical compile fix); this
      task VERIFIED both sites and added the missing test coverage rather than rewriting them
- [x] `addWorkspace` / `ensureWorkspace`: when the filter is ON, insert the new workspace into the set
      instead of clearing focus, so it is visible and the filter survives
- [x] rename the `clearFocus: Bool = true` parameter to `revealNewWorkspace: Bool = true` — after this change
      the old name states the opposite of what it does; update its callers in `AppStore.swift` and
      `agterm/Control/ControlServer+SessionActions.swift` (the `session.new --no-select` path, which must
      still NOT widen the set)
- [x] MIGRATE the existing auto-unfocus assertions from "focus cleared" to "set preserved, `focusEnabled`
      false". ⚠️ the plan mislocated these: of the five lines it named, only
      `AppStoreCloseReselectionTests.swift:125` and `:146` asserted the OLD contract —
      `AppStoreCloseReselectionTests.swift:104` and `AppStoreNavigationTests.swift:17`/`:230` already assert
      the SURVIVING filter (nav never crosses the boundary), so they needed no change. Seven more
      old-contract assertions the checkbox did not name live in `AppStoreOrganizationTests.swift` (the
      `addWorkspace` case at 200 plus the auto-unfocus cases at 309, 342, 357, 368, 400, 422) and were
      migrated here, with six test functions renamed off "ClearsFocus" onto the new contract
- [x] write tests: removing a member prunes the set, removing the LAST member disables, removing a
      non-member leaves the filter untouched (plus a `softRemoveWorkspace` case, which had no coverage)
- [x] write tests: selecting a session in a non-member workspace disables but preserves the set; selecting
      a session inside a member workspace changes nothing
- [x] write tests: `addWorkspace` with the filter on adds the new workspace to the set; with the filter off
      it touches neither field; `revealNewWorkspace: false` does not widen the set
- [x] run `swift test` — must pass before Task 4. **`make build` is NOT gated here**

### Task 4: Sweep the app target back to compiling

Mechanical translation ONLY — every site gets the minimum change that restores the build and preserves
today's observable behavior. The real UX work happens in Tasks 11-14, which rewrite several of these sites
again; that small churn is the price of a continuously-building tree.

**Files:**
- Modify: `agterm/AppActions+WorkspaceFocus.swift`
- Modify: `agterm/AppActions+Palette.swift` (line 29)
- Modify: `agterm/agtermApp+Menus.swift` (lines 242 AND 250 — two distinct sites)
- Modify: `agterm/Views/WorkspaceSidebar.swift` (lines 122, 551)
- Modify: `agterm/Views/WorkspaceSidebar+ContextMenu.swift` (line 141)
- Modify: `agterm/Views/WorkspaceSidebar+DragDrop.swift` (line 160)
- Modify: `agterm/Views/WindowContentView.swift` (line 781)
- Modify: `agterm/Control/ControlServer+WorkspaceCommands.swift`

- [x] rewrite `AppActions.focusWorkspace`'s body (was
      `store.setFocusedWorkspace(store.focusedWorkspaceID == id ? nil : id)`) as the replace-toggle against
      the set, and `AppActions.clearFocus`'s guard (was `store.focusedWorkspaceID != nil`) as a
      non-empty-set-or-enabled check
- [x] update `AppActions+Palette.swift:29`'s `hasFocusedWorkspace` to `!focusedWorkspaceIDs.isEmpty`
- [x] update BOTH `agtermApp+Menus.swift` sites: line 242's `focusedWorkspace?.id` comparison and line 250's
      `focusedWorkspaceID == nil` disabled-check
- [x] update `WorkspaceSidebar.swift:122` (the `updateNSView` observation read — now reads BOTH fields, which
      Task 11 only has to verify) and `:551` (the `rebuildAndReload` force-expand) to the set;
      `WorkspaceSidebar+ContextMenu.swift:141`'s focused check
- [x] update `WorkspaceSidebar+DragDrop.swift:160` to pass the single-member-when-enabled value (Task 6
      replaces this with the tested `dropFallbackWorkspaceID` accessor)
- [x] make `WindowContentView.swift:781`'s pill render only when the set holds exactly one member and the
      filter is enabled — its exact current behavior; it is DELETED in Task 13
- [x] update `ControlServer+WorkspaceCommands.swift`'s `focusWorkspace` string switch to the set (typed mode
      and the `add` case land in Tasks 8/9). `off` already maps to `setFocusMembership(id, member: false)`,
      the mapping Task 9 specifies
- [x] run `swift test`, `make build`, `make lint`, `make test-app` — all four must pass before Task 5; from
      here on every task gates on the full set. ⚠️ the static call-site list was COMPLETE: the build went
      green on the FIRST `make build` with exactly the eight listed files changed and no others

### Task 5: Persist the set and flag, with legacy migration

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Snapshot.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift` (`snapshot()`, line ~799)
- Modify: `agtermCore/Sources/agtermCore/AppStore+Focus.swift` (the restore-time prune)
- Modify: `agtermCore/Tests/agtermCoreTests/SnapshotRoundTripTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/PersistenceTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreFocusTests.swift`

- [x] add `focusedWorkspaceIDs: [UUID]?` and `focusEnabled: Bool?` to `Snapshot` (Optional, no
      `currentVersion` bump), keeping `focusedWorkspaceID` decodable but removing it from the memberwise init
- [x] implement the migration in the existing custom `init(from:)`: new key absent + legacy present →
      `[legacy]` with `focusEnabled = true`; both absent → `[]` / `false`. ⚠️ "both absent" decodes to
      `nil`/`nil` (the Optional default, matching every other forward-compat field) and `restore` maps that
      to `[]`/`false` — normalizing inside the decoder would have made the "was the key written?" question
      unanswerable to the round-trip tests
- [x] confirm no `encode(to:)` work is needed — it is synthesized and `encodeIfPresent` omits the never-
      populated legacy `UUID?` automatically (verified by a test asserting the written JSON carries no
      `"focusedWorkspaceID"` key)
- [x] update `AppStore.snapshot()` to emit the two new fields and stop passing `focusedWorkspaceID:`.
      ➕ the set is written in TREE order rather than `Set` order, so the on-disk list is deterministic
      instead of following the hash seed
- [x] make `AppStore.restore(from:)` PRUNE member ids absent from the restored tree, then disable when the
      pruned set is empty — this is what makes the all-stale case collapse instead of producing an
      enabled-but-invisible filter. Implemented as `AppStore.restoreFocus(from:)` in `AppStore+Focus.swift`,
      called from `restore(from:)` once the tree is rebuilt
- [x] write round-trip tests for the new fields, including the empty-set / disabled default shape
- [x] write a legacy-decode test: JSON carrying only `focusedWorkspaceID` decodes to a one-member enabled set
      (both as a raw `Snapshot` decode and end-to-end through `PersistenceStore.load`)
- [x] write a legacy-decode test: JSON carrying NEITHER key decodes to empty + disabled without throwing
- [x] write a restore test: a snapshot whose members are ALL absent from the tree restores to empty +
      disabled; one whose members are PARTIALLY absent keeps the survivors and stays enabled
- [x] run the full gate — must pass before Task 6

### Task 6: Add the tested drop-fallback accessor

`SidebarDrop.resolveDirectoryWorkspace` itself stays byte-identical; only what the caller passes changes. The
new logic must include the `focusEnabled` term — with one member marked and the filter OFF the full tree is
showing, so an empty-space drop must NOT land in the marked workspace.

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore+Focus.swift`
- Modify: `agterm/Views/WorkspaceSidebar+DragDrop.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreFocusTests.swift`

- [x] add `public var dropFallbackWorkspaceID: UUID?` returning
      `focusEnabled && focusedWorkspaceIDs.count == 1 ? that member : nil` (host-free, so it is unit-testable
      unlike the app-side call site)
- [x] pass it as `resolveDirectoryWorkspace`'s `focusedWorkspaceID:` argument from
      `WorkspaceSidebar+DragDrop.swift:160`, replacing Task 4's inline expression. ⚠️ the plan called the
      helper `resolveTargetWorkspace`; its real name is `SidebarDrop.resolveDirectoryWorkspace` (fixed here
      and in the Solution Overview bullet). Its `resolveDirectoryDrop` doc comment, which described the old
      single-`focusedWorkspaceID` fallback, was refreshed to name the accessor
- [x] leave `SidebarDrop.swift` and `SidebarDropTests.swift` untouched — the helper's contract is unchanged
- [x] write tests: empty set → nil; one member ENABLED → that member; one member DISABLED → nil; two members
      enabled → nil (the fallback would otherwise be a workspace the sidebar is not rendering)
- [x] run the full gate — must pass before Task 7

### Task 7: Extend the control protocol (mode enum, new command, tree read-back)

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlModes.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift` (⚠️ missing from the original list — its
  top-level `dispatch(_:)` switch is EXHAUSTIVE over `Command`, so a new case breaks the build)
- Modify: `agterm/Control/ControlServer.swift` (⚠️ same reason — its post-dispatcher fallthrough switch is
  exhaustive too)
- Modify: `agtermCore/Tests/agtermCoreTests/ControlModesTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`

- [x] add `WorkspaceFocusMode: String, CaseIterable, Sendable` with cases `on`, `off`, `toggle`, `add`, plus
      a `validNamesList`-style derived description for the error message (the `StatusShape` precedent).
      ➕ `validNamesPhrase` went in beside it, matching `StatusShape`'s pair: the dispatcher's rejection
      message (Task 8) wants the pipe form, the CLI's help text and local `validate()` (Task 10) the prose one
- [x] add `case workspaceFilter = "workspace.filter"` to `Command` (reuses `ControlArgs.mode` and
      `ControlArgs.window`; no new args field)
- [x] add `workspaceFilter: Bool?` to `ControlTree` with a doc comment stating it is LIVE and `tree`-only
      (the GUI toggle bypasses the command path, so a cached `window.list` copy would go stale)
- [x] update `ControlWorkspaceNode.focused`'s doc comment: it now means "is a member of the focus set",
      reported independently of the flag, and a workspace is visible iff `focused && tree.workspaceFilter` —
      noting that `enabled + empty` is unrepresentable, which is what makes the contract exact
- [x] ➕ keep the two exhaustive `Command` switches compiling: `ControlDispatcher.dispatch` gets a
      `.workspaceFilter` arm returning `nil` (the documented not-yet-migrated fallthrough — grouping it with
      the workspace commands instead would hit `dispatchWorkspaceCommand`'s `preconditionFailure`), and
      `ControlServer.dispatch`'s unhandled list gains the case. Task 8 replaces the DISPATCHER arm with the
      real routing; ⚠️ the `ControlServer` list entry is PERMANENT, not interim — that switch is exhaustive
      over `Command` and every dispatcher-owned command (`.tree`, `.sidebar`, `.workspaceFocus`, …) stays in
      it as the unreachable "dispatcher did not handle" safety net
- [x] write the `WorkspaceFocusMode` raw-value and `allCases` tests in `ControlModesTests.swift` (the
      existing home for mode enums), NOT in `ControlProtocolTests.swift`
- [x] write round-trip tests for `workspace.filter` requests in `ControlProtocolTests.swift`
- [x] write `treeRoundTripsWithWorkspaceFilter` and `treeOmitsWorkspaceFilterWhenNil`
- [x] run the full gate — must pass before Task 8

### Task 8: Hoist focus-mode validation into the dispatcher and route workspace.filter

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift`
- Modify: `agterm/Control/ControlServer+WorkspaceCommands.swift` (⚠️ missing from the original list — a
  changed/added `ControlActions` requirement breaks `ControlServer`'s conformance, so the app-side arms
  must move in the SAME task or `make build` cannot pass)
- Modify: `agtermCore/Tests/agtermCoreTests/MockControlActions.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherTests.swift` (⚠️ missing from the original
  list — it held the old raw-string routing assertion, migrated into the workspace suite here)
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherWorkspaceTests.swift` (created in Task 1)

- [x] change `ControlActions.focusWorkspace` from `mode: String?` to `mode: WorkspaceFocusMode` and parse the
      raw string in the dispatcher's `.workspaceFocus` arm, defaulting to `toggle` when absent
- [x] reject an unknown mode in the dispatcher BEFORE any mutation, with a message derived from
      `WorkspaceFocusMode.allCases` (e.g. `invalid focus mode: <raw> (on|off|toggle|add)`)
- [x] add `ControlActions.setWorkspaceFilter(window:mode:)` and the `.workspaceFilter` dispatch arm, reusing
      the shared `ControlToggleMode` parser the `sidebar` command already uses, with an unknown mode an error.
      ⚠️ the wire tokens are `on|off|toggle`, NOT the `sidebar` command's `show|hide|toggle` spelling — this
      checkbox said "show/hide/toggle" but Tasks 10 and 17 both spell the CLI `workspace filter on|off|toggle`,
      so the shared PARSER is reused with its default tokens
- [x] update `MockControlActions` for both signature changes
- [x] write dispatcher tests IN `ControlDispatcherWorkspaceTests.swift`: each of the four focus modes reaches
      the action with the right typed value; an unknown mode is rejected without calling the action
- [x] write dispatcher tests: `workspace.filter` routing for on/off/toggle, unknown-mode rejection, and that
      it carries `--window` through
- [x] run the full gate — must pass before Task 9. ⚠️ the `ControlServer` arms landed here out of necessity
      (the conformance break above): `focusWorkspace` switches on the typed mode with `add` →
      `setFocusMembership(id, member: true)`, and `setWorkspaceFilter` resolves via `resolvePlacementStore`
      and calls `setFocusEnabled` — Task 9's first two checkboxes are therefore already satisfied and only
      need VERIFYING there; its `controlTree` read-back work is untouched

### Task 9: Wire the ControlServer arms and the tree read-back

**Files:**
- Modify: `agterm/Control/ControlServer+WorkspaceCommands.swift` (the `workspace.*` adapter home, per
  `.claude/rules/control-api.md` — NOT `+AppCommands.swift`)
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift` (`controlTree`)
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreFocusTests.swift` (the focus read-back tests moved
  here in Task 1)
- Modify: `agtermCore/Tests/agtermCoreTests/MockControlActions.swift` (⚠️ missing from the original list —
  the empty-set test must drive the REAL command path, so the mock's `setWorkspaceFilter` gained an opt-in
  `filterStore` that applies the parsed mode to a live `AppStore` the way the app-side arm does)

- [x] rewrite `focusWorkspace` to switch on the typed `WorkspaceFocusMode`: `on` → `setFocusedWorkspace(id)`,
      `off` → `setFocusMembership(id, member: false)`, `add` → `setFocusMembership(id, member: true)`,
      `toggle` → replace-toggle; delete the inline string switch and its error return (now dispatcher-owned).
      ⚠️ landed in TASK 8 (changing the `ControlActions` requirement broke conformance, so `make build`
      could not pass without it) — VERIFIED here, all four arms present and correct
- [x] add the `setWorkspaceFilter` arm in the same file: resolve the target store via
      `resolvePlacementStore(window)` (so it honors the global `--window` selector like
      `sidebar.expand`/`sidebar.collapse`), compute the delta, and call `AppStore.setFocusEnabled`.
      ⚠️ also landed in TASK 8 for the same conformance reason — VERIFIED here, incl. the no-open-window guard
- [x] populate `ControlWorkspaceNode.focused` from set membership (`focusedWorkspaceIDs.contains(id) ? true : nil`)
      and the new top-level `workspaceFilter` from `focusEnabled` in `AppStore.controlTree`.
      ⚠️ the `focused` half landed in the TASK 4 sweep; the `workspaceFilter` half landed here, always
      populated (never nil) on an app-produced tree, matching `sidebarVisible`
- [x] write tests: `controlTree` reports `focused` on every member and omits it on non-members, independent
      of the flag; `workspaceFilter` reflects `focusEnabled` in both states
- [x] write a test that `workspace.filter on` against an EMPTY set leaves `workspaceFilter` false, so the
      documented `focused && workspaceFilter` contract cannot be violated through the control path.
      Driven through `ControlDispatcher.dispatch(.workspaceFilter, mode: "on")` against a store-backed
      action, so the mode parse and `setFocusEnabled`'s refusal are both exercised, not the mutator alone
- [x] run the full gate — must pass before Task 10

### Task 10: Extend the agtermctl CLI

**Files:**
- Modify: `agtermCore/Sources/agtermctlKit/WorkspaceCommands.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/CommandsTests.swift`

- [x] extend `Workspace.Focus`: accept `add` in `validate()` and in the `@Argument` help text, deriving both
      from `WorkspaceFocusMode.allCases` so the CLI list cannot drift from the dispatcher's. The `validate()`
      guard is now `WorkspaceFocusMode(rawValue:) != nil` with a `validNamesPhrase` message, and the mode's
      default is `WorkspaceFocusMode.toggle.rawValue` rather than a bare `"toggle"` literal
- [x] update the `Focus` subcommand abstract — it no longer focuses "a single workspace"; it now reads
      "Mark a workspace in the sidebar focus set (`\(WorkspaceFocusMode.validNamesList)`)", so the abstract
      is `allCases`-derived too
- [x] add a `Workspace.Filter` subcommand (`on|off|toggle`, default `toggle`, `ClientOptions` for `--window`,
      NO `TargetOptions`) emitting `.workspaceFilter`, and register it in the `Workspace` subcommand list
- [x] write tests for `workspace focus add` mapping and for rejection of an invalid mode (the existing
      loose `throws: (any Error).self` rejection assertion was MIGRATED to pin the exact
      `allCases`-derived message, matching `sessionStatusRejectsUnknownShape`)
- [x] write tests for `workspace filter` mapping across all three modes, that it carries `--window`, and that
      it rejects an invalid mode. ➕ plus `workspaceFilterTakesNoTarget`, pinning the deliberate absence of
      `TargetOptions` — an unregistered/mis-shaped option group is otherwise invisible to a mapping test
- [x] write a test pinning the help text to `WorkspaceFocusMode.allCases` (the
      `sessionStatusShapeHelpListsEveryShape` precedent). ⚠️ the checkbox said "the `--mode` help text", but
      `workspace focus` takes the mode as a POSITIONAL `@Argument`, not a `--mode` option, so
      `workspaceFocusHelpListsEveryMode` asserts against the whole rendered
      `Workspace.Focus.helpMessage(columns: 200)`
- [x] run the full gate — must pass before Task 11

### Task 11: Draw the filled grid icon for marked workspaces

Not accessibility-observable, so its regression coverage is Task 15's e2e; this task gates on build + lint.

**Files:**
- Modify: `agterm/Views/WorkspaceSidebar.swift`
- Modify: `agterm/Views/WorkspaceSidebar+RowRendering.swift`

- [x] add a lazily-cached `focusedWorkspaceIcon = Self.rowIcon("square.grid.2x2.fill")` beside
      `flaggedSessionIcon`
- [x] select it in the workspace-row branch of the row builder when the workspace is a SET MEMBER,
      independent of `focusEnabled`
- [x] fold membership into `RowContent` (Equatable) so marking/unmarking triggers a per-row `reloadItem`
      rather than a full rebuild. ➕ went in as a SEPARATE `focusMember: Bool` field rather than reusing
      the session-only `flagged` one — same "filled variant" idiom but a different subject, and the
      existing struct already carries per-kind fields (`hasSplit`, `indicator`) documented as always-false
      for the other kind
- [x] confirm `updateNSView` reads BOTH `store.focusedWorkspaceIDs` and `store.focusEnabled` (Task 4 changed
      the field; this task verifies BOTH are read) — LOAD-BEARING: with only one read, toggling the filter
      does not redraw. ⚠️ VERIFICATION ONLY: Task 4 already landed both reads (`WorkspaceSidebar.swift:123-124`)
      with a comment stating why one alone is not enough; nothing was rewritten
- [x] verify `TreeShape` still derives from `visibleWorkspaces` and refresh any code comment naming the old
      single-workspace field. ⚠️ `currentShape()`'s `.tree` arm already maps `store.visibleWorkspaces` —
      untouched. Four comments still described the single-workspace model and were refreshed: `currentShape()`'s
      doc, `rebuildAndReload`'s render-scope and force-expand comments, and `expandAll`'s doc
- [x] run the full gate — must pass before Task 12. ⚠️ NO new unit test: the icon is an `NSImage` on a
      recycled cell, not accessibility-observable, so any assertion here would test the store field the
      Task 2/3 suites already cover, not the rendering — Task 15's e2e is this task's regression coverage,
      as the plan's Testing Strategy states

### Task 12: Regroup the workspace context menu and add the membership item

Menu behavior is covered by Task 15's e2e.

**Files:**
- Modify: `agterm/Views/WorkspaceSidebar+ContextMenu.swift`
- Modify: `agterm/AppActions+WorkspaceFocus.swift`

- [x] add `AppActions.setFocusMembership(_ id: UUID, member: Bool)` delegating to the store mutator —
      guarded like its `focusWorkspace` sibling (`uiActionsEnabled` + an unknown-id no-op)
- [x] change the existing Focus item's label logic: "Unfocus" only when the set is exactly `{this}` AND the
      filter is enabled, else "Focus". ⚠️ VERIFICATION ONLY: the TASK 4 sweep already landed exactly this
      predicate (`store.focusEnabled && store.focusedWorkspaceIDs == [node.id]`), so nothing was rewritten —
      only its comment, which still described the item as collapsing the tree rather than REPLACING the set
- [x] add the membership item directly below it, labelled "Remove from Focus" when the workspace is a member
      and "Add to Focus" otherwise, computing its own direction so no toggle mode is needed.
      ➕ `menuToggleFocusMembership` derives that direction by re-reading the Coordinator's OWN `store` (the
      one the label was built from) rather than carrying a build-time `Bool` in a `SessionBatchRequest`-style
      wrapper — three lines instead of a new type, and label and action read the same source
- [x] restructure the menu with separators into three groups: New Session / Open Directory… | Focus /
      Add-or-Remove from Focus | Delete Workspace. ⚠️ the workspace row's **Rename** item is added BEFORE
      the `node.kind` switch (it is shared with session rows), so the first group actually renders as
      Rename / New Session / Open Directory… — unchanged, and the new separator goes in right after
      Open Directory… exactly as specified
- [x] run the full gate — must pass before Task 13

### Task 13: Replace the focus pill with the bottom-bar filter toggle

**Files:**
- Modify: `agterm/Views/WindowContentView.swift`
- Modify: `agterm/AppActions+WorkspaceFocus.swift`
- Modify: `agtermCore/Sources/agtermCore/AppSettings.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppSettingsTests.swift`

- [x] delete the `focus-pill` Button (kept alive mechanically by Task 4) and its store binding
- [x] add `AppActions.toggleFocusFilter()` flipping `focusEnabled` on the active store
- [x] add a `focus-filter-toggle` Button beside `flagged-view-toggle`: 2-state
      `square.grid.2x2` / `square.grid.2x2.fill` glyph, `chromeText` tint, disabled and dimmed to 0.35 when
      `focusedWorkspaceIDs.isEmpty` (mirroring the flagged toggle's empty-state rule and its explicit opacity,
      which is needed because the explicit `foregroundStyle` defeats SwiftUI's default disabled dimming).
      ➕ it took the pill's SLOT (right after the trailing `Spacer()`, before `flagged-view-toggle`) rather
      than trailing it, and its `.help(…)` is a PLAIN string, not `helpHint(_:_:)` — the
      `BuiltinAction.toggleWorkspaceFilter` that a hint would resolve against does not exist until Task 14,
      which should upgrade it there
- [x] give the button an `accessibilityValue` reflecting on/off so the filter state stays XCUITest-observable
      now that the pill is gone. The strings are exactly `"on"` / `"off"` — Task 15 must assert those
- [x] add `case focusFilter` to `InterfaceElement` with `section == .sidebar` and displayName
      "Workspace filter", and gate the button behind `shows(.focusFilter)` — it auto-appears in
      Settings ▸ Interface via `allCases`. Ordered between `flaggedView` and `workspaceAddSession` so the
      footer controls stay grouped ahead of the row element
- [x] write a test that `InterfaceElement.focusFilter` decodes and reports the sidebar section (extend the
      existing tolerant-decode coverage). ➕ `interfaceElementSectionsPartitionAllCases` pins the sidebar
      ORDER, so its expected array gained the case too
- [x] ➕ `.claude/rules/settings.md`'s `hiddenInterfaceElements` bullet said the focus pill "is transient,
      so [it is] not a per-element toggle" and listed the sidebar elements without `focusFilter` — both
      falsified by this task, so the two sentences were corrected here rather than left wrong until Task 18
      (which does not cover `settings.md`)
- [x] run the full gate — must pass before Task 14

### Task 14: Add the menu, palette, and keymap surfaces

**Files:**
- Modify: `agterm/agtermApp+Menus.swift`
- Modify: `agterm/AppActions+WorkspaceFocus.swift`
- Modify: `agterm/AppActions+Palette.swift`
- Modify: `agtermCore/Sources/agtermCore/PaletteCatalog.swift`
- Modify: `agtermCore/Sources/agtermCore/BuiltinAction.swift`
- Modify: `agterm/Views/WindowContentView.swift` (the Task 13 carry-over `helpHint` upgrade)
- Modify: `.claude/rules/menu-actions.md` (the `helpHint` button count this task falsifies)
- Modify: `agtermCore/Tests/agtermCoreTests/PaletteCatalogTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/BuiltinActionTests.swift`

- [x] add `AppActions.addActiveWorkspaceToFocus()` (targets `currentWorkspaceID`, the sibling of
      `focusActiveWorkspace`)
- [x] add View-menu items "Add Workspace to Focus" and "Toggle Workspace Filter" beside the existing
      Focus/Unfocus Workspace and Clear Focus entries, disabled when there is no active store.
      ⚠️ the Toggle item's disabled predicate is the STRONGER
      `focusedWorkspaceIDs.isEmpty != false || modalActive` (Clear Focus's existing expression, which
      already covers the no-store case): the bottom-bar button disables and the palette entry hides in
      exactly that state, and the action is a genuine no-op there since the store refuses to enable an
      empty set — so all three surfaces agree. Add keeps the `currentWorkspaceID == nil` gate, matching
      its Focus Workspace sibling
- [x] add two `PaletteCommand` cases in `PaletteCatalog.swift` with their `isVisible`, `title`, and
      `builtinAction` arms, plus the matching `runPaletteCommand` arms in `AppActions+Palette.swift`
- [x] set the visibility predicates deliberately: "Add Workspace to Focus" always visible; "Toggle Workspace
      Filter" visible only when the set is non-empty (matching the disabled bottom-bar button); "Clear Focus"
      keeps keying on `hasFocusedWorkspace`, now `!focusedWorkspaceIDs.isEmpty` — so it is offered whenever
      there is a set to clear, even with the filter off. ⚠️ VERIFIED, not changed: Task 4 already pointed
      `paletteContext.hasFocusedWorkspace` at `focusedWorkspaceIDs.isEmpty == false`
- [x] add `case toggleWorkspaceFilter = "toggle_workspace_filter"` to `BuiltinAction` (keyless/expressible,
      like `toggleFlaggedView`) and include it in the expressible list
- [x] write tests for the new `BuiltinAction` raw value and its expressible classification.
      ⚠️ there is no literal "expressible list" to join — expressibility is DERIVED (`starterKeymapConf`
      renders a default that can't round-trip as `(not expressible)`, and a keyless action has no default
      to render), so `toggleWorkspaceFilterIsKeylessAndMappable` pins what the classification actually
      means for a keyless action: nil default, its raw name parses as a `map` target, and no glyph hint
      until mapped
- [x] write `PaletteCatalogTests` cases for both new entries' titles and visibility predicates
- [x] ➕ Task 13 carry-over: upgrade the `focus-filter-toggle` button's plain `.help(…)` to
      `helpHint(_:_:)` against the now-existing `.toggleWorkspaceFilter`, matching the neighbouring
      `flagged-view-toggle`
- [x] ➕ `.claude/rules/menu-actions.md` counted "the 8 `BuiltinAction`-backed toolbar/sidebar buttons"
      that `helpHint` tooltips; the count was already stale at 9 and this task makes it 10, so it was
      corrected here rather than left wrong until Task 18 (whose menu-actions checkbox covers only the
      renamed helper)
- [x] run the full gate — must pass before Task 15

### Task 15: Rewrite and extend the end-to-end tests

**Files:**
- Modify: `agtermUITests/FocusWorkspaceUITests.swift`
- Modify: `agtermUITests/ControlSidebarStatusUITests.swift`

- [x] re-point the three `focus-pill` assertions at `workspace-row` visibility (assert the OTHER workspaces'
      rows disappear when focused and return when cleared) plus the `focus-filter-toggle` accessibilityValue;
      update the suite's header comment, which currently documents the pill. ⚠️ the count was right (3 sites:
      the pre-focus non-existence, the appears-while-focused, and the click-✕-then-disappears pair). The
      escape hatch they exercised is now the row menu's **Unfocus** (the label flip the pill's ✕ replaced),
      so the rewritten case asserts BOTH `workspace-row` visibility AND the toggle's `value`+`isEnabled`,
      and was renamed `testFocusWorkspaceHidesOthersAndUnfocusRestores`
- [x] add a test that marks a second workspace via the context menu's Add to Focus and asserts BOTH
      workspaces' rows are visible while a third is not. ⚠️ this bullet originally recorded that marking the
      SECOND row had to route through the bottom-bar toggle (the first mark turned the filter on, so the
      second workspace's row was not rendered and there was nothing to right-click). That friction is what
      prompted the mark-only decision below: the shared `markFirstTwoOfThreeWorkspaces` fixture now marks
      both rows directly and clicks the toggle ONCE, and it asserts the filter stays off — and all three rows
      stay on screen — across both marks
- [x] add a test that the bottom-bar toggle disables the filter (all rows return) and re-enables it (the
      same two rows return), proving the set survived
- [x] add a test that `focus-filter-toggle` reports `isEnabled == false` with nothing marked and true once a
      workspace is marked (`isEnabled` IS accessibility-observable, so it belongs here, not in manual checks).
      ➕ it also asserts the accessibilityLabel string and that **Remove from Focus** on the last member puts
      the toggle back to disabled — the `enabled + empty` invariant's GUI half, in both directions
- [x] add a `ControlSidebarStatusUITests` case driving `workspace.focus add` and reading the `focused` flags
      back off `tree` (`testWorkspaceFocusAddBuildsAMultiWorkspaceSet`: on → add → repeat-add → off across
      three workspaces, asserting the row set AND every workspace's `focused` flag at each step)
- [x] add a `ControlSidebarStatusUITests` case driving `workspace.filter on|off|toggle` and reading
      `workspaceFilter` back off `tree` (`testWorkspaceFilterTogglesWithoutLosingTheSet`). ➕ it opens with
      the empty-set case — `workspace.filter on` with nothing marked succeeds yet leaves `workspaceFilter`
      false — so the `focused && workspaceFilter` contract is pinned end-to-end, not only host-free
- [x] refresh the stale comment at `ControlSidebarStatusUITests.swift:171-173`, which explains the old
      `focusedWorkspaceID` auto-reveal for `testSessionNewNoSelectCreateWorkspacePreservesFocus`.
      ➕ two more stale-comment/coverage findings in the same file, fixed here: the "off unfocuses only the
      currently focused one" comment in `testWorkspaceFocusHidesOtherWorkspaces` (now "drops it from the
      set"), and the `--no-select` test itself, which was strengthened with the assertions that the filter is
      still applied AND the background-created workspace is NOT a member — the Task 3 `revealNewWorkspace`
      contract had no e2e at all
- [x] run `make test-app` and the UI suite — must pass before Task 16. ⚠️ `make test-app` runs the
      `agtermTests` scheme, which does NOT include `agtermUITests/`; the two suites here run with
      `xcodebuild test -project agterm.xcodeproj -scheme agterm -destination 'platform=macOS'
      -derivedDataPath build/DerivedData -only-testing:agtermUITests/<Class>[/<method>]`. Both were RUN:
      all 4 `FocusWorkspaceUITests` (68.8 s) and the 4 affected `ControlSidebarStatusUITests` methods (17.6 s)
      passed

### ➕ Post-Task-15 decision: "Add to Focus" marks without enabling

Not one of the numbered tasks — a user decision taken after Task 15, whose e2e work exposed that a
marking add which also enabled the filter made a multi-workspace set cost one toggle-off per extra member.
`setFocusMembership`'s `wantEnabled` term became `wantIDs.isEmpty ? false : focusEnabled`, so adding
preserves whatever the filter state was and only removing can disable (as the set empties). `Focus` /
`workspace.focus on|toggle` are UNCHANGED and still enable immediately. Implemented across
`AppStore+Focus.swift`, the `add`-mode doc comments (`ControlModes.swift`,
`ControlServer+WorkspaceCommands.swift`, `agtermctlKit/WorkspaceCommands.swift`,
`AppActions+WorkspaceFocus.swift`), the migrated unit tests (`AppStoreFocusTests`, `SnapshotRoundTripTests`)
with a new `addingToTheSetNeverTurnsTheFilterOn` case, and both e2e suites. **Tasks 16, 17 and 18 must
document THIS semantic** — `add` = "insert X into the marked set", never "insert X, enable".

### Task 16: Update the product documentation surfaces

**Files:**
- Modify: `agterm/Resources/agent-skill/SKILL.md`
- Modify: `agterm/Resources/agent-skill/reference.md`
- Modify: `agterm/Resources/agent-skill/examples.md`
- Modify: `site/commands.html`
- Modify: `site/docs.html`
- Modify: `README.md`
- Modify: `agtermCore/Tests/agtermCoreTests/SkillInstallTests.swift` (⚠️ missing from the original list —
  `bundledSkillDocumentsEventSubscriptionCommand` PINS the bundled skill's command count, so the 66 → 67
  bump fails `swift test` until the assertion moves with it)

- [x] bump the command count 66 → 67 in ALL five places: `SKILL.md:145`, `README.md:186`,
      `site/docs.html:1114`, and `site/commands.html` lines 21 and 33 (two `<meta>` description tags) plus
      line 238 (body copy) — four separate spots in `commands.html` alone. ⚠️ there is a SIXTH place the
      plan did not name: `SkillInstallTests.swift:17` asserts `Command summary (66 commands)` against the
      bundled `SKILL.md`, so the bump is a code gate too. Counted against the source to confirm 67 is
      right: `Command` has 68 cases, minus the excluded `debug.appearance` test seam = 67
- [x] update `SKILL.md`'s command summary with `workspace.filter` and the `workspace.focus` mode list
      gaining `add`. ➕ `workspace.filter` also went into the frontmatter `when_to_use` trigger list beside
      `workspace.focus`, which is how a model finds the skill by command name
- [x] update `reference.md`: full per-command detail for `workspace.filter`, the four `workspace.focus`
      modes, the `tree` schema's new `workspaceFilter` field, and the changed meaning of
      `ControlWorkspaceNode.focused`. ➕ four more stale single-workspace descriptions in the same file
      were corrected: the top-level field count ("ten" → "eleven" + the `tree`-only list), `session go`'s
      scoping sentence, `sidebar mode`'s nav-scoping sentence, and `session new --no-select`'s
      "does not clear a focused-workspace filter" note (it now does not WIDEN the set)
- [x] update `reference.md:817`'s error-string catalog for the reshaped `invalid focus mode` message.
      ⚠️ the entry was a bare `invalid focus mode`; it now carries the full `allCases`-derived socket
      string AND the CLI's own local rejection wording, matching how `--shape` documents both, plus a new
      `invalid workspace filter mode` entry and `workspace filter` added to the `no open window` list
- [x] update the EXISTING `examples.md:346-348` recipe, which describes `workspace focus on|toggle|off` as
      single-workspace zoom, and add a new recipe building and restoring a multi-workspace working set
      (mark, read back `focused` + `workspaceFilter` off `tree`, restore)
- [x] add a `site/commands.html` card for `workspace.filter`, update the `workspace.focus` card's arguments
      and read-back, update the tree `focused` field description at line 455, and add `workspaceFilter` to
      the top-level tree field list at lines 466-467 ("All five" → "All six")
- [x] add `toggle_workspace_filter` to the keymap built-in action lists, which are duplicated at
      `README.md:369` and `site/docs.html:1563` (`toggle_flagged_view` is the precedent). ➕ also added to
      the skill's own partial list in `reference.md`, together with `focus_workspace`, which that list had
      always omitted — listing the new action without its sibling would have read as an oversight
- [x] update `README.md` and `site/docs.html` where the sidebar focus filter is described (no longer
      single-workspace) and where the bottom-bar controls and Settings ▸ Interface toggles are listed.
      The GUI changes are documented in both: Focus vs Add to Focus in the row menu, the filled grid icon
      on a marked row, the bottom-bar toggle replacing the pill (with its empty-set disabled state), the
      new Settings ▸ Interface "Workspace filter" entry (placed after flagged-view, matching
      `InterfaceElement`'s declared order), and the two lifecycle rules
- [x] edit ONLY `agterm/Resources/agent-skill/` — never the installed copies under `~/.claude/skills/agterm/`
      or `~/.codex/skills/agterm/`, which are regenerated install outputs
- [x] do NOT touch `CHANGELOG.md` — release-only
- ➕ discovered, NOT fixed here (out of this task's product-doc scope — for Task 18 / the maintainer to
      decide): (1) `.claude/rules/keymap.md:38` calls `BuiltinAction` "the 36 rebindable actions"; the real
      count is 42 after this feature (41 before it), so that line was already stale and `keymap.md` is not
      in Task 18's file list. (2) `site/docs.html`'s built-in action list is missing `reopen_recent` and
      `undo_close`, which `README.md`'s copy of the same list carries — pre-existing drift between the two
      duplicated lists, unrelated to the focus set

### Task 17: Verify acceptance criteria

- [x] a workspace can be marked and unmarked from its row menu, and the row icon fills/unfills accordingly.
      MARK/UNMARK verified by `FocusWorkspaceUITests.testFilterToggleIsDisabledUntilAWorkspaceIsMarked`,
      which invokes the row items BY TITLE ("Add to Focus" then "Remove from Focus"), so the label flip is
      itself asserted; wiring read at `WorkspaceSidebar+ContextMenu.swift:149-156` + `menuToggleFocusMembership`
      (:252-255, which re-reads the Coordinator's own store for direction). ⚠️ the ICON half is NOT
      accessibility-observable and is verified BY CODE READING only —
      `WorkspaceSidebar+RowRendering.swift:58` picks `focusedWorkspaceIcon` on `focusedWorkspaceIDs.contains(node.id)`,
      independent of `focusEnabled`. Its RENDERED appearance stays on the Post-Completion manual list
- [x] marking a workspace does NOT turn the filter on: the whole tree stays on screen, so three workspaces
      can be marked in a row and applied with one click of the bottom-bar toggle. The post-Task-15 contract,
      pinned host-free by `AppStoreFocusTests.addingToTheSetNeverTurnsTheFilterOn` (BOTH polarities) against
      `AppStore+Focus.swift:46`'s `wantEnabled = wantIDs.isEmpty ? false : focusEnabled`; in the GUI by
      `FocusWorkspaceUITests`'s `markFirstTwoOfThreeWorkspaces`, which asserts the toggle stays `off` AND
      all three rows stay on screen across BOTH marks before one click applies; and over the socket by
      `ControlSidebarStatusUITests.testWorkspaceFocusAddBuildsAMultiWorkspaceSet` (`add` on an empty set →
      `workspaceFilter` still false)
- [x] with three workspaces marked and the filter on, exactly those three render in the tree.
      ⚠️ [deviation] verified at N=2-of-3, not N=3: `FocusWorkspaceUITests.testAddToFocusKeepsBothMarkedWorkspacesVisible`
      (`pollWorkspaceRowCount(2)` + the third row absent) and host-free
      `AppStoreFocusTests.visibleWorkspacesReturnsTheMarkedSubsetInTreeOrder` (two of three marked, rendered
      in TREE order not mark order). The arity is not a boundary — `visibleWorkspaces` filters by set
      membership with no count term — so two-marked-of-three already proves the multi-member case
- [x] the bottom-bar toggle disables and re-enables the filter WITHOUT losing the marked set —
      `FocusWorkspaceUITests.testFilterToggleSuspendsAndRestoresTheMarkedSet` (the same two rows return with
      nothing re-marked), `AppStoreFocusTests.setFocusEnabledRoundTripsWithoutLosingTheSet`, and the control
      half `ControlSidebarStatusUITests.testWorkspaceFilterTogglesWithoutLosingTheSet`
- [x] the toggle is disabled when nothing is marked, and `workspace.filter on` with an empty set leaves the
      filter off (so `focused && workspaceFilter` can never lie) —
      `FocusWorkspaceUITests.testFilterToggleIsDisabledUntilAWorkspaceIsMarked` (both directions: marking
      enables it, removing the last member disables it again), `AppStoreFocusTests.setFocusEnabledRefusesAnEmptySet`
      + `workspaceFilterOnAnEmptySetLeavesTheFilterOffThroughTheControlPath` (driven through
      `ControlDispatcher.dispatch`), and `testWorkspaceFilterTogglesWithoutLosingTheSet`, which opens with
      the empty-set case
- [x] Focus on a single workspace still behaves exactly as before (including the Unfocus label flip) —
      `FocusWorkspaceUITests.testFocusWorkspaceHidesOthersAndUnfocusRestores` invokes the item by title
      "Focus" then "Unfocus", so the flip is asserted; the predicate is
      `WorkspaceSidebar+ContextMenu.swift:144` (`store.focusEnabled && store.focusedWorkspaceIDs == [node.id]`).
      Host-free: `setFocusedWorkspaceSetsAndClears`, `setFocusedWorkspaceReplacesTheWholeSet`,
      `visibleWorkspacesReturnsOneWhenFocused`; over the socket `testWorkspaceFocusHidesOtherWorkspaces`
- [x] selecting a session outside the marked set disables the filter and preserves the set —
      `AppStoreFocusTests.selectingOutsideTheSetDisablesTheFilterButKeepsEveryMember` and its
      `selectingInsideTheSetChangesNothing` twin, against `AppStore+Focus.swift:18-22`
- [x] creating a workspace while filtered adds it to the set and keeps the filter on —
      `AppStoreFocusTests.addWorkspaceJoinsTheSetOnlyWhileTheFilterIsOn` (with the filter OFF it touches
      neither field) + `addWorkspaceWithoutRevealDoesNotWidenTheSet`, and the e2e
      `ControlSidebarStatusUITests.testSessionNewNoSelectCreateWorkspacePreservesFocus`
- [x] deleting the last marked workspace disables the filter —
      `AppStoreFocusTests.removingTheLastMemberWorkspaceDisablesTheFilter`, with
      `removingAMemberPrunesItAndKeepsTheRestFiltered`, `removingANonMemberWorkspaceLeavesTheFilterUntouched`,
      and `softRemovingAMemberPrunesItAndDisablesWhenTheSetEmpties` covering the neighbouring paths
- [x] a snapshot written by the CURRENT release (carrying `focusedWorkspaceID`) restores as a one-member
      enabled set; a snapshot whose members are all gone restores to empty + disabled. The BACK-COMPAT
      guarantee, so it was checked against the decode path itself: `Snapshot.swift:80-88` decodes the legacy
      key, and ONLY when `focusedWorkspaceIDs` is absent does it migrate to `[legacy]` + `focusEnabled = true`;
      `AppStore+Focus.swift:74-78` then intersects with the restored tree and disables on an empty result.
      PROVEN by `PersistenceTests.legacySnapshotWithSingleFocusedWorkspaceMigratesToAnEnabledSet` — a raw
      legacy JSON file through `PersistenceStore.load` + `AppStore.restore`, asserting the one-member enabled
      set AND `visibleWorkspaces == [ws]` — with `SnapshotRoundTripTests.legacySnapshotWithSingleFocusedWorkspaceDecodesAsAnEnabledSet`
      pinning the raw decode, `snapshotWithBothFocusKeysPrefersTheSet` pinning that the SET wins a
      downgrade/upgrade round trip, and `snapshotWithoutAnyFocusKeyDecodesToNilWithoutThrowing` +
      `PersistenceTests.legacySnapshotWithoutFocusedWorkspaceDecodesUnfocused` pinning the no-key case.
      The all-gone case is `AppStoreFocusTests.restorePrunesAnAllStaleSetToEmptyAndDisabled`; the partial
      case `restoreKeepsTheSurvivorsOfAPartiallyStaleSet`. Verified entirely against test fixtures — the
      real `~/Library/Application Support/agterm/` state was never read or touched
- [x] a drop on empty sidebar space lands in the marked workspace only when exactly one is marked AND the
      filter is on — the four `AppStoreFocusTests.dropFallback*` cases (empty → nil; one member enabled →
      that member; one member DISABLED → nil; two members enabled → nil) against `AppStore+Focus.swift:110-113`,
      consumed at `WorkspaceSidebar+DragDrop.swift:161` as `resolveDirectoryWorkspace`'s `focusedWorkspaceID:`
- [x] session nav, attention nav, Ctrl-Tab, and the ⌃P palette all scope to the multi-workspace set.
      ⚠️ verified BY CODE READING + composition, not by a direct multi-member test: all four consumers read
      `AppStore.navigableSessions` (`AppStore.swift:556` for `navigateSession`, which backs both plain and
      attention nav; `SessionSwitcher.swift:85` for Ctrl-Tab; `AppActions+Palette.swift:157` for ⌃P), and
      that is `visibleWorkspaces.flatMap(\.sessions)` (`AppStore+Focus.swift:99`), whose multi-member
      behavior IS pinned by `visibleWorkspacesReturnsTheMarkedSubsetInTreeOrder`. The nav suite itself
      (`navigateScopesToFocusedWorkspace`, `navigateAttentionScopesToFocusedWorkspace`,
      `navigableSessionsReflectsFlaggedFocusAndUnfocused`) only ever drives a set of ONE, so no test walks
      nav across a 2-member set. Left as-is rather than fixed: the plan's Solution Overview lists this as
      "FREE — do not fix", and a strengthening test is a maintainer call, not an acceptance fix
- [x] `agtermctl workspace focus add`, `workspace filter on|off|toggle`, and the `tree` read-backs all work
      and are idempotent — CLI mapping by `CommandsTests.workspaceFocusAddWithTarget` +
      `workspaceFocusRejectsBadMode`/`workspaceFocusHelpListsEveryMode` and the six `workspaceFilter*` cases;
      dispatcher routing/validation by the nine `ControlDispatcherWorkspaceTests` cases; the read-backs by
      `AppStoreFocusTests.controlTreeReportsEveryMemberAsFocused` /
      `controlTreeReportsMembershipIndependentlyOfTheFilterFlag` / `controlTreeReportsWorkspaceFilterInBothStates`.
      IDEMPOTENCY: the store mutators are delta-guarded (`focusSettersAreNoOpWritesWhenUnchanged` +
      `setFocusEnabledOnAnEmptySetIsANoOpWrite` assert no file is even written), and the e2e
      `testWorkspaceFocusAddBuildsAMultiWorkspaceSet` drives an explicit repeat-`add` end to end
- [x] run the full unit suite: `cd agtermCore && swift test` — **1860 tests in 75 suites, 0 failures**
- [x] run the app-hosted suite: `make test-app` — **22 tests, 0 failures** (`** TEST SUCCEEDED **`)
- [x] run the linter: `make lint` (zero findings, `--strict`) — `swiftlint lint --strict --quiet` exited 0
      with NO output, i.e. zero violations
- [x] build clean: `make build` — `** BUILD SUCCEEDED **`
- [x] verify no source file crossed 1000 lines and no test file crossed 2000, and that no swiftlint limit was
      raised. Measured across every tracked `.swift`: NO source file over 1000 (largest touched:
      `AppStore.swift` 965, `AppActions.swift` 935, `WorkspaceSidebar.swift` 899) and NO test file over 2000
      (largest: `ControlDispatcherTests.swift` 1946, `AppStoreTests.swift` 1938,
      `ControlSidebarStatusUITests.swift` 1008). `git diff origin/master...HEAD --name-only | grep -i swiftlint`
      is EMPTY — neither the root `.swiftlint.yml` nor the three nested test configs were touched on this branch
- [x] ➕ the two e2e suites were re-run as part of this gate:
      `xcodebuild test … -only-testing:agtermUITests/FocusWorkspaceUITests` → **4 tests, 0 failures (67.9 s)**,
      and the four affected `ControlSidebarStatusUITests` methods
      (`testWorkspaceFocusHidesOtherWorkspaces`, `testWorkspaceFocusAddBuildsAMultiWorkspaceSet`,
      `testWorkspaceFilterTogglesWithoutLosingTheSet`, `testSessionNewNoSelectCreateWorkspacePreservesFocus`)
      → **4 tests, 0 failures (17.8 s)**
- ➕ [decision] the acceptance list needed NO old-behavior corrections: every criterion already describes
      the post-Task-15 mark-only contract, and the criterion Task 15b said it added ("marking a workspace
      does NOT turn the filter on") is present and now verified. The two annotations above are a coverage
      arity note and a composition-only verification note, not behavior corrections

### Task 18: [Final] Update project documentation

**Files:**
- Modify: `.claude/rules/sidebar.md`
- Modify: `.claude/rules/control-api.md`
- Modify: `.claude/rules/menu-actions.md`
- Modify: `.claude/rules/keymap.md` (➕ carry-over 1 from Task 16)
- Modify: `site/docs.html` (➕ carry-over 2 from Task 16)
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreNavigationTests.swift` (➕ carry-over 3 from Task 17)
- ~~`CLAUDE.md`~~ — not modified; no new cross-cutting convention emerged (see the checkbox below)

- [x] rewrite the sidebar rule's "Focus filter" bullet for the set + flag model, covering the two lifecycle
      rules (cross-set select disables and keeps; workspace creation adds), the mark-only add (Focus
      REPLACES and enables; Add to Focus only marks, so a set is built then applied once), the
      unrepresentable `enabled + empty` invariant, the filled-icon indication, the removal of the pill, and
      the dual-field `updateNSView` observation dependency. ➕ the one bullet became FIVE (filter/mutators,
      mark-only, the invariant + its three guards, the two lifecycle rules, the row icon + bottom-bar
      toggle) — a single bullet carrying all of it was unreadable. ➕ four NEIGHBOURING bullets named the
      deleted `focusedWorkspaceID` and would have actively misled: scoped session navigation, the
      Focus×selection contract, the reconcile signal's `updateNSView` dependency, and persistence (the
      decode-only legacy key + the restore prune), plus the multi-selection and force-expand asides
- [x] update the control-api rule's `workspace.focus` paragraph for the fourth mode (`add` inserts WITHOUT
      enabling the filter) and the dispatcher-hoisted typed parse, add the `workspace.filter` entry with its
      four-point keep-in-sync audit, and bump the catalog count 66 → 67 everywhere it appears in that file.
      Counted against the source, not the plan: `Command` has 68 cases (63 with explicit raw values + `tree`,
      `dashboard`, `quick`, `sidebar`, `notify`), minus the excluded `debug.appearance` seam = 67. The count
      appears FIVE times in the rule (catalog heading, the debug-seam note, TWO skill-bundle sentences, the
      website-mirror sentence); ➕ the read-back pair list gained `workspace.filter`/`workspaceFilter`, and
      the website-mirror note now records that the count sits in THREE spots in `commands.html` (the plan's
      Task 16 note said four) plus README/docs.html/SKILL.md and the `SkillInstallTests` assertion
- [x] update the control-api rule's `session.new --no-select` paragraph (lines ~477-484), which documents
      `clearFocus: Bool = true` gating `focusedWorkspaceID = nil` — both the parameter name and the
      mechanism changed in Task 3. Verified against `AppStore.swift:268-271` and
      `ControlServer+SessionActions.swift:105`: reveal now INSERTS into the marked set rather than clearing
      the filter, so `--no-select` does not WIDEN the set. ➕ the same paragraph's
      `autoUnfocusIfOutsideFocus` mention was renamed, and `testSessionNewNoSelectCreateWorkspacePreservesFocus`
      added to its e2e list
- [x] update `.claude/rules/menu-actions.md:255`, which names `autoUnfocusIfOutsideFocus` by its old name,
      and re-read its "focus filter deliberately does NOT scope the close-reselection MRU" reasoning against
      the set model. The reasoning HOLDS and is if anything stronger: focus is a property of the TREE, and a
      SET can hold even more workspaces the closing session does not belong to. Both failure states stay
      reachable (the second one whenever the emptying workspace is the only marked one), and both pinned
      tests still exist. Rewrote the paragraph in set terms rather than only swapping the name.
      ➕ the View-menu inventory listed only "Focus Workspace"; it now names all four workspace-focus items
      and which two are `BuiltinAction`-backed
- [x] ➕ CARRY-OVER 1 (Task 16): `.claude/rules/keymap.md` called `BuiltinAction` "the 36 rebindable
      actions". Counted from `BuiltinAction.swift:10-27`: 42 (41 before `toggleWorkspaceFilter`), which
      `BuiltinActionTests.swift:33` already asserts. Corrected to 42 and pointed at that test so the number
      has an owner
- [x] ➕ CARRY-OVER 2 (Task 16): `site/docs.html`'s built-in action list was missing `reopen_recent` and
      `undo_close` (40 entries vs README's 42). Verified by DIFFING the three lists mechanically rather than
      by eye — the extracted `site/docs.html` list is now byte-identical to both the README copy and the
      raw values in `BuiltinAction.swift`
- [x] ➕ CARRY-OVER 3 (Task 17): nav scoping across a MULTI-member focus set had no test — every case in
      `AppStoreNavigationTests.swift` drove a set of exactly one. Added `makeThreeWorkspaceNavTree` plus
      `navigateScopesToEveryMemberOfAMultiWorkspaceSet` (marks a NON-contiguous 2-of-3 set, then walks
      next/previous/first/last through BOTH marked workspaces' sessions, skipping the unmarked one's and
      wrapping within the set) and `navigateAttentionScopesToEveryMemberOfAMultiWorkspaceSet` (an attention
      session in the unmarked workspace is never reached). Both PASS unmodified against the existing code —
      the composition-only verification in Task 17 was correct, and this closes the last known coverage gap
- [x] use semantic line breaks (one sentence per line) in all three rule files, per the CLAUDE.md convention
- [x] update `CLAUDE.md` only if a genuinely new convention emerged — otherwise leave it alone.
      [decision] LEFT ALONE. Everything this feature exercised was an EXISTING convention applied, not a new
      one: the dispatcher-first hoist, the four-point control audit + its read-back obligation, the
      agent-skill/website keep-in-sync surfaces, the Settings ▸ Interface toggle proposal, and the file-size
      discipline are all already written there. Inventing an entry to have something to write would dilute
      the file
- [x] move this plan to `docs/plans/completed/` — NOT done here by design: the execution flow performs the
      move at the very end, after the review phases and finalize, via its own script

## Post-Completion

*Items requiring manual intervention or external systems — no checkboxes, informational only*

**Manual verification** (not accessibility-observable, so it cannot be covered by XCUITest):

- The filled vs outline `square.grid.2x2` icon renders at the correct tint against both a light and a dark
  terminal theme, and the swap causes no row layout shift.
- The bottom-bar toggle's disabled 0.35 opacity reads as disabled against the themed sidebar background.
- The tree narrow/widen animates cleanly through `splitRoot`'s `.animation(value:)` when the filter flips.
- Verify on an ISOLATED dev instance (`open -n --env AGTERM_STATE_DIR=/tmp/<name> …` with a SHORT socket
  path), never against the deployed `~/Applications/agterm.app` or the default socket — that is the live
  daily driver with real sessions.

**Migration check on real data:**

- Before merging, confirm a COPY of the real `~/Library/Application Support/agterm/windows/<id>.json`
  (copied into the isolated dev state dir, never the original) restores correctly through the legacy path.

**PR and cleanup:**

- Open the PR from the worktree; merge from the MAIN checkout so the worktree's branch is never switched.
- After a squash merge, `ExitWorktree` will refuse with "N commits will be discarded permanently" — this is
  expected. Verify the squash landed on `origin/master`, then re-invoke with `discard_changes: true`, and
  delete the leftover local branch from the main checkout.

---

Smells pre-check: skipped — non-Go project
