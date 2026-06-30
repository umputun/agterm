---
paths:
  - "agterm/Notifications/NotificationManager.swift"
  - "agtermCore/Sources/agtermCore/Notifications.swift"
  - "agtermCore/Sources/agtermCore/AgentStatus.swift"
---

## Notifications

- Terminal desktop notifications (OSC 9 / 777).
  `GhosttyCallbacks.action` handles `GHOSTTY_ACTION_DESKTOP_NOTIFICATION` — copies the `title`/`body`
  C strings synchronously (only valid for the call), recovers the firing `GhosttySurfaceView` via the
  existing `surfaceView(from:)`, and hops to `NotificationManager.shared.notify(surface:title:body:)`.
  (The bell, `GHOSTTY_ACTION_RING_BELL`, is intentionally NOT a notification source.)
- `NotificationManager` (`agterm/Notifications/`, `@MainActor` singleton + `UNUserNotificationCenterDelegate`,
  `@preconcurrency` conformance like macterm) owns the macOS surface.
  `notify` resolves the owning `Session` (the view's `weak var session`) + `PaneRole` (identity-compare
  the view to the session's `surface`/`splitSurface`/`overlaySurface`), applies suppression,
  **always bumps `session.unseenCount`** (the badge), then posts a `UNNotificationRequest` ONLY if `bannersEnabled`
  (the General toggle) — so turning banners off still tracks the badge.
  Registered + `requestAuthorization([.alert])` from the scene `.task` (alongside `controlServer.start()`);
  auth is best-effort — the badge works even when banners are denied.
  `willPresent` returns `[.banner, .list]` so banners show even while agterm is frontmost (the focused-pane
  case is dropped at delivery, NOT in `willPresent`).
  `clearDelivered(sessionID:)` removes a session's delivered banners (all three pane identifiers) when
  you focus it, so a notification you've navigated to doesn't linger in Notification Center.
  `send(toSession:title:body:)` is the control channel's entry point (the `notify` command / `agtermctl notify`):
  same badge + banner + reveal-identity machinery, but NO focus-suppression (the caller asked for it)
  and attributed to the `.main` pane.
- **Suppression**
  is the pure, agtermCore-tested `TerminalNotification.shouldDeliver(firingIsFocused:appActive:)`:
  drop entirely only when the firing surface is the key window's first responder AND `NSApp.isActive`
  (you're already looking at it).
  The manager uses the strict first-responder check (NOT `AppActions.focusedSurface()`,
  whose active-session fallback would wrongly count a sidebar-focused window as "looking at the pane").
- **Identity / navigation.**
  `TerminalNotification.identity`/`parseIdentity` (agtermCore) make the request identifier `"<sessionID>:<paneRole>"`
  — it both coalesces repeats from the same pane (the OS replaces, doesn't stack) and carries the click
  target (no `userInfo` needed).
  `didReceive` parses it, `NSApp.activate`s, and calls `AppActions.reveal(sessionID:pane:)`:
  `selectSession` (which clears the badge + derives the workspace) then `focusSplitPane` for the pane,
  stale-safe (unknown session → just activate; a `.split` no longer split → primary).
  `reveal` is internal click-routing (not on toolbar/menu/palette) composing the already-controllable
  `session.select`, so it has NO control command (keep-in-sync exempt, by user decision).
- **Badge.**
  `Session.unseenCount` (observed; ephemeral — `SessionSnapshot` doesn't capture it,
  so it never persists).
  `SidebarCellView.badge` is a custom-drawn `BadgeView` (an accent capsule,
  count capped `99+`, accessibility role `.staticText` with id `notify-badge`) at the row's trailing
  edge, with a `Workspace.unseenCount` roll-up on the workspace row so an unseen badge stays visible
  when the workspace is collapsed.
  `unseenCount` is folded into the sidebar's `updateNSView` dependency read,
  and `reloadChangedBadgeRows`/`snapshotBadges` reload only the changed session + workspace rows.
  Cleared by `AppStore.selectSession` and by a pane's `onFocusChange(true)` (which also calls `clearDelivered`
  — focusing a pane means you've seen the session).
  **The count pill rendering is gated by the `notificationBadgeEnabled` Settings toggle** (see the Settings
  section): the Coordinator's `effectiveUnseen(_:)` returns 0 when the flag is off,
  applied to BOTH the session badge and the workspace roll-up (and to `RowContent.unseen` so a toggle
  reloads the rows).
  This gates ONLY the red count pill — the agent-status glyph (drawn just left of it by `StatusIconView`)
  is always on, never gated by this.
- **Dock badge (`DockBadgeController`, app target).**
  A `@MainActor` singleton (next to `NotificationManager`, wired in the scene `.task`) that shows the
  app-wide unseen total on the Dock icon.
  The total is the host-free `WindowLibrary.totalUnseenCount` (sum of every open window's sessions'
  `unseenCount`, unit-tested); it's gated by the SAME `notificationBadgeEnabled` toggle as the sidebar
  pill (badge count is 0 when off).
  **Uses `UNUserNotificationCenter.setBadgeCount(_:)`, NOT `NSApp.dockTile.badgeLabel`.** For agterm the
  legacy dock-tile label is silently suppressed — the value sets and persists on the tile but the Dock
  never draws the pill — because it needs the `.badge` authorization option; `NotificationManager.start`
  now requests `[.alert, .badge]`.
  The modern UN badge renders correctly over the LIVE adaptive Icon Composer icon with no loss of
  light/dark/tint/clear adaptivity, so there is NO `applicationIconImage` override.
  Cleared to 0 on quit (`DockBadgeController.clear()` from `applicationWillTerminate`) — the OS badge
  outlives the process and `unseenCount` is ephemeral, so without it a quit with unseen > 0 would leave a
  stale count pinned on the Dock icon (the `willClose` poke can't do it: `isTerminating` makes `closeWindow`
  no-op, so the total recomputes unchanged).
  Reactivity is the Observation re-registration pattern (`apply()` reads `totalUnseenCount` inside
  `withObservationTracking` and re-arms on change), with explicit `refresh()` pokes on the two
  unobservable store mutations — a window CLOSE (`willClose` teardown in `ContentView`, `window.close` in
  `ControlServer`) AND a window REOPEN (`ContentView.resolveStore` after `loadStore`, so a reopened
  window's bumps aren't stale) — and an `.agtermAppearanceChanged` observer for the (non-`@Observable`)
  toggle flip.
  Keep-in-sync EXEMPT — pure derived chrome (`unseenCount` is already driven by `notify` / `session.select`),
  nothing new to drive over the socket.
- **Agent-status glyph.**
  Mirrors the `notify-badge` cell pattern (see the Control API `session.status`).
  `StatusIconView` (an `NSImageView` sibling of `BadgeView` in `WorkspaceSidebar`) draws the row's tinted
  SF Symbol just LEFT of the count badge — `active`=`ellipsis.circle.fill`,
  `blocked`=`exclamationmark.circle.fill`, `completed`=`checkmark.circle.fill`,
  `.idle`=hidden, each tinted with its configurable Settings color (`GhosttyApp.{active,blocked,completed}StatusColor`,
  default `#DBD9E6` muted lavender-grey / system amber / system green; see the Settings section) — with
  accessibility role `.staticText`, id `agent-status`, value = the state name (so XCUITest matches `app.staticTexts["agent-status"]`),
  and a `CABasicAnimation` `opacity` pulse added only while visible AND `blink` (the install's `UserPromptSubmit→active --blink`
  hook pulses the in-progress glyph).
  The glyph shows on EVERY non-idle session, the selected one INCLUDED — there is NO visibility gate.
  (An earlier `isFrontmostWindow`-driven hide-on-the-selected-session gate was removed:
  blanking the status on the row you're viewing read as confusing, since every other row carried a state;
  the `isFrontmostWindow` plumbing went with it.) `effectiveIndicator(forSession:)` is just the session's
  own `agentIndicator`; it rides in `RowContent` (Equatable) so a status/blink change reloads only that
  row, and `agentIndicator` is folded into the `updateNSView` dependency read.
  A one-time `completed --auto-reset` is cleared by `AppStore.selectSession` on BOTH the session visited
  AND the one left (`clearAutoResetIndicator(new)` + `clearAutoResetIndicator(previous)`) so it never
  lingers on the row you switch away from — a Claude Code hook can't do this,
  it has no notion of the agterm selection.
  `StatusIconView` owns its OWN width constraint (0 when `.idle`, glyph-width otherwise,
  toggled in `apply`) so an idle row collapses the slot and reads full-width;
  `BadgeView.intrinsicContentSize` likewise collapses to zero width at `count == 0` (so a hidden OSC
  badge reserves no trailing slot and the glyph sits flush-right), with the glyph-to-badge gap baked
  into the badge's leading edge so it only appears when the badge does.
  **Clear Status** forces a session's indicator back to idle from the GUI:
  the sidebar row's right-click menu (first item, only when non-idle), the menu bar,
  and the ⌃⇧P palette — the row menu targets the clicked node id, the menu bar + palette go through `AppActions.clearActiveSessionStatus`
  (the active session); all route to `AppStore.setAgentIndicator(AgentIndicator(), forSession:)`,
  the GUI half of `session.status idle`.
  **Typing also clears an attention glyph:** `GhosttySurfaceView.keyDown` calls `AgentStatus.clearedByKeystroke(isEscape:)`
  on the owning session's `agentIndicator.status` and, when it returns true,
  fires `onUserInputClearsStatus` (wired by the main/split surface factories to the same `setAgentIndicator(AgentIndicator(), …)`
  → idle).
  The decision is host-free + unit-tested in `agtermCore`: `blocked`/`completed` clear on ANY key (you've
  engaged with the prompt / finished result); `active` clears ONLY on Escape — the interrupt key (`keyCode == 53`)
  — so ordinary typing while the agent works does NOT wipe the "working" glyph,
  but cancelling a prompt with Esc does; `idle` has no glyph.
  This is the ONE input-driven clear (status is otherwise control-driven).
  It covers the Esc-decline/interrupt case Claude Code fires NO hook for — the keystroke flows through
  the surface's `keyDown` on its way to the agent's PTY, so it clears the stale glyph the moment you
  deal with the prompt — and clears the `completed` flash once you re-engage.
  The `active`-on-Esc arm is load-bearing for the QUICK-Esc case: a pending question can still read `active`
  when you cancel it, because Claude Code's `blocked` (`Notification[permission_prompt]`) fires on a
  DELAY (~tens of seconds — its idle-notification timer, `messageIdleNotifThresholdMs`,
  default 60000), so a fast Esc lands while the glyph is still `active`,
  and the interrupt itself fires no hook (verified by a status-hook probe:
  an Esc-cancel logs no hook at all; a manual decline fires neither `Stop` nor `PostToolUse`) — the keystroke
  clear is the only signal.
  The `PostToolUse→active --blink` install hook covers the answer-then-resume case (the agent's next
  tool re-asserts `active`).
  Peer terminals get the decline case for free by different means agterm avoids:
  cmux owns the permission decision UI (a blocking hook round-trip captures accept/deny),
  herdr scrapes the PTY (the prompt chrome leaving the screen clears it).
- **Titlebar attention bell (opt-in, window-wide aggregate of the glyph).**
  When `attentionButtonEnabled` is on (Settings ▸ General, default OFF — see the Settings section),
  `customTitlebar` (`ContentView`) shows a bell icon just after the title that recovers the per-session
  attention signal when the sidebar is hidden.
  It derives THREE states from the window's `AppStore.attentionSessions` (the host-free per-window set
  — ALL non-idle sessions, broader than `needsAttention`): empty → `bell`,
  ~0.35 opacity, `.disabled(true)`; non-empty no-blocked → `bell`, `chromeText`,
  enabled; any `.blocked` → `bell.fill` tinted `GhosttyApp.shared.blockedStatusColor`,
  enabled.
  No count, no pulse.
  Reading `attentionSessions` registers the `agentIndicator` observation,
  so the icon updates LIVE on status change.
  Click → `AppActions.toggleAttentionPalette()` (the `.attention` palette — see the Menu/actions section).
  It carries `.accessibilityIdentifier("attention-button")`, a `.help` string,
  and an `.accessibilityValue` of `none`|`attention`|`blocked` — mirroring `StatusIconView`'s state-name
  value so XCUITest can read the otherwise-unobservable `bell`↔`bell.fill` highlight.
  `WindowContentView` mirrors the chrome flag into `@State` (seeded from `GhosttyApp.shared.attentionButtonEnabled`,
  refreshed on `.agtermAppearanceChanged`), NOT from `model.settings`.
  The bell is pure visual chrome (it opens the already-controllable attention palette / `session.select`)
  — keep-in-sync EXEMPT, like the other titlebar buttons.

