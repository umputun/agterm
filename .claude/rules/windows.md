---
paths:
  - "agtermCore/Sources/agtermCore/WindowLibrary.swift"
  - "agtermCore/Sources/agtermCore/WindowGeometry.swift"
  - "agtermCore/Sources/agtermCore/QuitPrompt.swift"
  - "agterm/Views/QuickTerminal.swift"
  - "agtermUITests/MultiWindowUITests.swift"
  - "agtermUITests/QuickTerminalUITests.swift"
---

## Windows (multi-window)

A **window** is the top level above the workspace tree: a named, persisted bundle of workspaces + sessions,
each rendered in its own on-screen macOS window.
The user keeps a library of windows (e.g. "work", "personal"), opens one per on-screen window,
and the set open at quit reopens on next launch.
Strict 1:1 — a bundle shows in exactly one on-screen window, never two windows for one bundle,
never two bundles in one window.
**No** shared/cross-window live state and **no** cross-window session drag (out of scope by the 1:1 model).

- **Model (`agtermCore`, host-free).**
  `WindowLibrary.swift` holds `WindowInfo {id: UUID, name: String}` (named `WindowInfo`,
  NOT `Window`, to avoid the SwiftUI/AppKit clash) and the persisted Codables `WindowsIndex {version, frontmost: UUID?, windows: [WindowEntry]}`
  / `WindowEntry {id, name, isOpen}` (the index carries its OWN `version`,
  independent of `Snapshot.version`).
  `WindowLibrary` is `@Observable @MainActor` like `AppStore`: it owns the ordered `windows: [WindowInfo]`,
  the live per-window `stores: [UUID: AppStore]` (`@ObservationIgnored`),
  `frontmostWindowID`, and per-window + index persistence.
  A window is "open" iff its `AppStore` is loaded (`stores[id] != nil`).
- **`AppStore` stays the per-window unit**
  — it already is one tree + one selection, so internals are unchanged; `WindowLibrary` just owns one
  store per open window, lazily loaded.
  `store(for:)` returns an open window's store; `loadStore(for:)` lazily builds/caches it from `windows/<id>.json`;
  `newWindow(name:)` seeds a fresh window (one "workspace 1" + one `$HOME` session — the seeding that
  used to live in the dropped `agtermApp.restoredStore()`); `closeWindow`/`renameWindow`/`removeWindow`
  (`canRemoveWindow` = count > 1, keep-at-least-one) mutate + persist; `openIDs()` is the persisted open-set
  for launch reopen.
- **Persistence layout**
  under `<stateDir>` (`AGTERM_STATE_DIR`-aware, else `~/Library/Application Support/agterm`):
  `windows.json` is the index, `windows/<uuid>.json` is each window's `Snapshot` (the same shape `workspaces.json`
  had), and the legacy `workspaces.json` is left dormant after migration.
  `PersistenceStore` gained an optional `fileName:` init param (default `workspaces.json`) so a per-window
  store targets `windows/<id>.json` without breaking existing callers.
  A per-mutation `saveIndex()` rewrites only `windows.json`; each store's own `save()` rewrites only
  its file.
- **Migration + recovery (on `WindowLibrary` init `bootstrap()`; never throws,
  mirrors `PersistenceStore.load()`):** valid `windows.json` → load it; absent index but legacy `workspaces.json`
  present → wrap it into one window ("window 1", marked open/frontmost);
  neither → seed one empty window.
  A corrupt or `version`-mismatched `windows.json` is treated as absent,
  but BEFORE the legacy-else-seed fallback `recoverOrphanedWindows()` (run in `bootstrap()` between `loadIndex()`
  and `migrateLegacy()`) enumerates any `windows/<uuid>.json` files (skipping non-UUID names),
  appends them ALL to `windows` FIRST (`loadStore` guards on `windows.contains(id)`),
  default-names them (`window N`), `loadStore`s each, and marks them all open with the first frontmost
  — so a future index schema bump RECOVERS the user's sessions instead of resurrecting stale `workspaces.json`
  or seeding empty; only with NO per-window files does the migrate-from-legacy-else-seed path run.
  A missing/corrupt `windows/<id>.json` opens that window with an empty `Snapshot` (one default workspace
  + session).
  Net: the app always reaches a valid, non-empty window set, never windowless at launch.
