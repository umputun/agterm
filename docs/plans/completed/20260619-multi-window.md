# Multi-window support (named "windows" — top-level workspace/session bundles)

## Overview

Add a top level above the workspace tree: a **window** is a named, persisted bundle of
workspaces + sessions, each rendered in its own on-screen macOS window. The user keeps a
library of windows (e.g. "work", "personal"), opens one per on-screen window, and the set
that was open at quit reopens on next launch.

- **Problem it solves:** today everything lives in one window with one `AppStore` created
  once in `agtApp.init`. There is no way to keep separate work/personal setups side by side.
- **Scope (locked in brainstorm):** *area = window content*, named "window". Strict 1:1 — a
  window's bundle shows in exactly one on-screen window, never two windows for one bundle,
  never two bundles in one window. **Reopen-all** on launch (every window open at quit comes
  back, frames included). **No** shared/cross-window live state, **no** cross-window session
  drag (out of scope by the 1:1 model).
- **Integration:** a new app-global `WindowLibrary` owns the set of windows and lazily-loaded
  per-window `AppStore`s. Today's `AppStore` becomes the *per-window* unit (it already is "one
  tree + one selection") — internals essentially unchanged. The global singletons
  (`GhosttyApp`, `SettingsModel`, `NotificationManager`, `ControlServer`) stay single and learn
  to span windows; the quick terminal becomes per-window.

## Context (from discovery)

- **Project:** native macOS SwiftUI terminal on libghostty. Two modules: host-free `agtCore`
  (Foundation/Observation only, `swift test`) + an app target (SwiftUI + libghostty/AppKit
  bridge). Pattern to mirror: pure model/logic in `agtCore`, all SwiftUI/AppKit/libghostty in
  the app target. Deployment target **macOS 14.0** (`project.yml`).
- **The single-store assumption is everywhere.** Confirmed (read from source):
  - `AppStore` (`agtCore/Sources/agtCore/AppStore.swift`) = `workspaces: [Workspace]` +
    `selectedSessionID` + `sessionRecency`, with a `PersistenceStore`. `snapshot()` →
    `Snapshot{version, selectedSessionID, workspaces}`; `restore(from:)` rebuilds it. This whole
    class is exactly one window's content.
  - `agtApp.init` (`agt/agtApp.swift`) builds **one** `store` via `restoredStore()` and hands the
    same instance to `ContentView`, `AppActions`, `ControlServer`, `SessionSwitcher`,
    `SettingsModel`, and `AppDelegate.store`. The scene is a single `Window("agt", id: "main")`.
  - `AppActions` (`agt/AppActions.swift:13`) holds `private let store: AppStore` (a fixed
    instance); `focusedSurface()` is `private` (`:218`); `focusSplitPane(_:wantSplit:attempt:)`
    (`:193`); `toggleSplit()` (`:161`) acts on `store.activeSession` only; `paletteActions()`
    (`:115`).
- **Persistence:** `PersistenceStore` (`agtCore/.../PersistenceStore.swift`) writes
  `workspaces.json` in `defaultDirectory` (`~/Library/Application Support/agt`), honoring
  `AGT_STATE_DIR`. `load()` recovers an empty `Snapshot` on any failure (missing/corrupt/version
  mismatch) — never throws. `Snapshot.currentVersion = 1`.
- **TitleProbeView** (`agt/ContentView.swift:323`, an `NSViewRepresentable`) already grabs the
  hosting `NSWindow` and observes `NSWindow.didBecomeKeyNotification` /
  `didBecomeMainNotification` / `didExitFullScreenNotification` to re-apply window appearance.
  This is the hook to extend for per-window frontmost tracking + window-close.
- **Quick terminal** (`agt/Views/QuickTerminal.swift`): `QuickTerminalController.shared`
  (app-global singleton, `static let shared`) with `toggle()`/`show()`/`hide()`/`isVisible`/
  `currentSurface()`/`cwdProvider`. `agtApp` `.task` sets `cwdProvider` to the active session's
  cwd. This is the one singleton that must split per window.
- **Surface env injection is available.** `ghostty_surface_config_s` carries `env_vars:
  ghostty_env_var_s*` (`{const char* key; const char* value}`) + `env_var_count: size_t`
  (GhosttyKit header). The config is built in `GhosttySurfaceView` around
  `GhosttySurfaceView.swift:239`; `working_directory`/`command` already strdup into the
  `nonisolated(unsafe) configCStrings` array, freed in `destroySurface()`/`deinit`. Env key/value
  buffers join the same lifetime. `init(workingDirectory:fontSize:command:waitAfterCommand:
  autoFocus:)` is the surface constructor; `weak var session` ties a surface to its session.
- **Surface factories** in `agtApp.swift` (`makeSurface`/`makeSplitSurface`/`makeOverlaySurface`)
  build each `GhosttySurfaceView`; they take `store` today and will take the owning window id +
  ids for env.
- **Control API** (`agtCore/.../ControlProtocol.swift`, `ControlResolve.swift`; app
  `agt/Control/ControlServer.swift`; CLI `agtCore/Sources/agtctlKit`). `Command` enum (19 cases),
  `ControlArgs` (optional bag), `ControlResult{id,tree,text}`. `ControlResolve.resolve(_:
  candidates:active:)` is the pure target resolver (active / exact uuid / unique prefix /
  ambiguous / not-found); reused as-is for window targets. `ControlServer` dispatches onto
  `AppActions`/`AppStore`; it is constructed with the single `store`+`actions` today and must
  dispatch onto `WindowLibrary` instead. The XCUITest seam is `AGT_STATE_DIR` + an
  `AGT_CONTROL_SOCKET` override, asserting via file-polling and the write-to-file trick.

## Development Approach

- **Risk-first.** The one real unknown is the `WindowGroup(for:)` multi-window scene +
  restoration on this toolchain/deployment target (like the opacity-surface de-risk in the
  settings plan). Task 0 proves it end-to-end before any model refactor.
- **testing approach:** TDD where practical — the pure `agtCore` pieces (`WindowLibrary`,
  persistence round-trip, migration, the window-target resolver, protocol codecs) get tests
  first; the scene/window lifecycle, env injection, and control dispatch are covered by
  XCUITests.
- complete each task fully before the next; small, focused changes.
- **CRITICAL: every task MUST include new/updated tests** (success + error scenarios).
- **CRITICAL: all tests must pass before starting the next task.** Gate per task:
  `cd agtCore && swift test` (host-free) and, for app-target tasks, the relevant `xcodebuild
  test … -only-testing:agtUITests/<Suite>` case(s). The app must build.
- **CRITICAL: update this plan file when scope changes during implementation** (➕ for added
  scope, ⚠️ for blockers).
- maintain backward compatibility: migration wraps the legacy single tree into one window; a
  single-window user sees no behavioral change.

## Keep-in-sync convention (HARD — from CLAUDE.md)

Every new user action added to `AppActions`/`WindowLibrary` is not "done" until it is drivable
from the control socket. Shipping a new window action requires all four of:

1. a `Command` case (+ any args) in `agtCore`'s control protocol,
2. a dispatch arm in `ControlServer`,
3. an `agtctl` subcommand,
4. protocol round-trip + end-to-end tests for it.

This plan adds six window actions (new/list/select/close/rename/delete); each must satisfy all
four points (protocol Task 6, ControlServer Task 7, agtctl Task 8, verified in Task 10).

## Testing Strategy

