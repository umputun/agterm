---
paths:
  - "agterm/Notifications/NotificationManager.swift"
  - "agtermCore/Sources/agtermCore/Notifications.swift"
  - "agtermCore/Sources/agtermCore/AgentStatus.swift"
---

## Notifications

- OSC 9/777 reaches `GHOSTTY_ACTION_DESKTOP_NOTIFICATION`; copy its call-scoped C strings immediately,
  recover the `GhosttySurfaceView`, and call `NotificationManager.notify`. `GHOSTTY_ACTION_RING_BELL`
  is not a notification source.
- `NotificationManager` is an `@MainActor` singleton and `@preconcurrency`
  `UNUserNotificationCenterDelegate`. It resolves `Session` and `PaneRole` by surface identity, applies
  suppression, always increments `unseenCount`, and posts only when `bannersEnabled`. Authorization is
  best-effort; request `[.alert, .badge, .sound]` from the scene task. `willPresent` returns
  `[.banner, .list, .sound]`, except for one `TerminalNotification.isStale` rejects — delivered after its
  session changed windows — which is dropped and removed instead.
- A cross-window move retires the session's banners through `retireBanners(forMovedSession:destinationWindowID:)`:
  they carry the source window's id, and a click on one left behind would reopen the window the session left.
  Both that sweep and focus's `clearDelivered` match the delivered set by session id, never by rebuilding
  identifiers from the current window, which would match none of them. The delivered set is queried
  asynchronously, so `TerminalNotification.shouldSweep` spares what the sweep's own window still owns,
  anything delivered after the sweep started, and any identity re-posted after it — else a move's sweep
  overtaken by a later move, or a focus clear, takes a banner that arrived after it, or removes by
  identifier the newer banner that replaced one its query named. `lastPostedAt` records each submission and
  the query's result is filtered back on the main actor against it; the map clears once no sweep is in
  flight, since only one can be spared by a record. The move also records the destination per session,
  which is what `windowID(forSession:)` stops answering once that window closes.
  `openWindowID(forSession:)` is where a live window contradicts a record, so every caller seeing an open
  owner — `notify` and `send` included — drops it while a window still can, and `currentWindowID(forSession:)`
  falls back to the record only when none does. The sweep is the records' garbage collection:
  `TerminalNotification.retainedMoveRecords` keeps those with a delivered banner left to retarget plus the
  `unsettledSessions` — every session whose submission or sweep is still outstanding, including concurrent
  moves, whose banners no snapshot names yet — so moved-then-closed sessions cannot accumulate.
  The sweep sees only what is already delivered (`add` confirms scheduling, not delivery), so three
  gaps close elsewhere against that: `post(identity:content:sessionID:)` retires its own request when the add
  was still in flight, `willPresent` drops one delivered after the sweep, and `didReceive` — the only hook a
  background delivery reaches — reveals the session's current window rather than the one its identity names.
- `send(toSession:)`, used by `notify`, shares badge, banner, bounce, sound, and identity behavior but
  deliberately skips focus suppression and attributes the request to `.main`.