- **Scene + restoration — ⚠️ deviates from the planned `WindowGroup(for:)`.**
  A *value-based* `WindowGroup(for:)` does NOT auto-open any window at launch when SwiftUI window restoration
  is off (the scene `.task` never runs, so `openWindow(value:)` can't bootstrap).
  The scene is therefore a **plain `WindowGroup(id: "terminal")`** (auto-opens one window at launch +
  one per `openWindow(id:)`).
  `WindowLibrary` is the single source of truth for the open-set; each appearing SwiftUI window claims
  the next id from a FIFO **claim queue** (`consumeReopen()` seeds it launch-window-first,
  `claimNextWindowID()` pops, `enqueueClaim(_:)` appends for a brand-new window),
  and a window beyond the open set (a SwiftUI-restored stray) gets no id and `dismiss()`es itself.
  **No `.restorationBehavior`:** it is macOS 15+ and `SceneBuilder` rejects `if #available` entirely
  (verified — `@ViewBuilder` accepts it, `@SceneBuilder` does not, and there is no `AnyScene` eraser),
  and the deployment floor is macOS 14, so the mechanism is **dedup-by-id only** (claim queue + dismiss-stray),
  uniform across 14 and 15.
  `reopenWindows()` in the scene `.task` opens one window per *remaining* open id (SwiftUI auto-opened
  the first), once via the `hasReopened` latch.
  `TitleProbeView` sets `frameAutosaveName("agterm-window-<id>")` so AppKit restores geometry per window.
- **Frontmost-store resolution + quit-flush.**
  `AppActions` takes the `WindowLibrary`, not a fixed store: its mutating methods resolve `library.activeStore`
  (the frontmost open store, falling back to the first open store; backed by `activeWindowID`,
  the same resolution the quick terminal uses) and no-op when nil.
  The app `.commands` builder and `paletteActions()` build-time reads go through the same accessor —
  reactive because `WindowLibrary` is `@Observable`.
  `ControlServer`/`SettingsModel`/`SessionSwitcher` are likewise wired to the library.
  `TitleProbeView` reports frontmost (`didBecomeKey/Main` → `library.frontmostWindowID` + `saveIndex()`)
  and close (`willClose` → tear down that window's surfaces + `library.closeWindow`).
  The quit-flush replaces the dropped single-store `AppDelegate.store.save()`:
  `applicationWillTerminate` sets `library.isTerminating` (so the per-window `willClose` close-reporting
  can't zero the open-set as windows tear down on quit) then `library.saveAllOpen()` + `library.saveIndex()`
  — load-bearing because `AppStore` does NOT save on a live `cd`, so cwd changes since the last structural
  mutation are flushed here.
  `selectSession`/`setFontSize` also persist via a debounced `scheduleSave()` (~0.3 s,
  host-free `Debouncer`) instead of an immediate `save()` — structural mutations (add/close/move/rename/addWorkspace)
  still `save()` synchronously, and `save()` cancels any pending scheduled save so this quit-flush captures
  the latest selection/font (same lose-last-change-on-SIGKILL tradeoff as the split-ratio debounce).
- **Quit confirmation.**
  `AppDelegate.applicationShouldTerminate` gates a menu/⌘Q quit behind a standard warning `NSAlert` (Quit
  / Cancel → `.terminateNow`/`.terminateCancel`), reporting how many windows + sessions the quit closes
  (closing them ends every shell, the same loss `deleteWorkspace`/`deleteActiveWindow` confirm).
  Counts come from the host-free `WindowLibrary.openCounts()` (open windows + total sessions across them)
  and the message from the host-free `QuitPrompt.message(windows:sessions:)` (both unit-tested);
  the AppKit alert is the app-side glue, manually verified like the other `confirmDelete` alerts.
  Skips the prompt (`.terminateNow`) when nothing is open (the auto-quit after the last window closed
  — `applicationShouldTerminateAfterLastWindowClosed` already gates that on the model open-set) OR under
  an XCUITest launch (`ContentView.isUITestLaunch` — a modal would hang the test's terminate;
  the dialog is therefore manually verified, not XCUITest-covered).
  `let library else .terminateNow` is a safety fallback: a quit before the scene `.task` wired the library
  (sub-~4 s after launch) allows termination rather than deadlocking.
  Keep-in-sync EXEMPT — a quit-confirm modal is GUI-only chrome with nothing to drive over the socket
  (there is no `app.quit` control command).
- **`WindowRegistry`**
  (`ContentView.swift`, app-side, `@MainActor` singleton) maps a `WindowInfo.ID` to its live `NSWindow`
  — `WindowLibrary` is host-free (no AppKit), so the NSWindow handles live app-side.
  `TitleProbeView` registers/unregisters on attach/close; `raise(_:)` brings an already-open window forward
  (the dedup-by-id raise path), `close(_:)` runs `performClose` (driving the standard `willClose` teardown,
  used by `window.close`).
- **Per-window quick terminal.**
  `QuickTerminalController` is no longer a `static let shared` singleton — it is a per-window instance
  owned by `WindowContentView` (as `@State`), registered in the app-side `QuickTerminalRegistry` (`Views/QuickTerminal.swift`,
  `@MainActor` singleton) keyed by `WindowInfo.ID` on appear, unregistered on disappear.
  Its `cwdProvider`/`envProvider` bind to that window's active session.
  The frontmost-window call sites resolve via `QuickTerminalRegistry.controller(for: library.activeWindowID)`
  (the toggle goes through `AppActions.toggleQuickTerminal()`; `ControlServer`'s `quick` arm errors with
  `no open window` when none is open); the settings broadcast reaches every window's quick terminal via
  `allControllers()`.
  Zero `QuickTerminalController.shared` references remain.
- **Cross-window notification reveal.**
  The notification identity (`TerminalNotification.identity`/`parseIdentity` in agtermCore) is now `"<windowID>:<sessionID>:<paneRole>"`
  — the windowID lets a banner clicked after its window closed know which window to reopen.
  The capture side (`NotificationManager.notify`/`clearDelivered`) resolves the firing window via `library.windowID(forSession:)`.
  `AppActions.reveal(windowID:sessionID:pane:)` uses `library.store(forSession:)`;
  if the owning window is closed it reopens it via the `actions.openWindow` closure (`agtermApp` wires
  it to `WindowRegistry.raise` else `enqueueClaim` + `openWindow(id:)`),
  polls for the store to load, then `selectSession` + focus the pane (stale-safe:
  unknown window/session → just activate).
  `reveal` stays a keep-in-sync exemption (internal click-routing, not on toolbar/menu/palette).
- **Spawned-shell `AGTERM_*` env (per surface).**
  `GhosttySurfaceView.init` takes `env: [String: String] = [:]`; it strdups each key/value into the existing
  `configCStrings` and builds a `nonisolated(unsafe) var envVars: [ghostty_env_var_s]` field set as `config.env_vars`/`config.env_var_count`
  — the struct array must outlive `ghostty_surface_new` and can't live in `configCStrings` (wrong element
  type), so `ghostty_surface_new` is called *inside* the `envVars.withUnsafeMutableBufferPointer` closure
  (no env → plain path) and the array is cleared in `destroySurface`/`deinit` alongside the strdup frees.
  Tree surfaces (main/split/overlay, via `agtermApp.surfaceEnv(for:)`) inject `AGTERM_ENABLED=1`,
  `AGTERM_WINDOW_ID` (`library.windowID(forSession:)`), `AGTERM_WORKSPACE_ID` (`store.workspace(forSession:)`),
  `AGTERM_SESSION_ID`, `AGTERM_SOCKET`; split/overlay inherit the parent session's ids.
  The quick terminal (`quickTerminalEnv(for:)`) gets only `AGTERM_ENABLED` + `AGTERM_WINDOW_ID` + `AGTERM_SOCKET`
  (scratch, not in the tree).
  `AGTERM_SOCKET` is the path `ControlServer` *actually bound* (`ControlServer.boundSocketPath`,
  nil before bind → the var is omitted), so a test-overridden `AGTERM_CONTROL_SOCKET` and the injected
  env agree.
- **`window.zoom` (maximize-to-screen toggle, control + double-click-header GUI).** `WindowRegistry.zoom(_:)`
  drives the standard `NSWindow.zoom(nil)` — toggles between the normal frame and the screen's visible frame
  (NOT native fullscreen); a second call restores.
  Unlike `resize`/`move` it has a GUI surface: a custom-titlebar SwiftUI view can't receive the OS
  double-click handling, so `WindowControlArea` (an `NSViewRepresentable` behind `customTitlebar`'s decorative
  regions in `ContentView.swift`) handles `mouseDown` — `clickCount == 2` runs the user's configured title-bar
  action, else `performDrag` (also making the FULL header draggable, not just the native top band);
  `mouseDownCanMoveWindow = false` so our handler sees the double-click.
  The double-click honors the macOS **Desktop & Dock ▸ "Double-click a window's title bar to"** setting
  (`AppleActionOnDoubleClick` in `NSGlobalDomain`, read LIVE per click): Zoom/Fill → `window.zoom(nil)`,
  Minimize → `performMiniaturize`, "Do Nothing" → no-op; the key is absent until the user changes it from the
  macOS default (Zoom), so an untouched system still zooms (the prior behavior).
  So the GUI double-click is NOT always-zoom — only the `window.zoom` control command unconditionally zooms.
  A UITest env override (`AGTERM_UITEST_DOUBLECLICK_ACTION`, read ahead of the system default) pins the action
  so the gesture tests are hermetic regardless of the host setting; it rides the environment, not launch
  arguments (FB11763863 — see `ui-tests.md`).
  The header's decorative parts (the traffic-light spacer, the divider gap, the title text) opt out via
  `.allowsHitTesting(false)` so their region falls through to the layer; the buttons stay in front.
  Requires the window OPEN (closed → the `window not open` error), like `resize`/`move`.
  Four-point keep-in-sync audit: (1) `case windowZoom = "window.zoom"` in `ControlProtocol.swift`,
  (2) the `.windowZoom` dispatch arm (`windowZoom`) in `ControlServer` → `WindowRegistry.shared.zoom`,
  (3) the `window zoom <id>` subcommand in `agtermctlKit`, (4) `.windowZoom` in `windowCommandsRoundTrip`
  (`ControlProtocolTests`) + the e2e `testWindowZoom` plus the gesture tests
  `testDoubleClickHeaderZoomsAndRestores` / `testDoubleClickHeaderHonorsNoneSetting` /
  `testHeaderButtonsStillReceiveClicksOverControlArea` / `testDragHeaderMovesWindow` in `ControlAPIUITests`.
- **`window.*` control additions (eight commands, plus `window.zoom`).**
  `window.new` (returns the new id + opens its window), `window.list` (returns `windows` with each window's
  `open`/`active` flag), `window.select` (raise-or-open), `window.close` (`WindowRegistry.close` → standard
  teardown), `window.rename`, `window.delete` (`canRemoveWindow` keep-at-least-one → error,
  not a GUI confirm).
  `window.resize` (`args.width`/`height` → the window's frame size in points) and `window.move` (`args.x`/`y`
  → the top-left relative to display `args.display`, default the window's current display;
  y from the display top, so multiple displays are addressed by index) drive the app-side `WindowRegistry.resize`/`move`
  (the NSWindow handles, since `WindowLibrary` is host-free); both require the window OPEN (a closed
  window errors) and are control-NATIVE (no GUI surface — the native title bar already drags-to-resize).
  Both CLAMP the request via the host-free `WindowGeometry` (`clampSize` into `[window.minSize, screen.visibleFrame]`,
  `clampOrigin` keeps a grabbable on-screen strip) applied INSIDE `WindowRegistry` (the only place with
  the live `NSWindow`/`NSScreen`); `ControlServer` keeps only the `>0` guard.
  `WindowGeometry` is agtermCore's first CoreGraphics types (CG ≠ AppKit/Metal,
  Foundation-provided on Darwin).
  Window-id resolution reuses the pure `ControlResolve.resolve` over `library.windows` (active=frontmost
  / exact / prefix / ambiguous / not-found); a window need NOT be open to be a `window.*` target.
  The global `--window <id>` selector (`ControlArgs.window`) targets a session/workspace command at a
  *specific* window's tree: with `args.window` set, the window must be open (else `window not open — window.select it first`);
  without it, `active`/placement default to the frontmost store, but an id/prefix session/workspace target
  is matched across ALL open stores (`resolveTargetAcrossWindows`) and mapped back to its owning `AppStore`.
  See the Control API section for the catalog and the keep-in-sync four-point audit (all eight window
  commands satisfy it).

