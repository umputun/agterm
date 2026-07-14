---
paths:
  - "agterm/AppActions*.swift"
  - "agterm/agtermApp*.swift"
  - "agterm/Views/Palette.swift"
  - "agterm/Views/PaneShortcuts.swift"
  - "agterm/Views/SessionSwitcher.swift"
  - "agtermCore/Sources/agtermCore/RecencyStack.swift"
  - "agtermCore/Sources/agtermCore/Fuzzy.swift"
  - "agtermUITests/MenuUITests.swift"
  - "agtermUITests/PaletteUITests.swift"
  - "agtermUITests/SessionNavUITests.swift"
  - "agtermUITests/SessionSwitcherUITests.swift"
  - "agtermUITests/SplitUITests.swift"
---

## Menu bar and actions

- User actions live in `AppActions` (app target, `@MainActor`), shared by the toolbar/bottom-bar buttons
  (`WindowContentView`), the menu bar (`agtermApp`'s `.commands`), and the control channel (`ControlServer`)
  so the three never drift.
  Trivial one-liners (quick-terminal toggle) call the controller/store directly;
  `AppActions` owns the ones with real logic — new-session placement, the directory picker,
  split + focus, and font.
- **Menu split: View vs Navigate.**
  The menu bar has TWO custom menus (besides File/Help).
  **View** (`CommandGroup(after: .toolbar)`) holds appearance + what-is-shown:
  font/theme, sidebar show-hide + expand/collapse, the flagged-view + Flag/Clear-Flagged + Focus Workspace
  items, the surface toggles (Split/Scratch/Find/Quick Terminal), and Toggle Full Screen
  (`toggle_fullscreen`, ⌃⌘F → `AppActions.toggleFullscreen()`, native `NSWindow.toggleFullScreen` on the
  key window; the `window.fullscreen` control command is a fourth driver of native full screen, via
  `WindowRegistry.fullscreen` with id resolution (not through `toggleFullscreen()`) — see control-api / windows).
  agterm ships its OWN Toggle Full Screen item so full screen is rebindable/palette/control-drivable;
  `AppDelegate` strips AppKit's auto-injected native "Enter Full Screen" item (re-injected on every menu
  open) so the two don't render as a duplicate — see the `window.fullscreen` note in windows.md.
  **Navigate** (a separate top-level `CommandMenu("Navigate")`, placed right after the View group so
  AppKit renders it after View) holds moving the selection/focus: the two palettes (Go to Session / Command
  Palette), session stepping (Previous/Next, Previous/Next Attention, First/Last),
  and Focus Left/Right Pane.
  It also carries the **Dashboard** grid opener (⌘⇧D → `AppActions.toggleDashboard`,
  the `dashboard` built-in action) — a toggle that opens the frontmost window's most-recently-used
  dashboard grid (auto-sized, the `dashboard --mru --auto-size` control equivalent) or closes it,
  inert while terminal zoom is active; it is ALSO a command-palette entry.
  Unlike the pure placement split, this one IS a keep-in-sync-ish addition:
  the `dashboard` built-in reuses the existing socket `dashboard` command (no NEW control command),
  and the session→pane-cell expansion is hoisted into the shared host-free `AppStore.dashboardMembers(for:limit:)`
  helper that both `ControlServer.setDashboard` and `toggleDashboard` call.
  This is a pure menu-PLACEMENT split — every item still drives the SAME `AppActions`,
  and the control/palette/keymap surfaces are untouched (so it is NOT a keep-in-sync change).
  When adding a menu item, file it by intent: display state → View, moving between things → Navigate.
  XCUITest helpers that open a menu by title must target the menu the item actually lives in (the `PaletteUITests`/`KeymapUITests`
  `openPalette` helpers open **Navigate** for the palette items).
- **Keep-in-sync convention (HARD).**
  Any new user action added to `AppActions`/`AppStore` is not "done" until it is also drivable from the
  control socket.
  Shipping a new action requires all four of: (1) a `Command` case (plus any args) in `agtermCore`'s
  control protocol, (2) a dispatch arm in `ControlServer`, (3) an `agtermctl` subcommand,
  (4) protocol round-trip plus end-to-end tests for it.
  This extends the toolbar/menu-bar "never drift" rule to the third surface — the control channel.
  See the Control API section below.