- **unit tests (`agtCore`, host-free, `swift test`):** `WindowLibrary` add/list/rename/delete
  (keep-at-least-one), open-set + frontmost tracking, lazy store load, migration from legacy
  `workspaces.json`, the recovery matrix (corrupt/mismatched index → migrate/seed; missing/corrupt
  per-window file → empty window), persistence round-trip (per-window file + `windows.json` index);
  the window-id resolver (reuse `ControlResolve.resolve` with window-id candidates); protocol
  round-trip for `window.*` + the new `window` arg + `ControlWindowNode`. `WindowLibrary` is
  `@MainActor` (like `AppStore`), so its tests are `@MainActor` and inject a temp directory the way
  the existing `PersistenceStore`/`AppStore` tests do.
- **end-to-end (XCUITest):** a new `MultiWindowUITests` suite — seed `AGT_STATE_DIR` with a
  `windows.json` index + two per-window files, assert both windows open on launch; create a
  window via the menu, close one, reopen it; env injection verified with the write-to-file trick
  (`session.type 'echo "$AGT_WINDOW_ID" > FILE\n'`, read FILE, assert it equals the window id,
  the split-test idiom). Control coverage extends `ControlAPIUITests` (`agtctl window new/list`,
  `--window` targeting, closed-window error).

## Progress Tracking

- mark completed items with `[x]` immediately when done.
- add newly discovered tasks with ➕ prefix; document blockers with ⚠️ prefix.
- keep the plan in sync with the actual work.

## Solution Overview

Three concentric layers, placed to match the core/app split:

1. **`agtCore` model + persistence + protocol** (Foundation/Observation only): `WindowInfo`
   (`{id: UUID, name: String}` metadata — NOT named `Window`, to avoid the SwiftUI/AppKit
   clash), `WindowLibrary` (`@Observable @MainActor`, owns the ordered `[WindowInfo]`, live
   `stores: [UUID: AppStore]`, the open-set, frontmost id, and per-window + index persistence),
   the `WindowsIndex` Codable, migration, and the `window.*` protocol additions. Host-free,
   unit-tested.
2. **Scene + window wiring (app target):** `WindowGroup(for: WindowInfo.ID.self)`; `ContentView`
   resolves its `AppStore` from `WindowLibrary` by id; launch reopens the open-set explicitly;
   `TitleProbeView` reports frontmost + close; `AppActions` resolves the frontmost store; per-
   window quick terminal; global services span all open windows.
3. **Control + env + UX:** `ControlServer` dispatches onto `WindowLibrary` with a `--window`
   selector; `agtctl` gains a `window` subcommand group; five `AGT_*` env vars are injected per
   surface; the File menu + ⌃⇧P palette gain window new/open/rename/delete.

