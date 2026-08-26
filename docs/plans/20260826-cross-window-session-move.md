# Cross-window session move

## Overview

Let a session move from one open window to another, carrying its live shell, and expose which window and
workspace a session currently belongs to so a caller can find itself after the move.

- **Problem it solves:** a session is pinned to the window it was created in. Splitting work across
  windows means closing a session and starting over, losing the running process. There is no GitHub issue
  or discussion for this — the only prior statement is `docs/plans/completed/20260619-multi-window.md`,
  which deferred cross-window *drag* and *shared* state. A move keeps the strict 1:1 model intact
  (one bundle, one window) and is not what that note excluded.
- **Second half — ownership read-back:** `AGTERM_WINDOW_ID` and `AGTERM_WORKSPACE_ID` are spawn-time
  snapshots baked into the shell env (`SurfaceEnvironment.swift:24`). Nothing can rewrite a live
  process's `environ`, so any move makes them stale, and today there is no command that answers "which
  window/workspace owns this session". `AGTERM_WORKSPACE_ID` already goes stale on an ordinary
  `session.move --workspace`, so this is a pre-existing hole this plan closes.
  `control-api.md` also requires a state-setting command to publish its result on the session node, so
  the move command owes this read-back regardless.
- **Integration:** the move is a transfer of one `Session` *instance* between two `AppStore`s.
  `AppStore.moveSession` already keeps the instance alive within a store "so its attached surface and
  live shell survive"; this generalizes that across stores. `WindowLibrary` owns the operation because it
  spans two stores and is where cross-window lookup already lives.

**Scope decisions (locked in planning):**
- Destination must be an **open** window; a closed one is refused with the existing wording
  `window not open — window.select it first`. No auto-open: a closed window has no mounted deck, and
  scene IDs are claimed from a FIFO queue, so the moved surface could land with no host.
- The move does **not** select or raise. A background move stays background, matching
  `session.new --no-select`. `--select` opts into selecting it in the destination.
- GUI surface is the sidebar row menu + command palette. **No cross-window drag** — that stays deferred.

## Context (from discovery)

**Files/components involved:**
- `agtermCore/Sources/agtermCore/AppStore.swift:549` — `moveSession`, the same-instance in-store move.
- `agtermCore/Sources/agtermCore/WindowLibrary.swift:290` — `windowID(forSession:)`, `store(forSession:)`,
  `store(for:)`, and `reopenRecentClosed(_:into:)`, which already inserts into an arbitrary target store.
- `agtermCore/Sources/agtermCore/AppStore+CloseReselection.swift` — reselection when the selected session
  leaves the store.
- `agtermCore/Sources/agtermCore/ControlModes.swift:111` — `ControlSessionMove`.
- `agtermCore/Sources/agtermCore/ControlDispatcher.swift:502` — `dispatchSessionMove`.
- `agtermCore/Sources/agtermCore/ControlProtocol.swift:484,690,794` — `ControlSessionNode`, `ControlTree`,
  `ControlWindowNode`, `ControlResult`.
- `agtermCore/Sources/agtermCore/AppStore.swift:257` — `controlTree`, the tree projection.
- `agtermCore/Sources/agtermctlKit/SessionCommands.swift:150-167` — `session move` CLI validation.
- `agterm/Control/ControlTargetResolver.swift:70` — session resolution scoping.
- `agterm/Control/ControlServer+SessionActions.swift:509` — app-side `moveSession`/`moveSessions`.
- `agterm/Control/ControlServer+AppCommands.swift:10` — `controlTree(window:)`.
- `agterm/Views/WorkspaceSidebar+ContextMenu.swift:102-116,212` — the "Move to" workspace submenu and
  `menuMove`, the pattern the window submenu mirrors.
- `agterm/AppActions.swift:515` — `moveSession`, used by the palette's "Move Session to …" items.

**Related patterns found:**
- `TerminalView.makeNSView` reuses `session.surface` if already set and `dismantleNSView` is a deliberate
  no-op (`agterm/Views/TerminalView.swift:40,91`), so unmounting from one window's deck does not tear down
  the shell.
