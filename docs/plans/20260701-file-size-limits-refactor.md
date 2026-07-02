# File-Size Limits Refactor (swiftlint 1000/2000)

## Overview

Refactor 10 oversized/near-limit Swift files so swiftlint `--strict` passes with tightened size limits and the near-limit files gain headroom, then tighten the config:

- `file_length`: warning 1000 / error 1100 (source), warning 2000 / error 2200 (tests, via nested configs)
- `type_body_length`: warning 800 / error 1000 (source), warning 1800 / error 2000 (tests)

Today the limits are grandfathered at 2700/3000 and 1850/2500 just to keep the tree green. This plan removes the grandfathering by actually splitting the big files — behavior-preserving throughout (zero functional changes: control protocol wire format, persistence, keymap semantics, CLI arguments/help output, and all observable behavior stay identical).

The designs were produced and adversarially verified by three multi-agent analysis passes (structure analysis → architecture design → verification → consolidation). The chosen shape is deliberately proportionate: three targeted extractions where a real seam existed (`ControlTargetResolver`, `SidebarRenameController`, `ControlAPITestCase` harness base), and honest mechanical splits (whole-type moves / extension files / suite-per-concern) everywhere else. No new protocols, no new layers, no module-boundary changes.

**Files in scope** (current line counts at HEAD `f98de51`):

| File | Lines | Limit | Outcome |
|---|---|---|---|
| `agterm/Control/ControlServer.swift` | 1663 | 1000 | resolver type + 3 extension files |
| `agterm/ContentView.swift` | 1653 | 1000 | 5 whole-type moves |
| `agterm/Views/WorkspaceSidebar.swift` | 1422 | 1000 | rename controller + row views + 3 extension files |
| `agterm/Ghostty/GhosttySurfaceView.swift` | 1187 | 1000 | +Input extension file |
| `agtermUITests/ControlAPIUITests.swift` | 2678 | 2000 | harness base class + 3 suite classes |
| `agtermCore/Tests/agtermCoreTests/AppStoreTests.swift` | 2098 | 2000 | fixtures file + 3 suite structs |
| `agtermCore/Sources/agtermctlKit/Commands.swift` | 984 | 1000 | 4 command-family files |
| `agterm/agtermApp.swift` | 920 | 1000 | AppDelegate move + menus extension |
| `agterm/AppActions.swift` | 900 | 1000 | +Palette extension file |
| `agtermCore/Sources/agtermCore/AppStore.swift` | 846 | 1000 | +Panes extension file |

Only the first six files violate the new limits — Tasks 1–6 plus the config Task 11 are the gate-required core. The last four (Commands, agtermApp, AppActions, AppStore) already pass both new limits untouched; Tasks 7–10 are preventive headroom splits, explicitly approved by the maintainer (Commands.swift sits 16 lines under a hard CI gate). A time-constrained run may land Tasks 1–6 + 11 first and still reach a green `--strict` tree.

## Context (from discovery)

- Swift 6 project: app target `agterm/` (SwiftUI + AppKit + libghostty), host-free SwiftPM package `agtermCore/` (strict concurrency `complete`), XCUITests `agtermUITests/`.
- `make lint` = `swiftlint lint --strict` from repo root (swiftlint 0.65.0 local = current brew formula = what CI installs). Under `--strict` a warning IS the hard gate; error tiers are cosmetic.
- Empirically verified (fixtures run against swiftlint 0.65.0): nested `.swiftlint.yml` child configs overlay only the keys they declare onto the inherited root config (root `disabled_rules` etc. still apply inside); nested configs ignore `included`/`excluded`; `file_length` counts raw lines identical to `wc -l`; `type_body_length` skips comments/blanks and does NOT count extension bodies at all — so moving method groups into extension files shrinks both measures.
- xcodegen app target uses `path: agterm` directory glob; agtermUITests likewise; SwiftPM targets glob their directories — new `.swift` files are picked up with no `project.yml`/`Package.swift` edits (just `xcodegen generate`, which `make build` runs).
- CI (`ci.yml`) never runs XCUITests and never compiles `agtermUITests` (the scheme builds it only for the `test` action) — the UI-test split task therefore needs an explicit `build-for-testing` gate.
- All new file paths verified collision-free at HEAD; all cross-file references (WindowRegistry, `.agtermApplySplitRatio`, SessionTextUITests helpers) verified to close cleanly.

## Development Approach

- **Testing approach**: Regular — existing tests are the oracle (maintainer decision). This is a behavior-preserving refactor: no new tests; the acceptance for every task is the existing suites passing unchanged, plus test-count oracles proving no test was lost in the splits. The two new app-target types have no unit-test host (app target has only XCUITests); the existing control-API and sidebar e2e suites pin their behavior.
- **Branch**: create `refactor/file-size-limits` from current master before Task 1.
- **CRITICAL — verbatim moves**: moved code is relocated byte-identically (same doc comments, same blank-line structure inside regions). No logic edits, no renaming sweeps, no "fixing" pre-existing oddities while moving (e.g. the `Session`/`Workspace`/`Window` ParsableCommand type shadowing in agtermctlKit is pre-existing and stays).
- **CRITICAL — line ranges are anchored to HEAD `f98de51`**: every cited range indexes the ORIGINAL file as of that commit. Locate each move target by its type/MARK declaration in the file as it exists at execution time — earlier steps in the same task shift line numbers. Re-verify the region content before cutting (concurrent-session hazard).
- Per-task green gate (no exceptions, all under the CURRENT grandfathered config until Task 11): `make build` (runs `xcodegen generate`) + `cd agtermCore && swift test` + `make lint`. Tasks touching only agtermCore may skip `make build` mid-task but must run it once before task completion.
- Tasks 1–10 are mutually independent and order-free (verified: disjoint edit sets); Task 11 (config tightening) MUST run after all of them. Sequential execution assumed; if ever parallelized on branches, batch each shared doc's edit into a single owning task (control-api.md is touched by Tasks 1, 5, 7; menu-actions.md by Tasks 8, 9; libghostty.md by Tasks 2, 4; windows.md by Tasks 2, 5, 8; ARCHITECTURE.md by Tasks 1, 2).
- **XCUITest runs synthesize real input on the user's screen**: coordinate with the user before ANY local XCUITest run, including single-test smoke runs (ui-tests.md hands-off rule). Never touch the deployed `~/Applications/agterm.app`.
- **Keep-in-sync / agent-skill convention: consciously N/A for this whole plan** — no Control API command/arg/return, keymap format, or window/workspace/session/pane model changes; pure code motion. Stated here so the check is documented, not skipped.
- **CRITICAL: update this plan file when scope changes during implementation.**

