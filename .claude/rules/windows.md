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

## Windows

A window is a named, persisted workspace/session bundle rendered in exactly one macOS window. One bundle
never appears in two windows, and one window never holds two bundles. Shared live state and cross-window
session drag are out of scope.

- The Dock menu snapshots the last-active store and strongly retains item targets because `NSMenuItem.target`
  is weak. Invalidate previous targets on rebuild. Every item except New Window keeps its captured scope,
  rechecks that window's modal/dashboard/zoom state, raises it, and synchronously publishes
  `frontmostWindowID` before invoking shared actions. Stale items become inert. New Window captures no
  store and bypasses modal gating. Do not defer scope publication to key-window notifications.
- Dock actions compose existing session/window/quick/dashboard/select capabilities and need no new command.

## Model and persistence

- Host-free `WindowLibrary` owns ordered `WindowInfo` values, live stores, and `frontmostWindowID`.
  Use `WindowInfo`, not `Window`, to avoid framework name collisions. `WindowsIndex` has its own version,
  independent of `Snapshot.version`; `WindowEntry` stores ID, name, and open state.
- A window is open when its store is loaded. `loadStore` lazily caches `windows/<id>.json`; `newWindow`
  seeds workspace 1 and a `$HOME` session. Keep at least one library entry. `openIDs` drives relaunch.
  `applyInactiveWindowSidebarHiding` shows the active sidebar and hides other windows' sidebars.
- `closeWindow` that empties the open set pins `frontmostWindowID` to the closing window.
  The persisted index then has no open entries, so the next launch takes reopen's never-windowless
  fallback — the pin makes it reopen the exit window (whose captured commands were just persisted),
  not `windows.first`.
- State lives under `AGTERM_STATE_DIR` or Application Support: `windows.json` plus
  `windows/<uuid>.json`. Legacy `workspaces.json` remains dormant after migration. `PersistenceStore.fileName`
  defaults to `workspaces.json`; index and window mutations save only their own files.
- Bootstrap never throws. Load a valid index; otherwise recover every UUID-named per-window file before
  considering legacy migration or an empty seed. Recovered files are appended before `loadStore`, named
  `window N`, all opened, and the first made frontmost. Missing/corrupt window snapshots open with a
  default workspace/session. The library is never empty after launch.

## Scene lifecycle

- Use plain `WindowGroup(id: "terminal")`, not value-based `WindowGroup(for:)`: with restoration off,
  the value form opens no launch window and its task never bootstraps. The library owns the open set.
- Appearing windows claim IDs from a FIFO queue: seed launch first, pop with `claimNextWindowID`, enqueue
  new windows, and dismiss SwiftUI-restored strays. `reopenWindows` opens remaining IDs once behind
  `hasReopened`.
- Do not use `.restorationBehavior`; it requires macOS 15, the floor is 14, and `SceneBuilder` rejects
  availability conditionals without an `AnyScene` eraser. Deduplicate by ID on both systems.
- `TitleProbeView` sets `frameAutosaveName("agterm-window-<id>")`, reports key/main changes, and on close
  tears down surfaces before `closeWindow`.
  An app-exit close captures foreground commands first, while those surfaces are still alive; see
  [[settings]] for that contract.
- `AppActions`, commands, palette construction, `ControlServer`, `SettingsModel`, and `SessionSwitcher`
  resolve through observable `WindowLibrary.activeStore`: frontmost open store, then first open store.
- On termination, set `isTerminating` before windows close, then `saveAllOpen` and `saveIndex`. This preserves
  live cwd changes, which structural saves may not capture. Selection and font use a roughly 0.3-second
  `Debouncer`; structural mutations save synchronously and cancel pending saves.
- Quit uses `applicationShouldTerminate` and a warning alert with host-free `openCounts` and
  `QuitPrompt.message`. Skip it for no open windows, XCUITest, or an unwired library during the first
  roughly four seconds. The GUI-only prompt is keep-in-sync exempt and manually verified.
- App-side `WindowRegistry` maps IDs to `NSWindow`. Register/unregister through `TitleProbeView`;
  `raise` deminiaturizes and fronts, and `close` uses `performClose` so standard teardown runs.

## Quick terminal, notifications, and environment

- `QuickTerminalController` is per-window state registered by ID, never a singleton. Providers bind to
  that window; frontmost calls use `activeWindowID`, control reports `no open window`, and settings
  broadcast to all controllers.
