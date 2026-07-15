---
paths:
  - "agterm/Ghostty/GhosttySurfaceView*.swift"
  - "agterm/Ghostty/GhosttyApp.swift"
  - "agterm/Ghostty/GhosttyCallbacks.swift"
  - "agterm/Ghostty/GhosttyResources.swift"
  - "agterm/ContentView.swift"
  - "agterm/Views/WindowContentView.swift"
  - "agterm/Views/SplitRatioAccessor.swift"
  - "agterm/Views/TerminalView.swift"
  - "agterm/Views/TerminalSearchBar.swift"
---

## libghostty gotchas

- **Chrome colors track the terminal theme; `config_get` can't read the optional `selection-*` keys.**
  The non-terminal chrome (sidebar row text + icons, title-bar text + buttons,
  the bottom add-buttons) uses the theme's colors instead of system label colors:
  `GhosttyApp.resolveThemeColors` reads `background`/`foreground` via `ghostty_config_get` and mirrors
  `terminalForegroundColor` into the views (refreshed on `.agtermAppearanceChanged`,
  like `terminalColor`).
  But `ghostty_config_get` returns the non-optional `background`/`foreground` and **returns false for
  the optional `selection-background`/`selection-foreground`** (verified:
  `selBg=false` even when the theme sets them).
  So the selection colors are resolved by `resolveSelectionColors()` — parsing the same config sources
  `loadConfig` loads (defaults → `~/.config/ghostty/config` → the agterm settings conf,
  last-wins) for `theme`/explicit `selection-*`, then reading the named theme file under `Bundle.main/ghostty/themes/<name>`.
  The selected sidebar row draws the theme's `selection-background` pill with `selection-foreground`
  text (a luminance-contrast black/white fallback when only the background is set).
  The borderless New-Session `Menu` glyph ignores `foregroundStyle` on its label,
  so it's tinted via `.tint(chromeText)`.
- **Light/dark theme following is NATIVE — feed the raw dual value, don't pre-resolve.**
  `theme = light:X,dark:Y` is a first-class runtime conditional in the pinned libghostty (verified on
  `4dcb09ada`: `Config.zig` has `_conditional_state` + `changeConditionalState` and a light→dark test).
  So `ghosttyConfigLines()` emits the dual value RAW while following (no `isDark` param, no side-pick) and
  ghostty resolves the active side.
  The switch is NOT fully autonomous on `set_color_scheme`: `ghostty_surface/app_set_color_scheme` only
  RECORD the new conditional state and emit a SOFT `reload_config` action (which agterm does not handle,
  so it is dropped); libghostty re-resolves only when the host re-feeds the config via `update_config`.
  agterm therefore triggers the reload ITSELF on a flip.
  The appearance side is single-sourced from the APP-level `NSApplication.effectiveAppearance`, observed
  via KVO in `SystemAppearanceObserver` (the same mechanism Ghostty and the AppKit community use — Apple
  exposes no notification API for appearance).
  The observer posts `.agtermSystemAppearanceChanged` with the KVO-delivered `isDark` (`change.newValue`,
  the SETTLED value, never re-read at receive time), and `SettingsModel.appearanceChanged` threads that
  `isDark` straight into `reloadConfigPreservingSessionZoom` → `GhosttyApp.reloadConfig(surfaces:isDark:)`,
  which sets the app + each surface scheme from it and re-feeds the config via `update_config` (NOT through
  `apply()`/`writeGhosttyConfig`, whose text-diff would skip the reload — the raw dual file is byte-identical
  across flips).
  KVO is what makes this survive sleep/wake: it fires when the property SETTLES (including the belated
  update after wake), so there is no dead callback to route around — unlike the old per-view
  `viewDidChangeEffectiveAppearance` hook, which stopped firing in the wedge and left the terminal stuck
  on the old theme (the wake-from-sleep bug).
  Deliberately NOT `AppleInterfaceStyle` (wrong under macOS "Auto" scheduled switching) and NOT the
  distributed `AppleInterfaceThemeChangedNotification` (fires before `effectiveAppearance` settles).
  The flip reload PRESERVES each session's ⌘+/⌘− zoom (an automatic OS flip must not wipe it silently):
  it skips `resetSessionFontSizesAllWindows`, and `reapplySessionConfigIfNeeded` (the widened watermark
  re-assert) re-emits each zoomed session's `font-size` per surface after the shared-config broadcast.
  Only the explicit reloads (File ▸ Reload / `config.reload` / a settings change) keep the documented
  zoom-clearing contract via `reloadConfigClearingSessionZoom`.
  Every reload records `lastAppliedIsDark` from the `isDark` it applied (the KVO-delivered side threaded
  through `reloadConfig`), so "latch == applied side" holds by construction — there is ONE source now, so
  the poster-vs-rendered divergence the old two-source (view + watchdog) design feared is gone.
  `appearanceChanged` suppresses same-side re-posts via that latch (seeded `false` because a host-loaded
  config starts light-sided), so the KVO `[.initial]` launch seed and any coalesced burst drive at most
  one reload.
  A zero-surface reload is chrome-correct: `reloadConfig` sets the APP scheme (`ghostty_app_set_color_scheme`)
  before `update_config`, so the CONFIG_CHANGE clone resolves to the applied side even with no surfaces —
  a dark launch re-sides the sidebar/titlebar before any surface exists.
  The chrome retints on the same reload, but NOT from the host-loaded config: `ghostty_config_get` on
  a config the host built always reads the DEFAULT (light) conditional side — there is no C API to
  re-side a host config.
  Instead ghostty replies to `ghostty_app_update_config` with a synchronous app-target `CONFIG_CHANGE`
  action carrying the config it actually APPLIED (the dual resolved to the current side via
  `changeConditionalState`) — the same channel Ghostty.app reads its chrome colors from.
  `GhosttyCallbacks` clones that config into a lock-protected box (surface-target `CONFIG_CHANGE`s —
  watermark overlays — are ignored), and `reloadConfig` takes it for `resolveThemeColors` and frees it;
  so no `COLOR_CHANGE` callback is needed for this feature.