## Testing Strategy

- **Oracle**: full existing suites green after every task. agtermCore: `swift test` (capture the executed-test grand total as baseline before Task 6 and compare after every test-file split). XCUITests: `xcodebuild build-for-testing` compiles them; targeted local runs where a task touches fragile UI surfaces (rename, drag-reorder, control API) — with user coordination.
- **Test-count oracles**: `rg -c '@Test ' ` across split Swift Testing files must sum to the original count (178 for AppStoreTests); XCUITest identities: 98 tests across the five control classes after the split.
- **CLI oracle**: `agtermctl --help` (and family `--help`s) byte-identical before/after the Commands split.
- No new unit/e2e tests — pure moves with zero functional change (maintainer decision).

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope

## Solution Overview

Three targeted architectural extractions (each owns real state, injected minimally):

1. **`ControlTargetResolver`** (`@MainActor final class`, `init(library: WindowLibrary)`) — the control channel's target-resolution query layer. Owns the `emptyStore` lazy fallback + `store` computed property (deleted from ControlServer instead of bumped internal). Wraps agtermCore's pure `ControlResolve` string matcher with app-side store scoping and pinned wire-error formatting; does NOT duplicate it.
2. **`SidebarRenameController`** (`@MainActor final class`, NSObject, NSTextFieldDelegate) — owns the four inline-rename reentrancy flags (`editing`, `committing`, `cancellingRename`, `renameOriginalValue`) as privates, removing the most bug-prone mutable state and a delegate conformance from the Coordinator god class. `init(store: AppStore)` + settable `onRenameEnded` callback.
3. **`ControlAPITestCase`** (XCTestCase base) — the UI-test harness capsule (stateDir/socketPath/app/launch/seed/socket/poll oracles). Fixes the existing smell where SessionTextUITests was an `extension ControlAPIUITests` borrowing another file's guts; all five control suites inherit instead.