- While quick terminal is visible, no deck surface may be active. Gate main, split, maximized split,
  scratch, and overlay with `deckInteractive && isActive && !quickTerminal.isVisible`; the overlay shares
  the containing window's first responder.
- Notification identity is `"<windowID>:<sessionID>:<paneRole>"`. Capture resolves the owning window.
  Reveal reopens a closed window through raise or enqueue/open, polls until its store loads, then selects
  and focuses the pane. Unknown window/session only activates. This internal route is keep-in-sync exempt.
- `GhosttySurfaceView` accepts an environment dictionary. `strdup` keys/values, retain a
  `[ghostty_env_var_s]` beside `configCStrings`, call `ghostty_surface_new` inside its mutable-buffer
  lifetime, and clear it with the strdup storage on destroy/deinit.
- Tree surfaces inject `AGTERM_ENABLED`, window/workspace/session IDs, and `AGTERM_SOCKET`; split/overlay
  inherit the session IDs. Quick terminal gets enabled, window, and socket only. Use
  `ControlServer.boundSocketPath`, omitting the variable before bind, so overridden sockets match children.

## Window state controls

- `window.zoom` uses `NSWindow.zoom`: visible-frame maximize, not native fullscreen. The control toggle
  requires an open window. Read back `isZoomed` on `window.list`.
- `WindowControlArea` handles titlebar dragging and double-click because SwiftUI titlebar views do not
  receive native handling. Set `mouseDownCanMoveWindow = false`; double-click reads live
  `AppleActionOnDoubleClick`: Zoom/Fill zooms, Minimize miniaturizes, Do Nothing does nothing, and an absent
  key defaults to Zoom. `AGTERM_UITEST_DOUBLECLICK_ACTION` overrides via environment because launch
  arguments hit FB11763863. Decorative titlebar regions disable hit testing; buttons remain above them.
- `window.fullscreen` uses `toggleFullScreen`, a distinct native Space. GUI surfaces are the palette,
  `BuiltinAction.toggleFullscreen` with Ctrl-Command-F through the key monitor, AppKit's own injected
  View menu item, and the green button. Control resolves an open ID; read back the `.fullScreen` style mask.
- agterm ships NO full screen menu item. AppKit appends its own "Enter Full Screen" (`toggleFullScreen:`,
  Globe+F) to the View menu as it is prepared for display, so any item of agterm's own is a visible
  duplicate. All of these were measured and none suppresses it: removing the injected item on
  `NSMenu.didBeginTrackingNotification` (posted once per ROOT tracking session, before the injection);
  removing it deferred one runloop turn (too late — the displayed menu is already snapshotted, so the model
  loses the item while the duplicate stays on screen); registering `NSFullScreenMenuItemEverywhere` false,
  which macOS 26 ignores; and giving agterm's own item the `toggleFullScreen:` selector, which AppKit
  injects past anyway. Do not install a menu delegate, which would replace SwiftUI updates.
- `toggle_fullscreen` therefore has no menu item to carry its equivalent, and is matched in
  `CustomCommandRunner`'s key monitor instead — the one built-in that does not ride a SwiftUI shortcut.
  A half-typed leader sequence still wins. The menu affordance and Globe+F are AppKit's item.
- `testViewMenuHasSingleFullScreenItem` asserts the item COUNT and matches on TITLE. Matching by
  identifier silently fails to find the injected item, which is why the assertion it replaced passed for
  months while the duplicate was on screen. Never trust the AX tree alone here: it reflects the menu model,
  which a removal can change without changing the pixels. Verify a menu fix by opening the menu and looking.
- `window.minimize` accepts `on`, `off`, or `toggle` through `ControlToggleMode`, defaulting to toggle.
  Deterministic modes support park-all-but-one. GUI Command-M, yellow button, and titlebar preference use
  AppKit directly, so observe `didMiniaturize`/`didDeminiaturize` to keep control read-back current.
- Reject closed or full-screen windows for minimize; AppKit silently ignores full-screen miniaturize.
  Poll the animated transition until `isMinimized == desired` before refreshing the cache. Retain geometry
  for minimized windows through shared `resolvedScreen`: live screen, largest-overlap display, then main.
  Geometry reads, move, and resize must share this resolver to preserve display-index round trips.
- Minimizing the frontmost window calls `handOffFrontmost` to a visible open window. A minimized store
  remains loaded, so `activeWindowID` cannot correct it. Background scripts receive no AppKit key-window
  handoff; if all windows are minimized, retain the pointer. Minimized state is live-only.