- `GhosttySurfaceView.viewDidMoveToWindow` (`agterm/Ghostty/GhosttySurfaceView.swift:794`) re-pushes
  `ghostty_surface_set_content_scale` and `ghostty_surface_set_size` for an existing surface; the
  key-window observers are deliberately unfiltered so a re-host survives. Cross-display moves get the
  right backing scale for free. **No new AppKit work is needed for the surface itself.**
- `WindowContentView+Detail.swift` mounts EVERY session of the store in one deck, so the moved session
  unmounts from the source window's `ForEach` and mounts in the destination's.

**Dependencies identified:**
- `TerminalZoomRegistry` (`TerminalZoom.swift:233`) and `DashboardControllerRegistry`
  (`DashboardController.swift:175`) are keyed by `WindowInfo.ID` and can hold the moved session's surface;
  `PickRegistry` is consulted the same way in `ControlServer+SurfaceIO.swift:374`. All three live in
  `agtermCore`, so eviction stays host-free.
- Per-store session-keyed state that must be pruned or transferred: `selectedSessionID`,
  `sidebarSelectionIDs`, `sessionRecency`, `pendingCloseSummary`.
- `--window` is already taken: on `session.move` it scopes where `--target` is *searched*
  (`ControlTargetResolver.resolveSession`), not where the session goes. The destination flag must be
  `--to-window`.

## Development Approach

- **Testing approach**: Regular (code first, then tests)
- Complete each task fully before moving to the next
- Make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional - they are a required part of the checklist
  - write unit tests for new functions/methods
  - write unit tests for modified functions/methods
  - add new test cases for new code paths
  - update existing test cases if behavior changes
  - tests cover both success and error scenarios
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- Run tests after each change
- Maintain backward compatibility