Everything else is honest code motion: whole-type moves (ContentView's nine types, AppDelegate, the four command families), extension-in-new-file for method groups (ControlServer actions, Coordinator regions, surface input, AppActions palettes, AppStore panes), and suite-per-concern splits for the two big test files.

## Technical Details

**Access-control deltas** (the full member-by-member traces live in each task):
- Swift rule driving everything: `private` members are visible to same-file extensions only; moving an extension to a new file forces `private`→`internal` on every member it touches; top-level `private` = fileprivate. Whole-type moves are visibility-neutral except the type declaration itself.
- Net exposure is kept minimal by design: co-locating helpers with their only callers, and the two extractions each REDUCE god-object internals versus a plain split.

**swiftlint mechanics** (Task 11): root `.swiftlint.yml` keeps all policy; two new nested configs (`agtermUITests/.swiftlint.yml`, `agtermCore/Tests/.swiftlint.yml` — the latter covers both agtermCoreTests and agtermctlKitTests) declare ONLY `file_length`/`type_body_length` overrides. `make lint` and CI run from repo root with no path args — exactly the mode where SwiftLint auto-discovers nested configs; no Makefile/CI command change.

**Post-split size expectations** (largest): source — WindowContentView.swift ~820, ControlServer.swift ~700, WorkspaceSidebar.swift ~680; effective type bodies all under 800 (largest ~750). Tests — residual ControlAPIUITests.swift ~1025, AppStoreOrganizationTests.swift ~610.

## What Goes Where

- **Implementation Steps** (checkboxes): all code moves, config, docs — everything in this repo.
- **Post-Completion** (no checkboxes): the user's own manual verification in his daily-driver build after deploy.

## Implementation Steps

### Task 1: ControlServer — extract ControlTargetResolver + action extension files

**Files:**
- Create: `agterm/Control/ControlTargetResolver.swift`
- Create: `agterm/Control/ControlServer+SessionActions.swift`
- Create: `agterm/Control/ControlServer+SurfaceIO.swift`
- Create: `agterm/Control/ControlServer+WindowCommands.swift`
- Modify: `agterm/Control/ControlServer.swift`
- Modify: `.claude/rules/control-api.md`, `ARCHITECTURE.md`

Read `.claude/rules/control-api.md` first. External API of ControlServer (`init`/`start`/`stop`/`resolvedSocketPath`) is untouched; the flat 44-arm dispatch stays flat; all socket lifecycle / nonisolated accept-loop machinery / fast-path window cache stays in the main file.

- [x] create `ControlTargetResolver.swift` (`@MainActor final class`, `init(library: WindowLibrary)`): move verbatim from ControlServer — nested `Resolution<T>` (internal), `emptyStore` lazy var + `store` computed property (both private — they are DELETED from ControlServer, not bumped), `resolvePlacementStore`, `resolveSession`, `resolveWorkspace`, `resolveSessionTarget`, `resolve(_:candidates:active:noun:_:)` (internal entry points), `resolveWindowStore`/`resolveTargetAcrossWindows`/`resolveAcrossWindows`/`resolutionError` (private), BOTH `resolveWindowID` overloads (internal — relocated from the window-commands region so `resolutionError` stays private), plus a private 6-line copy of `trimmed` (deliberate duplication over a back-reference). Keep every error string byte-identical — ControlAPIUITests pin them.
- [x] in `ControlServer.swift`: add `private let resolver: ControlTargetResolver` (constructed from the same `library` in init), delete the moved members, prefix ~42 call sites with `resolver.` (`resolveSession` x19, `resolvePlacementStore` x7, `resolveWindowID` x7, `resolveWorkspace` x5, `resolveSessionTarget` x2, `resolve` x2 — each missed site is a hard compile error). Gate: `make build` + `cd agtermCore && swift test` + `make lint`.
- [x] create `ControlServer+SessionActions.swift` (`extension ControlServer`, imports Foundation + agtermCore): move the control-actions first half verbatim — `splitSession`, `scratchSession`, `focusSessionPane`, `resizeSplit`, the `StatusUpdate` struct + `setSessionStatus` doc-comment block moved as ONE unit, `flagSession`, `moveSession`, `moveWorkspace`, `focusWorkspace`, `sendNotification`, `setQuickTerminal`, `setSidebar`, `setSidebarViewMode`, `expandWorkspaces`, `collapseWorkspaces`. Bump to internal exactly what the compiler demands: `resolver`, `library`, `actions`, `settingsModel`, `trimmed` (6 call sites end up outside the resolver: 2 main file, 2 here, 2 in +WindowCommands — internal from THIS step, not private), `StatusUpdate`, and the 15 moved methods. Gate.
- [x] create `ControlServer+SurfaceIO.swift` (imports Foundation + agtermCore + AppKit, plus GhosttyKit if the moved code names its types directly — mirror what the moved region needs): move verbatim — `font`, `copySelection`, `setBackground` + `applyWatermark` (stays private — only caller is same-file), `readText`, `searchSession` (async), `injectText` (async). `buildTree` does NOT move (stays private in main next to dispatch, its only caller). Bump the 6 dispatch-called methods internal. Gate.
- [x] create `ControlServer+WindowCommands.swift` (imports AppKit + Foundation + agtermCore): move verbatim — `windowNew`, `buildWindowList`, `windowSelect` (async), `windowClose` (async), `pollUntil` (stays private), `windowResize`, `windowMove`, `windowZoom`, `windowRename`, `windowDelete` — MINUS the `resolveWindowID` overloads (already in the resolver). Bump the 9 dispatch-called methods internal. Gate.
- [x] docs: `.claude/rules/control-api.md` frontmatter — replace the exact `agterm/Control/ControlServer.swift` entry with `agterm/Control/ControlServer*.swift` AND add `agterm/Control/ControlTargetResolver.swift` (the resolver does not match the glob). ARCHITECTURE.md: the control paragraph stays true (class stays in ControlServer.swift); add at most one sentence naming the resolver.
- [x] verify: main file ~700 lines; run the full gate one final time.

### Task 2: ContentView — five whole-type moves

**Files:**
- Create: `agterm/WindowRegistry.swift`, `agterm/Views/WindowControlArea.swift`, `agterm/Views/SplitRatioAccessor.swift`, `agterm/Views/WindowAccessor.swift`, `agterm/Views/WindowContentView.swift`
- Modify: `agterm/ContentView.swift`
- Modify: `ARCHITECTURE.md`, `.claude/rules/libghostty.md`, `.claude/rules/windows.md`

Read `.claude/rules/libghostty.md` and `.claude/rules/windows.md` first. Access changes total exactly FOUR type-declaration bumps `private`→internal (`WindowContentView`, `WindowAccessor`, `SplitRatioAccessor`, `WindowControlArea`); ZERO member-level bumps. All cited ranges index the original 1653-line file — locate by type declaration at execution time (steps 1–2 delete ~176 lines and shift everything after).

- [x] move `WindowRegistry` + the three private `WindowGeometry` CG-conversion extensions (orig 1301–1424, agtermCore-SIL-crash comment intact) → `agterm/WindowRegistry.swift` (imports agtermCore + AppKit; correctly NO SwiftUI). Zero access changes — lowest-risk move first. Gate: `make build` + `cd agtermCore && swift test` + `make lint`.
- [x] move `WindowControlArea` (+ nested TitlebarControlView, orig 1249–1299) → `agterm/Views/WindowControlArea.swift`; drop top-level `private`. Gate.
- [x] move `SplitRatioAccessor` (+ nested SplitProbeView, orig 1485–1653, full doc comment) → `agterm/Views/SplitRatioAccessor.swift`; bump type declaration to internal; all members stay private. Gate.
- [x] move `WindowAccessor` + nested TitleProbeView (orig 964–1247, bump struct to internal) AND `WindowCloseDelegateProxy` (orig 1426–1483 — KEEP `private`, its only consumer TitleProbeView is now same-file) → `agterm/Views/WindowAccessor.swift`; carry the willClose capture-not-self comment. Gate.
- [x] move `WindowContentView` (orig 147–962) whole and unsplit → `agterm/Views/WindowContentView.swift`; bump struct declaration to internal; every member (incl. the @State mirrors and six static resolved* readers) stays private; carry the NSSplitView-overrun / titlebar-scrim / eager-deck comment blocks intact. `ContentView.swift` lands at ~146 lines (ContentView + private StrayWindowCloser). Gate.
- [x] docs: ARCHITECTURE.md — update the "`WindowRegistry` (in `ContentView.swift`)" reference to `agterm/WindowRegistry.swift` (REQUIRED). Rule frontmatter: `libghostty.md` paths += `agterm/Views/WindowContentView.swift`, `agterm/Views/SplitRatioAccessor.swift` (keep the existing `agterm/ContentView.swift` entry); `windows.md` paths += `agterm/WindowRegistry.swift`, `agterm/Views/WindowAccessor.swift`, `agterm/Views/WindowControlArea.swift`.
- [x] ⚠️ flag for the maintainer (do NOT silently rewrite): ContentView.swift's file-top doc comment still describes the detail pane with stale `.id(session.id)` swap wording — propose a one-paragraph fix for approval.

### Task 3: WorkspaceSidebar — rename controller extraction + Coordinator split

**Files:**
- Create: `agterm/Views/SidebarRowViews.swift`, `agterm/Views/SidebarRenameController.swift`, `agterm/Views/WorkspaceSidebar+RowRendering.swift`, `agterm/Views/WorkspaceSidebar+ContextMenu.swift`, `agterm/Views/WorkspaceSidebar+DragDrop.swift`
- Modify: `agterm/Views/WorkspaceSidebar.swift`, `.claude/rules/sidebar.md`

Read `.claude/rules/sidebar.md` first. The Coordinator remains the single NSOutlineView dataSource/delegate; the hard-won drag-reorder math stays in `agtermCore.SidebarDrop` untouched.

- [ ] move the five private top-level helper types (`SidebarCellView`, `BadgeView`, `StatusIconView`, `SidebarRowView`, `SidebarNode`; orig 13–220) verbatim → `SidebarRowViews.swift`, dropping top-level `private` (collision-free module-wide, verified). Imports AppKit + agtermCore (CABasicAnimation works via AppKit's QuartzCore re-export). MUST be first — the controller references SidebarNode/SidebarCellView cross-file. Gate: `make build` + `cd agtermCore && swift test` + `make lint`.
- [ ] create `SidebarRenameController.swift` (`@MainActor final class`, NSObject, NSTextFieldDelegate): move the Inline-rename MARK region (`beginEditing`, `control(_:textView:doCommandBy:)`, `controlTextDidEndEditing`, restore; orig 1006–1091) plus the four flag declarations with doc comments (`editing`, `committing`, `cancellingRename`, `renameOriginalValue`) — all private except internal `beginEditing(node:)` and read-only `isEditing`/`isCommitting`. Wiring fixes (verifier-mandated, compile-order): controller gets `var onRenameEnded: (() -> Void)?`; Coordinator's stored `let renameController` is initialized from the store init PARAMETER before `super.init()`; `renameController.onRenameEnded = { [weak self] in self?.focusActiveTerminal() }` assigned AFTER `super.init()`. The existing `DispatchQueue.main.async` deferral moves INTO the controller's `controlTextDidEndEditing`, wrapping the `onRenameEnded` invocation — invoking synchronously would hit focusActiveTerminal's firstResponder-is-NSText early-return and silently break focus hand-back; the closure body is the bare `focusActiveTerminal()` call. Plus: weak `outlineView` reference propagated in makeNSView; Coordinator drops NSTextFieldDelegate; `viewFor` sets `field.delegate = renameController`; `reloadChangedContentRows` guard → `!renameController.isCommitting && !renameController.isEditing`; `focusActiveTerminal` early-return → `renameController.isEditing`; rename entry points call `renameController.beginEditing(node:)`.
- [ ] gate, then coordinate with the user and run the rename-exercising XCUITests locally (SidebarUITests at minimum): Esc-cancel restores label, commit renames, double-click and menu rename both start the edit, badge tick mid-rename does not drop the edit.
- [ ] create `WorkspaceSidebar+RowRendering.swift`: move `isGroupItem`, `shouldSelectItem`, `rowViewForItem`, `viewFor`, `applyBadge`, `iconForSession`, `makeCell`, `rowLabel(forSession:)`; keep the 5 lazy icons + static `rowIcon` + `rowLabel(for:workspaceName:)` declared in the main file; bumps to internal: `store`, `effectiveIndicator`, `effectiveUnseen`, `rowLabel(for:workspaceName:)`, the five lazy icon caches, plus the new internal `let renameController`. Gate.
- [ ] create `WorkspaceSidebar+ContextMenu.swift`: move `handleDoubleClick`, `menu(forRow:)`, `ownerWorkspaceID`, `MoveRequest`, the nine `@objc` handlers (stay private — selector dispatch from an extension works), `addSession`, `openDirectoryAndAddSession`; bump `actions` internal. Gate; spot-check right-click menu + double-click rename in an isolated dev instance.
- [ ] create `WorkspaceSidebar+DragDrop.swift`: move `pasteboardWriterForItem`, `validateDrop`, `acceptDrop`, `SessionMove`, resolve helpers, dragged-id readers; `workspaceNode(forID:)` stays in main bumped internal (keeps the `roots` cache private); top-level pasteboard constants drop `private`. Gate, then coordinate with the user and run ReorderUITests locally (`testReorderWorkspaceOntoSessionRow` is the documented regression guard).
- [ ] docs: `sidebar.md` frontmatter — replace exact `agterm/Views/WorkspaceSidebar.swift` with `agterm/Views/WorkspaceSidebar*.swift`, add `agterm/Views/SidebarRowViews.swift` and `agterm/Views/SidebarRenameController.swift`; touch the rule prose only where it names the Coordinator as the rename NSTextFieldDelegate. Final full gate. All structural caches (`roots`, `nodeCache`, `lastShape`, `lastMode`, `lastRowContent`, `expandedWorkspaceIDs`, `applyingSelection`, `lastRevealedSelection`, `emptyStateLabel`) remain private in the main file.

### Task 4: GhosttySurfaceView — input handling to +Input extension file

**Files:**
- Create: `agterm/Ghostty/GhosttySurfaceView+Input.swift`
- Modify: `agterm/Ghostty/GhosttySurfaceView.swift`, `.claude/rules/libghostty.md`

Read `.claude/rules/libghostty.md` first. Responder-chain overrides stay on the NSView subclass (they move as an extension of it, not to a helper type — the stateless key-translation helper extraction was evaluated and rejected as ceremony). No `nonisolated(unsafe)` state moves.

- [ ] create the file with the `// adapted from thdxg/macterm (MIT)` header + imports (agtermCore, AppKit, GhosttyKit; no QuartzCore); move ONLY the "Drag and drop (issue #51)" MARK (`draggingEntered`, `performDragOperation`, private `dropText` — all callers move together, everything stays private) into a plain `extension GhosttySurfaceView`. Gate — proves the mechanism with ZERO access changes.
- [ ] move the rest of the input block in one step (it is one private-helper web): keyboard MARK (`keyDown`/`doCommand`/`keyUp`/`flagsChanged`), mouse MARK (private `mousePoint` + handlers + `scrollWheel`), key-event-helpers MARK (all seven helpers, staying private), and the `NSTextInputClient` extension VERBATIM including `@preconcurrency`; relocate `private static let escapeKeyCode` into the extension (stays private; `Self.escapeKeyCode` resolves unchanged).
- [ ] in the main file bump exactly five members to internal: `currentKeyEvent`, `keyTextAccumulator`, `_markedRange`, `_selectedRange` (IME composition state shared with +Input.swift — add the one-line comment saying so; stored properties cannot live in extensions) and `updateGhosttyFocus()` (stays in main beside `liveFocus` per the focus contract; called from both sides). Gate.
- [ ] verification gate, no edits: `wc -l` both files (main ~840, +Input ~360); grep the new file — `nonisolated(unsafe)` absent, `@preconcurrency NSTextInputClient` present; main file still holds `updateDropRegistration`/`deckVisible didSet`, `createSurface`/`destroySurface`/`deinit`, all callback entry points. Full gate.
- [ ] docs: `libghostty.md` frontmatter += `agterm/Ghostty/GhosttySurfaceView+Input.swift` (or widen to `GhosttySurfaceView*.swift`) — the design text omitted this step; the consolidator caught it.

### Task 5: ControlAPIUITests — harness base class + suite-per-family split

**Files:**
- Create: `agtermUITests/ControlAPITestCase.swift`, `agtermUITests/ControlWindowUITests.swift`, `agtermUITests/ControlOverlaySplitUITests.swift`, `agtermUITests/ControlSidebarStatusUITests.swift`
- Modify: `agtermUITests/ControlAPIUITests.swift`, `agtermUITests/SessionTextUITests.swift`, `.claude/rules/control-api.md`, `.claude/rules/windows.md`

Read `.claude/rules/ui-tests.md` first. CRITICAL: nothing in the normal toolchain compiles agtermUITests (`make build` and CI never touch it; the scheme builds it only for the test action) — the gate for EVERY step here is `xcodegen generate` + `xcodebuild build-for-testing -project agterm.xcodeproj -scheme agterm -destination 'platform=macOS' -derivedDataPath build/DerivedData` + `make lint`. Assertions untouched throughout; 98 test identities preserved (class prefixes change for moved tests — verified inert: no `-only-testing`/scheme/CI references exist). Coordinate with the user before ANY test run, including single-test smoke runs.

- [ ] create `ControlAPITestCase.swift` (`@MainActor class`, not final): move VERBATIM the four fixtures, `setUp`/`tearDown` (add a one-line pointer comment on the `AGTERM_UITEST_DOUBLECLICK_ACTION` env branch noting the None-case test's future home), `activeSessionID`, the four `relaunch` helpers, `typeRequest`/`pollMarker`/`typeUntilMarker`, `pollSessionRowCount`, the snapshot oracles, and the socket client — EXCEPT (verifier FIX 1): `pollSessionOverlay`, `pollActiveSessionScratch`, `pollSessionActiveAndScratch`, `keyboardTypeUntilMarker` stay OUT of the base (private in the residual class for now; they move private into ControlOverlaySplitUITests with their callers later). Access: `stateDir`/`socketPath`/`connect`/`writeAll`/`readLine`/`posixError` private in base; `markerDir` private(set); ~13 members internal (internal is Swift's only base→subclass spelling in a test target; visibility never leaves agtermUITests). Re-declare `final class ControlAPIUITests: ControlAPITestCase` with moved members deleted. Base lands ~315 lines.
- [ ] gate (build-for-testing + lint); then, with user coordination, one smoke test (`-only-testing:agtermUITests/ControlAPIUITests/testTreeReturnsSeededWorkspaceAndSession`) to prove per-test launch/teardown semantics are identical.
- [ ] convert `SessionTextUITests.swift` from `extension ControlAPIUITests` to `@MainActor final class SessionTextUITests: ControlAPITestCase`; reword its header comment (it documents the extension hack); `pollPaneText` stays private. Update the control-api.md body line that says "a ControlAPIUITests extension". Gate.
- [ ] create `ControlWindowUITests.swift`: move the window-commands test regions (orig 1793–2159, 2241–2315) verbatim into `@MainActor final class ControlWindowUITests: ControlAPITestCase`; every moved helper stays private; add the pointer comment on `testDoubleClickHeaderHonorsNoneSetting` referencing the base setUp env pin. Update the windows.md body class-name reference. Gate.
- [ ] create `ControlSidebarStatusUITests.swift`: move the sidebar/flag/focus/status/notification regions (orig 425–450, 851–1028, 1041–1046, 1281–1448, 1536–1544, 2327–2344) verbatim; `sessionRowValueExists` and `toggleNotificationBadges` private. Update control-api.md body e2e citations for the moved tests. Gate (one file per step — the excisions are interleaved).
- [ ] create `ControlOverlaySplitUITests.swift`: move the overlay/scratch/split regions (orig 647–849, 1057–1279) verbatim, PLUS the four FIX-1 helpers as PRIVATE members here (bodies verbatim; ~525 lines). Update control-api.md citations for `testSessionScratchToggle`/`testSessionResizeSplitDivider`. Residual ControlAPIUITests.swift lands ~1025 lines. Gate.
- [ ] docs: control-api.md frontmatter (verifier FIX 2) — REPLACE the exact `agtermUITests/ControlAPIUITests.swift` entry with `agtermUITests/Control*.swift` (covers the base + residual + three new classes; verified no over-match — consistent with the replace-with-glob pattern of Tasks 1/3/7) AND add the missing `agtermUITests/SessionTextUITests.swift` entry (pre-existing gap). One cosmetic note: the "mirrors keyboardTypeUntilMarker's retry idiom" comment lands cross-class — tweak wording.
- [ ] docs verification (markdown is outside every build/lint gate — this is the one silent-regression surface): for EVERY test func moved out of ControlAPIUITests, grep `.claude/rules/control-api.md` (and `windows.md`) for its name and repoint the class in the citation; then verify no stale reference remains — every citation of the form ``in `ControlAPIUITests` `` must name only tests still living in the residual class (check must come back clean).
- [ ] final: with user coordination, run the five classes locally (`xcodebuild test -only-testing:` each of ControlAPIUITests, ControlWindowUITests, ControlOverlaySplitUITests, ControlSidebarStatusUITests, SessionTextUITests) — all 98 tests pass, proving subclass-hosted discovery.

### Task 6: AppStoreTests — fixtures file + suite-per-concern split

**Files:**
- Create: `agtermCore/Tests/agtermCoreTests/AppStoreTestFixtures.swift`, `agtermCore/Tests/agtermCoreTests/AppStorePaneTests.swift`, `agtermCore/Tests/agtermCoreTests/AppStoreOrganizationTests.swift`, `agtermCore/Tests/agtermCoreTests/AppStoreNavigationTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreTests.swift`

Swift Testing; sibling convention is `@MainActor struct` with no `@Suite` attribute. Capture the FULL-MODULE `swift test` executed-test baseline total BEFORE step 1 (this file alone contributes 178 `@Test` funcs).

- [ ] create `AppStoreTestFixtures.swift` (imports Foundation + `@testable import agtermCore`): move `makeStore` verbatim (doc comment included) as internal top-level `@MainActor func makeStore() -> AppStore`, and `SpySurface` verbatim with `private` dropped — do NOT add an explicit `@MainActor` annotation to SpySurface (it is MainActor-inferred via its `TerminalSurface` conformance, declaration-based, so the verbatim move is isolation-preserving). In AppStoreTests.swift delete the originals and replace all 143 `Self.makeStore()` with `makeStore()` (pre-verified: exactly 143, all zero-arg, no other makeStore in the module). Verify: `rg -c 'Self.makeStore'` = 0; full-module executed-test total unchanged vs baseline; `make lint`; `make build`.
- [ ] create `AppStoreNavigationTests.swift`: move the navigation regions (orig 1394–1405 + 1743–2077) byte-verbatim into `@MainActor struct AppStoreNavigationTests`; static `makeNavTree` travels with all 19 `Self.makeNavTree()` sites. Collapse each excision seam in the residual to ONE blank line (`vertical_whitespace` fails `--strict` on doubles). Verify: full-module total unchanged; lint.
- [ ] create `AppStoreOrganizationTests.swift`: move orig 1071–1091, 1152–1260, 1262–1392 stitched with a single blank line to 1407–1482 (the seam left by the navigation lift), then 1484–1741; `makeReorderTree` + `makeWorkspaceReorderTree` statics travel with all 17 call sites. Collapse seams. Verify: total unchanged; lint.
- [ ] create `AppStorePaneTests.swift`: move orig 419–608, 741–831, 833–943 byte-verbatim; add three `// MARK: -` section comments (split panes / overlay / scratch). Collapse seams. Verify: total unchanged; lint. (Name pairs with Task 10's `AppStore+Panes.swift` — do not rename unilaterally.)
- [ ] final verification: `wc -l` the five files (~745 residual / ~405 / ~610 / ~360 / ~18 fixtures); `rg -c '@Test '` across the five sums to 178; `make build` + `cd agtermCore && swift test` (full-module total = baseline) + `make lint`.

### Task 7: Commands.swift — split by command family

**Files:**
- Create: `agtermCore/Sources/agtermctlKit/SessionCommands.swift`, `agtermCore/Sources/agtermctlKit/WorkspaceCommands.swift`, `agtermCore/Sources/agtermctlKit/WindowCommands.swift`, `agtermCore/Sources/agtermctlKit/MiscCommands.swift`
- Modify: `agtermCore/Sources/agtermctlKit/Commands.swift`, `.claude/rules/control-api.md`

Zero access changes (the file has zero `private` declarations — verified). CLI surface must stay byte-identical. `Commands.swift` keeps its name (root `Agtermctl` + shared plumbing: ConnectionOptions, BasicOptions, ClientOptions, TargetOptions, RequestCommand, Tree; ~122 lines). Do NOT touch `docs/plans/completed/*` references (historical) and do NOT "fix" the pre-existing Session/Workspace/Window type shadowing.

- [ ] baseline: `cd agtermCore && swift build --product agtermctl`; capture `agtermctl --help`, `agtermctl session --help`, `agtermctl window --help`, `agtermctl session background --help` outputs.
- [ ] move the Session family (orig 203–687, incl. Background's static validate and Overlay's `--block` run() override) verbatim → `SessionCommands.swift` (imports ArgumentParser, Foundation, agtermCore). Gate: `cd agtermCore && swift test` + `make lint` + `make build`.
- [ ] move Workspace (orig 124–201) → `WorkspaceCommands.swift`; move Window (orig 689–782) → `WindowCommands.swift` (imports ArgumentParser + agtermCore each). Gate.
- [ ] move Keymap/Config/Restore/Theme/Quick/Sidebar/Notify/Font (orig 784–984, MARK headers included; optionally add the missing `// MARK: - restore`) → `MiscCommands.swift`. Gate. Mind new-file whitespace (single trailing newline, no leading blank).
- [ ] rebuild agtermctl and diff all four `--help` outputs against the baseline — byte-identical.
- [ ] docs: control-api.md frontmatter — replace the exact `Commands.swift` and `SocketClient.swift` entries with `agtermCore/Sources/agtermctlKit/*.swift`; amend the layer-3 prose ("the ParsableCommand tree in Commands.swift") to name the per-family files.

### Task 8: agtermApp — AppDelegate move + menus extension

**Files:**
- Create: `agterm/AppDelegate.swift`, `agterm/agtermApp+Menus.swift`
- Modify: `agterm/agtermApp.swift`, `.claude/rules/menu-actions.md`, `.claude/rules/windows.md`

Read `.claude/rules/menu-actions.md` and `.claude/rules/windows.md` first. The `+Menus` naming follows the `NSColor+AgtermHex` precedent (NOT `agterm/Commands/` — that's the keymap runner's home).

- [ ] move `AppDelegate` (`@MainActor final class`, orig 699–920, doc comments included) verbatim → `agterm/AppDelegate.swift` (imports agtermCore + AppKit). ZERO access edits (verified member by member: the `.task` property-handover wiring is all internal; all nine private members are class-internal). Gate: `make build` + `cd agtermCore && swift test` + `make lint`; agtermApp.swift drops to ~698.
- [ ] create `agterm/agtermApp+Menus.swift`: `extension agtermApp { @CommandsBuilder var appCommands: some Commands { <verbatim menu builders, orig 193–417> } }` plus the four helpers moved verbatim with doc comments (`shortcut(for:)`, `arrowShortcut(for:)`, `toShortcut(_:)`, `showAboutPanel()` — all stay private; every call site moves with them). Imports agtermCore, AppKit, SwiftUI.
- [ ] in agtermApp.swift: replace the whole `.commands { … }` block with `.commands { appCommands }`; change exactly four properties from `@State private var` to `@State var`: `library`, `actions`, `palette`, `settingsModel`. Gate; main file ~410, extension ~300.
- [ ] docs: menu-actions.md frontmatter — widen `agterm/agtermApp.swift` to `agterm/agtermApp*.swift` (covers +Menus; no other file shares the prefix); windows.md += `agterm/AppDelegate.swift` (quit-flush/quit-confirm/restored-window reconciliation are its subject matter; without this the file matches NO rule).
- [ ] optional, with user coordination: spot-run MenuUITests + MultiWindowUITests against a Debug build (menu titles, shortcuts, enabled-state reactivity unchanged).

### Task 9: AppActions — palettes + theme picker to +Palette extension

**Files:**
- Create: `agterm/AppActions+Palette.swift`
- Modify: `agterm/AppActions.swift`, `.claude/rules/menu-actions.md`, `.claude/rules/theme-picker.md`

Read `.claude/rules/menu-actions.md` and `.claude/rules/theme-picker.md` first. The public action surface (three keep-in-sync callers) is untouched — all moved methods were already internal.

- [ ] create `AppActions+Palette.swift` (imports agtermCore + AppKit mirroring the parent; short doc noting the preview stored state lives on the main type): move orig 416–666 verbatim (the "Command palettes" + "Theme picker" MARK sections, incl. `setTheme`/`availableThemes`/`currentTheme` — kept for MARK contiguity — and the private `customCommandItems`/`paletteItem(for:in:status:)`/`themeID` helpers which stay private, all callers moving too).
- [ ] in AppActions.swift: delete orig 416–667 (region + ONE of the two now-adjacent seam blanks — `vertical_whitespace` under `--strict`); drop `private` on exactly four members: `library`, `store` (computed), `themePreviewActive`, `themePreviewOriginal` (stored theme-preview state must stay in the class declaration; its only users move). The other 14 private members stay private (verified caller-by-caller).
- [ ] gate: `make build` + `cd agtermCore && swift test` + `make lint`; files land ~648 + ~260, type bodies ~330/~158 effective.
- [ ] docs: menu-actions.md frontmatter — widen `agterm/AppActions.swift` to `agterm/AppActions*.swift`; theme-picker.md — same widening (BOTH files carry theme-picker content: logic in +Palette, stored state in the main file).

### Task 10: AppStore — panes region to +Panes extension

**Files:**
- Create: `agtermCore/Sources/agtermCore/AppStore+Panes.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`

agtermCore purity holds: `import Foundation` only. Zero access changes — empirically pre-verified (the move was simulated in a scratch copy: compiled under strict concurrency, all 894 tests passed, zero modifier edits; the moved methods touch only public AppStore API).

- [ ] baseline gate: `make build`; `cd agtermCore && swift test`; `make lint`.
- [ ] single atomic move (one commit — create+delete cannot be separated or the duplicated methods are a redeclaration error): create `AppStore+Panes.swift` with `import Foundation`, a `// MARK: - Split, overlay, and scratch panes` header, and `extension AppStore { … }` wrapping orig lines 301–454 moved BYTE-IDENTICALLY (already indented one level, no reindent); delete those lines plus the one now-duplicate blank separator from AppStore.swift (846 − 155 = 691 exactly).
- [ ] full gate: `make build` + `cd agtermCore && swift test` + `make lint`; `swiftlint lint --strict agtermCore/Sources/agtermCore/AppStore+Panes.swift` shows zero findings.
- [ ] naming note honored: pairs with Task 6's `AppStorePaneTests.swift`; a future navigation extraction pre-agrees `AppStore+Navigation.swift` ~ `AppStoreNavigationTests.swift`. No rule-frontmatter change (AppStore.swift deliberately matches no rule — hub file).

### Task 11: Tighten swiftlint config, fix CI filter, update policy docs

**Files:**
- Modify: `.swiftlint.yml`, `.github/workflows/ci.yml`, `CLAUDE.md`
- Create: `agtermUITests/.swiftlint.yml`, `agtermCore/Tests/.swiftlint.yml`

MUST run after Tasks 1–10. Before pinning values, re-measure actual post-split maxima (`wc -l` census + a scratch `only_rules: [type_body_length]` run) and confirm the recommended values hold.

- [ ] root `.swiftlint.yml`: set `file_length` warning 1000 / error 1100; `type_body_length` warning 800 / error 1000. Rewrite the header philosophy comment (drop "grandfather size limits") and replace the "big-by-design … just above today's maxima" block with the new policy description (source ≤1000, tests ≤2000 via nested configs; name `agterm/Views/WindowContentView.swift` where the old comment said "eager-deck ContentView"). Everything else (disabled_rules, line_length, type_name, function_body_length, cyclomatic_complexity, nesting, large_tuple) unchanged.
- [ ] create `agtermUITests/.swiftlint.yml` and `agtermCore/Tests/.swiftlint.yml`, each containing ONLY the overridden keys + a one-line comment: `file_length: {warning: 2000, error: 2200}`, `type_body_length: {warning: 1800, error: 2000}`. (Nested configs inherit everything else from the root and ignore included/excluded — root `excluded` still governs; `agtermCore/.build` is a sibling of `agtermCore/Tests`, unaffected.)
- [ ] `.github/workflows/ci.yml`: add `agtermUITests/.swiftlint.yml` to the paths-filter (verified gap: `agterm/**` does not match the sibling `agtermUITests/`, and the existing `.swiftlint.yml` filter entry is root-only — without this, edits to that nested config would not trigger CI lint). `agtermCore/Tests/.swiftlint.yml` is already covered by the existing `agtermCore/**` filter; listing it too is harmless but redundant.
- [ ] `CLAUDE.md`: rewrite the `make lint` bullet (the grandfathered-limits description) to describe the 1000/2000 scheme + the two nested configs; update the "Manage file sizes for real" bullet ("tests may run 2–3×" → hard 2000 = 2×; reword the two "grandfathered … limits" phrasings; the don't-bump-limits guidance stays).
- [ ] gate: `make lint` (now `--strict` under the NEW limits) green; `make build` + `cd agtermCore && swift test` green.

### Task 12: Verify acceptance criteria

- [ ] census: `git ls-files '*.swift' | xargs wc -l` — no source file over 1000, no test file over 2000 (largest expected: WindowContentView ~820 source, residual ControlAPIUITests ~1025 test)
- [ ] full gates: `xcodegen generate`, `make build`, `cd agtermCore && swift test` (executed-test total = pre-refactor baseline), `make lint` under the new limits
- [ ] `xcodebuild build-for-testing` for the UI-test target compiles clean
- [ ] confirm behavior-identity artifacts recorded: `agtermctl --help` diffs byte-identical (Task 7), 98 XCUITest identities ran green (Task 5), 178 `@Test` oracle (Task 6)
- [ ] with user coordination: one full local XCUITest pass if not already done in Task 5

### Task 13: [Final] Update documentation

- [ ] README.md: verify no file-enumeration/lint mentions need updates (analysis found none — confirm)
- [ ] CLAUDE.md subsystem index prose: optional one-line touch-ups where rules now name split files (e.g. control-api triggers)
- [ ] ARCHITECTURE.md: confirm the Task 1/Task 2 edits landed; no other file-path references affected (verified in analysis)
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

*Items requiring manual intervention - no checkboxes, informational only*

**Manual verification** (user's daily driver, after his own `make deploy` + relaunch on his schedule — never relaunch the deployed app for him):
- inline rename feel: double-click rename, Esc-cancel, focus returning to the terminal after commit (SidebarRenameController is the one extraction touching a fragile interactive path)
- drag-reorder of sessions and workspaces in the sidebar
- menus: titles, shortcuts, enabled-state reactivity; theme picker live preview/commit/cancel
- control channel spot check: `agtermctl tree`, `session select` by prefix, a window command

**Notes:**
- the agent-skill / control-API keep-in-sync convention was evaluated and is N/A for this plan (no wire, keymap, or model change) — documented in Development Approach
- if `agterm/AppActions.swift` or other near-limit files grow again, the same split mechanics apply; `AppStore+Navigation.swift` ~ `AppStoreNavigationTests.swift` is the pre-agreed next pairing

---
Smells pre-check: skipped — non-Go project