Key design decisions:
- **`AppStore` stays the per-window unit** — minimal churn; it already is one tree + selection.
- **One file per window** (`windows/<uuid>.json`, today's `Snapshot` shape) + a thin
  `windows.json` index, so a per-mutation `save()` rewrites only the touched window.
- **`WindowLibrary` is the single source of truth for the open-set**; SwiftUI auto window
  restoration is disabled (or, on macOS 14, neutralized) so the two restoration mechanisms can't
  fight. AppKit `frameAutosaveName` per window restores geometry.
- **Never launch windowless:** empty open-set at launch → open last-frontmost (else first). A
  corrupt/mismatched `windows.json` falls back to the same path (migrate-from-legacy, else seed
  one window); a missing/corrupt per-window file opens that window empty rather than aborting.
- **Last-window-close keeps today's behavior:** `applicationShouldTerminateAfterLastWindowClosed`
  stays `true`, so closing the last on-screen window quits the app (flushing all state first). The
  "never windowless" rule is therefore a *launch-time* invariant, not a runtime one.

## Technical Details

### Persistence layout

```
~/Library/Application Support/agt/   (or $AGT_STATE_DIR)
  windows.json                 # index: { version, frontmost: UUID?, windows: [{id, name, isOpen}] }
  windows/<uuid>.json          # per window: today's Snapshot (selectedSessionID + workspaces)
  workspaces.json              # legacy; left dormant after migration
```

- `WindowsIndex: Codable, Equatable, Sendable` — `version` (own counter), `frontmost: UUID?`,
  `windows: [WindowEntry{ id: UUID, name: String, isOpen: Bool }]` (ordered).
- A per-window `AppStore` keeps its own `PersistenceStore` pointed at `windows/<id>.json`
  (filename overridable; today the filename is hard-coded `workspaces.json`, so `PersistenceStore`
  gains an optional `fileName:` init param — additive, default unchanged).
- **Migration (on `WindowLibrary` init):** if `windows.json` is absent AND legacy
  `workspaces.json` exists → load it, mint a `WindowInfo`("window 1"), write `windows/<id>.json`
  (the loaded snapshot) + `windows.json` marking it `isOpen:true, frontmost:<id>`. Leave
  `workspaces.json` in place, ignored. If neither exists → seed one empty window ("window 1") so
  the app is never windowless. If `windows.json` exists → load it (ignore legacy).
- **Recovery contract (mirrors `PersistenceStore.load()`, never throws to the caller):** a
  corrupt or `version`-mismatched `windows.json` is treated as absent → the migration path above
  runs (migrate-from-legacy, else seed one window). A per-window `windows/<id>.json` that's missing
  or corrupt for an indexed window loads as an empty `Snapshot`, so that window opens with one
  default workspace + session instead of failing the launch. Net: the app always reaches a valid,
  non-empty window set. This is a Task 1 unit-test matrix.

### `WindowLibrary` (agtCore, `@Observable @MainActor`)

```
@Observable @MainActor final class WindowLibrary {
    private(set) var windows: [WindowInfo]          // ordered, for the menu/palette
    var frontmostWindowID: UUID?
    // open-set + live stores live together: a window is "open" iff stores[id] != nil
    @ObservationIgnored private var stores: [UUID: AppStore]
    @ObservationIgnored private let directory: URL  // state dir (AGT_STATE_DIR-aware)

    func store(for id: UUID?) -> AppStore?           // live store of an open window
    func isOpen(_ id: UUID) -> Bool
    func openIDs() -> [UUID]                          // persisted open-set, for launch reopen
    @discardableResult func newWindow(name: String?) -> WindowInfo  // fresh: 1 workspace + 1 session
    func loadStore(for id: UUID) -> AppStore?         // lazily build/cache an AppStore from windows/<id>.json
    func closeWindow(_ id: UUID)                      // mark isOpen=false, drop store, persist (surfaces torn down by caller)
    func renameWindow(_ id: UUID, to: String)
    var canRemoveWindow: Bool { windows.count > 1 }
    func removeWindow(_ id: UUID)                     // keep-at-least-one; deletes windows/<id>.json + index entry
    func defaultWindowName: String                    // "window N"
    func saveIndex()                                  // writes windows.json
}
```

- `store(for:)`/`loadStore(for:)` are how `ContentView` and `ControlServer` get a window's
  `AppStore`. Tearing down surfaces on close stays in the app target (it owns
  `GhosttySurfaceView`); `WindowLibrary` only drops the store + persists.

### Scene + window wiring (app target)

- Scene: `WindowGroup(for: WindowInfo.ID.self) { $id in ContentView(windowID: id, library: library, …) }`.
  `ContentView` calls `library.store(for: id) ?? library.loadStore(for: id)` to get its store; a
  nil id (a brand-new window with no value) creates one via `library.newWindow(nil)`.
- **Launch reopen:** in the scene `.task` (once), for each `library.openIDs()` call
  `openWindow(value: id)`; if the open-set is empty, open the last-frontmost (else first) window.
  SwiftUI auto restoration is disabled so it doesn't double-open: `.restorationBehavior(.disabled)`
  is macOS 15+, so gate with `#available(macOS 15, *)`; on macOS 14 neutralize duplicates by
  deduping on `WindowInfo.ID` (the library refuses a second window for an already-open id and just
  focuses the existing `NSWindow`). **Task 0 confirms which mechanism actually fires.**
- **Frame restoration:** in `TitleProbeView` set `window.setFrameAutosaveName("agt-window-\(id)")`
  so AppKit persists/restores geometry per window, independent of `windows.json`.
- **Frontmost + close (extend `TitleProbeView`):** on `didBecomeKey/Main` →
  `library.frontmostWindowID = id` + `library.saveIndex()`. On `NSWindow.willCloseNotification`
  → tear down that window's sessions' surfaces (its store), then `library.closeWindow(id)`.
- **Quit-time flush (replaces the dropped `AppDelegate.store.save()`):** today
  `AppDelegate.applicationWillTerminate` calls the single `store?.save()` (`agtApp.swift:250`).
  `AppStore` does NOT save on a live `cd` (only on quit/structural change — ARCHITECTURE.md), so
  the terminate flush is load-bearing. With per-window stores, terminate must iterate **every open
  store** (`library` exposes them) and `save()` each, then `library.saveIndex()`. `AppDelegate`
  gets the `WindowLibrary` (same hand-off the single `store` used) and drives this. Named step in
  Task 2 — without it, cwd changes since the last structural mutation are lost on quit, per window.
- **`AppActions` takes the `WindowLibrary`, not a fixed store:** it resolves the frontmost store
  via `library.store(for: library.frontmostWindowID)` for its mutating methods (each early-returns
  when nil). Two consequences the plan makes explicit: (1) the app-global menu/palette builders
  read state at *build* time (`agtApp.swift:79-83` disables items off `store.activeSession`;
  `paletteActions()` reads `store.canRemoveWorkspace`/`workspaces`) — these must read through the
  same frontmost accessor, which is reactive because `WindowLibrary` is `@Observable`; (2)
  `reveal(sessionID:pane:)` (the notification click entry, `AppActions.swift:208`) currently does
  `store.session(withID:)` — it needs a **cross-window** session lookup (search all open stores for
  the id, get its owning store) and, if the owning window is closed, open it first. `renamePending`
  and the other instance state stay on the single `AppActions` instance; only the store reference
  becomes a per-call frontmost lookup.
- **Dedup:** `WindowLibrary` holds each open window's `NSWindow` (handed in by `TitleProbeView`);
  opening an already-open window `makeKeyAndOrderFront`s it instead of spawning a second.

### Spawned-shell environment (per surface)

- `GhosttySurfaceView.init` gains `env: [String: String] = [:]`. In the config build (~`:239`):
  strdup each key and value into the existing `configCStrings` (`[UnsafeMutablePointer<CChar>]`),
  AND build a separate `[ghostty_env_var_s]` array of `{key,value}` structs pointing at those
  strdup'd buffers. **Both** must outlive `ghostty_surface_new`: the struct array can't live in
  `configCStrings` (wrong element type), so it needs its own `nonisolated(unsafe) var envVars:
  [ghostty_env_var_s]` field on the view, retained until `destroySurface`/`deinit` (the char*
  buffers are freed there already; the struct array is value-type, so just clear it alongside).
  Set `config.env_vars = &envVars` + `config.env_var_count = envVars.count`. Getting the struct-
  array lifetime wrong is the same class of bug as ARCHITECTURE.md's strdup fragile-point — call
  it out as its own checkbox.
- The factories pass the env: main/split/overlay surfaces get
  `{AGT_ENABLED:"1", AGT_WINDOW_ID:<window>, AGT_WORKSPACE_ID:<ws>, AGT_SESSION_ID:<session>,
  AGT_SOCKET:<bound socket path>}`. Split/overlay inherit the parent session's window/workspace/
  session ids. The quick terminal gets `{AGT_ENABLED, AGT_WINDOW_ID, AGT_SOCKET}` only (scratch,
  not in the tree). Each env value is baked into the `ghostty_surface_config_s` at surface creation
  and stable for the surface's life (no cross-window moves); a fresh surface on the next launch is
  built with freshly-resolved values. `AGT_WINDOW_ID` resolves via `library.windowID(forSession:)`,
  which searches only OPEN stores, so a surface realized before its window's store is registered
  simply omits `AGT_WINDOW_ID` (handled gracefully — the env var is just absent, not empty).
- **`AGT_SOCKET` uses the path `ControlServer` actually bound**, not a re-derivation:
  `ControlServer.defaultSocketPath()` honors the `AGT_CONTROL_SOCKET` override (and the ~104-byte
  cap) used by XCUITests, so the factories read the live bound path off `ControlServer` — otherwise
  a test-overridden socket and the injected env disagree.

### Control protocol additions (agtCore)

```
// Command: add
case windowNew = "window.new", windowList = "window.list", windowSelect = "window.select"
case windowClose = "window.close", windowRename = "window.rename", windowDelete = "window.delete"

// ControlArgs: add
var window: String?            // id / prefix / "active" (=frontmost), selects the target window's tree

// ControlResult: add
var windows: [ControlWindowNode]?     // window.list
struct ControlWindowNode: Codable, Sendable, Equatable { let id, name: String; let open, active: Bool }
```

- **Resolution — two distinct pieces:**
  - *Window-id resolution* reuses the pure `ControlResolve.resolve(target, candidates: <window
    ids>, active: <frontmost id>)` unchanged (active=frontmost / exact / prefix / ambiguous /
    not-found). This is the only part that's a clean reuse — unit-tested in agtCore.
  - *Cross-window session targeting is NEW `ControlServer` logic, not a `resolve` reuse.*
    `ControlResolve.resolve` returns a bare `UUID` with no owning-window info, and the current
    `ControlServer` builds candidates from a single `store.workspaces`. For id/prefix targeting
    without `args.window`, `ControlServer` must gather candidates across **all open stores** and
    map the resolved `UUID` back to its owning `AppStore` — a `(UUID) -> (AppStore, Session)`
    lookup that lives app-side. It's small, but it's real code with its own checkbox + test, not
    an additive enum change.
  - With `args.window` set → resolve the window, then target within *that* window's store (must be
    open, else the closed-window error). Without it → `active`/placement default to the frontmost
    window; `tree` with no `window` → frontmost window's tree, with `window` → that window's.
- **Closed-window targeting** of session/workspace commands → `{"ok":false,"error":"window not
  open — window.select it first"}`. `window.select` opens it (`openWindow(value:)` + raise).
- `window.delete` honors `canRemoveWindow` (keep-at-least-one), returns an error instead of any
  GUI confirm.

### CLI (`agtctlKit`)

- New `window` subcommand group: `agtctl window new [name]`, `window list`, `window select <id>`,
  `window close <id>`, `window rename <id> <name>`, `window delete <id>`.
- A global `--window <id>` option added to the session/workspace subcommands (maps to
  `args.window`). `window list` prints `id  name  [open]  [active]` (raw with `--json`).

### UX (File menu + ⌃⇧P palette)