Project-specific rules that bind this plan:
- Model, persistence, parsing, validation, routing, response shaping stay in host-free `agtermCore`; the
  app target is a side-effect adapter (the #78 hoist series). `agtermCore` imports no GhosttyKit or AppKit.
- New protocol fields are OPTIONAL so legacy decode survives without a `Snapshot.version` bump.
- No surface states a command total — adding a command must not require editing a count anywhere.
- Comments stay short and carry only non-obvious constraints.

## Testing Strategy

- **Unit tests**: required for every task. Host-free tests in `agtermCore/Tests/agtermCoreTests/`
  (`WindowLibraryTests`, `AppStoreTests`, `ControlDispatcherTests` + `MockControlActions`,
  `ControlProtocolTests`) and CLI validation tests in `agtermCore/Tests/agtermctlKitTests/CommandsTests`.
- **E2E tests**: `agtermUITests/MultiWindowUITests.swift` and `agtermUITests/ControlAPIUITests.swift` are
  the XCUITest surface. Add the end-to-end move there in the task that completes the control path.
- **Gate discipline**: run `swift test` per task. Run `make test-app` and `make lint` ONCE at the end.
  Scope XCUITest runs with `-only-testing:<Target>/<Class>/<test>` — never re-run a whole suite
  (`ControlAPIUITests` alone is ~82 methods / ~7.5 minutes).

## Progress Tracking

- Mark completed items with `[x]` immediately when done
- Add newly discovered tasks with ➕ prefix
- Document issues/blockers with ⚠️ prefix
- Update plan if implementation deviates from original scope
- Keep plan in sync with actual work done

## What Goes Where

- **Implementation Steps** (`[ ]` checkboxes): code, tests, documentation updates in this repo
- **Post-Completion** (no checkboxes): manual GUI verification and anything needing a running app

## Implementation Steps

### Task 1: Add detach/adopt seam to AppStore

- [x] add `AppStore.detachSession(_ id: UUID) -> Session?` (landed in a new `AppStore+Transfer.swift`;
      `AppStore.swift` is already at the 1000-line limit): removes the instance from
      its workspace WITHOUT tearing down its surface, reselects through the existing close-reselection
      path when it was `selectedSessionID`, prunes `sessionRecency` and `sidebarSelectionIDs`, calls
      `scheduleTreeChanged()` and `save()`; returns nil for an unknown id
- [x] add `AppStore.adoptSession(_ session: Session, toWorkspace: UUID?, at index: Int?, select: Bool) -> Bool`:
      inserts the instance (nil workspace → `currentWorkspaceID`, then `workspaces.last`), optionally
      selects it, `scheduleTreeChanged()` + `save()`; false on an unknown workspace or a duplicate id
- [x] make `detachSession` tolerate emptying a workspace and emptying the whole store (a window with no
      sessions renders "No session selected"; do not seed a replacement)
- [x] write tests for `detachSession` (selected vs unselected source, recency pruned, last-session-in-store,
      unknown id)
- [x] write tests for `adoptSession` (default workspace, explicit workspace, `select:` both ways, unknown
      workspace, duplicate id rejected)
- [x] run `cd agtermCore && swift test` - must pass before task 2

### Task 2: Add WindowLibrary.moveSession across windows

- [ ] add `WindowLibrary.moveSession(_ sessionID: UUID, toWindow: UUID, workspace: UUID?, select: Bool) -> Bool`
      in `WindowLibrary.swift`: resolve the source store via `store(forSession:)`, the destination via
      `store(for:)`; a nil destination store means not open and returns false
- [ ] delegate a same-store call to the existing `AppStore.moveSession` so single-window behavior is
      unchanged and the wire contract does not fork
- [ ] before detaching, evict the session from the SOURCE window's `TerminalZoomRegistry` controller
      (`clear()` when its target is this session) and `DashboardControllerRegistry` controller
      (`close()` when the session is a member) — otherwise the source window keeps a zoom target or grid
      cell pointing at an NSView now hosted by another window
- [ ] refuse the move while the source window has a pending pick for this session (`PickRegistry`),
      mirroring the `pick pending` guard in `ControlServer+SurfaceIO.swift:374`
- [ ] compose detach + adopt, then `saveIndex()` is unnecessary but BOTH stores must persist (each
      `save()`s its own `windows/<id>.json`)
- [ ] write tests for the happy path in `WindowLibraryTests`: the SAME `Session` instance (identity `===`)
      and its `surface` slot survive; source no longer lists it; destination does
- [ ] write tests for error/edge cases: closed destination, unknown session, unknown destination workspace,
      same-window delegation, moving the source's selected session (source reselects), moving the last
      session out of a window
- [ ] write tests for zoom/dashboard eviction (source controller cleared)
- [ ] run `cd agtermCore && swift test` - must pass before task 3

### Task 3: Add the wire contract for a destination window

- [ ] add a `.window(window: String, workspace: String?)` case to `ControlSessionMove` in `ControlModes.swift`
- [ ] add `toWindow: String?` to `ControlArgs` in `ControlProtocol.swift` (optional, legacy decode intact)
- [ ] route it in `ControlDispatcher.dispatchSessionCommand`/`dispatchSessionMove`: `--to-window` is a
      placement intent, may carry an optional destination workspace, and REJECTS `--to` (reorder is
      same-workspace) and `--after`/`--before` (anchors resolve within one store)
- [ ] extend `ControlActions.moveSession`/`moveSessions` signatures and `MockControlActions` for the new case
- [ ] write tests in `ControlDispatcherTests` for routing the new case (single + batch, with and without a
      destination workspace)
- [ ] write tests for the rejection paths (`--to-window` with `--to`, with `--after`, with `--before`)
- [ ] write round-trip tests in `ControlProtocolTests` for `toWindow` encode/decode and legacy-payload decode
- [ ] run `cd agtermCore && swift test` - must pass before task 4

### Task 4: Wire the app-side move

- [ ] handle `.window` in `ControlServer+SessionActions.moveSession` (`:509`): resolve the session with the
      existing `resolver.resolveSession(target, window:)` (so `--window` keeps meaning "search scope"),
      resolve the destination window id through `library.resolveWindow`, then call
      `WindowLibrary.moveSession`
- [ ] return the closed-window error verbatim as `window not open — window.select it first`, and resolve an
      optional destination workspace against the DESTINATION store's workspaces
- [ ] handle `.window` in `moveSessions` for batches, returning `affected` like the other batch paths
- [ ] add an XCUITest in `agtermUITests/MultiWindowUITests.swift`: two windows, move a session across,
      assert both windows' `tree` and that the moved session still answers `session.text`
- [ ] write tests for the resolver paths that stay host-free (destination resolution errors) in
      `ControlDispatcherTests`
- [ ] run `cd agtermCore && swift test`, then the single new UI test with
      `-only-testing:agtermUITests/MultiWindowUITests/<test>` - must pass before task 5

### Task 5: Add --to-window to agtermctl

- [ ] add `--to-window` to `session move` in `agtermCore/Sources/agtermctlKit/SessionCommands.swift`, help
      text naming it a DESTINATION so it cannot be confused with the shared `--window` target scope
- [ ] extend `validate()` (`:150-167`): `--to-window` satisfies the "provide a destination" requirement;
      reject it with `--to`/`--after`/`--before`; allow it with a positional workspace (the destination
      workspace INSIDE the target window)
- [ ] populate `ControlArgs.toWindow` in `makeRequest()`
- [ ] write validation tests in `agtermctlKitTests/CommandsTests` for each accepted and rejected combination,
      pinning the exact error strings the way the existing move cases are pinned (`:269`, `:273`)
- [ ] write a test that a bare `--window` still fails with the unchanged
      `provide a destination workspace, --to, or --after/--before` message
- [ ] run `cd agtermCore && swift test` - must pass before task 6

### Task 6: Publish window/workspace ownership on the session node

- [ ] add optional `windowId` and `workspaceId` to `ControlSessionNode` in `ControlProtocol.swift`
- [ ] add optional `windowId` to `ControlTree` — the tree is already a single-window projection and never
      said which one
- [ ] add a `windowID: String?` parameter to `AppStore.controlTree` (`AppStore.swift:257`) and stamp it on
      every session node; `workspaceId` comes from the workspace already being iterated, so no new lookup
- [ ] pass it from `ControlServer.buildTree(in:)` via `library.windowID(for: store)`
- [ ] render both in `agtermctl tree`'s human output only where it earns the line (window id on the tree
      header, not repeated per row)
