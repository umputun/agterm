---
paths:
  - "agtermCore/Sources/agtermCore/WindowLibrary.swift"
  - "agtermCore/Sources/agtermCore/WindowGeometry.swift"
  - "agtermCore/Sources/agtermCore/QuitPrompt.swift"
  - "agterm/WindowRegistry.swift"
  - "agterm/AppDelegate.swift"
  - "agterm/AppDelegate+DockMenu.swift"
  - "agterm/Views/WindowAccessor.swift"
  - "agterm/Views/WindowControlArea.swift"
  - "agterm/Views/QuickTerminal.swift"
  - "agtermUITests/MultiWindowUITests.swift"
  - "agtermUITests/QuickTerminalUITests.swift"
  - "agtermTests/DockMenuTests.swift"
---

## Windows (multi-window)

A **window** is the top level above the workspace tree: a named, persisted bundle of workspaces + sessions,
each rendered in its own on-screen macOS window.
The user keeps a library of windows (e.g. "work", "personal"), opens one per on-screen window,
and the set open at quit reopens on next launch.
Strict 1:1 — a bundle shows in exactly one on-screen window, never two windows for one bundle,
never two bundles in one window.
**No** shared/cross-window live state and **no** cross-window session drag (out of scope by the 1:1 model).

- **Dock-menu window scope.**
  `AppDelegate.applicationDockMenu` snapshots the last-active `AppStore` when AppKit opens the Dock menu.
  `NSMenuItem.target` is weak, so the delegate's target array is the sole strong owner for the active menu.
  The delegate invalidates the old target set on rebuild to stop an already-loaded or in-flight stale target from dispatching.
  Every top-level and session closure keeps the captured store/window scope even if window B becomes frontmost before a window A item is chosen.
  Invocation rechecks A's per-window modal/controller state, raises A, and synchronously writes `library.frontmostWindowID` plus posts `.agtermWindowFrontmostChanged` before shared actions resolve their store.
  New Session, Quick Terminal, Dashboard, selection, and pane-aware reveal therefore all target A.
  New Window is the ONE item outside that scheme — it captures nothing and skips the modal gate, because a new window belongs to no existing window, and its enabled state reads the action hub rather than the captured window; see the Dock-menu bullet in `menu-actions.md` for why, and for the activation it has to do itself.
  Do not defer that publication to `WindowAccessor`'s key-window notification because all action work must target A during the same Dock invocation.
  Recheck the captured window instead of invocation-time frontmost B because modal state is per-window.
  A stale item becomes inert if A closes or enters dashboard/terminal zoom while the menu is open.
  A Dashboard item built while A's dashboard is already open remains a valid close toggle, while one built closed becomes inert if the dashboard opens before invocation.
  The Dock surface composes the existing `session.new`, `window.new`, `quick`, `dashboard`, and `session.select` control capabilities, so it requires no new control command.

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
  for launch reopen; `applyInactiveWindowSidebarHiding()` is the host-free auto-hide-inactive-sidebars
  driver (shows the active window's sidebar, collapses the rest) — see the `autoHideSidebarInactiveWindows`
  bullet in `settings.md`.
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
  (`agterm/WindowRegistry.swift`, app-side, `@MainActor` singleton) maps a `WindowInfo.ID` to its live `NSWindow`
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
  regions in `agterm/Views/WindowControlArea.swift`) handles `mouseDown` — `clickCount == 2` runs the user's configured title-bar
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
  Its READ side is `ControlWindowNode.zoomed` on `window.list` (via `WindowRegistry.windowFlags(for:)` →
  `NSWindow.isZoomed`), so a script can toggle idempotently.
  Four-point keep-in-sync audit: (1) `case windowZoom = "window.zoom"` in `ControlProtocol.swift`,
  (2) the `.windowZoom` dispatch arm (`windowZoom`) in `ControlServer` → `WindowRegistry.shared.zoom`,
  (3) the `window zoom <id>` subcommand in `agtermctlKit`, (4) `.windowZoom` in `windowCommandsRoundTrip`
  (`ControlProtocolTests`) + the e2e `testWindowZoom` plus the gesture tests
  `testDoubleClickHeaderZoomsAndRestores` / `testDoubleClickHeaderHonorsNoneSetting` /
  `testHeaderButtonsStillReceiveClicksOverControlArea` / `testDragHeaderMovesWindow` in `ControlWindowUITests`.