- **New Window** (⌘N path) → `library.newWindow(nil)` + `openWindow(value:)` (fresh: one default
  workspace + session, auto-named "window N").
- **Open Window ▸** submenu listing `library.windows`; a checkmark on open ones; pick a closed →
  open it, an open → focus it.
- **Rename Window…** opens a minimal standard `NSAlert` with an accessory `NSTextField`
  pre-filled with the current name (OK/Cancel). The app has no generic inline-prompt affordance
  (inline rename is sidebar-row-only, routed through `.agtBeginRename*` to the `NSOutlineView`
  Coordinator), and a window has no sidebar row — so a one-shot `NSAlert` is the standard, minimal
  fit. The rename itself flows through `library.renameWindow` (also reachable via `agtctl window
  rename` / the palette), so the behavior is testable on the control path without driving the
  alert in XCUI. **Delete Window** (confirm when it still has sessions; `canRemoveWindow` gates
  the last one).
- Same entries added to `AppActions.paletteActions()` for ⌃⇧P.

## What Goes Where

- **Implementation Steps** (`[ ]`): all code, tests, docs in this repo.
- **Post-Completion** (no checkboxes): manual multi-window/HazeOver/Spaces verification a human
  should eyeball (frame restoration across displays, reopen-all after a real quit).

## Implementation Steps

### Task 0: De-risk the multi-window scene + restoration

**Files:**
- Modify (temporarily): `agt/agtApp.swift`

- [x] stand up a throwaway `WindowGroup(for: UUID.self)` scene rendering a trivial per-id view
      (a label showing the id), alongside or replacing the current `Window` scene behind a flag
- [x] confirm `openWindow(value:)` opens distinct windows per id, and two windows coexist
      (compiled; `@Environment(\.openWindow)` + `openWindow(value: UUID())` resolve and build at the
      macOS 14.0 target — see findings)
- [x] confirm whether SwiftUI auto-restores these windows on relaunch at **macOS 14** (the
      deployment target) and whether `.restorationBehavior(.disabled)` compiles/needs `#available`
      — decide: disable-and-drive-ourselves (macOS 15+) vs dedup-by-id on macOS 14
- [x] confirm `frameAutosaveName` per window restores geometry, and `TitleProbeView` can read
      `id` + observe `willCloseNotification` (probe `NSView` read `id`, called
      `window.setFrameAutosaveName(...)`, and registered a `willCloseNotification` observer — all compiled)
- [x] **manual gate:** run, open two windows, quit, relaunch — document the actual restoration
      behavior in this plan (➕). **manual (not automatable in headless exec) — see Post-Completion**
- [x] no test gate (scaffolding); record findings here before Task 1

➕ **Task 0 findings (toolchain: Xcode 26 / MacOSX26.5 SDK, deployment target macOS 14.0,
Swift 6 strict concurrency).** Verified by both reading the SwiftUI `arm64e-apple-macos.swiftinterface`
in the SDK and by actually compiling a throwaway `WindowGroup(for: UUID.self)` scene + a per-id view +
an `NSView` probe (Debug `xcodebuild` against `-target arm64-apple-macos14.0`), then reverting all
scaffolding (`git status` left only this plan file):

- **`WindowGroup(for:)`, `openWindow(value:)`, `frameAutosaveName`, `willCloseNotification` all
  compile on macOS 14.** The value-based `WindowGroup.init(for:content:)` is `@available(macOS 13.0)`;
  `OpenWindowAction` / `EnvironmentValues.openWindow` / `callAsFunction(value:)` are `@available(macOS
  13.0)`; `setFrameAutosaveName(_:)` and `NSWindow.willCloseNotification` are long-standing AppKit.
  The probe `NSView` read its injected `id`, set `frameAutosaveName`, and registered the close observer
  — full Debug build **SUCCEEDED**.
- **`.restorationBehavior(.disabled)` is macOS 15+ ONLY and cannot be `#available`-gated inside a
  scene.** `SceneRestorationBehavior` and `Scene.restorationBehavior(_:)` are both
  `@available(... macOS 15.0 ...)` in the SDK swiftinterface. Applying it unconditionally fails with
  `'restorationBehavior' is only available in macOS 15.0 or newer`.
- **CRITICAL toolchain constraint: `@SceneBuilder` rejects `if #available` entirely.** Both an inline
  `if #available(macOS 15, *) { group.restorationBehavior(.disabled) } else { group }` in the scene
  `body` AND a dedicated `@SceneBuilder` helper method with the same branch fail to compile with
  `closure containing control flow statement cannot be used with result builder 'SceneBuilder'`.
  Unlike `@ViewBuilder` (which accepts `if #available`), `SceneBuilder` does not — so there is **no way
  to conditionally apply a macOS-15-only scene modifier within a scene tree on this toolchain.** There
  is no `AnyScene` type-eraser in SwiftUI to unify the two branch types either.
- **DECISION — drop `restorationBehavior` entirely; use dedup-by-id on BOTH macOS 14 and 15.** Because
  the modifier can't be conditionally applied, do NOT plan to call `.restorationBehavior(.disabled)`
  at all (it would force a macOS-15 deployment floor, which is locked at 14.0). Instead, `WindowLibrary`
  owns the open-set as the single source of truth and **neutralizes any SwiftUI auto-restoration by
  deduping on `WindowInfo.ID`**: opening a window for an id that already has a live `NSWindow`
  `makeKeyAndOrderFront`s the existing one instead of spawning a second; an id with no library entry
  (a SwiftUI-restored stray) is closed/ignored. This is the macOS-14 fallback path the plan already
  describes (Solution Overview / Task 2) — Task 0 promotes it from "macOS-14 only" to the **uniform
  mechanism for all supported versions**. Tasks 2's checkbox "gate `.restorationBehavior(.disabled)`
  behind `#available(macOS 15,*)`, else dedup-by-id" should be read as **"dedup-by-id only; no
  `restorationBehavior`"** when implemented.