- CLI window subcommands normally take ID first. A bare `window minimize on` would parse `on` as the ID;
  recover mode words by targeting `active`, as pinned by `windowMinimizeBareModeTargetsActive`. Do not copy
  the mode-first `surface zoom --target` convention.
- `window.new --minimized` reuses the existing command argument and `window.list.minimized`. Wait one poll
  tick after registration before parking because `WindowAccessor` presents again on the next main turn.
  Then hand frontmost off. `bringForwardForUITests` must latch as soon as the window is already presented;
  otherwise its six ticks over 0.95 seconds undo a deliberate minimize.
- Control changes to frontmost state must call `takeFrontmost`, which records, persists, and reconciles
  auto-hidden sidebars. Inactive apps do not receive `didBecomeKey`, so relying on AppKit makes following
  untargeted commands hit the previous window. This requires manual isolated verification: background
  agterm, select the non-active window, confirm list marks it active and untargeted session creation lands
  there. XCUITest cannot deactivate without disturbing the user's Space.

## Attachment and cache

- `window.new` is not ready when its store becomes open. Its `NSWindow` registers only after store
  resolution, a second render, and `viewDidMoveToWindow`. Poll `WindowRegistry.isRegistered`; selection
  waits for both open and registered. Never gate NSWindow work on `isOpen` alone.
- `window.list` is served from `cachedWindowNodes`. Registration and unregistration post
  `.agtermWindowAttachmentChanged`; observe it on `.main`, not synchronously, because unregister precedes
  `closeWindow` and an immediate refresh captures `open: true` without geometry.
- Refresh on every command, frontmost change, sidebar visibility change, attachment, and NSWindow
  move/resize/fullscreen/minimize transitions. Ignore notification payloads: carrying non-Sendable
  `Notification` into a main-actor region fails Swift 6 Release WMO even when Debug passes.

## Control catalog

- Commands are `window.new`, `window.list`, `window.select`, `window.close`, `window.rename`,
  `window.delete`, `window.resize`, `window.move`, `window.zoom`, `window.fullscreen`, and
  `window.minimize`. Keep their protocol cases, dispatch/actions, CLI mappings, and tests synchronized
  per the repository-wide control contract.
- `window.list` returns ID/name/open/active plus open-store auto-follow/sidebar state and live
  geometry/fullscreen/zoom/minimize. Closed-window live fields are omitted. Geometry is top-left,
  display-relative, y-down, matching move/resize.
- Delete enforces at least one library entry without GUI confirmation. `window.select` raises or opens.
  Window ID resolution accepts active, exact ID, unique prefix, ambiguity, and not found; most library
  commands can address closed entries.
- `window.resize` and `window.move` are control-native and require open windows. Validate positive sizes,
  then clamp inside `WindowRegistry` with host-free `WindowGeometry`: size to min/visible frame, origin to
  a grabbable screen strip. `WindowGeometry` may use CoreGraphics but not AppKit/Metal.
- Global `--window` requires that window open. Without it, untargeted operations use active placement,
  while an explicit session/workspace ID resolves across all open stores and returns its owning store.
- For exact coverage names and command inventory, see [[control-api]]; do not duplicate its audit here.

## Finder open

- Warm `open -a agterm /path` (Discussion #230) resolves folders to themselves and files to parents,
  queues them, and drains into the active store through `openSession(atDirectory:)`. Gate on a current
  workspace and retry every 0.1 seconds for at most 50 ticks. After insertion, raise the active window so
  a minimized target becomes visible.
- `CFBundleDocumentTypes` with `public.folder` and Viewer role adds Finder's Open With entry; it is not
  required for the `odoc` event itself.
- Cold `open -a` is deliberately unsupported. SwiftUI fully initializes then retracts its auto-created
  `WindowGroup` before delivering `odoc`, and macOS reaps the windowless process without
  `applicationWillTerminate`. Independent bundle IDs reproduce it; preventing last-window termination,
  forced reopen, untitled/reopen delegates, and in-process claim tricks do not solve it.
- AppKit terminals create windows manually; Muxy's SwiftUI implementation routes cold opens through its
  CLI. The clean workaround is an `odoc` to `oapp` relaunch, rejected because it double-launches and
  flickers for the rare cold case. `defaultLaunchBehavior(.presented)` requires macOS 15 and cannot be
  conditionally expressed in the macOS 14 `SceneBuilder`.
- Finder open composes `session.new --cwd` with frontmost placement, so it is keep-in-sync exempt.