- [ ] write tests that `controlTree` stamps `windowId`/`workspaceId` on every node and that a
      host-produced tree with no window id omits them
- [ ] write decode tests proving a payload without the new fields still decodes (legacy server skew)
- [ ] run `cd agtermCore && swift test` - must pass before task 7

### Task 7: Add tree --all-windows

- [ ] add `allWindows: Bool?` to `ControlArgs` and `trees: [ControlTree]?` to `ControlResult`
- [ ] `ControlDispatcher` rejects `--all-windows` together with `--window` (one names a single window, the
      other means every one)
- [ ] implement it in `ControlServer.controlTree(window:)`: build one tree per OPEN window via
      `library.openIDs()`, each tagged with its `windowId`; populate `trees`, leaving `tree` nil
- [ ] add `--all-windows` to the `tree` CLI command with human rendering that prints each window's name and
      id as a section header above its workspace tree
- [ ] write tests for the mutual-exclusion error and for the multi-window projection shape
- [ ] write tests that each returned tree carries the right `windowId` and that closed windows are absent
- [ ] run `cd agtermCore && swift test` - must pass before task 8

### Task 8: Add the GUI entry points

- [ ] add a "Move to Window" submenu in `agterm/Views/WorkspaceSidebar+ContextMenu.swift`, built like the
      existing "Move to" workspace submenu (`:106-116`): list OTHER open windows by name, omit the submenu
      entirely when there is no other open window
- [ ] reuse `SessionBatchRequest` so multi-selection moves as one block, and route the action through
      `AppActions` (which owns cross-window concerns) rather than the window-local `store`
- [ ] add `AppActions.moveSession(_:toWindow:)` and a batch form beside the existing
      `moveSession(_:toWorkspace:)` (`AppActions.swift:515`), delegating to `WindowLibrary.moveSession`
- [ ] add "Move Session to Window …" palette entries beside the existing "Move Session to …" items,
      gated on there being another open window
- [ ] write host-free tests for the palette entry's visibility gate in `PaletteCatalogTests`
- [ ] write tests for the `AppActions` delegation where it is host-free; note in the plan if the AppKit
      submenu itself is manual-verification only
- [ ] run `cd agtermCore && swift test` - must pass before task 9

### Task 9: Verify acceptance criteria

- [ ] verify all requirements from Overview are implemented: cross-window move preserves the live shell,
      destination must be open, no raise/select without `--select`, ownership readable in one call