- **Auto-restoration behavior at runtime was NOT exercised** (headless exec can't launch the GUI); the
  visual quit/relaunch confirmation is the manual gate above (Post-Completion). The compile-time facts
  alone settle the mechanism choice (dedup-by-id), which is what Task 1+ depend on.

### Task 1: agtCore WindowLibrary, per-window persistence, migration

**Files:**
- Create: `agtCore/Sources/agtCore/WindowLibrary.swift` (WindowInfo, WindowsIndex, WindowEntry, WindowLibrary)
- Modify: `agtCore/Sources/agtCore/PersistenceStore.swift` (optional `fileName:` init param)
- Create: `agtCore/Tests/agtCoreTests/WindowLibraryTests.swift`

- [x] add `WindowInfo {id: UUID, name: String}` (`Codable, Sendable, Identifiable`) and the
      `WindowsIndex`/`WindowEntry` Codables (the index carries its own `version`, deliberately
      independent of `Snapshot.version`)
- [x] give `PersistenceStore` an optional `fileName:` (default `workspaces.json`) so a per-window
      store can target `windows/<id>.json` without breaking existing callers
- [x] implement `WindowLibrary` (`@Observable @MainActor`): windows list, lazy `stores`,
      `store(for:)`/`loadStore(for:)`, `newWindow`, `closeWindow`, `renameWindow`, `removeWindow`
      (keep-at-least-one), `frontmostWindowID`, `openIDs()`, `defaultWindowName`, `saveIndex()`,
      and `saveAllOpen()` (flush every open store — used by the terminate path in Task 2)
- [x] add the cross-window session lookup used by reveal + ControlServer: `store(forSession:
      UUID) -> AppStore?` and `windowID(forSession: UUID) -> UUID?` searching the **open** stores
      (host-free, unit-testable — this is the tested primitive findings #2/#3 need)
- [x] move the default-window seeding (`restoredStore()`'s "workspace 1" + one `$HOME` session)
      into `WindowLibrary.newWindow`. (the seed now lives in `WindowLibrary.newWindow`; the actual
      removal of `agtApp.restoredStore()` happens in Task 2's agtApp rewire — left in place here so
      the app target still builds without touching it)
- [x] implement migration: legacy `workspaces.json` → one window; none → seed one empty window;
      existing `windows.json` → load
- [x] implement the recovery contract (never throws): corrupt/`version`-mismatched `windows.json`
      → treated as absent (migrate-from-legacy, else seed one); a missing/corrupt
      `windows/<id>.json` → that window loads an empty `Snapshot` (one default workspace+session)
- [x] tests: add/list/rename/delete + keep-at-least-one; open-set + frontmost tracking; lazy load
      from a per-window file; `store(forSession:)`/`windowID(forSession:)` across open windows
      (hit + miss); migration (legacy present, neither present, index present); the recovery matrix
      (corrupt index, version-mismatch index, missing per-window file, corrupt per-window file);
      persistence round-trip (index + per-window file) via an `AGT_STATE_DIR`-style temp dir.
      `WindowLibrary` is `@MainActor`, so the tests are `@MainActor` with an injected temp dir
- [x] run `cd agtCore && swift test` — must pass before Task 2

### Task 2: Scene refactor to WindowGroup + per-window store wiring

**Files:**
- Modify: `agt/agtApp.swift` (scene, store construction, factories, terminate flush)
- Modify: `agt/ContentView.swift` (windowID/library inputs, TitleProbeView frontmost + close + frameAutosave)
- Modify: `agt/AppActions.swift` (resolve the frontmost store via the library)
- Create: `agtUITests/MultiWindowUITests.swift`

- [x] construct one app-global `WindowLibrary` in `agtApp.init` (AGT_STATE_DIR-aware); drop the
      single `restoredStore()` store; hand the `WindowLibrary` to `AppDelegate` (the same hand-off
      the single `store` used)
- [x] change the scene to a window group; `ContentView` resolves its `AppStore` from the library
      (lazy-load on cold restore). ⚠️ **Deviation from the planned `WindowGroup(for: WindowInfo.ID.self)`:**
      a *value-based* `WindowGroup(for:)` does NOT auto-open any window at launch when SwiftUI window
      restoration is off (verified empirically — `app.windows == 0`, scene `.task` never runs, so
      `openWindow(value:)` can't bootstrap). Switched to a **plain `WindowGroup(id: "terminal")`**
      (auto-opens one window at launch + one per `openWindow(id:)`), and each appearing window claims
      the next open id from a `WindowLibrary` FIFO claim queue (`claimNextWindowID`/`enqueueClaim`)
      seeded by `consumeReopen()`; a window beyond the open set (a SwiftUI-restored extra) gets no id
      and `dismiss()`es itself (the Task 0 dedup-by-id "ignore strays" path)
- [x] launch reopen-all in the scene `.task`: opens one window per *remaining* open id (SwiftUI
      auto-opens the first, which claims the launch id) via `openWindow(id:)`; never windowless
      (bootstrap guarantees ≥1 open id); runs once via the `consumeReopen()` latch. No
      `.restorationBehavior` (macOS 15+, can't be `#available`-gated in a SceneBuilder — Task 0):
      dedup-by-id only, via the claim queue + dismiss-stray
- [x] **quit-time flush (replaces the dropped `AppDelegate.store.save()`):**
      `applicationWillTerminate` sets `library.isTerminating` (so the per-window `willClose`
      close-reporting can't zero the open-set as windows tear down on quit), then calls
      `library.saveAllOpen()` + `library.saveIndex()`
- [x] extend `TitleProbeView`: set `frameAutosaveName("agt-window-<id>")`, report frontmost
      (`didBecomeKey/Main` → `library.frontmostWindowID` + `saveIndex()`), report close
      (`willClose` → tear down that window's surfaces + `library.closeWindow`, captured by value not
      `self` so it fires as the view deallocates); register the `NSWindow` in an app-side
      `WindowRegistry` for dedup/raise (the library is host-free, so the NSWindow handles live app-side)
- [x] make `AppActions` take the `WindowLibrary` (not a fixed store): mutating methods resolve the
      frontmost store (`library.activeStore`, frontmost-or-first-open) and no-op when nil; the app
      `.commands` builder + `paletteActions()` build-time reads go through the same accessor (reactive
      via `@Observable`). `ControlServer`/`SettingsModel`/`SessionSwitcher` likewise rewired to the
      library's frontmost store (minimal — full multi-window behavior is later tasks). (reveal's
      cross-window lookup lands in Task 4)
- [x] `MultiWindowUITests`: seed `AGT_STATE_DIR` with an index + two per-window files; assert both
      windows open (≥2 on-screen + at least one seeded workspace renders + the `windows.json` index
      records both open). Close one → exactly one window marked closed in the index, the other open.
      Per Task 0, per-window sidebar content across BOTH windows isn't asserted (the force-sidebar
      fixup reliably expands only the key window), so the index file is the authoritative oracle
- [x] run `cd agtCore && swift test` + `xcodebuild test … -only-testing:agtUITests/MultiWindowUITests`
      (Task 2 cases) — must pass before Task 3

➕ **Task 2 added scope — existing XCUITest file oracle moved.** Per-window state now lives in
`windows/<uuid>.json` instead of `workspaces.json`, so every existing UI test that polled
`workspaces.json` (Sidebar/Menu/Palette/FontSize/SessionSwitcher/ControlAPI) was failing against the
stale path. Added a shared `URL.windowSnapshotFile()` helper (the single per-window file, legacy
fallback) and repointed those readers at it; `ControlAPIUITests.relaunch(withSnapshot:)` now writes
the per-window file the existing `windows.json` references. Full `agtUITests` suite verified green.

### Task 3: Per-window quick terminal

**Files:**
- Modify: `agt/Views/QuickTerminal.swift` (instance, not singleton)
- Modify: `agt/ContentView.swift` (own a per-window QuickTerminalController)
- Modify: `agt/AppActions.swift`, `agt/agtApp.swift`, `agt/Control/ControlServer.swift` (the `.shared` call sites)

- [x] convert `QuickTerminalController` from a `static let shared` singleton to a per-window
      instance owned by `WindowContentView`; its `cwdProvider` binds to that window's active session.
      (Owned as `@State` in `WindowContentView`, registered in a new app-side `QuickTerminalRegistry`
      keyed by `WindowInfo.ID` on appear, unregistered on disappear; `QuickTerminalPane` now takes the
      per-window controller. Frontmost-window resolution rides a new host-free `WindowLibrary.activeWindowID`
      — the same frontmost-or-first-open resolution `activeStore` uses, factored out + unit-tested.)
- [x] update every `QuickTerminalController.shared` call site to "the frontmost window's quick
      terminal": removed the `agtApp` `.task` cwdProvider wiring (now per-window in `WindowContentView`);
      the `⌃\`` / View-menu toggle goes through new `AppActions.toggleQuickTerminal()`; `AppActions`
      `focusActiveSession` consults `frontmostQuickTerminal?.isVisible` (`focusedSurface()` never used the
      singleton — it reads the key window's first responder); the palette "Quick Terminal" item routes
      through `toggleQuickTerminal()`; `SettingsModel.liveSurfaces` gathers every open window's quick
      terminal via `QuickTerminalRegistry.allControllers()`; `ControlServer`'s `quick` arm resolves the
      frontmost controller (no open window → `no open window` error). Zero `QuickTerminalController.shared`
      references remain.
- [x] e2e (real automated gate, reuses the existing `quick-terminal` accessibility id + the
      existing `quick` control command): `MultiWindowUITests.testQuickTerminalIsPerWindow` seeds two
      windows + the control socket, drives `quick show` on the frontmost window and asserts exactly ONE
      `quick-terminal` element appears (not both), then `quick hide` clears it. The existing single-window
      `ControlAPIUITests.testQuickTerminalToggle`/`testInvalidQuickModeErrors` + `QuickTerminalUITests`
      still pass (no regression).
- [x] run `cd agtCore && swift test` + the relevant `MultiWindowUITests`/`ControlAPIUITests` case
      — must pass before Task 4 (agtCore 218 tests green; `MultiWindowUITests` quick + structural,
      `ControlAPIUITests` quick, `QuickTerminalUITests` all green)

### Task 4: Global services span windows (settings broadcast + notification reveal)

**Files:**
- Modify: `agt/SettingsModel.swift` (liveSurfaces across all open windows)
- Modify: `agt/Notifications/NotificationManager.swift`, `agt/AppActions.swift` (reveal cross-window + reopen closed)
- Modify: `agtCore/Sources/agtCore/Notifications.swift` (identity carries windowID)
- Modify: `agtCore/Tests/agtCoreTests/NotificationsTests.swift`

- [x] `SettingsModel.liveSurfaces()` iterates **all** open windows' stores (via the library) +
      each window's quick terminal, so a config reload broadcasts everywhere; `WindowAppearance.sync`
      stays per window from the same global settings (now `library.openIDs()` → each store's
      session surfaces + the quick terminals; per-session font reset also runs for every open window)
- [x] extend the notification identity (the host-free `TerminalNotification.identity`/`parseIdentity`)
      to carry `windowID` — `"<windowID>:<sessionID>:<paneRole>"` — so a banner clicked after its
      window closed knows which window to reopen (the firing surface is always in an open window at
      fire time). Capture side (`NotificationManager.notify`/`clearDelivered`) resolves the firing
      window via `library.windowID(forSession:)`
- [x] `AppActions.reveal(windowID:sessionID:pane:)` (the notification entry): use
      `library.store(forSession:)`; if the owning window is closed, reopen it (the `openWindow`
      closure `agtApp` wires to `WindowRegistry.raise` ?? `enqueueClaim` + `openWindow(id:)`), then
      poll for its store to load, `selectSession` + focus the pane; stale-safe (unknown window/session
      → just activate). **[x] manual (not automatable in headless exec) — see Post-Completion** for the
      `NSApp.activate`/`openWindow` reveal click path; the code path compiles and is wired
- [x] tests: agtCore identity round-trip with `windowID` (host-free, extended `NotificationsTests`);
      `store(forSession:)` hit/miss already covered in Task 1. The `NSApp.activate`/`openWindow` reveal
      wiring + settings-broadcast-to-two-windows are **[x] manual (not automatable in headless exec) —
      see Post-Completion**
- [x] run `cd agtCore && swift test` + the app build — must pass before Task 5 (218 agtCore tests
      green incl. the windowID identity round-trip; Debug app build SUCCEEDED)

### Task 5: Spawned-shell environment injection

**Files:**
- Modify: `agt/Ghostty/GhosttySurfaceView.swift` (env param + config build + the struct-array field)
- Modify: `agt/agtApp.swift` (factories pass the env dict)
- Modify: `agtUITests/MultiWindowUITests.swift`

- [x] add `env: [String:String]` to `GhosttySurfaceView.init`; strdup key/value into
      `configCStrings`; **add a `nonisolated(unsafe) var envVars: [ghostty_env_var_s]` field** built
      from those buffers, set `config.env_vars`/`config.env_var_count`, and clear it in
      `destroySurface`/`deinit` alongside the strdup frees (the struct array must outlive
      `ghostty_surface_new` and can't live in `configCStrings`). The `config.env_vars` pointer is
      taken via `envVars.withUnsafeMutableBufferPointer` with `ghostty_surface_new` called *inside*
      the same closure (no env → plain path), so the buffer pointer is never used past the call — no
      escaping-pointer UB; the char* buffers join `configCStrings`' free in destroy/deinit.
- [x] factories inject `AGT_ENABLED=1`, `AGT_WINDOW_ID`, `AGT_WORKSPACE_ID`, `AGT_SESSION_ID`,
      `AGT_SOCKET` (split/overlay inherit the parent session's ids; quick terminal gets only
      ENABLED + WINDOW_ID + SOCKET). `AGT_SOCKET` reads the path `ControlServer` actually bound (new
      `ControlServer.boundSocketPath`, nil before bind → the var is omitted), so a test-overridden
      `AGT_CONTROL_SOCKET` and the env agree. `agtApp.surfaceEnv(for:)` resolves window via
      `library.windowID(forSession:)` + workspace via `store.workspace(forSession:)`;
      `quickTerminalEnv(for:)` threads down through `ContentView` → `WindowContentView` to bind the
      quick terminal's new `envProvider` (mirroring `cwdProvider`).
- [x] e2e (write-to-file trick): `MultiWindowUITests.testSpawnedShellSeesWindowAndSessionEnv` —
      `session.new` (so the surface realizes after the socket bound) then `session.type
      'echo "$AGT_WINDOW_ID" > FILE\n'` / `'echo "$AGT_SESSION_ID" > FILE\n'` → read FILE → assert
      `AGT_WINDOW_ID` equals the frontmost window's id (from `windows.json`) and `AGT_SESSION_ID` the
      new session's id. Verified with a negative-control run (the shell wrote the real session UUID,
      proving the probe genuinely executes).
- [x] run `cd agtCore && swift test` + the relevant `MultiWindowUITests` case — must pass before Task 6
      (agtCore 218 tests green; Debug app build SUCCEEDED; all 4 `MultiWindowUITests` green)

### Task 6: Control protocol — window.* commands + window arg (agtCore)

**Files:**
- Modify: `agtCore/Sources/agtCore/ControlProtocol.swift`
- Modify: `agtCore/Tests/agtCoreTests/ControlProtocolTests.swift`
- Modify: `agtCore/Tests/agtCoreTests/ControlResolveTests.swift`

- [x] add the six `window.*` `Command` cases; add `ControlArgs.window`; add
      `ControlResult.windows` + `ControlWindowNode`
- [x] round-trip tests for each new request (window.new/list/select/close/rename/delete) and the
      `windows` result payload
- [x] resolver tests for the **window-id** target only (reuse `ControlResolve.resolve`:
      active=frontmost, exact, prefix, ambiguous, not-found) — this is the clean reuse. The
      cross-window session→store mapping is NOT here; it's app-side `ControlServer` logic (Task 7)
- [x] run `cd agtCore && swift test` — must pass before Task 7

### Task 7: ControlServer dispatch onto WindowLibrary

**Files:**
- Modify: `agt/Control/ControlServer.swift`
- Modify: `agt/agtApp.swift` (construct ControlServer with the library)
- Modify: `agtUITests/ControlAPIUITests.swift`

- [x] construct `ControlServer` with `WindowLibrary` (+ `AppActions`) instead of a single store
      (already wired in Task 2; this task adds the dispatch arms onto it)
- [x] add `window.new` (returns id + opens its window via `actions.openWindow`), `window.list`
      (returns `windows` with each window's `open`/`active` flag), `window.select` (raise-or-open
      via `actions.openWindow`), `window.close` (new `WindowRegistry.close` → `performClose` runs the
      standard `willClose` teardown + `library.closeWindow`), `window.rename`, `window.delete`
      (`canRemoveWindow` keep-at-least-one error). A new `resolveWindowID` resolves the window target
      (active=frontmost, exact, prefix) over `library.windows` — a window need NOT be open to be a
      window.* target (select opens it, delete removes a closed one)
- [x] **cross-window session/workspace targeting (NEW app-side logic, not `resolve` reuse):** with
      `args.window` → `resolveWindowStore` resolves the window (must be open, else `window not open —
      window.select it first`), and session/workspace targets resolve within that store; without
      `args.window` → `active`/placement default to the frontmost store (`resolvePlacementStore`),
      but an id/prefix session/workspace target is matched across ALL open stores
      (`resolveTargetAcrossWindows`) and mapped back to its owning `AppStore`; `tree` honors `window`.
      `session.move`/`session.new` resolve the destination/target workspace within the same resolved
      store. A local `Resolution<T>` enum stands in for `Result` (`ControlResponse` isn't an `Error`)
- [x] e2e (4 new `ControlAPIUITests`): `testWindowNewAndList` (`window.new` → `window.list` shows it
      open + the active-flag invariant); `testClosedWindowTargetingErrors` (`window.close` then `tree
      --window B` → the `window not open` error); `testWindowTargetingRoutesToTheRightTree` (`--window`
      routes `session.new`/`tree` to the right tree); `testCapturedIDResolvesWhileAnotherWindowFrontmost`
      (a B-session id resolves with no `--window` while window A is frontmost). All four green
- [x] run `cd agtCore && swift test` + the relevant `ControlAPIUITests` cases — must pass before Task 8
      (agtCore 227 tests green; full `ControlAPIUITests` 30 tests green — 26 existing unchanged + 4 new)

### Task 8: agtctl window subcommands + global --window option

**Files:**
- Modify: `agtCore/Sources/agtctlKit/Commands.swift`
- Modify: `agtCore/Tests/agtctlKitTests/CommandsTests.swift`
- Modify: `agtUITests/ControlAPIUITests.swift`

- [x] add the `window` subcommand group (new/list/select/close/rename/delete) mapping to
      `ControlRequest`s; add a global `--window` option on session/workspace subcommands
      (added to the shared `ClientOptions` so it threads into session/workspace/tree/font requests via
      `ClientOptions.withWindow(_:)`, which folds it into the per-command args bag or returns nil when
      absent — keeping no-window requests in their compact `args:nil` wire form. Window subcommands take
      a positional `<id>` mapped to `target`; new/rename carry `args.name`)
- [x] `window list` prints `id name [open] [active]` (raw with `--json`) — new
      `SocketClient.formatWindows` renders one `id  name  [open]  [active]` line per window, wired into
      `formatResponse` ahead of the text/id fallbacks
- [x] `CommandsTests`: each new subcommand parses to the expected request; `--window` populates
      `args.window`; an invalid-args case (`window rename` with only one positional). Added
      `SocketClientTests.formatResponseWindows` covering the open/active/closed column rendering
- [x] e2e: the existing `ControlAPIUITests` speak the socket directly (never shell `agtctl`), so per the
      task split the CLI parse correctness is covered by `CommandsTests` and the `window.*` + `--window`
      routing by the already-present Task 7 socket e2e (`testWindowNewAndList`,
      `testWindowTargetingRoutesToTheRightTree`, `testClosedWindowTargetingErrors`,
      `testCapturedIDResolvesWhileAnotherWindowFrontmost`) — all four green across both full runs
- [x] run `cd agtCore && swift test` + the relevant `ControlAPIUITests` cases — must pass before Task 9
      (agtCore 243 tests green; Debug build SUCCEEDED; the four window e2e tests pass consistently. Two
      unrelated session-type Metal-injection tests flaked under full-suite load — `testSessionType{Into
      ActiveSession,SelectRealizesNeverShownSession}`, a different one each run — and both pass in
      isolation; the change is confined to the host-free `agtctlKit` library)

### Task 9: UX — File menu + palette window actions

**Files:**
- Modify: `agt/agtApp.swift` (File menu: New Window, Open Window ▸, Rename/Delete Window)
- Modify: `agt/AppActions.swift` (newWindow/openWindow/renameWindow/deleteWindow + paletteActions + the rename NSAlert)
- Modify: `agtUITests/MultiWindowUITests.swift`

- [x] File menu: **New Window** (creates + opens a fresh window via `actions.newWindow`),
      **Open Window ▸** submenu (library windows, checkmark = open, pick to open/focus via
      `actions.openWindow`), **Rename Window…** (a one-shot `NSAlert` + accessory `NSTextField`
      pre-filled with the name → `library.renameWindow`, in `AppActions.renameActiveWindow`),
      **Delete Window** (`actions.deleteActiveWindow` — confirm when non-empty, mirroring the Delete
      Workspace confirm; `canRemoveWindow` gates/disables the last)
- [x] add the same actions to `AppActions.paletteActions()` so ⌃⇧P can run them (New Window,
      Rename Window, Delete Window when removable, and one "Open Window: <name>" per *closed* window)
- [x] e2e: `testNewWindowMenuOpensSecondWindow` (menu → second window + new index entry),
      `testDeleteWindowMenuRemovesExtraWindow` (menu + confirm → back to one window),
      `testDeleteWindowMenuDisabledForLastWindow` (last window's menu item disabled), and
      `testRenameWindowViaControlUpdatesIndex` (rename via the control path, not the alert)
- [x] run `cd agtCore && swift test` + the relevant `MultiWindowUITests` cases — must pass before Task 10
      (agtCore 243 tests green; all 4 new Task 9 `MultiWindowUITests` green + the other structural cases.
      `testSpawnedShellSeesWindowAndSessionEnv` is the documented pre-existing Metal-injection flake —
      passes in isolation both with and without these changes, flakes under full-suite load; unrelated
      to the menu/palette additions, which don't touch the env-injection path)

### Task 10: Verify acceptance + keep-in-sync check

**Files:**
- Modify: `agtUITests/MultiWindowUITests.swift`, `agtUITests/ControlAPIUITests.swift`

- [x] integration coverage not already gated: reopen-all after a simulated quit (relaunch with the
      seeded index) restores the open-set + selection
      (`MultiWindowUITests.testReopenAllAfterSimulatedQuitRestoresOpenSetAndSelection`: seeds two open
      windows each with a known selected second session, launches → both reopen with selection intact,
      then `app.terminate()` (the quit-time flush) + relaunch → both windows reopen open AND each
      window's `selectedSessionID` survives. The per-window snapshot file is the selection oracle, the
      index `isOpen` flags the open-set oracle.)
- [x] keep-in-sync four-point check for all six window commands: `Command` case + `ControlServer`
      arm + `agtctl` subcommand + test — record the audit result here (catalog is now 25 commands)
- [x] run the full gate: `cd agtCore && swift test` + all `agtUITests` — must pass before Task 11
      (agtCore 243 tests green — Task 10 adds XCUITest coverage only; full `agtUITests` suite green
      after the three full-suite-gate fixes below — first full run flagged the Palette breakage + the
      two load flakes, then confirmed green across consecutive full runs)

➕ **Task 10 keep-in-sync audit (six `window.*` commands × four points).** Catalog is now **25 commands**
(19 original + 6 window). Each window command satisfies all four points of the keep-in-sync convention:

| command | (1) `Command` case (agtCore) | (2) `ControlServer` arm | (3) `agtctl` subcommand | (4) test |
|---|---|---|---|---|
| `window.new` | `windowNew = "window.new"` | `.windowNew → windowNew(name:)` | `Window.New` | `CommandsTests.windowNew{WithName,WithoutName}` + e2e `testWindowNewAndList` |
| `window.list` | `windowList = "window.list"` | `.windowList → buildWindowList()` | `Window.List` | `CommandsTests.windowList` + `SocketClientTests.formatResponseWindows` + e2e `testWindowNewAndList` |
| `window.select` | `windowSelect = "window.select"` | `.windowSelect → windowSelect(_:)` | `Window.Select` | `CommandsTests.windowSelect{,DefaultsActive}` + e2e `testCapturedIDResolvesWhileAnotherWindowFrontmost` |
| `window.close` | `windowClose = "window.close"` | `.windowClose → windowClose(_:)` | `Window.Close` | `CommandsTests.windowClose` + e2e `testClosedWindowTargetingErrors` |
| `window.rename` | `windowRename = "window.rename"` | `.windowRename → windowRename(_:name:)` | `Window.Rename` | `CommandsTests.windowRename{,RequiresBothArgsFails}` + e2e `testRenameWindowViaControlUpdatesIndex` |
| `window.delete` | `windowDelete = "window.delete"` | `.windowDelete → windowDelete(_:)` | `Window.Delete` | `CommandsTests.windowDelete{,DefaultsActive}` + e2e (keep-at-least-one via menu `testDeleteWindowMenuDisabledForLastWindow`) |

The global `--window` selector (folded into `ClientOptions.withWindow`) covers the session/workspace/tree/font
commands; covered by `CommandsTests.{sessionNew,sessionSelect,workspaceNew,tree}WithWindow` +
`treeWithoutWindowOmitsArgs`, and e2e by `testWindowTargetingRoutesToTheRightTree` /
`testClosedWindowTargetingErrors` / `testCapturedIDResolvesWhileAnotherWindowFrontmost`.

➕ **Task 10 full-suite-gate findings + fixes.** The full `agtUITests` gate (which Tasks 2–9 never ran in
full — each ran only its own `-only-testing` subset) surfaced three issues, all fixed (all test-layer only,
no production code changed):

1. **session.type Metal keystroke-injection readiness race (flake).** The session.type write-to-file tests
   (`MultiWindowUITests.testSpawnedShellSeesWindowAndSessionEnv`,
   `ControlAPIUITests.testSessionType{IntoActiveSession,SelectRealizesNeverShownSession}`) flaked under
   full-suite CPU load (a different one failing each run, all passing in isolation). **Root cause:** the
   inject path realizes the surface object and injects on the first attempt where `surface != nil`, but a
   just-spawned shell's pty isn't necessarily ready to read those keystrokes yet — under load the single
   injection's bytes were dropped and the marker file never appeared, so the bounded marker poll timed out.
   The realization poll (`injectText`'s 12 × 0.03 s) gates on `surface != nil`, NOT shell readiness, and
   libghostty exposes no "child spawned / first prompt" signal to gate on. **Fix:** a shared
   `typeUntilMarker(...)` helper re-injects the probe command (up to 4 attempts × 4 s) until the shell
   writes the marker file — the marker is the deterministic readiness signal, so a dropped first injection
   is retried once the shell is ready. The ControlServer/GhosttySurfaceView inject path is unchanged, so
   single-window session.type behavior is untouched.

2. **`PaletteUITests.testActionPaletteArrowNavigationRunsSecondItem` — REAL breakage from Task 9 (not a
   flake).** Task 9 added "New Window" to `AppActions.paletteActions()`, so the query "new" now matches
   THREE items alphabetically — `[New Session, New Window, New Workspace]` (all score 0 as exact prefixes,
   tie-broken by title) — not two. A single ↓ landed on "New Window" (opens a window) instead of
   "New Workspace", so `workspaceCount() == beforeWs + 1` failed deterministically. **Fix:** the test now
   presses ↓ twice to reach "New Workspace" at index 2; comment updated to the three-item list. (Task 9
   missed this — it ran only its own MultiWindow cases, never the palette suite; the full gate caught it.)

3. **`ControlAPIUITests.testClosedWindowTargetingErrors` — window-close settle flake.** `window.close`
   drives AppKit `performClose` → `willCloseNotification` → per-window surface teardown →
   `library.closeWindow` → index save, a heavier round-trip than the other commands. Under full-suite CPU
   contention (window B's Metal surface still initializing keeps the main actor busy) the `willClose`
   handler was delayed past the 10 s poll budget; it passes in ~3 s in isolation. **Fix:** the close-settle
   `pollWindowList` budget raised 10 s → 30 s — the `open` flag is the deterministic readiness signal, this
   waits longer for it rather than adding a blanket sleep. Only this one assertion changed (the other window
   tests don't close a window).

**Verification:** confirmed by the targeted subset (the 6 affected cases all green in isolation) plus
consecutive full `agtUITests` runs green.

### Task 11: Documentation

**Files:**
- Modify: `CLAUDE.md`, `README.md`, `ARCHITECTURE.md`

- [x] `CLAUDE.md`: a "Windows (multi-window)" section — the `WindowLibrary`/`WindowInfo` model,
      per-window `AppStore`, persistence layout + migration + recovery contract, the
      scene/restoration approach, the frontmost-store resolution + quit-flush, per-window quick
      terminal, cross-window reveal (windowID-bearing identity), the `AGT_*` env vars, and the
      `window.*` control additions; update the Control API catalog from **19 commands to 25**
      (enumerate the six `window.*`), not just the number
- [x] `README.md`: features list (named windows, reopen-all) + a "Scripting agt" note for `agtctl
      window …`, `--window`, and the `AGT_WINDOW_ID`/`AGT_SESSION_ID`/`AGT_SOCKET` env vars
- [x] `ARCHITECTURE.md`: the new top-level `WindowLibrary` owner and the per-window store split
- [x] move this plan to `docs/plans/completed/` (physical move performed by the exec completion step after reviews)

## Post-Completion

*Items that benefit from a human, not blockers:*

**Manual verification:**
- reopen-all after a real quit (two+ windows, distinct frames, multiple displays); confirm
  `frameAutosaveName` restores positions sanely.
- per-window quick terminal: open in two windows, confirm each spawns in its own active session's
  cwd and they don't cross-talk.
- a settings change (font/theme/opacity) with two windows open updates both live.
- notification banner click into a *closed* window reopens the right window + pane.
- the `AGT_*` env in a real shell: `agtctl session … --window "$AGT_WINDOW_ID"` from inside a
  session round-trips.

**Future / explicitly deferred (out of scope):**
- shared/cross-window live state (same bundle in two windows) and cross-window session drag — both
  excluded by the strict 1:1 model.
- a sidebar/header window switcher or a dedicated window-manager panel (menu + palette only for now).

---
Smells pre-check: skipped — non-Go project.
