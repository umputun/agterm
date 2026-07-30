---
paths:
  - "agterm/AppActions*.swift"
  - "agterm/AppDelegate+DockMenu.swift"
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
  - "agtermTests/DockMenuTests.swift"
---

## Menu bar and actions

- `@MainActor AppActions` shares nontrivial behavior among titlebar/footer, menu, palette, and control:
  placement, directory picking, split/focus, and font. Trivial toggles may call their owner directly.
- `toggleQuickTerminal` gates on all `uiActionsEnabled`, including terminal zoom and dashboard. Menu
  `.disabled(modalActive)` also gates rebound key equivalents; palette dispatch and Dock invocation recheck.
  Control drives `QuickTerminalRegistry` directly. The titlebar button is replaced by dashboard chrome,
  which hides an open quick terminal before showing the grid.
- Every new action must satisfy the control contract in [[control-api]]: protocol, dispatch, CLI, and
  protocol/end-to-end tests. Do not restate per-action audits here.

## Dock menu

- `applicationDockMenu` exposes New Session, New Window, Quick Terminal, Dashboard, captured-window MRU
  sessions, and attention ordering.
- New Window alone is app-scoped (Discussion #313): capture nothing, call
  `newWindow(ignoringModals: true)`, enable only when `actions != nil`, and explicitly unhide/activate.
  Do not mark it always enabled before the action hub is wired. Require `openWindow` before persisting an
  open entry. Menu and palette New Window retain modal gating.
- Other items capture store and window ID at build time. Recheck per-window modal/controller state, raise
  that window, synchronously publish it frontmost, then dispatch. A stale closed/modal item is inert;
  dashboard built open may close it, but one built closed becomes inert if it opens before invocation.
- `NSMenuItem.target` is weak and AppKit sends nil sender. Retain closure targets until the next rebuild,
  invalidate old targets first, and capture session IDs rather than `Session` or surfaces.
- Selection uses the pre-reset indicator returned by store selection and reveals pane tags only for
  blocked/completed. Active and idle use ordinary focus.
- `navigableRecentSessions`, excluding current and capped by `SessionSwitcher.maxCandidates`, supplies
  visible-scope MRU entries. Hosted coverage uses `make test-app`, isolated state/socket variables, and
  `AGTERM_HOSTED_TESTS=1`; never add that sentinel to the UI-test scheme. Dock actions compose existing
  control capabilities.

## Menu organization and shortcuts

- View contains display state: font/theme, sidebar and workspace expansion, flagged/focus controls,
  split/scratch/find/quick terminal, and fullscreen. Navigate contains palettes, session/attention
  stepping, pane focus, and Dashboard. File UI tests against the menu that owns the item.
- Workspace focus controls are mode-agnostic because membership applies when tree mode returns.
  Expand/Collapse Workspaces alone are disabled outside tree mode, in both menu and palette.
- Dashboard uses Command-Shift-D, `BuiltinAction.dashboard`, and `toggleDashboard`; it toggles an MRU,
  auto-sized grid unless terminal zoom is active. Share `dashboardMembers` with control.
- Remove AppKit's reinjected fullscreen item as described in [[windows]]. agterm's own
  `toggle_fullscreen` remains rebindable and control-drivable.
- Font shortcuts call libghostty binding actions on the key window's first-responder surface, falling back
  to the active session. Persistence still flows from cell-size callbacks.
- `shortcutGlyph` delegates to host-free `Keymap.glyphHint`. Use it for palette hints and the ten built-in
  toolbar/sidebar tooltips so rebinds update both. This visual text is keep-in-sync exempt.

## Search

- `BuiltinAction.toggleSearch` defaults to Command-F and drives the focused surface's `start_search`.
  View > Find and the palette read its configured equivalent.
- `START_SEARCH` toggles: if this session's bar is visible, send `end_search`; otherwise open, seed the
  returned needle, and focus. `END_SEARCH` clears all four ephemeral fields and refocuses the terminal.
  TOTAL/SELECTED convert negative `ssize_t` to nil. Copy callback strings before the main-actor hop.
- Wire all four callbacks through `wireSearchCallbacks` for main, split, and scratch. Surface methods are
  thin binding-action wrappers; `AppActions` owns GUI needle/navigation/end behavior. The same session
  state and `searchDisplayText` back `session.search`.
- Scratch is searchable; quick terminal and full overlay are not. `searchTarget` checks a covering scratch
  before focused-surface fallback so sidebar focus cannot target the hidden pane. Floating overlay leaves
  pane search available.
- On scratch exit, clear search only when `searchSurface === scratchSurface`; pane-owned search survives.
  Split/primary teardown follows the same ownership rule.

## Split panes

- `isSplit` means shown side-by-side, `hasSplit` means the second shell exists, and `splitFocused` chooses
  focus. Split title/cwd feed focus-aware display name and focused cwd based on `splitFocused`, even hidden.
  `effectiveCwd` remains primary for new panes and `AGTERM_SESSION_PWD`; `activeSurface` follows focus.
- Creating a split focuses right. Hiding retains both shells and shows the focused pane maximized;
  reshown splits preserve focus. `closePrimaryPane` promotes right into primary with cwd/title/foreground
  command; `closeSplitPane` keeps primary when both exist and otherwise closes the session.
  `focusAfterReparent` restores focus after the surviving view changes host.
- Pane focus actions, menu/palette, and `session.focus` gate on `hasSplit`, not `isSplit`, so they also swap
  the maximized hidden pane. Ctrl-1/Ctrl-2 use an app-wide event monitor and always consume these reserved
  keys, even when no split exists.
- Persist each pane cwd and the 0...1 left-pane `splitRatio`. `SplitRatioAccessor` is an unconditional
  background representable on primary, introspects `NSSplitView`, retries until width exists, observes
  `didResizeSubviews`, and debounces save by about 0.4 seconds. Regular saves and quit flush also persist it.
- `SplitRatioAccessor` masks only the compact-titlebar divider overrun. At 30pt compact height, SwiftUI
  padding lies inside the safe-area band and AppKit expands `NSSplitView` full height; normal 48px mode is
  already bounded. Compute the live overrun and apply a CALayer mask, removing it at zero.
  Do not use SwiftUI mask/clipping because it reflows and loses the terminal's top row; do not use an
  opaque cover because it breaks translucency. Key `HSplitView` identity by session.
- Sidebar icon follows `hasSplit`. The titlebar's four-state icon is outline with none,
  `rectangle.split.2x1.fill` while shown, left-half filled for hidden primary, and right-half filled for
  hidden split.

## Close and reselection

- Command-W first dismisses the frontmost cover: quick terminal, then overlay, then scratch. Only then close
  the active session. If no cover or session exists, the menu performs window close. Keep the cover check
  inside `closeActiveSession`, since a sessionless window can still show quick terminal.
- All active-session close paths use host-free `closeReselectionTarget` (Discussion #147). Prefer the most
  recent survivor in three widening scopes: same workspace intersected with `navigableSessions`, all
  navigable sessions, then the whole tree. Build scopes from the post-removal tree; soft close retains
  recency until grace finalization for undo.
- This preserves the current workspace when possible, remains inside flagged/focused views while they
  contain survivors, and lets `disableFocusIfSelectionOutsideSet` reveal a whole-tree fallback while
  preserving membership.
- If MRU is empty, narrowed modes use `nearestInScopeTarget` over flattened sidebar order; unfiltered tree
  uses the sole `reselectionTarget` caller. Do not choose the first flagged row because it destroys locality.
  Closing the last flagged session widens to the whole tree rather than leaving no terminal.
- Workspace removal uses `workspaceRemovalTarget`: most recent visible, then first visible, then positional.
  Preserve `softCloseSessions.removedBeforeActive` for fallback index adjustment. The named
  close/reopen/filter tests in `AppStoreCloseReselectionTests` pin these scopes.
- Delete Workspace centralizes confirmation in `AppActions.deleteWorkspace(_:in:)`, then removes surfaces,
  recency, and reselection. Row menus pass their own store because right-clicking a background window does
  not raise it. Menu/palette target active workspace and enforce `uiActionsEnabled`. Keep at least one workspace.

## Navigation

- Previous/Next Session default to Option-Command-Up/Down; First/Last have no hotkey. Avoid bare
  Command-arrows because menu equivalents shadow caret navigation in rename, palette, and settings fields.
  Option-Command-Left/Right remains pane focus.
- `navigateSession` uses `navigableSessions`, wraps previous/next, selects ends for first/last, chooses
  first on nil/invalid selection, and no-ops when empty. Menu, palette, and `session.go` share it.
- When selection moves, GUI callers reveal a captured blocked/completed pane; unchanged plain navigation
  only refocuses, preventing a one-item wrap from resetting split focus. Modal focus guards still apply.
- Attention navigation defaults to Control-Option-Up/Down, includes blocked/completed only, wraps, and
  excludes current. If it finds no other target, GUI callers may use the current live indicator solely to
  reveal its tagged pane. Control changes selection only.
- `revealActiveBlockedPane` focuses right only when the split surface exists, explicitly chooses primary
  for left/nil, and shows/focuses scratch. Promotion retags right to left. Idle/active never change pane or
  dismiss scratch. Navigation, palettes, sidebar, Dock menu, titlebar attention, and auto-follow share it.
- Sidebar selection expansion/scroll makes the target visible. Spatial navigation is distinct from MRU
  Ctrl-Tab and fuzzy Ctrl-P.

## Palettes, rename, and switcher

- `PaletteController`/`CommandPalette` consume `paletteActions`, `paletteSessions`, and host-free
  `fuzzyScore`. Store the visible results in state on query/mode changes so rendering and Enter target
  cannot diverge; sort by score then title. Ctrl-P opens sessions; Ctrl-Shift-P opens actions.
- Attention mode lists every non-idle session, ordered blocked, active, completed and then newest
  `statusChangedAt`, with nil last. Palette items carry status plus per-call color/shape, resolved by the
  same helpers as sidebar glyphs. Empty query preserves this order; typed queries use fuzzy score.
- Open attention through `show_attention` (Ctrl-Shift-I), Navigate > Go to Attention, or Show Attention
  in the action palette. The titlebar bell opens a popover, not this palette. Palette opening is
  keep-in-sync exempt.
- Keep the next-runloop `fieldFocused = true` retry: button-opened palettes otherwise lose first responder,
  even though no current titlebar button uses this path.
- Rename actions post begin-edit notifications; the Coordinator edits the selected row asynchronously after
  palette dismissal. `renamePending` suppresses terminal focus restoration for about 0.6 seconds.
- Ctrl-Tab snapshots `sessionRecency` and cycles without reordering until commit. Limit candidates to 10
  while retaining 100 history entries. Persist optional recency, drop stale IDs, and float restored
  selection on load (#110). Host-free tests cover the cap because XCUITest releases Control.
- Use app-wide key-down and flags-changed monitors for Ctrl-Tab, reverse, Esc, and release-to-commit.
  The overlay has no focusable control, so terminal first responder remains.

## Titlebar popovers

- Keep clock and bell popovers in `WindowContentView+RecentSessions` so `WindowContentView.swift` remains
  below 1000 lines. They use
  `SessionPopoverRow`: optional status glyph, hover selection color, full-row hit target, terminal
  background, and chrome text.
- Clock lists up to `maxCandidates` recent visible sessions excluding active and enables only with at
  least two sessions. Selection records activity, selects, and focuses.
- Bell lists all non-idle sessions including current. Selection uses pane-aware reveal.
- Popover opens are keep-in-sync exempt. Synthesized XCUITest clicks inside `NSPopover` do not fire the
  SwiftUI button, though real clicks do; tests verify open/list contents, while selection is manual plus
  host-free API coverage.
