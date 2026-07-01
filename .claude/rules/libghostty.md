---
paths:
  - "agterm/Ghostty/GhosttySurfaceView.swift"
  - "agterm/Ghostty/GhosttyApp.swift"
  - "agterm/Ghostty/GhosttyCallbacks.swift"
  - "agterm/Ghostty/GhosttyResources.swift"
  - "agterm/ContentView.swift"
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
- **Sidebar selection is drawn entirely by `SidebarRowView`, not AppKit.**
  `outline.selectionHighlightStyle = .none` (set right after `style = .sourceList`,
  which would otherwise reset it) so AppKit draws no selection of its own — otherwise it paints a gray
  *unemphasized* capsule whenever the sidebar isn't first responder (the normal case,
  since focus lives in the terminal), overriding any custom `drawSelection`.
  The row draws the themed pill in `drawBackground(in:)` for every state,
  and the Coordinator's `refreshSelectionAppearance()` repaints the pills + re-tints the row text on
  selection change (AppKit won't redraw rows on its own with `.none`) and on `.agtermAppearanceChanged`.
  **`SidebarOutlineView.acceptsFirstResponder` is `false`** so a mouse click selects without stealing
  first responder from the terminal — that responder bounce (terminal → outline → terminal,
  via `mouseDown`'s `focusActiveTerminal`) otherwise makes AppKit re-set `SidebarRowView.isEmphasized`,
  whose setter forces `needsDisplay`, and flicks the pill on every click (programmatic selection from
  the palette/Ctrl-Tab never bounces, so it was already smooth).
  **Reconcile splits SHAPE from CONTENT** (`TreeShape` ids/order → full `rebuildAndReload`;
  `RowContent` name/icon/badge → per-row `reloadItem`) so a cwd-driven `displayName` change reloads only
  its row instead of a full `reloadData` + re-expand that re-lays-out and horizontally jitters every
  source-list row.
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
  The detail pane is a *deck* — `ContentView.detailPane` is a `ZStack` over EVERY session (`store.workspaces.flatMap(\.sessions)`),
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
- **Search bar placement (NSSplitView-overrun rule).**
  `TerminalSearchBar` (`agterm/Views/`) is anchored on `detailPane` via `.overlay(alignment: .topTrailing) { searchBarLayer }`
  — the SAME level as `floatingOverlayLayer`, NEVER inside any session's `sessionDetail` HSplitView-hosting
  subtree.
  This is the same hard-won rule as the floating overlay: adding a conditional sibling (or flipping a
  pane modifier) inside `sessionDetail`'s ZStack when `searchActive` flips would re-host the `NSSplitView`
  and overrun it UP into the transparent titlebar.
  The bar reads `store.activeSession?.searchActive` and shows only when set,
  so the split subtree's SHAPE is constant whether or not the bar is shown.
  Because it is a `detailPane` `.overlay`, it renders ABOVE the in-deck scratch (zIndex 1 inside `sessionDetail`)
  and the FULL overlay (zIndex 2) without any layout change — so search-over-scratch shows the bar on
  top of the scratch with no `sessionDetail`/HSplitView perturbation.
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