- **`window.fullscreen` (native macOS full screen — control + View-menu / green-button / ⌃⌘F GUI).**
  `WindowRegistry.fullscreen(_:)` drives the standard `NSWindow.toggleFullScreen(nil)` — enters/exits NATIVE
  full screen (a separate Space, auto-hidden menu bar); a second call exits.
  Distinct from `window.zoom`, which only maximizes the frame in the SAME Space.
  It has a GUI surface across all four keep-in-sync callers: the **View ▸ Toggle Full Screen** menu item and
  the ⌃⇧P palette "Toggle Full Screen" both drive `AppActions.toggleFullscreen()` →
  `NSApp.keyWindow?.toggleFullScreen(nil)` (the KEY window, no id resolution — the menu/palette/keymap
  always act on the frontmost), `BuiltinAction.toggleFullscreen` gives it the ⌃⌘F default (expressible,
  rebindable via `keymap.conf`), and the green traffic-light button already toggles the same native path.
  The control command instead resolves a window id like `zoom` (`active`/prefix/id) and requires the window
  OPEN (closed → the `window not open` error).
  **AppKit auto-injects its OWN "Enter Full Screen" item (Globe+F / ⌃⌘F) into the View menu for any
  fullscreen-capable window and RE-INJECTS it every time the menu opens, so agterm's own item would render
  a DUPLICATE.** `AppDelegate` strips the native one — `removeNativeFullScreenMenuItem` removes the menu item
  whose action is `toggleFullScreen:` (agterm's item uses a SwiftUI closure action, a different selector, so
  only the native one matches).
  It runs once at launch AND on every `NSMenu.didBeginTrackingNotification` (the point AppKit re-injects it) —
  a launch-time one-shot does NOT stick because of the re-injection; a menu delegate is NOT used (it would
  clobber SwiftUI's dynamic View-menu updates).
  Guarded by the e2e `testViewMenuHasSingleFullScreenItem` in `MenuUITests` (View menu shows Toggle Full
  Screen, NOT the native Enter Full Screen).
  Its READ side is `ControlWindowNode.fullscreen` on `window.list` (via `WindowRegistry.windowFlags(for:)` →
  `styleMask.contains(.fullScreen)`), so a script can enter/exit only when needed.
  Four-point keep-in-sync audit: (1) `case windowFullscreen = "window.fullscreen"` in `ControlProtocol.swift`
  + `case toggleFullscreen = "toggle_fullscreen"` (⌃⌘F `defaultChord`) in `BuiltinAction`,
  (2) the `.windowFullscreen` dispatch arm (`windowFullscreen`) in `ControlServer` →
  `WindowRegistry.shared.fullscreen`, plus `AppActions.toggleFullscreen()`, the View menu item, and
  `PaletteCommand.toggleFullscreen`,
  (3) the `window fullscreen <id>` subcommand in `agtermctlKit`, (4) `.windowFullscreen` in
  `windowCommandsRoundTrip` (`ControlProtocolTests`) +
  `windowCommandsRouteParsedInputsAndKeepActionResponses` (`ControlDispatcherTests`) + the CLI mapping in
  `CommandsTests` + the e2e `testWindowFullscreen` in `ControlWindowUITests`.
- **`window.minimize` (Dock-minimize toggle — control + ⌘M / yellow button / title-bar double-click GUI).**
  `WindowRegistry.minimize(_:mode:)` drives the standard `NSWindow.miniaturize`/`deminiaturize`.
  It is MODE-BEARING (`on`|`off`|`toggle`, default toggle via `ControlToggleMode.parse`), unlike the bare
  `window.zoom`/`window.fullscreen` toggles, because the workflow it exists for — park every window except
  the one you're on — needs a deterministic minimize without reading state first.
  It is NOT control-native: ⌘M (AppKit's own Window menu, which agterm never replaces), the yellow
  traffic-light button, and the Minimize title-bar double-click action all drive the same AppKit path.
  That is exactly why the read-back needs the `NSWindow.didMiniaturize`/`didDeminiaturize` observers in
  `ControlServer` — three GUI drivers mutate it with no control command.
  It requires the window OPEN (closed → the `window not open` error) and REJECTS a window in native full
  screen (`cannot minimize a full-screen window — window.fullscreen it first`): AppKit no-ops `miniaturize`
  there, so applying it would report success having done nothing.
  The arm is `async` and settle-POLLS `WindowRegistry.isMinimized(id) == desired` before replying, because
  miniaturize/deminiaturize are ANIMATED — without the poll the `defer`-ed `refreshWindowCache()` captures
  the pre-animation value and the next `window.list` reports the state the caller just changed away from.
  Its READ side is `ControlWindowNode.minimized` on `window.list`, and a minimized window still reports its
  `geometry` — the frame it comes back to — which needs `WindowRegistry.resolvedScreen(for:)`, since
  `NSWindow.screen` is nil while miniaturized.
  That resolver (`window.screen` → `WindowGeometry.bestDisplayIndex` largest-overlap → `NSScreen.main`) is
  SHARED by `geometry`, `move`, and `resize` on purpose: a read resolved by overlap and a write resolved
  against `NSScreen.main` would disagree on the display index, so a minimized window's frame would stop
  round-tripping back through `window.move`.
  Parking the FRONTMOST window HANDS `frontmostWindowID` off to a still-visible open window
  (`handOffFrontmost`).
  `activeWindowID` only falls back when the frontmost window's STORE is gone, and a minimized window keeps
  its store, so without the handoff `tree`, `session.new`, `quick`, the palette, and the menu bar all keep
  routing into a window sitting in the Dock — exactly the state a park-all-but-one script produces.
  AppKit keys another window on a minimize only while the APP is active, so a background script never gets
  that handoff for free; when AppKit DID hand off, `reportFrontmost` already moved the id and the guard
  skips.
  With every open window minimized there is no candidate, so the pointer stays put rather than being
  cleared.
  `minimized` is LIVE-ONLY (never persisted — see the control-api rule), so a parking script re-applies
  after a relaunch.
  Both GUI directions keep the read-back honest, verified: a ⌘M/menu minimize
  (`testMenuMinimizeReadsBackOverControl`) and a Dock-icon click restore (AppKit's default reopen handling
  — agterm implements no `applicationShouldHandleReopen`) each flip the flag with no control command in
  play.
  Four-point keep-in-sync audit: (1) `case windowMinimize = "window.minimize"` + `minimized` on
  `ControlWindowNode` in `ControlProtocol.swift` (reuses `ControlArgs.mode`),
  (2) the `.windowMinimize` dispatcher arm (mode parse + error string) → `ControlActions.windowMinimize`
  (app-side `ControlServer+WindowCommands`) → `WindowRegistry.minimize`, plus the two miniaturize
  notifications in the `ControlServer` observer array,
  (3) the `window minimize <id> [on|off|toggle]` subcommand in `agtermctlKit`,
  (4) `.windowMinimize` in `windowCommandsRoundTrip` + `windowNodeRoundTripsWithMinimized`/`…OmitsMinimizedWhenNil`
  (`ControlProtocolTests`) + `windowCommandsRouteParsedInputsAndKeepActionResponses` /
  `…RejectInvalidInputsBeforeCallingActions` (`ControlDispatcherTests`) +
  `controlWindowNodesIncludeFullscreenZoomFromClosure` (`WindowLibraryTests`) + the CLI mapping in
  `CommandsTests` + the e2e `testWindowMinimizeAndRestore` in `ControlWindowUITests`.
  **CLI positional note:** every `window` subcommand takes the id as its first positional, so `minimize`'s
  mode is a SECOND optional positional and a bare `window minimize on` would bind the mode word to the id.
  A window address is a hex UUID prefix or `active` and can never be a mode word, so `makeRequest` recovers
  that case by targeting `active` — covered by `windowMinimizeBareModeTargetsActive`.
  Do NOT "fix" it by copying `surface zoom`'s mode-first-plus-`--target` shape; that is a different family
  convention.
- **`window.new --minimized` creates a window already parked.**
  It rides the existing command as an ARG (`ControlArgs.minimized`), so there is no new `Command` case and
  the catalog count is unchanged — the `session.new --no-select` precedent, and like it the read-back is
  the EXISTING field (`window.list`'s `minimized`), so no new node field is owed.
  Ordering inside the arm is load-bearing: `WindowAccessor` presents a new window BOTH synchronously in
  `viewDidMoveToWindow` and again on the next main-queue turn, and that second present deminiaturizes — so
  `park` waits one poll tick after registration before minimizing, else the park is silently undone.
  It then hands frontmost off (the same `handOffFrontmost`), because `newWindow()` pre-sets
  `frontmostWindowID` and a window in the Dock must not be where untargeted commands land.
  It ALSO required fixing `bringForwardForUITests` (`WindowAccessor`): its guard returned WITHOUT latching
  for an already-presented window, leaving all six ticks of the 0.95 s schedule armed to fight a later
  deliberate minimize — the same oscillation hazard its own comment warns about.
  It now latches as soon as the window is on screen.
  Verified load-bearing: reverting that latch fails `testWindowNewMinimizedStaysParked`.
- **A control command that changes which window is frontmost must SAY SO — `takeFrontmost`, not AppKit.**
  `library.frontmostWindowID` is normally written by `WindowAccessor.reportFrontmost` on `didBecomeKey`,
  and AppKit does not deliver that while the app is INACTIVE — which is exactly the state a driving script
  is in.
  So `window.select` used to `raise` the window, reply `ok`, and leave frontmost on the PREVIOUS window;
  every untargeted command that followed (`session.new`, `tree`, the palette, the quick terminal) then
  routed into the window the caller had just navigated away from.
  Both `windowSelect` and `handOffFrontmost` now go through `takeFrontmost(_:)`, which records the id,
  persists the index, and runs the auto-hidden-sidebar reconcile — the same three things `reportFrontmost`
  does, minus the notification the dispatch path already covers.
  **This path has NO XCUITest coverage, deliberately.** Reproducing it requires agterm to be inactive, and
  every way to arrange that from XCUITest disturbs the user's session — activating another app jumps to
  whatever Space that app's window is on.
  A test written without deactivating the app passes with OR without the fix (verified: it did), so it
  would guard nothing.
  Verify by hand on an ISOLATED instance instead: open two windows, leave agterm in the background, run
  `window select <the non-active one>`, then check `window list` reports it `active` and that an untargeted
  `session new` lands in it.
- **`window.new` replies only once its NSWindow has ATTACHED — the open-vs-attached distinction.**
  A window is "open" the moment its `AppStore` loads (`WindowLibrary.isOpen` = `stores[id] != nil`), which
  `newWindow()` does SYNCHRONOUSLY. The NSWindow lands much later: registration happens in
  `TitleProbeView.viewDidMoveToWindow`, which needs `ContentView` to resolve its store (`Color.clear` until
  then), `.onAppear` → `resolveStore`, and a SECOND render pass before the accessor attaches.
  So `window.new` used to return with `open: true` and no NSWindow, and an immediate
  `window.resize <new id>` — the shipped `examples.md` recipe — failed with `window not open`.
  `windowNew` is therefore `async` and polls `WindowRegistry.isRegistered(id)`; `windowSelect` polls
  `library.isOpen(id) && isRegistered(id)` (the CONJUNCTION — `isOpen` alone is what `tree --window` needs
  and stays, but it flips a render pass before the NSWindow exists).
  Never gate a readiness poll on `isOpen` alone for anything that touches the NSWindow.
- **The `window.list` cache must refresh on ATTACH, not just on frontmost change.**
  `window.list` is fast-path-served from `cachedWindowNodes` and never rebuilds its own cache, so the node
  captured right after `window.new` (no geometry, no flags) stuck FOREVER for a polling script: `newWindow()`
  pre-sets `frontmostWindowID`, so the new window's first `didBecomeKey` computes `changed == false` and
  skips `.agtermWindowFrontmostChanged`, and a brand-new id has no saved frame, so `restoreSavedFrame`
  early-returns and no `didMove`/`didResize` fires either.
  `WindowRegistry.register`/`unregister` therefore post `.agtermWindowAttachmentChanged`
  (`GhosttyApp.swift`, app-side — the poster is app-side), which `ControlServer` observes to
  `refreshWindowCache`.
  It also covers the paths the `window.new` poll cannot: GUI New Window (⌘⌥N), launch reopen-all, and a
  red-button close (whose `willClose` unregisters with no command in play).
  Use `queue: .main`, NOT the `queue: nil` the sidebar observer uses: `unregister` runs near the TOP of the
  `willClose` block and `library.closeWindow` at the BOTTOM, so a synchronous refresh would capture
  `open: true` + `geometry: nil` and never refresh again.
- **`window.*` control additions (eight commands, plus `window.zoom`/`window.fullscreen`/`window.minimize`).**
  `window.new` (returns the new id + opens its window), `window.list` (returns `windows` with each window's
  `open`/`active` flag, plus `autoFollowMs` and `sidebarVisible` read from the open window's store, and
  `geometry` — the live NSWindow frame `{x, y, width, height, display}` in `window.move`/`window.resize`'s
  own coordinate system (top-left relative to the display, y down) so a read-back round-trips through them,
  read app-side via `WindowRegistry.geometry(for:)` — plus `fullscreen`/`zoomed` (the read side of
  `window.fullscreen`/`window.zoom`, read via `WindowRegistry.windowFlags(for:)` so a script can make
  those toggles idempotent) — all omitted for a closed window),
  `window.select` (raise-or-open), `window.close` (`WindowRegistry.close` →
  standard teardown), `window.rename`, `window.delete` (`canRemoveWindow` keep-at-least-one → error,
  not a GUI confirm).
  `window.list` is answered from the background-thread `cachedWindowNodes` cache (see the fast-path note
  above), refreshed after every dispatched command + on `.agtermWindowFrontmostChanged`.
  `sidebarVisible` is the first frequently-GUI-mutated field on that node, so a GUI-only ⌃⌘S sidebar
  toggle (no control command, no frontmost change) would otherwise leave it stale — `AppStore.setSidebarVisible`
  posts `.agtermSidebarVisibilityChanged` and `ControlServer` observes it to `refreshWindowCache`.
  The live, never-cached copy of `sidebarVisible` is on `tree`'s top level (main-actor per request);
  prefer it for read-then-act scripts.
  The node's `geometry`/`fullscreen`/`zoomed` are the SAME problem writ larger — live NSWindow state that a
  user drag/resize/zoom/fullscreen changes with no command, and (unlike `sidebarVisible`) with NO live tree
  copy, so a polling `window.list` would read them stale forever. `ControlServer` therefore observes the
  NSWindow `didMove`/`didResize`/`didEnterFullScreen`/`didExitFullScreen` notifications (object nil) and
  `refreshWindowCache`s on each — the fullscreen enter/exit fire AFTER the async transition, so the settled
  `styleMask` is captured; a drag's storm just keeps the cache current.
  The notification is IGNORED (`_ in`), NOT captured: a non-Sendable `Notification` can't cross into the
  `MainActor.assumeIsolated` region under Swift 6 (the `sending 'note'` error — which a Debug build compiles
  clean but the Release WMO rejects, so verify app-target concurrency changes with a Release build), so the
  refresh can't filter to an agterm window by the notification's object; a non-agterm panel firing it just
  rebuilds the same cheap agterm nodes.
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
- **`open -a agterm /path` (the OS "open terminal here" integration — Discussion #230) is WARM-ONLY on purpose.**
  `AppDelegate.application(_:open:)` resolves each URL to a directory (host-free `OpenPathResolver`:
  a folder → itself, a file → its parent, nil for a non-file / missing path), queues it in
  `pendingOpenDirectories`, and `drainPendingOpenDirectories` grafts a session into the last-active window
  via `AppActions.openSession(atDirectory:)` (which mirrors `newSession()` — note-activity + select +
  focus — but seeds the cwd from the path and targets `library.activeStore`, the SAME window the control
  channel's `session.new` defaults to).
  The drain gates on `library.activeStore?.currentWorkspaceID != nil` and retries on a bounded 0.1 s
  backoff (dropping the queue after 50 ticks so a stray folder can't wedge a timer); the scene `.task`
  hands the delegate `actions` and calls the drain once, and `application(_:open:)` calls it inline for
  the running instance.
  After a session lands it `WindowRegistry.raise`s `library.activeWindowID` (deminiaturize + make-key) so
  an "open here" into a MINIMIZED last-active window is actually visible — `NSApp.activate()` alone only
  brings the app forward and would leave the window in the Dock; a no-op for an already-frontmost window.
  `CFBundleDocumentTypes`/`LSItemContentTypes = public.folder` (role Viewer) in `Info.plist` is what puts
  agterm in Finder's right-click **Open With ▸ agterm** for folders; it is NOT required for `open -a`
  routing (odoc delivers the folder either way) — only for the Finder listing.
  **The COLD case (agterm NOT running) is deliberately unsupported and flashes-then-quits, and this is a
  hard SwiftUI-`WindowGroup` limitation, not a missing feature — do NOT re-attempt an in-process fix.**
  On a cold `open -a agterm /path` (an `odoc` AppleEvent) SwiftUI auto-opens the `WindowGroup` window,
  lets it FULLY initialize (it adopts a launch id, runs the scene `.task`, starts the control server,
  runs `consumeReopen()` so `hasReopened` is already true), then RETRACTS the un-presented window
  (SwiftUI's "don't keep an untitled window on a document launch" behavior) BEFORE delivering the open
  event — and macOS then reaps the windowless odoc process (verified: `applicationShouldTerminateAfterLastWindowClosed`
  returning `false` does NOT stop it, and no `applicationWillTerminate` fires).
  This was proven NOT to be the deployed daily-driver twin (a fully-independent bundle id fails
  identically) and is NOT fixable by the reference tricks: a forced `NSWorkspace.open` reopen never gets a
  window-less moment and the claim queue strays the re-presented window (`adoptedLaunchID` is stuck +
  `hasReopened` true); `applicationShouldOpenUntitledFile`/`applicationShouldHandleReopen` are never even
  consulted on odoc; and `WindowGroup.defaultLaunchBehavior(.presented)` (the intended API) is macOS 15+
  while the floor is macOS 14 and `SceneBuilder` rejects `if #available`.
  The reference terminals confirm the shape: AppKit ones (Ghostty, iTerm, kitty, conterm) create
  `NSWindow`s manually and never hit the retract; the SwiftUI-`WindowGroup` one that ships folder-open
  (Muxy) routes it through its OWN CLI (socket when warm, argv/`oapp` when cold), never odoc.
  The ONLY clean cold path is a relaunch (odoc → `oapp`), deliberately NOT taken (a double-launch flicker
  for the rare not-running case; agterm is a daily driver, so warm covers ~all real use).
  KEEP-IN-SYNC EXEMPT: `openSession(atDirectory:)` is the OS-`open` entry point onto a capability the
  socket ALREADY exposes (`session.new --cwd <path>`, frontmost-defaulted), so it needs no new `Command`
  case / `agtermctl` subcommand / `commands.html` entry — call it out as the exemption it is, like
  `reveal`.