- **The sidebar's disclosure triangle tracks the theme via `NSAppearance`, not a color we set.**
  The expand/collapse triangle is drawn by `NSOutlineView` itself, colored from the view's `NSAppearance`
  — which follows the macOS system light/dark setting, NOT the terminal theme.
  So a light theme under macOS dark mode (or the mirror, a dark theme under macOS light mode) draws the
  triangle in the wrong brightness and it vanishes against the themed sidebar background
  (the row text/icons stay visible only because they're set explicitly to `terminalForegroundColor`).
  `WorkspaceSidebar.Coordinator.applyThemeAppearance()` pins `outline.appearance` to `.darkAqua`/`.aqua`
  from `GhosttyApp.terminalThemeIsDark`, called in `makeNSView` (launch) and `appearanceChanged` (live
  theme switch — which the Sidebar-Tint slider also posts, so a tint change re-pins).
  `terminalThemeIsDark` classifies the perceived luminance of the color the triangle actually sits on:
  the theme background with the sidebar-tint wash applied (`ThemeBrightness.isDark(…, shiftAmount:)`,
  host-free), NOT the raw background — so a strong tint that pushes a near-threshold theme across the
  0.5 midpoint still picks the readable triangle.
  The triangle color is not accessibility-observable, so this is verified by eye, not a UI test — like
  the cursor solid/hollow case.
- **Sidebar selection is drawn entirely by `SidebarRowView`, not AppKit.**
  `outline.selectionHighlightStyle = .none` (set right after `style = .plain`,
  which would otherwise reset it) so AppKit draws no selection of its own — otherwise it paints a gray
  *unemphasized* capsule whenever the sidebar isn't first responder (the normal case,
  since focus lives in the terminal), overriding any custom `drawSelection`.
  The `.plain` style (chosen over `.sourceList` to drop the built-in ~10px top inset above the first row)
  also reverts the outline's `backgroundColor` to an OPAQUE `controlBackgroundColor`, so
  `outline.backgroundColor = .clear` is set alongside `scroll.drawsBackground = false` to keep the column
  transparent over the terminal-colored/translucent window backing.
  The row draws the themed pill in `drawBackground(in:)` for every state,
  and the Coordinator's `refreshSelectionAppearance()` repaints the pills + re-tints the row text on
  selection change (AppKit won't redraw rows on its own with `.none`) and on `.agtermAppearanceChanged`.
  **The row view is the single source of truth for the cell's selection tint.**
  The pill reads `isSelected` live at draw time, but the text/icon color is applied imperatively
  (`SidebarCellView.setColors`), so the two can desync when a re-tint event is missed —
  the cell builder's `row(forItem:)` can return -1 mid-reload/expand-collapse animation
  (the constant OSC-title `reloadItem` ticks make this window easy to hit),
  and on the ~1/3 of themes using the inverted-selection idiom (`selection-background == foreground`,
  e.g. `Ghostty Default Style Dark`) a stale tint renders the row text fully INVISIBLE
  (white-on-white pill, plus the previously-selected row dark-on-dark).
  `SidebarRowView` therefore re-asserts `setColors` from its own live `isSelected`:
  its `didSet` re-tints the hosted cell on every selection flip,
  and `didAddSubview` tints a cell the moment it attaches (superseding the builder's build-time guess).
  Rename `restore` reads the same row-view `isSelected` instead of recomputing via `row(for:)`.
  Text color is not accessibility-observable, so this is verified by eye — like the disclosure-triangle
  and cursor solid/hollow cases.
  **`SidebarOutlineView.acceptsFirstResponder` is `false`** so a mouse click selects without stealing
  first responder from the terminal — that responder bounce (terminal → outline → terminal,
  via `mouseDown`'s `focusActiveTerminal`) otherwise makes AppKit re-set `SidebarRowView.isEmphasized`,
  whose setter forces `needsDisplay`, and flicks the pill on every click (programmatic selection from
  the palette/Ctrl-Tab never bounces, so it was already smooth).
  **Reconcile splits SHAPE from CONTENT** (`TreeShape` ids/order → full `rebuildAndReload`;
  `RowContent` name/icon/badge → per-row `reloadItem`) so a cwd-driven `displayName` change reloads only
  its row instead of a full `reloadData` + re-expand that re-lays-out and horizontally jitters every
  sidebar row.
  **Inline rename** paints the edit field with the terminal theme's foreground-on-background (the row's
  selection-foreground would be dark-on-dark in the system edit box), and `restore` re-applies the row's
  selection-aware color when editing ends (a same-name commit doesn't reload the row).
- **terminfo sibling dir.**
  `GHOSTTY_RESOURCES_DIR` points at `Contents/Resources/ghostty`; libghostty derives `TERMINFO` as `dirname(...)/terminfo`
  at shell spawn, so the compiled terminfo database must be a sibling at `Contents/Resources/terminfo`.
  `GhosttyResources` sets only `GHOSTTY_RESOURCES_DIR` and never `TERMINFO` (libghostty overwrites it
  at spawn).
  If this layout breaks, `TERM=xterm-ghostty` fails and keys break.
- **Surface lifecycle (EAGER deck).**
  `Session` owns its `GhosttySurfaceView` (`@ObservationIgnored`).
  The detail pane is a *deck* — `WindowContentView.detailPane` is a `ZStack` over EVERY session (`store.workspaces.flatMap(\.sessions)`),
  each session's `TerminalView` mounted at once, with only the selected one at `opacity 1` + hit-testable.
  So every session's shell spawns at startup (eager realization, not lazy-on-first-select),
  and switching is a visibility + `isActive` flip, never an `.id` swap — re-hosting a surface invalidates
  its Metal drawable and flickers the window.
  `dismantleNSView` is a no-op; `ghostty_surface_free` runs only in `destroySurface()` (reached via `teardown()`
  on close or pane-exit).
  This single-owner, single-free rule is what makes passing the view as unretained `userdata` safe.
  `destroySurface()` ALSO nils every `store`-capturing callback (`onExit`/`onExitCodeCaptured`/`onFocusChange`/`onUserInputClearsStatus`/`onFontSizeChange`/the
  four `onSearch*`) at its END — AFTER `onExitCodeCaptured` is read for the overlay exit status (niling
  it earlier would silently break `session.overlay.result`/`--block`) — to break the `store → session → surface → closure → store`
  retain cycle on every window/session close.
- **Drag-and-drop targets only the ON-SCREEN deck pane (`deckVisible` gates `registerForDraggedTypes`).**
  Every session's surface is eagerly realized, so every one is a candidate file-drop target.
  SwiftUI's `.opacity(0)` + `.allowsHitTesting(false)` on the inactive deck panes do NOT stop AppKit's
  drag machinery: the NSView keeps `alphaValue == 1`, AND AppKit's drag-destination resolution does NOT
  consult `hitTest` (verified: an off-screen surface whose `hitTest` returns nil STILL gets `draggingEntered`/`performDragOperation`).
  So if every surface stayed registered, a file drop would land on whichever surface is topmost in z-order
  (the ForEach/array order, NOT the selection) — an INVISIBLE background session — and inject the path
  there, so the visible terminal shows nothing (single-session works, which is why #52 shipped with this
  latent).
  The fix is `GhosttySurfaceView.deckVisible` (set by `TerminalView` from the deck, = session selected
  AND not hidden by a full overlay/scratch; NOT focus-gated, so BOTH panes of a visible split qualify —
  unlike `deckActive`): its `didSet` calls `updateDropRegistration()` which `registerForDraggedTypes`
  when visible and `unregisterDraggedTypes` otherwise, so only the on-screen pane is ever a drop target.
  Not `hitTest` (AppKit drag ignores it) and not a `draggingEntered` reject (AppKit does not fall through
  to the sibling behind a rejecting target — the drop is simply lost).
- **A drop inserts as a bracketed paste, never typed keystrokes.**
  `performDragOperation` routes the dropped text through `GhosttySurfaceView.insertPasted(text:)` (`ghostty_surface_text`),
  whose bracketed-paste wrapping makes the running program treat the payload as literal text, so a multi-line
  drop lands at the cursor without auto-submitting — the same behavior as ⌘V paste.
  The no-submit guarantee tracks the program's bracketed-paste mode: a program with mode 2004 OFF (a raw
  prompt, some TUIs) still submits a trailing newline, exactly the caveat ⌘V has — closing that residual is
  the separate unsafe-paste-confirmation work, not this change.
  This is deliberately NOT `inject(text:)`, which turns each `\n`/`\r` into a Return: a drop is a paste,
  while `session.type` is automation that WANTS newline→Return.
  Drop USED to reuse `inject(text:)`; this change splits it off so drop uses the bracketed-paste call and
  `session.type` keeps `inject` — do not re-unify them (the control-api note "do not simplify inject back to
  `ghostty_surface_text`" is about `session.type` only).
  (`pasteboardText`, the pasteboard reader, is shared by the drop path and the ⌘V clipboard-paste path
  `readPasteboardText`, NOT by `session.type`, which takes its text from the control request.)
  `ShellEscape.path` still escapes file-URL paths so a path with spaces lands as one shell token on Enter;
  the newline-escaping from #96 is now belt-and-suspenders under bracketed paste.
- **Search bar placement (NSSplitView-overrun rule).**
  The underlying rule: nothing may change `sessionDetail`'s ZStack SHAPE when a per-session toggle flips —
  adding/removing a child (or flipping a pane modifier) inside that HSplitView-hosting subtree re-hosts the
  `NSSplitView` and overruns it UP into the transparent titlebar.
  Two surfaces obey it in two different ways.
  The SEARCH BAR (`TerminalSearchBar`, `agterm/Views/`) stays OUT of `sessionDetail` entirely: it is anchored
  on `detailPane` via `.overlay(alignment: .topTrailing) { searchBarLayer }`, NEVER inside any session's
  `sessionDetail` subtree, so toggling it can't perturb the split at all.
  The bar reads `store.activeSession?.searchActive` and shows only when set.
  Because it is a `detailPane` `.overlay` it composites ABOVE the whole detail deck without any layout change
  — the in-deck scratch (zIndex 1 inside `sessionDetail`) and the overlay panel (zIndex 3, hosting BOTH the
  full and floating overlay) — so search-over-scratch shows the bar on top of the scratch with no HSplitView
  perturbation.
  The overlay takes the opposite route: it IS a `sessionDetail` ZStack sibling (`overlayPanel` at
  `.zIndex(3)`), but an ALWAYS-PRESENT, constant-shape one — its panel content (surface + frame +
  click-catcher) is gated INSIDE the sibling, so the ZStack child count never changes when an overlay
  opens/closes/resizes and the `NSSplitView` is never re-hosted, even when a floating overlay leaves the
  pane(s) VISIBLE behind its opaque panel.
  (`overlayPanel` is per-session in the eager deck, so its program runs regardless of which session is
  active — see the surface-lifecycle note.)
- **Window overlays sit BELOW the custom titlebar, NOT as a body-level `.overlay` (transparent-titlebar-scrim
  rule).** The quick terminal, command palettes, and Ctrl-Tab switcher render via `windowOverlayLayer`
  — a ZStack sibling INSIDE the body's root ZStack, inset by `titlebarHeight` (`.padding(.top, titlebarHeight)`)
  and at `.zIndex(1)`, with `customTitlebar` at `.zIndex(2)` ABOVE it.
  They are NOT body-level `.overlay { … }` (which layer above EVERYTHING).
  Reason: `customTitlebar` is transparent (no backing) AND AppKit's native titlebar backing is deliberately
  hidden for translucency (`WindowAppearance`); a full-window overlay's dim scrim (`Color.black.opacity(0.2)`)
  attached as a body `.overlay` composites OVER the titlebar and darkens/seams it — visible only in the
  TALL non-compact (48px) titlebar (the cwd-subtitle strip lives in the content area below the native
  titlebar band; the 30px compact bar stays within the band and hides it).
  Keeping the titlebar at the highest zIndex means a scrim can never cover it;
  insetting the overlays by `titlebarHeight` keeps them off the titlebar entirely.
  The empty `windowOverlayLayer` (all three conditionals false) is a bare `.frame`-sized `ZStack` — an
  empty frame is NOT hit-testable, so the terminal below stays interactive (do NOT put a `Color`/`contentShape`
  at that level).
  Diagnosed by codex; the fix preserves translucency (titlebar stays backing-free) and keeps the overlays
  outside `detailPane`/`sessionDetail`/`HSplitView` (no split perturbation).
  Do NOT "fix" this with a permanent `.background(terminalColor)` on `customTitlebar` — it masks the
  symptom but breaks the opacity/blur chrome.
- **Under window translucency every surface renders a fully transparent background — never leave a
  surface visible beneath the FULL overlay.**
  The translucency setting pins `background-opacity = 0` for every ghostty surface (the window's AppKit
  backing supplies the tint), and the FULL overlay deliberately has no opaque SwiftUI backing.
  Any surface left mounted at opacity 1 below it shows straight through — a "the overlay opened under
  the scratch" report is SEE-THROUGH, not a z-order inversion (the layer compositing order was verified
  correct in every open sequence: the overlay's layer sits above the scratch's).
  `sessionDetail` therefore hides EVERY covered surface when `session.fullOverlayActive`:
  the pane(s) via `hideForOverlay`, the scratch via its own `opacity(0)` + `allowsHitTesting(false)` +
  a `deckVisible` gate (so a covered scratch is also not a file-drop target).
  The FLOATING (sized) overlay and the quick terminal need none of this — both draw an opaque
  `terminalColor`-backed panel, so nothing shows through them.
- **Non-zero backing size.**
  Create the surface only when the view has a non-zero backing size, else the Metal layer renders blank.
  `pendingSurfaceCreation` defers creation until `setFrameSize` reports a real size.
- **Re-parent invalidates the drawable → force a repaint.**
  The split toggle re-hosts a surface between the `HSplitView` and a standalone host,
  detaching/re-attaching the `NSView` and invalidating its Metal drawable.
  `ghostty_app_tick` (demand-driven, coalesced on wakeup) only draws surfaces flagged dirty,
  and `ghostty_surface_set_size` to an UNCHANGED grid is a no-op, so a re-attached pane keeps a blank
  drawable even though its terminal buffer is intact (verified: `ghostty_surface_read_text` returns the
  full screen while the pane shows blank).
  `updateMetalLayerSize` calls `ghostty_surface_refresh` after every size push to force the redraw.
  This is a DISPLAY fix, not a buffer fix.
  The parked font-increase blank is ALSO buffer-intact (a `read_text` probe returns the full screen),
  but is harder: it is NOT fixed by `refresh` or a forced `set_size` jitter,
  and a font change doesn't resize the view so this `updateMetalLayerSize` path never fires for it —
  still parked.
- **Dashboard grid = the N-PANE generalization of terminal-zoom's reparent, focus inverted.**
  Where `surface.zoom` reparents ONE session surface into the window and focuses it, the dashboard
  (`DashboardView` + `WindowContentView+Dashboard.swift`, driven by the host-free `DashboardController`)
  reparents up to `DashboardLayout.maxCells` (9) PANE surfaces into a `ceil(sqrt(n))`-wide grid and
  focuses NONE while open — every cell is view-only.
  The cell unit is a `DashboardMember` = session + `.primary`/`.split`: a non-split session is ONE
  `.primary` cell, and a SPLIT session (`hasSplit`) shows as TWO cells — its `.primary` AND `.split`
  panes — so the app-side expansion in `ControlServer.setDashboard` yields both, and the 9-cap counts PANES.
  Each cell hosts its OWN pane surface — `.primary` → `\.surface` via `makeSurface`, `.split` →
  `\.splitSurface` via `makeSplitSurface` — via `TerminalView(isActive: false, deckVisible: false,
  reportsFocusChange: false, viewOnly: true)` with a stable slot `.id` (`-dashboard-primary`/`-dashboard-split`),
  so the grid shows the LIVE shell, never a fresh one.
  The generalized `dashboardHostsSurface` claims EACH member's pane slot (both panes of a split member),
  so `deckHostsSurface` yields a `Color.clear` placeholder in each claimed deck slot — the SAME "keep the
  deck mounted, swap only the hosted slot" contract zoom uses, generalized to N panes, so control-opened
  split/scratch/overlay surfaces still realize behind the grid.
  Enter on a cell selects the session, closes the dashboard, then focuses the cell's EXACT pane (the split
  pane for a `.split` cell, else the main pane).
- **Dashboard placement: a `windowOverlayLayer` branch, NOT a body-level `.overlay`.**
  It renders while `controller.isOpen` at `zIndex 1`, inset by `titlebarHeight`, below the `customTitlebar`
  — the same transparent-titlebar-scrim rule the quick terminal / palettes / switcher follow (see the
  `windowOverlayLayer` note above); never a body-level `.overlay`, which would composite over the titlebar.
- **Dashboard view-only is FIVE cooperating gates — hit-testing off alone is not enough.**
  `isActive: false` only stops auto-focus; it does NOT disable `mouseDown`/first-responder eligibility
  (see the surface-bridge note), so a click would still reach `mouseDown` and the retry loops would
  re-grab the surface.
  The full set:
  - each cell's terminal is `.allowsHitTesting(false)`, with a transparent hit target ABOVE it that flashes
    the highlight then enters that session+pane on a single click (the terminal itself takes no hits);
  - `GhosttySurfaceView.viewOnly` (threaded via `TerminalView`) makes the member surface refuse to be
    first responder (`acceptsFirstResponder = !viewOnly`) and drop hits (`hitTest` returns nil when
    `viewOnly`), so even a stray reactivation click can't focus it;
  - `deckInteractive` (`WindowContentView.swift`) is gated on `terminalZoom.target == nil &&
    !dashboard.isOpen`, killing pane focus, scratch/overlay auto-focus, drag registration, and
    background-click handling while the dashboard is up;
  - an AppKit key-catcher owns first responder and CONSUMES every key (arrows → `controller.move`,
    Enter → select+close, Esc → close, everything else swallowed), so no cell is ever first responder
    and every cursor draws hollow;
  - `AppActions.focusActiveSession` early-returns when `dashboardActive` (the window's controller
    `isOpen`), mirroring its existing zoom/palette guards — without it the ~12×0.03s
    `makeFirstResponder` retry would re-grab the active session's now-view-only grid cell and leak the
    keyboard to the terminal (a real bug the e2e surfaced).
- **Dashboard cell font uses a TRANSIENT `GhosttySurfaceView.dashboardFontOverride`, never a record-restore
  of `session.fontSize`.**
  There is no absolute font setter and a font round-trips through the model (`reportFontSize` →
  `onFontSizeChange` → `store.setFontSize`), and a reload re-emits `session.fontSize` — so a
  record-then-restore of the session font would be clobbered by a reload and would persist the dashboard
  size.
  Instead the per-surface config composer uses `dashboardFontOverride ?? session.fontSize`,
  `reapplySessionConfigIfNeeded` REASSERTS the override across a config reload (so a File ▸ Reload while
  the dashboard is open doesn't strand or clear the grid font), and `reportFontSize` is SUPPRESSED
  (`guard dashboardFontOverride == nil`) while the override is set, so the CELL_SIZE round-trip can't
  write the dashboard size into `session.fontSize`.
  On open the wiring sets each member cell's OWN pane surface override from `fontMode` (`.auto` via
  `DashboardLayout.dashboardFontSize`, base `AppSettings.fontSize ?? 13.0` ghostty default; `.fixed`
  value; `.untouched` leaves it nil) — `.primary` → `\.surface`, `.split` → `\.splitSurface`; on close it
  CLEARS the override with a store-wide sweep of BOTH `\.surface` AND `\.splitSurface` of every session
  (a split member's two panes can each carry one) and rebuilds from the session model — no record-restore
  dictionary.
- **Zoom ↔ dashboard are reciprocally exclusive.**
  `ControlServer.setDashboard` closes any active zoom before opening the grid, and
  `WindowContentView`'s `.onChange(of: terminalZoom.target)` closes the dashboard when a zoom becomes
  active — so the two view modes never stack.
- **Opening/closing the dashboard resizes each member's pty — unavoidable.**
  A cell is smaller than the full pane, so reparenting a member into (and back out of) its cell resizes
  its surface, which resizes the pty; the program receives a `SIGWINCH`/resize event and may redraw.
  "View-only" means no INPUT reaches the cell, NOT that the member's process is untouched — a full-screen
  TUI reflows to the cell on open and back on close.
- **strdup buffer lifetime.**
  `working_directory` (and `initial_input`) `const char*` buffers must outlive `ghostty_surface_new`;
  they are held in a `nonisolated(unsafe)` array and freed only in `destroySurface()`.
- **Cursor shape is a config default, not set in code.**
  `agterm/Resources/ghostty-defaults.conf` (loaded first in `GhosttyApp.loadConfig`,
  so a user's `~/.config/ghostty/config` still overrides it) pins a steady block cursor with `cursor-style = block`
  + `shell-integration-features = no-cursor,no-title`.
  The shell-integration `cursor` feature re-emits a DECSCUSR bar (`\e[5 q`) on every prompt and resets
  to the config default while a command runs, so setting `cursor-style` alone can't stop the bar-at-prompt
  — disabling the feature with `no-cursor` is what keeps the cursor a block everywhere.
  `no-title` disables the integration's auto-title (zsh `%(4~|…/%3~|%~)` / bash `\w`),
  which would emit OSC 2 with the abbreviated cwd on every prompt and — since `Session.displayName` prefers
  `oscTitle` over the cwd basename — always override the sidebar name with a noisy `…/a/b/c` path.
  Explicit titles still win: a remote host over SSH or a user `PROMPT_COMMAND` emitting OSC 2 sets `oscTitle`,
  and only local auto-titling is suppressed (OSC 7 pwd reporting is a separate feature,
  unaffected).
  **Caveat — a title is only kept while a foreground process HOLDS the local shell.** A one-shot local
  `printf` OSC 2 sets `oscTitle`, but the shell immediately returns to its prompt where the title is
  cleared again (the prompt cycle), so the sidebar name reverts to the cwd basename.
  A real `ssh` keeps its title precisely because it BLOCKS the local prompt cycle (and its remote re-emits
  each prompt); to reproduce that locally — e.g. in a test — hold the shell after setting the title:
  `printf '\033]2;X\007'; cat`.
  So a remote session's `oscTitle` (and the `subtitleDetail` second line that prefers it) is reliable,
  but a quick local printf "looks broken" only because it isn't held.
  See [[ui-tests]] for the test pattern.
- **Cursor focus = window-key AND first-responder (`GhosttySurfaceView.liveFocus`).** libghostty draws
  a solid (blinking) cursor only on a surface told it is focused via `ghostty_surface_set_focus`,
  a hollow outline otherwise. agterm reports `liveFocus = window.isKeyWindow && window.firstResponder === self`
  (the LIVE responder, NOT a cached flag), pushed through `updateGhosttyFocus()`.
  The key-window gate is LOAD-BEARING: AppKit's first responder is PER-WINDOW and does NOT resign when
  a window merely loses key, so without it EVERY window's active surface would keep a blinking cursor
  at once.
  Each surface observes `NSWindow.didBecomeKey/didResignKeyNotification` (`object: nil`,
  re-evaluating its OWN `isKeyWindow` on any window's key change) and re-pushes focus,
  so a background window goes hollow and the new key window's active surface goes solid.
  `becomeFirstResponder`/`resignFirstResponder` push DIRECTLY (become gated on `isKeyWindow`),
  because `window.firstResponder` is not yet self inside those calls; `createSurface`/`viewDidMoveToWindow`/the
  auto-focus + reparent grabs read `liveFocus`, so a re-hosted pane reports its TRUE (non-)focus instead
  of a stale latch — which is what left BOTH split panes solid on open before this.
  `onFocusChange` (the `splitFocused` model tracking) stays tied to first-responder transitions,
  NOT key state, so a session keeps its focused pane while its window is inactive.
  The observers are removed in `destroySurface`/`deinit`; `focusObservers` is `nonisolated(unsafe)` for
  the deinit read.
  Cursor solid/hollow is not accessibility-observable, so it is NOT unit/UI-testable — verified by instrumenting
  `set_focus` and reading `log show` across split-open + multi-window key switches (exactly one focused
  surface app-wide in every case).
- **A background window's LEFT reactivation click reaches the surface (`acceptsFirstMouse`), and `scrollWheel` self-syncs the mouse cell.**
  `GhosttySurfaceView.acceptsFirstMouse(for:)` returns true ONLY for `.leftMouseDown`, so the click that
  raises an inactive window also runs `mouseDown` — selecting the clicked split pane (`makeFirstResponder`
  → `onFocusChange` → `splitFocused`), the counterpart to the first-responder path above, instead of AppKit
  swallowing the click just to raise the window.
  It is gated to the LEFT button on purpose: a first-mouse right/middle click would otherwise reach
  `rightMouseDown`/`otherMouseDown`, which forward to libghostty, and with the default
  `right-click-action = paste` (`AppSettings.rightClickPaste`, nil = paste) that would paste the clipboard
  into a window you only meant to raise.
  Separately, `mouse_scroll` reports at libghostty's LAST-KNOWN cell, and a no-mouse-move reactivation
  (cmd-tab/keyboard, or scrolling to reactivate with the pointer already inside) fires no `mouseDown`/`mouseEntered`,
  so the position is stale or `-1,-1` (from `mouseExited`).
  `scrollWheel` therefore pushes `ghostty_surface_mouse_pos` from its own event before `mouse_scroll`, but
  ONLY when the point is stale — it differs from `lastReportedMousePoint`, which every mouse handler updates
  through the shared `reportMousePos` helper.
  So the first scroll after a no-move reactivation lands at the real cell instead of doing nothing until you
  nudge the mouse, while a normal already-synced scroll does NOT re-push the same cell on every packet —
  which in an any-motion + sgr-pixel mouse-reporting TUI would otherwise emit a synthetic motion report per
  packet.
  It is the companion to the `mouseEntered` restore (which only covers cross-the-boundary re-entry).
  Like the cursor-focus case, this input plumbing is not accessibility-observable and is verified by hand,
  not a UI test.
- **Only the ON-SCREEN deck pane may set the process-global cursor (`deckVisible` gates every cursor write).**
  Every session's surface is eagerly realized with a `.mouseMoved`/`.cursorUpdate` tracking area, and AppKit
  tracking ignores SwiftUI `.opacity(0)`/sibling overlap the SAME way drag-destination resolution does — a
  hidden surface's `visibleRect` is NOT clipped by the visible pane stacked over it.
  So several stacked surfaces receive the SAME `mouseMoved` and each ran `NSCursor.set()`; a hidden session
  cached at a different mouse shape (a mouse-reporting TUI, or an OSC 22 pointer shape) then flickered its
  shape over the visible terminal on every move — issue #225's arrow↔I-beam flicker, seen in RESTORED
  sessions precisely because restore mounts MANY surfaces at once (one session shows no competition).
  The fix gates the cursor on `deckVisible` (the same on-screen-pane flag drag registration uses) in TWO
  places: `setupTrackingArea` installs the tracking area only while `deckVisible` (a hidden surface gets no
  `mouseMoved` at all — this also stops the `reportMousePos` fan-out to every hidden TUI), AND the three
  cursor-set sites (`mouseMoved`, `applyMouseShape`, `cursorUpdate`) each `guard deckVisible`.
  The tracking-area gate ALONE is NOT enough: AppKit still delivers a `cursorUpdate` to a HIDDEN surface on
  window activation, so a background pane cached at a stale shape would paint it on the reactivating click
  without the `.set()`-site guards.
  Conversely AppKit does NOT re-issue a `cursorUpdate` to the VISIBLE pane on bare activation, so
  `reassertCursorOnActivation` (called from the `didBecomeKey` observer) re-asserts the visible pane's cursor
  when its window becomes key — gated `deckVisible` + `isKeyWindow` + pointer-in-bounds, so it never paints
  the terminal cursor over the sidebar or a background window, and it wins uncontested since hidden panes are
  already muted.
  `deckVisible` itself is computed in `WindowContentView.sessionDetail` (the pane's `visible`, plus the
  scratch and overlay `deckVisible` expressions); each must exclude EVERY layer that covers the surface, or
  the covered surface keeps `deckVisible = true` and competes anyway.
  Full overlay / scratch drop it via `hideForOverlay`; the window-level quick terminal drops it via
  `!quickTerminal.isVisible` on the pane, scratch, AND overlay expressions (it covers the deck WITHOUT
  touching `deckInteractive`/`hideForOverlay`, so without that term the covered surfaces flicker against the
  quick-terminal surface — issue #225's quick-terminal path).
  Two residual cases remain, both far milder than the original many-surface flicker and both predating this
  change.
  A FLOATING overlay leaves the pane VISIBLE in the margin around the panel (so the pane legitimately keeps
  `deckVisible = true`), and no boolean gate can scope the cursor to the panel-vs-margin split — over the
  panel's overlap the pane and the overlay surface can still show competing shapes.
  The command palette and Ctrl-Tab switcher (window-level SwiftUI overlays NOT in the `deckVisible`
  predicate) likewise leave the covered pane `deckVisible = true`, so over them the covered terminal surface
  can still write its cached cursor (cosmetic, plus a rare drop-through) — but that is ONE terminal surface
  under a SwiftUI overlay, not two terminals fighting, and these are transient keyboard-driven overlays the
  pointer rarely rests on.
  Both are left as known limitations of the boolean approach rather than chasing every window-level overlay
  into the predicate (the quick terminal is gated because it is the persistent, mouse-used one).
  The tracking + pointer methods live in `GhosttySurfaceView+Tracking.swift` (`currentTrackingArea` is
  `internal`, not `private`, so that extension can manage the stored area).
  Cursor shape is not accessibility-observable, so this is verified BY EYE (like the cursor solid/hollow
  case), reproduced deterministically with several stacked sessions given differing OSC 22 shapes
  (`printf '\033]22;crosshair\007'`).
  Do NOT "simplify" this to only the tracking-area gate (the refocus crosshair returns) or only the
  `.set()`-site gates (hidden TUIs keep getting the `reportMousePos` fan-out).
- **OSC 52 clipboard access is gated in OUR callbacks, not by a ghostty-internal dialog.**
  A program reading (`\e]52;c;?\a`) or writing (`\e]52;c;<base64>\a`) the system clipboard reaches agterm
  through `read_clipboard_cb`/`confirm_read_clipboard_cb` and `write_clipboard_cb` (`GhosttyCallbacks`).
  libghostty delegates the `ask` policy to the host: the write callback carries a `confirm` bool (true
  when `clipboard-write = ask`), and the read confirm callback carries a `ghostty_clipboard_request_e`
  (`GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ` for a program read, `..._PASTE` for ⌘V) — only `OSC_52_READ`
  is gated, so pastes never prompt.
  `ClipboardPromptController` (`@MainActor`) owns an app-session-scoped host-free `ClipboardPromptPolicy`
  (`ask`/`allow`/`deny` remembered per direction until agterm quits, shared across every window and
  terminal session: the "don't ask again this session" choice) and shows an `NSAlert` sheet.
  Coalescing is keyed by (requesting surface, direction), so a program looping OSC 52 collapses to one
  prompt while a DIFFERENT surface's concurrent request gets its OWN prompt, so one Allow never authorizes
  another surface's read (or, under `clipboard-write = ask`, its write: the write callback's userdata is
  the surface too, recovered the same way as the read confirm's).
  Two rules the build proved the hard way: the callback fires INSIDE a libghostty tick, so the sheet is
  deferred via `DispatchQueue.main.async` (a modal run loop opened inside the tick re-enters it); and a
  DENIED read must complete with an EMPTY string and `confirmed = true`, because completing with
  `confirmed = false` leaves the request unconfirmed and libghostty just re-asks, LOOPING the dialog.
  The clipboard callbacks run on the main actor inside the tick (verified), so the UNGATED write
  (`clipboard-write = allow`, the default) sets the pasteboard SYNCHRONOUSLY: deferring it would let a
  same-tick OSC 52 read observe the stale clipboard.
  Read gating rides ghostty's own `clipboard-read = ask` default (verified: the confirm callback fires
  with no explicit config); write stays `allow` by default (matches mainstream terminals, so a legit
  remote yank isn't interrupted) and opts into `ask`/`deny` via the agterm-scoped `ghostty.conf`.
  The deferred read completion captures the `GhosttySurfaceView` (NOT the raw surface pointer) and
  re-reads `view.surface` on the main actor before completing, skipping the call when it is nil: a
  session/window/pane close (or `session.close` over the control socket) can `ghostty_surface_free` the
  surface WHILE the sheet is open, and completing on the freed pointer is a use-after-free.
  Freeing the surface already discards its pending clipboard request, so skipping is safe and loop-free.
  The ghostty request `state` is `nonisolated(unsafe)` (same lifetime as the surface, guarded by that same
  `view.surface` check).
  The dialog is AppKit and not unit-tested (only `ClipboardPromptPolicy` is); the gating was verified with
  an isolated dev instance driving OSC 52 read/write by hand.