- Log every post and suppression at `.notice`, including the focus and banners-off gates (#286).
  Lower levels are not persisted by default, so post-event `log show --last 30m` depends on notice.
  When banners are off, return
  `ControlNotify.bannersOffNote` in `result.text`; plain `ok` cannot distinguish suppression from failure.
  This follows the `session.restore` note precedent. `NotifyBannersUITests` seeds
  `notificationsEnabled` through `ControlAPITestCase.seededSettings`; there is no runtime settings command.
- Suppress only when `TerminalNotification.shouldDeliver` sees both an active app and the firing surface
  as the key window's first responder. Do not use `AppActions.focusedSurface()`: its active-session
  fallback mistakes sidebar focus for viewing the pane.
- `TerminalNotification.identity` encodes `"<windowID>:<sessionID>:<paneRole>"`, coalescing repeats and
  carrying the click target without `userInfo`. `didReceive` activates the app and calls `AppActions.reveal`: select
  the session, clear its badge, derive its workspace, focus the pane, and raise its window through
  `WindowRegistry.raise`, which deminiaturizes first. Unknown sessions only activate; a missing split
  falls back to primary. Activation and first-responder changes do not order a background window front.
  XCUITest cannot drive the notification delegate, so verify clicks manually; `testWindowMinimizeAndRestore`
  covers the raise mechanism. Internal `reveal` composes controllable selection and is keep-in-sync exempt.

## Badges

- `Session.unseenCount` is observed but excluded from `SessionSnapshot`. `BadgeView` draws an accent
  capsule capped at `99+`, role `.staticText`, ID `notify-badge`; workspace rows roll up descendant counts.
  Dependency reads plus `snapshotBadges`/`reloadChangedBadgeRows` limit reloads to changed rows.
- Selection and pane focus clear unseen state and delivered banners. App activation does not transition
  the retained first responder, which caused #155; the `didBecomeKey` observer therefore calls
  `clearUnseenOnRefocus` only when `liveFocus` says this pane is the key window's first responder.
- `notificationBadgeEnabled` gates session, workspace, and Dock counts through `effectiveUnseen`, including
  `RowContent.unseen` so toggles reload rows. It never gates the agent-status glyph.
- `DockBadgeController` shows host-free `WindowLibrary.totalUnseenCount`. Use
  `UNUserNotificationCenter.setBadgeCount`, not `NSApp.dockTile.badgeLabel`, which stores but does not draw
  agterm's value. The modern API preserves the adaptive icon, so never override `applicationIconImage`.
  Clear the OS-persistent badge in `applicationWillTerminate`; `willClose` cannot do this because
  `isTerminating` makes `closeWindow` a no-op.
- `apply()` observes and re-arms on `totalUnseenCount`. Explicitly refresh after window close, control
  `window.close`, and `ContentView.resolveStore` reopen; observe `.agtermAppearanceChanged` for the
  non-observable toggle. This derived chrome is keep-in-sync exempt.

## Bounce and sound

- `DockBounce` is `off`, `once`, or `untilFocused`, with nil resolving to `off`; avoid `none` because it
  collides with `Optional.none`. `once` requests `.informationalRequest`; `untilFocused` uses
  `.criticalRequest`, which macOS cancels on activation, so no cancellation bookkeeping is needed.
  Bounce after every unseen increment in OSC and control paths, independent of banners. Both requests are
  no-ops while frontmost, so no extra app-active gate is needed.
- `SettingsModel.applyDockBounce` mirrors the setting into `NotificationManager`; it is neither a Ghostty
  key nor rendered chrome. The GUI-only picker is keep-in-sync exempt. Bounce is visually verified;
  tests cover tolerant settings round-trip and `SettingsUITests.testDockBouncePickerPersists`.
- `notificationSoundName` is nil/empty for silence or a system sound name. Attach it as
  `UNNotificationSound` to both OSC and control banners; do not use raw `NSSound` (#232). Sound must obey
  banners, authorization, and Focus, unlike badge and bounce. Assume `.aiff` without an extension;
  `default` and `beep` use `.default`. Same-pane requests coalesce, and `StatusSoundPlayer` throttling is
  irrelevant except for picker preview.
- `SettingsModel.applyNotificationSound` mirrors the next-delivery value. The Notifications picker maps
  None to nil and previews choices. It is keep-in-sync exempt; per-call sound remains
  `session.status --sound`.

## Agent status

- `StatusIconView`, an `NSImageView` beside `BadgeView`, draws every non-idle session as a filled SF Symbol
  in a 16pt slot at 13pt, with no selected-row hiding. Idle collapses its width to zero; a zero-count badge
  also collapses, with the inter-item gap owned by the badge.
- Default states share `circle.fill` and differ by tint. Discussion #277 rejected marked circles because
  their interior marks are illegible at row size. `AgentStatus.symbolName(override:configured:)` resolves
  per-call shape, configured status shape, then `circle`; require both arguments so omitted settings fail
  compilation. The fixed useful set is `circle`, `square`, `triangle`, `diamond`, `capsule`, `star`.
  `hexagon`/`octagon`/`pentagon`/`seal` resemble circle, `app` duplicates square, and `rhombus` duplicates
  diamond at this size. Raw values form `"<raw>.fill"` and `displayName` is the shared picker label.
  Keep `ControlArgs.shape`, website command docs, and agent skill lists synchronized; CLI and dispatcher
  validation derive from `validNamesList`/`validNamesPhrase`.
- `GhosttyApp.statusColor(for:override:)` similarly resolves per-call `#rrggbb`, configured status color,
  then the muted lavender-grey `#DBD9E6`, system amber, or system green defaults. SwiftUI `StatusGlyph`
  uses the same shape and tint helpers.
- The glyph is `.staticText`, ID `agent-status`, accessibility value equal to the state. Color and shape
  are not accessibility-observable, so end-to-end tests assert command and `tree` state, not pixels.
  `RowContent.agentIndicator` and the update dependency read restrict reloads to changed rows.
- Blink adds an opacity `CABasicAnimation` only while visible and when Reduce Motion is off.
  `SystemAccessibilityObserver` translates the workspace notification to
  `.agtermAccessibilityDisplayOptionsChanged`, and the sidebar reapplies visible glyphs. Dashboard pills
  gate their SwiftUI repeat with `accessibilityReduceMotion`. Retain `blink` so both resume when re-enabled.
- `completed --auto-reset` clears both the session entered and the session left in
  `AppStore.selectSession`; hooks cannot infer agterm selection.
- Clear Status is the first row-menu item when non-idle and also appears in the menu bar and palette.
  Row menus target their node; global surfaces call `clearActiveSessionStatus`; all set an empty indicator.
- `GhosttySurfaceView.keyDown` always calls `onUserInputClearsStatus(isInterrupt:)`. Main `.left`, split
  `.right`, and scratch `.scratch` factories own the pane-scoped decision, allowing scratch to clear
  without `view.session`. `AgentIndicator.clearedBy` clears blocked/completed on any key, active only on
  interrupt, and only when the key's pane owns the status. Thus foreground typing cannot clear another
  pane's status.
- Interrupt means Esc (`keyCode == 53`) or bare Ctrl-C: control with no command/option/shift and either
  character `c` or physical key code 8. Physical matching covers non-Latin layouts; character matching
  covers Dvorak; excluding shift preserves Ctrl-Shift-C. Keep the full host-free truth table in
  `InterruptKeystrokeTests`.
- On pane teardown, `closeSplit`, `closePrimaryPane`, and `closeScratch` clear status owned by the removed
  `.right`, `.left`/nil, or `.scratch` pane, respectively, as they do search state.
- Input clearing covers the hookless Esc/Ctrl-C decline and completed re-engagement. It must also clear
  active on quick interrupt: Claude's delayed `Notification[permission_prompt]` uses
  `messageIdleNotifThresholdMs` (default 60000), and Esc/manual decline emits neither `Stop` nor
  `PostToolUse`. `PostToolUse` reasserts `active --blink` after an answered prompt. cmux can observe its
  own permission UI and herdr scrapes PTY state; agterm does neither.
- `AgentIndicator.statusPane` also directs GUI selections needing attention. Attention and ordinary
  navigation, palettes, sidebar and Dock rows, and idle auto-follow use
  `revealActiveBlockedPane` to select split, reveal scratch, or target primary. Idle and active preserve
  current pane choice. Control `session.go next-attention|prev-attention` changes only selection; pane
  reveal remains a GUI/auto-follow concern.

## Titlebar attention

- With `attentionButtonEnabled` off by default, `customTitlebar` places a bell after recent sessions and
  before scratch/split/quick-terminal controls. It derives live state from all non-idle
  `AppStore.attentionSessions`: empty is disabled `bell` at about 0.35 opacity; non-blocked is enabled
  `bell` in `chromeText`; any blocked is enabled `bell.fill` in `blockedStatusColor`. There is no count
  or pulse.
- Clicking opens the mouse popover of `SessionPopoverRow`s with `StatusGlyph`, ordered
  blocked, active, completed; selection reveals the tagged blocked pane. Ctrl-Shift-I, Navigate > Go to
  Attention, and Show Attention in the palette retain the searchable keyboard surface.
- The button ID is `attention-button`, with help and value `none`, `attention`, or `blocked`.
  `WindowContentView` mirrors `GhosttyApp.attentionButtonEnabled` into state and refreshes on
  `.agtermAppearanceChanged`, not `model.settings`. This mouse form of controllable attention selection is
  keep-in-sync exempt.