- [ ] verify edge cases: last session out of a window, moving the selected session, zoomed session,
      dashboard member, session with a shown split, session with an open overlay or scratch
- [ ] verify `--window` semantics are UNCHANGED on every command that takes it
- [ ] run full test suite (`cd agtermCore && swift test`)
- [ ] run `make test-app`
- [ ] run `make lint` - zero findings required
- [ ] verify test coverage meets project standard

### Task 10: [Final] Update documentation

- [ ] `.claude/rules/windows.md` — amend the "cross-window session drag is out of scope" line: a MOVE is
      supported and keeps 1:1; DRAG remains out of scope
- [ ] `.claude/rules/control-api.md` — `session.move` placement intents now include `--to-window`;
      document `tree --all-windows` and the new node fields; note that `--window` stays a search scope
- [ ] `.claude/rules/sidebar.md` — the row menu's new submenu
- [ ] `plugins/agterm/skills/agterm/` (`SKILL.md`, `reference.md`, `examples.md`) — the sole source for
      installed Claude/Codex copies: demote `AGTERM_WINDOW_ID`/`AGTERM_WORKSPACE_ID` to spawn-time hints
      that go stale on any move, point at `tree --all-windows` as the source of truth, and note that
      passing a stale `--window` turns a working command into `no such session`
- [ ] `site/commands.html` — mirror the new argument, the new flag, and the new read-back fields
- [ ] `site/docs.html` — the user-facing description of moving a session between windows
- [ ] confirm NO surface states a command total (the rule that keeps a new command off every page)

*Note: ralphex automatically moves completed plans to `docs/plans/completed/`*

## Technical Details

**Move semantics on the wire:**

```
session.move --target <session> --to-window <window> [<workspace>] [--select]
```

- `--target` resolves as today: `active` against the frontmost store, an id/prefix across ALL open stores.
- `--window` (unchanged) narrows where `--target` is searched.
- `--to-window` names the destination; the optional positional workspace names the destination workspace
  INSIDE that window, defaulting to its `currentWorkspaceID`.
- Rejected combinations: `--to-window` with `--to`, `--after`, or `--before`.

**Ownership read-back:**

```
agtermctl tree --json --all-windows | jq -r --arg s "$AGTERM_SESSION_ID" '
  .result.trees[] | . as $t | .workspaces[] | . as $w | .sessions[]
  | select(.id == $s) | {window: $t.windowId, workspace: $w.id}'
```

**Why `window.list` is not the place for this:** `control-api.md` states the window list is cached and
refreshed on specific events; a live session tree hung off it would go stale between commands. That is the
same reason `idleMs` is tree-only.

**What is NOT needed:** any change to `GhosttySurfaceView` or `TerminalView`. The surface already survives
a re-host — `dismantleNSView` is a no-op, `makeNSView` reuses `session.surface`, and
`viewDidMoveToWindow` re-pushes scale and size. If a move produces a blank or mis-scaled pane, that is a
bug to investigate in the deck mount order, not a signal to add teardown.

## Post-Completion

*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification** (needs a Debug instance with an isolated `AGTERM_STATE_DIR` and short socket —
never the default socket, never the deployed app):
- move a session running an interactive TUI (`htop`, a Claude Code session) between windows on the SAME
  display; confirm output continues and input still reaches it
- move between windows on displays with DIFFERENT backing scale factors; confirm the terminal re-rasterizes
  at the destination scale rather than staying blurry or clipped
- move a session with a shown split and a set divider ratio; confirm both panes survive and the ratio holds
- move a session with an open overlay and one with an active scratch
- move the currently selected session out of a window and confirm the source reselects sensibly
- move the last session out of a window and confirm it renders "No session selected" rather than crashing
- confirm the sidebar submenu is absent with only one window open
- quit and relaunch; confirm the moved session restores in its NEW window

**Known accepted limitation to communicate:**
- a moved session's already-running shell keeps its original `AGTERM_WINDOW_ID`/`AGTERM_WORKSPACE_ID`.
  Nothing can rewrite a live process's environment. Newly spawned panes get correct values; existing
  shells must query `tree --all-windows`. This is documented in the skill, not worked around.