- Font menu items (⌘+/⌘−/⌘0) drive libghostty on the *focused* surface via `GhosttySurfaceView.performBindingAction("increase_font_size:1"/"decrease_font_size:1"/"reset_font_size")`.
  `focusedSurface()` is the key window's first responder (main pane, split pane,
  or quick terminal), else the active session's surface.
  A menu-driven font change still rides the CELL_SIZE → persist path, like the keybind.
- **In-terminal search (⌘F).**
  `BuiltinAction.toggleSearch` (`defaultChord` = ⌘F, expressible/rebindable — NOT one of the arrow-bound
  exceptions) drives `AppActions.toggleSearch()` → `focusedSurface().startSearch()` (the `start_search`
  binding action).
  It is a real View ▸ Find… menu item (reading `equivalent(for: .toggleSearch)`,
  no hardcoded shortcut) plus a ⌃⇧P palette "Find…" entry. libghostty replies with a `START_SEARCH` action;
  the surface's `onSearchStart` closure TOGGLES — if the owning session's bar is already visible it calls
  `endSearch()` (sends `end_search`, so libghostty actually exits search mode,
  never just flips the flag), else opens the bar (`searchActive = true`,
  seeds any returned needle) and focuses the field.
  The `onSearchEnd` closure clears the four search fields and returns first responder to the terminal
  (`focusAfterReparent`); `onSearchTotal`/`onSearchSelected` set `searchTotal`/`searchSelected` (negative
  `ssize_t` → nil).
  The four `GhosttySurfaceView` methods (`startSearch`/`sendSearchQuery`/`navigateSearch`/`endSearch`)
  are thin wrappers over `performBindingAction`, the four callbacks are wired by ALL THREE in-tree surface
  factories — `makeSurface`/`makeSplitSurface`/`makeScratchSurface` via the shared `wireSearchCallbacks`
  helper (the `splitFocused` direct-write precedent) — and the four `GHOSTTY_ACTION_START_SEARCH`/`END_SEARCH`/`SEARCH_TOTAL`/`SEARCH_SELECTED`
  arms in `GhosttyCallbacks.action` copy the needle to a `String` before the main hop and return `true`.
  `AppActions` also owns `updateSearchNeedle(_:)`/`navigateSearch(_:)`/`endSearch()` for the bar.
  The state is the four ephemeral `Session` fields + `searchDisplayText` (the "N of M" / "M matches"
  / "no matches" computed), shared with the `session.search` control half (see the Control API catalog)
  so the GUI and control surfaces can't drift.
  **The SCRATCH terminal is searchable (the quick terminal + full overlay are NOT).** Wiring `makeScratchSurface`
  makes the scratch `isSearchable`, so ⌘F over a shown scratch opens the bar on the scratch itself:
  `coverHidesActiveSession` (the ⌘F open gate) blocks only the quick terminal + a FULL overlay (both
  unsearchable, focus-stealing over a hidden pane) — NOT the scratch; and `searchTarget()` checks the
  scratch-covers case FIRST (returns `topmostSurface` = the scratch when `scratchActive && !overlayActive`,
  BEFORE consulting `focusedSurface()`), so a ⌘F while the scratch covers the session never opens on
  the pane underneath — even when key-window focus sits off the surface (e.g. the sidebar),
  where `focusedSurface()` would otherwise fall back to the hidden `activeSurface`.
  A FLOATING overlay leaves the pane visible, so search there still targets the pane behind it (not the
  unsearchable overlay surface).
  Teardown: `AppStore.closeScratch` (the scratch shell's `exit`) clears search via `session.clearSearch()`
  ONLY when the bar is pinned to the scratch being torn down (`searchSurface === scratchSurface`) — so
  a search owned by the main/split pane survives the scratch teardown — mirroring the closeSplit/closePrimaryPane
  clear; the full session/workspace/window teardowns destroy the session entirely so no surviving bar
  can stick.
- **Split panes (one session, two shells).**
  Three observed flags on `Session`: `isSplit` = the split is shown side-by-side;
  `hasSplit` = the session HAS a split pane at all (stays true while hidden,
  cleared only by `closeSplit`); `splitFocused` = which pane holds focus.
  The split (right) surface is wired to the session as `isSplitPane`, so its PWD/title go to `splitCwd`/`splitTitle`,
  and the focus-aware `Session.displayName`/`focusedCwd` make the sidebar row AND the title bar track
  whichever pane is focused — guarded on `splitFocused` alone (NOT `isSplit`),
  so it follows a hidden-but-focused split pane.
  `effectiveCwd` stays the PRIMARY pane's (non-focus-aware) for seeding new panes + the `AGTERM_SESSION_PWD`
  token; `Session.activeSurface` is the focused pane's surface (the focus helpers + the collapsed detail
  pane target it).
  **Opening a NEW split moves focus to the new (right) pane** (`AppStore.toggleSplit` sets `splitFocused = true`
  only when the split is genuinely new — `hasSplit` was false; hiding leaves it set so the focused pane
  is the one shown maximized, and RE-showing a hidden split PRESERVES that pane rather than jerking focus
  back to the right — so a hide/show round-trip, e.g. the tmux-style zoom script that drives `session split off`
  then `on`, keeps whichever pane you had focused).
  **Hiding the split (the toolbar toggle) keeps BOTH shells alive** and shows the focused pane maximized
  — `detailPane`'s collapsed branch renders `\.splitSurface` when `splitFocused`,
  else `\.surface` — so reopening restores the two panes in place; nothing is destroyed (`closeSplit`
  only runs when the split shell exits).
  **Exiting a pane's shell keeps the session, collapsed to the survivor:** the primary's `onExit` is
  `AppStore.closePrimaryPane` (promotes the surviving split pane INTO the main slot as a single non-split
  session — its cwd/title/foreground command migrate up) and the split's is `closeSplitPane` (collapses
  to the primary only for a genuine two-pane split, else closes the session — the primary already exited,
  or the promoted survivor's own exit, `splitSurface == nil`).
  Only a single (non-split) session's exit closes it.
  The collapse re-hosts the survivor (HSplitView → standalone), which drops focus,
  so `GhosttySurfaceView.focusAfterReparent` re-grabs first responder until it sticks past the re-host.
  `⌘⌥←`/`⌘⌥→` (+ the "Focus Left/Right Pane" menu items and palette entries,
  + `session.focus`) move focus via `AppActions.focusPane(_:)`/`setSplitFocus(_:of:)` — ALL gated on
  `hasSplit`, NOT `isSplit` (the menu items' `.disabled`, the palette gate,
  the `setSplitFocus` guard, `revealSession`, and the `session.focus` control arm),
  so pane navigation works whether the split is shown side-by-side OR hidden (maximized).
  When hidden, focusing the other pane just flips `splitFocused`, which swaps which pane the collapsed
  `detailPane` shows maximized (the "switch the zoomed pane with the other" behavior);
  the single-pane (no-split) state still disables/no-ops them.
  `⌃1`/`⌃2` are a direct-switch alias for the same `focusPane(.main)`/`focusPane(.split)` actions,
  caught by `PaneShortcuts` (an app-wide `NSEvent` local monitor, like the Ctrl-Tab switcher — NOT a
  SwiftUI shortcut, so they aren't duplicate menu items).
  The monitor ALWAYS consumes `⌃1`/`⌃2` (reserved app shortcuts) so they never leak to the shell — on
  a non-split session `focusPane` is a no-op rather than the terminal printing a literal "1" (the bug
  from the first cut, which only consumed when split).
  No new control command — `session.focus` already covers it.
  Each pane persists its OWN cwd: `SessionSnapshot.splitCwd` + `Session.initialSplitCwd` seed the split
  shell on restore.
  The split's DIVIDER RATIO persists per-session too: `SessionSnapshot.splitRatio` (a 0...1 left-pane
  fraction) is captured by `SplitRatioAccessor` (`agterm/Views/SplitRatioAccessor.swift`) — a `.background` `NSViewRepresentable`
  on the PRIMARY pane (a background, not a third arranged pane; unconditional so it never perturbs the
  split shape) that introspects the AppKit `NSSplitView` under the SwiftUI `HSplitView`,
  since no SwiftUI API exposes the divider position.
  It `setPosition`s the divider once the split has a real width (retried per `layout()` pass) and writes
  the current fraction back to `Session.splitRatio` (`@ObservationIgnored`) on each `NSSplitView.didResizeSubviewsNotification`.
  Persisted by a debounced `save()` ~0.4 s after the drag settles (coalescing one drag's resize ticks
  via a cancel-and-reschedule `DispatchWorkItem`), plus the usual save points and the quit-flush,
  so a force-quit keeps it too, symmetric with the sidebar WIDTH (which saves on the drag's `.onEnded`).
  **`SplitRatioAccessor` ALSO clips the split's divider out of the titlebar strip (`updateDividerClip`).**
  In COMPACT mode (`titlebarHeight` = 30) the SwiftUI `.padding(.top, titlebarHeight)` lands inside the
  window's safe-area band, so the AppKit `NSSplitView` IGNORES it and grows to the FULL window height
  (verified: its frame + both arranged panes span pt 0..windowHeight; the 48px non-compact inset clears
  the band so normal mode is already bounded).
  The panes' top strip is then empty terminal-bg (invisible against the window bg),
  but the divider draws BLACK through it — a streak up through the transparent titlebar (only the DIVIDER
  shows; the panes' content still starts at the content top because the terminal grid respects the safe
  area).
  The fix is a **CALayer mask on the `NSSplitView`** hiding its overrun strip — the overrun is computed
  LIVE (`titlebarHeight - splitTopFromContentTop`, ~30 in compact, 0 in normal → mask dropped) so normal
  mode is untouched and the clip tracks window resize.
  Use a layer mask, NOT SwiftUI `.mask`/`.clipped()`: those reflow the terminal grid (scroll the top
  row away — confirmed twice), while a layer mask is render-only; and NOT an opaque cover (would break
  translucency — the mask reveals the window backing).
  The detail `HSplitView` carries `.id("<session>-hsplit")` so its `NSSplitView`/divider can't leak across
  session switches.
  A session with a split shows a split-rectangle icon in the sidebar (`WorkspaceSidebar`,
  keyed on `hasSplit` via `RowContent`), which persists while the split is hidden.
  The title-bar split button is a 4-state glyph: an outline when there is no split, a filled
  split-rectangle (`rectangle.split.2x1.fill`) while the split is shown side-by-side, and a half-filled
  glyph naming the visible pane once the split is collapsed to one pane
  (`rectangle.lefthalf.filled` = primary, `rectangle.righthalf.filled` = split pane, driven by `splitFocused`).
- `Close Session` is ⌘W (terminal-style).
  `AppActions.closeActiveSession()` first dismisses a focus-stealing cover in z-order — the frontmost
  window's quick terminal (`hide`), else the active session's open overlay (`closeOverlay`,
  full OR floating), else a shown scratch (`toggleScratch`) — and only closes the active session when
  no cover is up; it returns whether it handled the keystroke, and the File ▸ Close Session menu item
  falls back to `performClose` on the window ONLY when it returns false (no cover and no session,
  e.g. a window emptied to zero sessions).
  The cover guard lives in `closeActiveSession` rather than the menu on purpose:
  the menu's old `if activeSession != nil` gate skipped the guard when a window had no session but the
  quick terminal was up, closing the window instead of the cover.
  `AppStore.currentWorkspaceID`/`defaultWorkspaceName` are the host-free placement/naming helpers behind
  New Session / New Workspace.
- **Closing the ACTIVE session returns to the most-recently-active SURVIVING session, not to a positional
  neighbor** (Discussion #147).
  `AppStore.closeReselectionTarget(after:)` (`AppStore+CloseReselection.swift`, host-free and unit-tested in
  `AppStoreCloseReselectionTests`) is the single reselection pick for all three close paths — `closeSession`
  plus the two undoable ones, `softCloseSession` / `softCloseSessions`.
  It takes `sessionRecency.top(1, in: scope)` where `scope` = the closing session's OWN workspace's surviving
  session ids, further ∩ the flagged set in `.flagged` sidebar mode.
  The workspace term is what keeps the close from being disorienting: an UNSCOPED "most recent survivor" could
  yank the user into another workspace, which is worse than the positional neighbor it replaces.
  The scope set is built from the TREE, not from the recency stack: the closing session is removed from
  `workspaces` before reselection at every call site, so it can never be picked — which is what makes the
  soft-close paths correct WITHOUT pruning `sessionRecency` at close time (they must not, since undo needs the
  entry back; only `hardFinalizePendingSession` prunes, at grace expiry).
  When the close leaves that workspace with NOTHING in scope — it emptied the workspace, or in `.flagged`
  mode no other session there is flagged — the workspace term is dropped and the MRU widens: "stay in the current
  workspace" has nothing left to mean, and the alternative is a positional jump into the FIRST workspace, which is
  the disorientation the whole feature exists to remove.
  The FLAGGED term survives that widening (`flaggedSessions` is cross-workspace by definition), so a
  `.flagged`-mode close crosses workspaces rather than landing on an unflagged session the sidebar isn't rendering.
- **The FOCUS filter deliberately does NOT scope the close-reselection MRU — do not "fix" this by reaching for
  `navigableSessions`.**
  It is the obvious-looking choice (one set, already the definition of "what the user is navigating within") and
  it is WRONG here, because focus is a property of the TREE, not of the selection: `setFocusedWorkspace` never
  moves the active session, so focus can sit on a workspace the closing session doesn't even belong to.
  Scoping by `navigableSessions` (which folds focus in) breaks two reachable states: closing a session while
  ANOTHER workspace is focused jumps the user INTO that focused workspace, and closing the focused workspace's LAST
  session widens into an EMPTY set (`navigableSessions` has collapsed to the workspace just emptied) and falls
  through to the positional first-workspace jump.
  Landing outside the focused workspace needs no scoping defense anyway: every caller already runs
  `autoUnfocusIfOutsideFocus` on the pick, which drops the filter to reveal the target.
  Both cases are pinned by `closeActiveSessionWhileAnotherWorkspaceIsFocusedStaysInTheClosingWorkspace` and
  `closeTheFocusedWorkspacesLastSessionPicksTheRecentSurvivorElsewhere`.
  Only an empty MRU after that (a fresh restore before anything was activated, or the only recent entry was the one
  just closed) falls back to the positional `reselectionTarget(after:)`, which is UNCHANGED — so the worst case is
  the old neighbor behavior (scoped to the flagged set in `.flagged` mode, see the next paragraph), never an empty
  selection.
  In `.flagged` mode that fallback is scoped too — `nearestInScopeTarget` repeats `reselectionTarget`'s walk
  restricted to the scope, because `reselectionTarget` walks the tree positionally and would otherwise land on an
  unflagged sibling the flagged sidebar has no row for (`syncSelection` would then `deselectAll` and show nothing
  selected).
  It stays POSITIONAL within the filter, and the walk runs over the tree FLATTENED in sidebar order: the in-scope
  session that shifted into the removed slot, else the nearest in-scope one before it.
  The walk spans workspaces because the scope can — once the closing workspace holds nothing in scope the scope has
  widened to the whole flagged set, which the flagged sidebar renders as ONE flat cross-workspace list, so the
  adjacent row there is the neighboring FLAGGED row even when it lives in another workspace.
  (While the scope is still same-workspace it holds only that workspace's ids, so the flat walk collapses to the
  in-workspace one.)
  Taking merely "the first flagged row" instead would throw away the locality the fallback exists to preserve and
  break the "worst case is the old neighbor behavior" promise above, jumping to the TOP of the flagged list when a
  mid-list session closes.
  Pinned by `closeActiveSessionInFlaggedModeWithAnEmptyScopedRecencyStaysWithinTheFlaggedSet`,
  `closeActiveSessionInFlaggedModeWithAnEmptyScopedRecencyPicksTheNEARESTFlaggedSurvivor`, and
  `closeTheWorkspacesLastFlaggedSessionWithAnEmptyRecencyPicksTheADJACENTFlaggedRow`.
  The ONE case the flagged scoping cannot hold is closing the LAST flagged session anywhere: the scope is then
  empty, the flagged sidebar renders no rows at all, and the positional pick stands — selecting nothing would
  leave no terminal.
  Pinned by `closeTheLastFlaggedSessionFallsThroughToThePositionalTarget`.
  `reselectionTarget` now has exactly ONE caller, this helper: `removeWorkspace` / `softRemoveWorkspace` never used
  it and keep their own inline positional pick (reselection there is deliberately untouched — the
  "stay in the current workspace" constraint is meaningless when the workspace itself is what's being removed).
  `softCloseSessions`' `removedBeforeActive` index adjustment is preserved verbatim — it now feeds only the
  fallback.
- **Session navigation (between sessions).**
  Previous/Next Session sit on ⌥⌘↑/⌥⌘↓; First/Last Session have NO hotkey (menu + palette + `session.go`
  only).
  The keys deliberately AVOID the bare ⌘+arrow cluster: as always-enabled menu key-equivalents,
  bare ⌘←/→/↑/↓ shadow standard text-field caret nav (line/doc start/end) in the inline rename field,
  the palette search field, and Settings fields. ⌥⌘+arrows is not a text-field caret binding,
  so it doesn't shadow editing; ⌥⌘↑/↓ for sessions also complements the existing ⌥⌘←/→ "Focus Left/Right
  Pane" (left/right = panes, up/down = sessions), and first/last need no dedicated key.
  They are real menu items (the Navigate menu — see the menu-split note below),
  so AppKit menu dispatch swallows the shortcut before libghostty and nothing leaks to the shell.
  The pure logic is `AppStore.navigateSession(_:)` (host-free, unit-tested):
  it flattens the tree (`workspaces.flatMap(\.sessions)`), WRAPS around on next/prev (an end lands on the opposite end),
  jumps to the ends for first/last, falls to first on no/invalid selection,
  no-ops on an empty tree, and routes through `selectSession` (recency + badge + persist + workspace-derivation).
  It is shared by the menu, the action palette, and the control channel (`session.go`) so the three can't
  drift.
  Each GUI action (`AppActions.select{Next,Previous,First,Last}Session`) calls `focusActiveSession()`
  after the move so first responder follows into the moved-to terminal (the sidebar never steals focus);
  `WorkspaceSidebar.syncSelection()` expands the owning workspace if collapsed and `scrollRowToVisible`s
  the target so an off-screen row is revealed.
  Distinct from the ⌃Tab MRU switcher (recency order) and the ⌃P fuzzy palette (search) — this is predictable
  spatial stepping in the sidebar's visual order.
  **Attention navigation** (⌃⌥↑/⌃⌥↓ — the SAME arrow-fallback as the session nav,
  since arrows aren't keymap-expressible) is the variant that steps through ONLY the sessions needing
  attention (`AgentStatus.needsAttention` = `blocked`/`completed`), WRAPPING around and skipping idle/active.
  It reuses `AppStore.navigateSession` (the `.nextAttention`/`.previousAttention` cases — host-free,
  unit-tested) and is driven by Navigate ▸ Previous/Next Attention Session,
  the action palette, and `session.go next-attention|prev-attention`; the two new `BuiltinAction`s (`previous_attention_session`/`next_attention_session`)
  join the arrow-bound set (nil `defaultChord`, hardcoded ⌃⌥↑/↓ via `arrowShortcut`).
  EVERY user-initiated GUI selection now REVEALS the blocked PANE, not just the session: the shared
  `AppActions.revealActiveBlockedPane()` (formerly private, now called on all selection paths) reads the
  landed session's `agentIndicator.statusPane` and focuses that pane — for `right`, the split surface via
  `focusSplitPane(_:wantSplit: true)` (a FIXED target gated on `splitSurface != nil`, and its `onFocusChange`
  re-asserts `splitFocused` to win the shown-split re-render race). A promoted split survivor is NOT covered
  by this branch — promotion moves it into `surface` with `splitSurface == nil` (and re-tags a `.right` block
  to `.left`), so it falls through to `focusActiveSession` as the session's sole main pane, which is correct;
  for `scratch`, shows a hidden scratch via `AppStore.toggleScratch` then focuses it;
  for `left`/nil, the main pane; and it is a no-op (plain `focusActiveSession`) for an IDLE session
  (no status set), so ordinary selections are unaffected (the idle gate is what keeps a plain nav to a
  session with a shown scratch from dismissing it).
  It fires from ALL of: attention-nav (⌃⌥↑/↓, `selectNext/PreviousAttentionSession`),
  plain session nav (⌥⌘↑/↓/first/last, `selectNext/Previous/First/LastSession`),
  the ⌃P/attention command palette (async in the palette item's run closure),
  a sidebar row click (`WorkspaceSidebar.Coordinator.outlineViewSelectionDidChange`, async),
  and idle auto-follow (`autoFollowed(_:)`) — the palette/sidebar paths dispatch async so the reveal runs
  AFTER the palette/selection focus-restore settles.
  All paths route through the one helper so they can't drift (the tag is set by `session.status --pane`
  — see the Control API + Notifications rules).
  Only the control `session.go next-attention|prev-attention` does NOT reveal (`goSession` just drives
  `AppStore.navigateSession`), so the socket steps the selection without moving focus into the pane.
- `Delete Workspace` lives once in `AppActions.deleteWorkspace(_:)` (confirm alert when the workspace
  still has sessions, then `AppStore.removeWorkspace`) and is invoked from all three surfaces — the sidebar
  workspace row's context menu, the menu bar, and the action palette (the latter two via `deleteActiveWorkspace()`,
  which targets `currentWorkspaceID`).
  `AppStore.removeWorkspace` tears down each session's surfaces, prunes recency,
  and reselects; `canRemoveWorkspace` (count > 1) enforces keep-at-least-one and gates the menu item
  / palette entry.
  The sidebar Coordinator takes `AppActions` so the row menu routes through it rather than duplicating
  the confirm.
- The command palettes (`Palette.swift`: `PaletteController` + `CommandPalette`) feed off `AppActions.paletteActions()`/`paletteSessions()`
  and the host-free `fuzzyScore` (agtermCore, unit-tested).
  The visible list is a `@State` array recomputed on query/mode change — NOT a computed property — so
  the rendered rows and the Enter target can't drift out of sync; results sort by score then title. ⌃P
  opens the session switcher, ⌃⇧P the action palette (the session/action shortcut split is deliberate).
- **Built-in shortcut hints are one resolver, shared by the palette AND the toolbar/sidebar tooltips.**
  `AppActions.shortcutGlyph(for:)` (formerly `paletteHint`) → the host-free `Keymap.glyphHint(for:)`
  (`equivalent(for:)?.glyphString ?? BuiltinAction.arrowGlyphFallback`, nil = no shortcut) renders an
  action's CURRENT chord as macOS glyphs (`⌃⌘S`), tracking a `keymap.conf` rebind live.
  `paletteActions()` reads it for the right-aligned palette hint; `WindowContentView.helpHint(_:_:)`
  appends `" (<glyph>)"` to the `.help(…)` tooltip of the 8 `BuiltinAction`-backed toolbar/sidebar buttons
  (a button with no configured shortcut shows just its label). One resolver so the two surfaces can't
  drift — the display analogue of the `defaultChord`-single-source-of-truth rule. Tooltip text is pure
  visual chrome, so it is control-API keep-in-sync EXEMPT (no command, nothing to drive headless).
- **Attention list (the `.attention` palette mode).**
  A fourth `PaletteMode` (`.attention`, placeholder "Go to a session that needs attention…") lists the
  window's NON-IDLE sessions — broader than the ⌃⌥↑/↓ attention-NAV, which steps only `needsAttention`
  (blocked/completed).
  `AppActions.paletteAttention()` maps `AppStore.attentionSessions` (host-free,
  per-window: all non-idle, sorted blocked→active→completed then `statusChangedAt` newest-first,
  nil last) to `PaletteItem`s mirroring `paletteSessions()` (title=`displayName`,
  subtitle="workspace · detail"), with the new `PaletteItem.status: AgentStatus?` set so `CommandPalette.row`
  renders a leading `StatusGlyph` (the shared `AgentStatus.symbolName` + `GhosttyApp.statusColor(for:)`
  mapping the sidebar's `StatusIconView` also uses); `run` = `store.selectSession(id)`.
  Empty-query order is the `attentionSessions` order (the palette re-sorts by fuzzy score only once the
  user types); `.attention` needs no theme-preview wiring (`syncThemeSession` guards on `.themes`).
  Opened three keyboard/menu ways: `BuiltinAction.showAttention` (rawValue `show_attention`,
  `defaultChord` ⌃⇧I — a distinct chord swallowed before the terminal like ⌃⇧P/⌃⇧O,
  expressible/pure-`defaultChord`, NOT an arrow exception) → `AppActions.toggleAttentionPalette()` →
  `palette.toggle(.attention)`, the **Navigate ▸ "Go to Attention…"** menu item (reading `equivalent(for: .showAttention)`),
  and a **"Show Attention"** entry in `paletteActions()` (the ⌃⇧P launcher).
  The title-bar bell is NOT a fourth palette opener: clicking it opens a MOUSE-form popover of the attention
  sessions, not the palette (see the Notifications section + the recent/attention popover note below).
  Opening a palette is interactive-only → keep-in-sync EXEMPT, like every other palette open.
  **Button-open focus fix (`CommandPalette.onAppear`):** kept from when the bell opened the palette — a palette
  opened from a title-bar BUTTON mounts while that button still holds first responder, so `onAppear`'s
  synchronous `fieldFocused = true` loses the race and the field never takes the keyboard; the fix re-asserts
  `fieldFocused = true` on the next runloop tick via `DispatchQueue.main.async`.
  The bell now opens a popover, so no button currently opens the palette and the fix is DORMANT/defensive
  (a no-op for the menu/hotkey/⌃P opens, which have no competing responder).
- Inline rename has no direct handle from the menu/palette into the sidebar's editor,
  so `AppActions.renameActive{Session,Workspace}()` post `.agtermBeginRenameSession`/`.agtermBeginRenameWorkspace`;
  `WorkspaceSidebar.Coordinator` observes them and calls `beginEditing` on the selected row (async,
  so the row is on screen after any palette overlay closes).
  `AppActions.renamePending` keeps `focusActiveSession` (the palette/quick-terminal close focus-restore)
  off the rename field for ~0.6 s.
- The Ctrl-Tab session switcher (`SessionSwitcher` + `SessionSwitcherOverlay`) cycles a most-recently-used
  list.
  `AppStore.sessionRecency` (`RecencyStack<UUID>` in agtermCore — host-free,
  unit-tested) is pushed on every selection and pruned on close;
  the switcher snapshots it on `begin()` so cycling never reorders it (only the commit does,
  via `selectSession`).
  `begin()` CAPS the snapshot at the 10 most-recent (`SessionSwitcher.maxCandidates` fed to
  `RecencyStack.top(_:in:)`) — Ctrl-Tab is a quick jump, not a full list (the ⌃P fuzzy palette covers
  everything); the recency STORE keeps its full 100-item history.
  The cap can't be observed through XCUITest (the overlay only shows while Ctrl is HELD and `typeKey`
  always releases the modifier), so it's covered host-free by `RecencyStackTests.topCapsResultAtRequestedCount`.
  The order is persisted (`Snapshot.sessionRecency`, an optional field like the other post-v1 additions)
  and re-seeded on restore — stale ids dropped, the restored selection floated to the front — so the
  switcher works right after a relaunch instead of starting empty (#110).
  Persistence is pure model/restore behavior with no new user action,
  so it is control-API keep-in-sync EXEMPT.
  Keys come from app-wide `NSEvent` local monitors (`.keyDown` for Ctrl+Tab / Ctrl+Shift+Tab / Esc,
  `.flagsChanged` to detect the Ctrl release = commit), NOT SwiftUI shortcuts — the interaction needs
  Tab-while-Ctrl-held plus the modifier-release signal.
  The overlay has no focusable control, so the terminal keeps first responder and selection-on-commit
  re-focuses via `TerminalView`.
- **Title-bar mouse popovers: the CLOCK is the mouse form of the Ctrl-Tab switcher, the BELL the mouse form
  of the attention palette** (`WindowContentView+RecentSessions.swift`, split out to keep `WindowContentView.swift`
  under 1000 lines; the `attentionButton` moved here too).
  Both open a theme-tinted SwiftUI `.popover` of clickable session rows — the shared `SessionPopoverRow`:
  a `SessionSwitcherRow` (now taking an optional themed `foreground` + an optional leading `status` glyph)
  wrapped in a `Button` with `.onHover` highlight (the theme selection color), `.contentShape(Rectangle())`
  for a full-row hit target, and `.presentationBackground(terminalColor)` + `chromeText` text so the panel
  tracks the terminal theme like the sidebar/titlebar chrome.
  The CLOCK's `recentSessions` = `sessionRecency.top(SessionSwitcher.maxCandidates, in:)` with the ACTIVE
  session removed (it is not a jump target), so the button enables only with ≥2 sessions; a row click runs
  `selectRecent` (`noteUserActivity` + `selectSession` + `focusActiveSession`).
  The BELL's `attentionPopover` = `AppStore.attentionSessions` (all non-idle, INCLUDING the current), each
  row carrying its `StatusGlyph`; a row click runs `selectAttention` (adds `AppActions.revealActiveBlockedPane`).
  Both are control-API keep-in-sync EXEMPT (interactive popover opens, like the bell↔palette before).
  **The row CLICK is not XCUITest-drivable** — a synthesized click (element OR coordinate) inside an
  `NSPopover` does not fire a SwiftUI `Button` action (confirmed by instrumentation: the action never ran),
  though a real mouse click does (it makes the popover key).
  So the e2e (`RecentSessionsButtonUITests`, `AttentionButtonUITests.testAttentionButtonOpensPopoverListingAttention`)
  asserts the popover OPENS and lists the right sessions; the click→select is verified by hand and covered
  host-free by the selection APIs (see [[ui-tests]]).

