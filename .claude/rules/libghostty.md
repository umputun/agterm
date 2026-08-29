---
paths:
  - "agterm/Ghostty/GhosttySurfaceView*.swift"
  - "agterm/Ghostty/GhosttyApp.swift"
  - "agterm/Ghostty/GhosttyCallbacks.swift"
  - "agterm/Ghostty/GhosttyResources.swift"
  - "agterm/ContentView.swift"
  - "agterm/Views/WindowContentView*.swift"
  - "agterm/Views/SplitRatioAccessor.swift"
  - "agterm/Views/TerminalView.swift"
  - "agterm/Views/TerminalSearchBar.swift"
  - "scripts/setup.sh"
---

## libghostty gotchas

## Rendering

- Nothing in agterm paints a surface. `src/apprt/embedded.zig` declares no `must_draw_from_app_thread`, so
  `renderer/Thread.drawFrame` draws on the render thread instead of posting `redraw_surface`, the only
  producer of `GHOSTTY_ACTION_RENDER`. The action is therefore unreachable on the embedded apprt and the
  `action` switch drops it to `default`. If `GHOSTTY_REV` ever advances onto a libghostty that declares
  that constant, panes stop painting until a RENDER arm calling `ghostty_surface_draw` comes back.
- The render thread is not the only painter: libghostty installs its own `CALayer` subclass as the surface
  view's layer, and its `display` calls a callback holding a raw `*Renderer`, so CoreAnimation draws on the
  main thread too. Before upstream `4b4a5b241109` nothing cleared that callback — `Metal.deinit` dropped
  only ghostty's retain while the view kept the layer alive — so after `ghostty_surface_free` the layer
  pointed into a freed renderer and the next display aborted on
  `BUG IN CLIENT OF LIBPLATFORM: os_unfair_lock is corrupt` (#443). Reproduced deterministically only under
  `MallocScribble=1`; on unrecycled memory the same sequence survives, which is why one report over 46
  hours was the expected shape rather than a weak signal.
- `destroySurface` swaps in a plain layer anyway, carrying the last frame's contents, and must do it AFTER
  the free, which is what joins the render thread. The current pin carries the upstream fix, so this is
  defence against building on a libghostty that does not — keep it even though it looks redundant.
- `ghostty_surface_set_occlusion(false)` stops hidden rendering and releases the Metal swap chain on the
  current pin. Drive it from `deckOnScreen`, not `deckVisible`: dashboard cells and passive HUDs paint while
  non-interactive, and `deckVisible`'s quick-terminal `holdsKey` term is focus ownership, not visibility —
  the inset panel leaves panes on screen. A detached quick/scratch/split host is hidden regardless of its
  last deck value, and the ordered-out quick panel clears `deckOnScreen` itself since `orderOut` keeps
  `window` set.
- Occlusion is TERMINAL visibility, not a renderer lever: every edge flips `terminal.flags.visible` and,
  under mode 2033, emits a visibility report, so never toggle it to force a GPU re-release for a pane
  that stayed hidden. The release is edge-triggered while the CA display callback draws unguarded, so a
  present after the hide edge rebuilds the swap chain and only an upstream fix can re-release it; the
  hidden janitor sweeps only the layer's retained frame. Reveal draws synchronously
  (`ghostty_surface_draw`) because that sweep cleared `contents` and `refresh` merely queues a render.
- A hidden pane also clears `needsDisplayOnBoundsChange` on libghostty's layer and restores it on
  reveal. Without that, a window resize makes CoreAnimation display every mounted hidden pane and
  rebuild the chain the release just freed. At `683d8db`, `Metal.init` installs one `IOSurfaceLayer`
  for the surface renderer and sets the flag once; no later Ghostty path replaces the layer or
  rewrites the flag. A `GHOSTTY_REV` bump has to recheck both, and that the synchronous reveal draw
  still restores the intended visible-resize path.

## Theme and sidebar

- Chrome reads background/foreground through `ghostty_config_get`. It cannot read optional
  `selection-*` keys, even when set, so `resolveSelectionColors` parses the same last-wins config sources
  and named bundled theme file. Selected rows use selection background/foreground, with black/white
  luminance fallback. Tint borderless New Session through `.tint`; its label ignores foreground style.
- Pass `theme = light:X,dark:Y` raw. The pinned libghostty supports conditional themes, but
  `set_color_scheme` only changes conditional state and emits an unhandled soft reload. agterm must set
  app and surface schemes, then call `update_config`.
- A dark launch must re-side the app config through `update_config` BEFORE the first surface exists;
  `GhosttyApp.syncLaunchColorScheme`, called from `applicationDidFinishLaunching`, owns that.
  `Surface.init` rebuilds a surface config whose conditional state differs from the app's, keeps only
  `working-directory`, and drops the per-surface env, `initial_input` and `command` (#260).
  A host-built config always resolves light, and `GhosttyApp` is built before `NSApp` exists, so its own
  appearance read is always light; the KVO reload is debounced and lands after the launch restore.
- Observe app-level `NSApplication.effectiveAppearance` through KVO, not per-view appearance,
  `AppleInterfaceStyle`, or the early distributed notification. Post the KVO-delivered settled `isDark`
  and thread it through `reloadConfigPreservingSessionZoom`; do not use `apply`, whose unchanged text skips
  the reload. KVO also survives sleep/wake.
- Appearance reload preserves per-session zoom and reasserts it after shared config. Explicit File Reload,
  `config.reload`, and settings changes use `reloadConfigClearingSessionZoom`. Record
  `lastAppliedIsDark` from the applied value; suppress same-side repeats. Seed false so initial KVO causes
  at most one dark reload.
- Set the app color scheme before update even with zero surfaces. Host-built config getters always expose
  the light conditional side. Instead, consume the synchronous app-target `CONFIG_CHANGE` config that
  libghostty actually applied; clone it under a lock, ignore surface-target watermark config changes, use
  it for chrome colors, then free it.
- AppKit draws disclosure triangles from `NSAppearance`, not explicit tint. Pin outline appearance to
  aqua/darkAqua from perceived luminance of the sidebar-tinted theme background, using the 0.5 midpoint.
  Apply at creation and `.agtermAppearanceChanged`. Verify by eye.
- Disable AppKit outline selection immediately after `.plain`, which otherwise restores it. Also clear
  outline/scroll backgrounds; `.plain` avoids source-list's roughly 10px top inset but installs opaque
  control background.
- `SidebarRowView` alone draws selection and reapplies cell colors from live `isSelected` in `didSet` and
  `didAddSubview`. Builder-time row lookup can be -1 during reload/animation, making inverted-selection
  themes render invisible text. Rename restoration also uses row-view selection.
- `SidebarOutlineView.acceptsFirstResponder` is false so clicks select without terminal-to-outline focus
  bounce and pill flicker. Reconcile `TreeShape` changes with full reload and `RowContent` changes per row.
  Inline rename uses theme foreground/background, then restores selection-aware colors. Visual tint cases
  are manual-only.

## Resources and lifecycle

- `GHOSTTY_RESOURCES_DIR` points to `Contents/Resources/ghostty`; terminfo must be its sibling at
  `Contents/Resources/terminfo`. Never set `TERMINFO`; libghostty derives and overwrites it at spawn.
- Sessions own surfaces. The eager detail deck mounts every session once in a ZStack and toggles only
  opacity, hit testing, and active state. Rehosting through identity changes invalidates Metal drawables.
- `dismantleNSView` is a no-op. Free only through `destroySurface`. After reading overlay exit status,
  nil every store-capturing callback to break the store/session/surface/closure cycle.
- Create surfaces only with nonzero backing size; otherwise Metal stays blank. Defer through
  `pendingSurfaceCreation` until `setFrameSize`.
- `ghostty_surface_new` returns NULL for as long as the DISPLAY is asleep, with a valid backing size —
  measured 21 consecutive failures over 40s, then success within ~2s of wake while the screen was still
  LOCKED. Unlock is irrelevant; display wake is the earliest moment creation can succeed, so retrying
  during sleep is pure spin. Nothing in the deck re-attempts on its own: every other retry path rides
  SwiftUI layout, which does not run for an off-display window, so `updateNSView` never fires. That is why
  a session a scheduled job creates overnight realized no surface and never ran its `--command`, while
  `session.new` had already answered `ok` (#416). `SystemWakeObserver` posts `.agtermScreensDidWake` and
  `GhosttySurfaceView.retryCreationAfterWake` re-attempts, bounded, because creation can still fail for a
  second or two after the notification. A failed create also re-arms `pendingSurfaceCreation`, so the
  layout path retries as well: the wake hook makes recovery TIMELY, not possible, and a view first
  mounted inside that residual window registered its observer too late for the wake that just fired.
- `working_directory`, `initial_input`, and environment strdup buffers must outlive
  `ghostty_surface_new`; retain them until destruction.
- Reparenting invalidates the drawable while leaving terminal buffer intact. `set_size` with an unchanged
  grid does nothing, so `updateMetalLayerSize` must call `ghostty_surface_refresh` after every size push.
  The parked font-increase blank is also buffer-intact but is not fixed by refresh or size jitter.

## Drag, paste, and overlays

- Only `deckVisible` surfaces register for file drag. SwiftUI opacity/hit-testing does not stop AppKit
  drag destination lookup, and rejecting in `draggingEntered` does not fall through. Visible split panes
  both qualify; full overlay, scratch-covered, and self-overlaid panes do not. This closes the latent
  background-session target shipped with single-session file drop in #52.
- File drop uses `insertPasted`/`ghostty_surface_text`, preserving bracketed-paste behavior. It may still
  submit a trailing newline when the program disables mode 2004. Do not reuse `inject`, which intentionally
  translates newline/return into Return for `session.type`. `pasteboardText` remains shared with clipboard
  paste, and `ShellEscape.path` keeps file paths one token; #96 newline escaping remains defense in depth.
- AX exposure (`axExposed` in `GhosttySurfaceView+Accessibility.swift`) rides on FOUR terms: `!viewOnly`,
  `deckVisible`, `surface != nil`, and `window?.isVisible`. Every one drives
  `postAccessibilityExposureChange` behind the `axPostedExposed` latch, so a new term owes a post site;
  none may be assumed to imply another. Detach posts from `viewDidMoveToWindow` ABOVE its nil-window
  guard, the only site that sees the quick terminal unmount. `liveFocus` has a second consumer here
  (`isAccessibilityFocused` and the AX write guard) besides the cursor, so it is not `private`.
  Focus posts are deferred one run-loop turn because `window.firstResponder` reads stale inside the
  responder transitions; the per-view `axPostedFocus` latch, not `axFocusPostScheduled`, is what stops a
  resign/become pair from announcing twice. This bridge adds no user action and no per-session state, so
  it is a genuine exemption from the control-API keep-in-sync rule: `session.type` already drives text in.
- Both programmatic writers commit a live IME composition first through `commitOrDiscardComposition`, in
  `GhosttySurfaceView+Input.swift` beside the `_markedText`/`_markedRange` state it operates on:
  `insertPasted` (drop and the AX control-character branch) and `inject` (`session.type`). Text inserted
  under a composition leaves it to re-commit on the next keystroke, landing the half-typed word after the
  inserted text. It no-ops unless this pane is composing, and it tears the IME session down only while the
  view holds first responder, because `inputContext` resolves to the shared context and discarding from a
  background pane would abandon whichever view is really composing.
- Never change the `sessionDetail` ZStack shape for per-session toggles; doing so rehosts `NSSplitView`
  into the titlebar. Search bar is a `detailPane` top-trailing overlay, above deck, scratch, and overlays.
  Overlay panel stays an always-present `sessionDetail` sibling whose internal content changes.
- The boundary is the arranged subview, not what it contains. Inside one, a constant-shape ZStack may swap
  children and change modifier values freely: a real NSView mounting and unmounting there held the divider
  across repeated toggles, both focus states, and a 0.85 ratio. That is what makes per-pane chrome — the
  pane overlay, `paneDim` before it — possible at all; a wrapper AROUND the split still perturbs it.
- Keep the detail deck — `detailPane`, `sessionDetail`, `deckPane`, `overlayPanel`, `paneOverlayPanel`,
  `paneDim` — in `WindowContentView+Detail.swift` so `WindowContentView.swift` remains below the
  1000-line limit. `sessionDetail` owns the constant-shape statement; every other site cross-references it.
  One `deckPane` renders each pane, so the split's two arranged subviews are the same view type.
- Palettes, switcher, and dashboard live in `windowOverlayLayer`, inset by
  `titlebarHeight` below `customTitlebar`. The quick terminal is NOT among them: it is a detached
  `QuickTerminalPanel` above every window, so it needs no inset and paints its own frame ([[windows]]).
  A body overlay's 0.2-opacity black scrim darkens the transparent tall titlebar.
  The seam appears in 48px normal mode; 30px compact remains inside the native band.
  Keep the empty overlay layer free of Color/contentShape so it cannot intercept hits. Do not add an opaque
  titlebar background; it breaks translucent chrome.
- With translucency, every surface has zero background opacity. A full overlay has no opaque SwiftUI
  backing, so hide panes and scratch beneath it and remove their drop eligibility. A floating overlay has
  an opaque terminal-color panel; the quick terminal takes the same backing from its own panel's content,
  through `WindowContentView.resolvedTerminalColor`.
- Because a floating overlay leaves a live terminal around its panel, its tap-catcher also paints the
  `inactivePaneMuteStrength` wash. Fill the existing catcher; never add a sibling scrim. Suppress `paneDim`
  while a backdrop wash is up or the covered inactive pane takes both. The quick terminal no longer takes
  part: its panel is a separate window, so there is no in-window margin left to catch a tap or wash.
- Anything that HIDES a pane in place takes the wash with it, so the cover must carry `paneDim` itself:
  `paneOverlayPanel` washes an overlay opened on the unfocused pane, or split focus stops reading.
  Wash a cover against ITS OWN background, not `washColor(for:)`. An overlay surface is sessionless and
  never inherits the session background, so the session color would shift the background it blends into.
- The wash is neutral only at full window opacity. Below it the wash color is opaque while the backing is
  not, so the body rises to `m + p(1-m)` against a title bar left at `p`; scaling by the rendered opacity
  shrinks that gap but no fill closes it. Scale by what the window actually renders at, not the saved
  setting: fullscreen and Reduce Transparency force it opaque, and scaling there under-mutes to nothing at
  a saved 0. Fullscreen is per-window, so it needs its own notification pair, not an app-global mirror.
- Take the covered session's own solid background when it set one, else the theme color. Neither that field
  nor a live OSC 11 color is observed, so the color is whatever it was when the wash was last drawn.

## OSC 11 backgrounds

- Handle background `GHOSTTY_ACTION_COLOR_CHANGE` per pane. Under zero surface opacity, apply a surface
  config overlay containing only `background-opacity = windowOpacity`; never include `background`.
  Preserve and reassert the latch through reload, opacity, and dashboard font changes.
- A live OSC 11 override masks config defaults in the pinned libghostty. No embedding API clears
  it: RIS leaves colors, PTY writes bypass the parser, and COLOR_CHANGE is outbound-only.
  `session.background color` changes only the default and cannot override live OSC.
- OSC 111 copies current default into override. Per-surface update also reseeds default from a
  `background` key. Restating OSC color in the overlay therefore made reset permanently retain it (#309).
  Opacity-only overlay leaves theme as default, so reset returns to theme.
- `tree.background` reports the stored specification and may differ from a live OSC-rendered color.
  `oscBackgroundColorHex` is both dedupe key and reassert source. Applying/clearing session background
  releases it so an identical later OSC value is not discarded.
- `session.background clear` cannot clear the underlying OSC override; it installs an empty overlay,
  returning opacity to zero and hiding OSC behind window backing. A later OSC re-renders. Setting a color
  restores opacity, so the live OSC resurfaces and masks it across main, split, and scratch.
- Host-free `OSCBackgroundPolicy` distinguishes set/reset because libghostty reports both identically.
  Baseline is the surface's own color without an OSC overlay: session color, overlay color, or theme.
  While the opacity-only OSC overlay is installed, baseline is theme. Baseline means reset, unchanged
  means ignore repeated prompt emission, anything else applies. Equal-to-baseline deliberate sets are
  harmless. Clear the latch on pane close. This behavior is visually verified.
- Only background needs this; OSC 10/12 render despite transparency.
  At 100% window opacity Ghostty renders OSC background itself, so the host fix is visible only when translucent.

## Dashboard

- Dashboard generalizes terminal zoom from one reparented focused surface to at most
  `DashboardLayout.maxCells` (9) view-only pane surfaces in a `ceil(sqrt(n))`-wide grid. A split session
  contributes primary and split cells, so the limit counts panes.
- Each `DashboardMember` hosts its existing pane with stable primary/split slot identity. Claim each exact
  slot through `dashboardHostsSurface`, leaving a clear placeholder in the eager deck so other surfaces
  still realize. Enter selects, closes, then focuses that exact pane.
- Place dashboard in `windowOverlayLayer`, never a body overlay.
- View-only requires all five gates:
  1. terminal hit testing off with a transparent click/highlight/enter layer above;
  2. `viewOnly` rejects first responder and hits;
  3. `deckInteractive` requires no zoom and no dashboard;
  4. an AppKit key catcher owns responder, handles arrows/Enter/Esc, and swallows all other keys;
  5. `focusActiveSession` returns while dashboard is active, preventing its roughly 12 by 0.03s
     retry from focusing a grid cell.
- Dashboard font uses transient per-surface `dashboardFontOverride`, never record/restore of
  `session.fontSize`. Compose override before session font, reassert on reload, and suppress CELL_SIZE model
  reporting while set. Auto uses `DashboardLayout.dashboardFontSize` with configured font or 13.0;
  fixed uses its value; untouched remains nil. On close, clear both primary and split overrides store-wide.
- Dashboard and terminal zoom are reciprocal: opening dashboard clears zoom; activating zoom closes
  dashboard. Reparenting grid cells necessarily resizes PTYs and sends SIGWINCH; view-only promises no
  input, not no process resize.

## Cursor defaults and focus

- Defaults load before user config and set `cursor-style = block` plus
  `shell-integration-features = no-cursor,no-title`. `no-cursor` prevents prompt DECSCUSR bar resets;
  `no-title` prevents abbreviated local cwd OSC 2 from overriding sidebar names. User/remote OSC titles
  still work, and OSC 7 is unaffected.
- `ssh-env` and `ssh-terminfo` are forced OFF after `ghostty_config_load_recursive_files`, so no user
  source including a `config-file` include can enable them: their wrappers call a `ghostty` CLI agterm
  does not bundle, and enabling either broke `ssh` outright (#463). The override reads the resolved
  packed bits back and restates all six flags, because ghostty re-parses the key from its defaults on
  every occurrence. Setting either is a silent no-op with no diagnostic: a report that it has no effect
  is by design, while a report that it still installs an `ssh` wrapper or breaks `ssh` is a regression.
- A one-shot local OSC 2 is cleared by the next prompt. Hold the shell with
  `printf '\033]2;X\007'; cat` to test; SSH works because it blocks the local prompt cycle.
- `liveFocus` is key window and first responder. The key gate is essential because AppKit retains one
  responder per inactive window. Observe all didBecomeKey/didResignKey events and reevaluate this window.
  Push directly from responder callbacks because AppKit has not updated `window.firstResponder` yet.
  Creation, attachment, and retry paths read live state, while `onFocusChange` tracks responder transitions,
  not window key state. Remove observers on destruction. Verify the solid/hollow cursor manually.
- `acceptsFirstMouse` permits left mouse only, so inactive-window clicks select a pane without permitting
  default right-click paste. Under `autoHideSidebarInactiveWindows`, reject first mouse because sidebar
  expansion resizes the surface mid-gesture and causes phantom selection; the next click selects.
- Before `mouse_scroll`, report the event position only when it differs from `lastReportedMousePoint`.
  This fixes stale/-1,-1 positions after keyboard activation without generating synthetic motion for every
  scroll packet in mouse-reporting TUIs.

## Process-global cursor

- Every hidden eager surface otherwise receives tracking and can call process-global `NSCursor.set`,
  causing issue #225 flicker, especially restored sessions and quick terminal.
- Gate both sides with `deckVisible`: install tracking areas only while visible, and guard `mouseMoved`,
  `applyMouseShape`, and `cursorUpdate`. Tracking alone is insufficient because hidden surfaces receive
  activation `cursorUpdate`; setter guards alone leave hidden mouse-report fan-out.
- On didBecomeKey, `reassertCursorOnActivation` for a visible, key-window, pointer-in-bounds surface because
  AppKit does not update the visible cursor automatically. Every `deckVisible` expression must exclude full
  overlay, scratch, persistent quick terminal, and that pane's own pane overlay coverage.
- `deckVisible` answers "am I the on-screen pane?", never "do I own this pixel?". Chrome drawn over a pane
  — the sidebar grab handle, an `NSSplitView` divider, a floating overlay's margin — still gets the pane's
  per-move `NSCursor.set`, which beats chrome setting the cursor on hover entry alone (#324). All four
  writers also gate on `ownsPointer`, a hit test against the window content view; it declines for chrome
  only, treating a hit on any surface as ownership so it can never silence the visible terminal. Do not
  replace either gate with the other.
- The split divider is decided BEFORE that hit test, by asking the pane's own `NSSplitView` whether the
  point is in its grab band. Every session's split is mounted at the full frame, so a window-down hit
  answers for whichever the deck stacked last, not this pane's — and a hidden entry's split reaches the
  divider column of the session that is on screen.
- Never gate `GhosttySurfaceView.hitTest` on `deckVisible` to fix that. Refusing while off-screen only
  promotes the hidden entry's own container, an `NSSplitView` or a pane view, to answer in its place: an
  `NSSplitView` whose subviews decline returns itself for its whole frame, `ownsPointer` sees a non-surface
  and declines everywhere, and the visible terminal loses every shape it paints. `alphaValue = 0` does not
  suppress hit testing and the deck never sets `isHidden`.
- Both dividers paint ↔ themselves: the sidebar handle from `onContinuousHover`, the split from
  `SplitProbeView`'s tracking area over the split, which covers both panes, so it repaints only inside the
  band and gates on the deck's `visible` minus any overlay or scratch. AppKit's own divider cursor stops
  firing once a second session is mounted, so nothing else writes it.
- Chrome that paints its own cursor must re-assert per move and per drag tick, then again on the next
  runloop turn re-reading live hover state: a replacement lands after a synchronous `.set()` returns, and a
  deferred pass that captured hover instead strands the shape over live terminal.
- Reproduce manually with stacked sessions and `printf '\033]22;crosshair\007'`. What libghostty asks for
  is verified by eye. The divider writer is not: `SplitRatioAccessorTests` drives `mouseMoved` and asserts
  `NSCursor.current`, so its gates are pinned and must stay that way.

## OSC 52 clipboard

- Gate clipboard in host callbacks. Write carries `confirm` for `clipboard-write = ask`; read confirmation
  distinguishes OSC 52 / Kitty reads and writes from paste and list. Prompt only protocol reads and writes,
  never Command-V.
- `ClipboardPromptController` owns app-session-wide per-direction ask/allow/deny policy. Coalesce by
  requesting surface plus direction so separate surfaces cannot inherit one decision.
- Defer sheets to the next main turn because callbacks occur inside a libghostty tick and a modal loop
  would reenter it. Deny via `ghostty_surface_deny_clipboard_request`, which writes the protocol's denial
  reply and invalidates the request; completing with `confirmed = false` re-asks in an endless loop.
- A text read always completes, serving a zero-length `text/plain` when the pasteboard is empty: an
  `UNAVAILABLE` result never starts the request, so an OSC 52 reader would wait for a reply that never comes.
- A write keeps every representation (`NSPasteboard.PasteboardType(mimeType:)` mapping): the callback is
  void and core reports `DONE` right after it, so a dropped representation is a false success.
- Default ungated writes are synchronous so a same-tick read sees them. Read defaults to ask; write defaults
  allow and can be changed in agterm `ghostty.conf`.
- Deferred completion captures `GhosttySurfaceView`, then rereads its live surface. If a pane closed while
  the sheet was open, skip completion rather than use the freed raw pointer; freeing already discards the
  request. Keep request state `nonisolated(unsafe)` under the same lifetime check.
- AppKit dialog behavior is manual-only; unit-test `ClipboardPromptPolicy`.
