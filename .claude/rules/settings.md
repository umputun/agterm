---
paths:
  - "agterm/SettingsModel.swift"
  - "agterm/Views/SettingsView.swift"
  - "agterm/SettingsCatalog.swift"
  - "agterm/Views/WindowAppearance.swift"
  - "agterm/NSColor+AgtermHex.swift"
  - "agtermCore/Sources/agtermCore/AppSettings.swift"
  - "agtermCore/Sources/agtermCore/QuickTerminalMetrics.swift"
  - "agtermCore/Sources/agtermCore/SettingsStore.swift"
  - "agtermUITests/SettingsUITests.swift"
---

## Settings

- `AppSettings` is a versionless Codable value in `agtermCore`; optional fields provide forward
  compatibility. `SettingsStore` writes `<stateDir>/settings.json` and follows `AGTERM_STATE_DIR`.
  Store enum-like settings as raw strings and resolve unknown values to defaults rather than failing the
  file.
- Theme slots and following are owned by the theme-picker rule. `ToolbarMode` is
  `normal|compact|hidden`, stored raw; nil defaults compact. Normal adds cwd, hidden removes titlebar and
  traffic lights but leaves an invisible roughly 3-point drag strip above the first row at padding 6.
  Hidden also drops the title/terminal hairline both columns draw: `titlebarHeight` is 0 there, so the line
  would sit on the window's top edge separating nothing and read as a rendering artifact.
  `effectiveToolbarMode` falls back through legacy `compactToolbar` (`false` = normal, nil/true = compact);
  writing a mode clears the legacy field.
- Default-on nil fields are `notificationsEnabled`, `notificationBadgeEnabled`, `rightClickPaste`, and
  `workspaceRowClickExpands`, whose mirror gates the sidebar row-click toggle only ([[sidebar]]).
  Default-off nil fields include attention button, Dock bounce, global config inheritance, close
  confirmation, auto-follow, hidden inactive sidebars, and interface hiding. `restoreMode` defaults to
  `none`; the legacy `restoreRunningCommand` boolean migrates to `rerun` or `none`.
- `sidebarFontSize` and `interfaceFontSize` are separate settings, both 9...20 default 13, read through
  `effectiveSidebarFontSize`/`effectiveInterfaceFontSize`. Neither falls back to the other: the sidebar
  is a density knob, the palette a readability one.
  `sidebarFontSize` drives sidebar rows and their height (clamped size + 15, so 13 gives 28).
  `interfaceFontSize` drives the palette/picker, the session switcher, and the title-bar popover rows
  that share `SessionSwitcherRow`; `InterfaceMetrics` derives the secondary (subtitle/badge) and
  shortcut sizes plus the panel scale from it, anchored so 13 reproduces the previously hardcoded
  `.caption`/`.callout` and the 520x320 palette, with derived text floored at 8pt. Panel widths and
  heights are then fitted to the window (`fittedPanelWidth`, `panelOffset`, `fittedPanelHeight`): the
  scaled width and the centering offset each grow unbounded and compound, and a panel wider than the
  window less the inset clips at the right edge. Never hand a height cap to `.frame(maxHeight:)` around
  a panel: a `ScrollView` renders at the height it is offered, and a stack centers inside it and drops
  down the window. Measure the content and set an exact height (`measuredPanelHeight`), or pass
  `alignment: .top`. Neither is testable at the view layer — hosted tests do not render SwiftUI and
  XCUITest cannot hold Ctrl for the switcher — so verify these by eye.
  Status glyphs stay fixed for both settings; the palette's search icon scales with the field it sits in.
  Unfocused-terminal mute and sidebar tint are 0...10 with neutral/default 5.
  `muteOpacity` maps 0/5/10 to 0/0.4/0.8. `sidebarShiftAmount` maps the endpoints to signed +/-0.30;
  below 5 uses white, above 5 black, behind the transparent sidebar only, never the title strip/text.
- `ghosttyConfigLines()` emits raw `key = value` with no quoting, including spaced names such as
  `3024 Night`. It always owns and emits `mouse-scroll-multiplier` (nil = 3 for wheel and trackpad) and
  `right-click-action` (nil/on = paste, off = ignore), overriding earlier config layers. Their Settings
  controls map defaults back to nil; right-click changes reload surfaces.
  The settings conf loads last among the top-level config sources, but `ghostty_config_load_recursive_files`
  expands `config-file` includes AFTER it, so an included value for a SCALAR key replaces what Settings
  wrote — `cursor-style`, `font-size`, `right-click-action` and the rest.
  `font-family` is ghostty's `RepeatableString` and ACCUMULATES instead, so the merge rule is per key and
  not a single precedence order.
  Never tell a user a picked value beats their `ghostty.conf`; it beats a scalar key written directly in it.
- Non-Ghostty settings update app mirrors and `.agtermAppearanceChanged`, not surfaces. The mute wash
  fades text toward terminal color; with transparency it also tints the see-through area. Sidebar tint
  composes over opaque or blurred backgrounds; AppKit must leave the sidebar unfilled.
- `quickTerminalSizePercent` is the quick-terminal panel's share of its screen, nil for the built-in size.
  `QuickTerminalMetrics` owns the arithmetic, the offered choices and the clamp; [[windows]] owns why a set
  percentage replaces the points cap instead of raising it. Mirrored to `GhosttyApp` like `toolbarMode`,
  and read when the panel is framed, so no appearance broadcast is involved.
- `inactivePaneMuteStrength` drives the inactive split pane and the backdrop behind a floating overlay and
  the quick terminal, so its label names both. [[libghostty]] owns how those washes render.
- Status colors default to active `#DBD9E6`, system amber, and system green. Shapes are raw
  `StatusShape` strings resolved only by `effectiveStatusShape(for:)`; nil and circle render identically.
  `SettingsModel` pushes both into `GhosttyApp`, then `.agtermAppearanceChanged` makes
  `reapplyStatusGlyphs()` update both sidebar and attention list. Per-call `session.status` color/shape
  overrides win.
- Blocked sound is nil/"None" by default and previews through `StatusSoundPlayer`. On a transition into
  blocked, the server plays it only when no non-empty per-call `--sound` exists; repeated blocked does
  not replay. `AgentStatus.effectiveSound` owns precedence. Reset clears colors, shapes, and sound, not
  auto-follow.
- Auto-follow choices are Disabled, 5s, 10s, 30s, 60s, and 5m, plus the guard against leaving a running
  session.
- Notification badges gate only the sidebar pill/workspace roll-up and Dock total; counts keep tracking
  while hidden. Banners are a separate `notificationsEnabled` mirror, and neither gates agent status.
- `SettingsModel` saves and writes last-loaded `ghostty-settings.conf`. Reload app/surfaces and clear
  per-session font zoom only when generated text changes. Opacity/blur are mirrored directly to window
  chrome. Slider ticks preview without save and debounce persistence about 0.3 seconds; mouse release
  flushes, and debouncing still catches keyboard changes.
- Keep each successful replacement config in `GhosttyApp.config`; `update_config` has no ownership
  contract, so freeing it risks a crash and the rare leak is accepted.
- `.agtermAppearanceChanged` is required because terminal color is not observable; it updates
  `terminalColor`, quick-terminal backing, title/window appearance, and non-observable chrome mirrors.
- Settings is a 540x640 six-tab SwiftUI scene with explicit selection defaulting General, preventing
  `com_apple_SwiftUI_Settings_selectedTabIndex` persistence. General holds Mouse, Sessions, and Ghostty
  Config. Appearance holds Terminal and Window. Interface groups `InterfaceElement`s two per row, plus
  Multiple Windows and the quick terminal's panel size, which sits there rather than under Appearance's
  Window because the panel belongs to no window.
  Notifications holds banner/badge/attention/bounce/sound. Agent Status holds colors/shapes, sound,
  auto-follow, and Reset. Key Mapping holds config directory, diagnostics, and Reload.
- Keep titlebar construction in `WindowContentView+Titlebar.swift` so `WindowContentView.swift` remains
  below the 1000-line limit.
- Keep Agent Status shape pickers in a trailing-aligned 80-point column wider than the 64.5...68-point
  buttons; centered alignment leaves the cluster about 38 points inboard. Keep color wells aligned.
  `testAgentStatusShapePickerRowLayoutAndOptions` checks picker `maxX`
  against Sound and well alignment before/after the widest shape. Offer exactly `StatusShape.allCases`;
  circle maps to nil. Use fresh non-template palette-colored `NSImage`s at
  `StatusIconView.glyphPointSize`; template/SwiftUI tint does not survive into the popup. Do not cache
  per-drag tint images. Derive both bindings from the row's `AgentStatus`. Keep display names as option
  AX labels and picker AX values.
- Keep captions only for facts labels cannot carry: the blur/Reduce Transparency hint and Ghostty config
  path. The blur hint states that opacity must be below 100%. Settings descriptions are one short line,
  never a mini-manual.
- **Window translucency is one AppKit layer.** Below opacity 1, make the window non-opaque, set terminal
  color with alpha, hide `NSTitlebarBackgroundView`, and call dynamically resolved
  `CGSSetWindowBackgroundBlurRadius`; absence is a no-op. `ghosttyConfigLines()` pins renderer opacity and
  blur to 0. At opacity 1, restore opaque rendering. Reduce Transparency temporarily forces opaque,
  unblurred windows/panels without changing saved settings or config.
- On macOS 26, find the wrapping `NSContainerConcentricGlassEffectView` by walking from
  `agterm-sidebar-scroll`; for translucent windows use clear style plus terminal tint. Its Liquid Glass
  blur is not pixel-identical to CGS blur. Reapply on key/main/fullscreen and appearance changes.
  `SystemAccessibilityObserver` bridges workspace accessibility changes to every window; SwiftUI's
  environment independently makes palettes/switcher opaque and changes the hint.
- `configDirectory` resolution is explicit setting, else `<AGTERM_STATE_DIR>/config`, else
  `~/.config/agterm`. It contains keymap, scoped Ghostty config, and restore denylist. Seed starter files
  only when absent. Keymap starter documents every action/default and token but rebinds nothing; reload
  posts `.agtermKeymapChanged`, never a surface config update.
- Ghostty layers are bundled defaults, optional `~/.config/ghostty/config`, always-loaded scoped
  `<configDir>/ghostty.conf`, then UI settings. Each overrides the previous; standalone Ghostty never
  reads the scoped file. `resolveConfigInputs()` must load settings once before `SettingsModel` exists and
  thread the scoped URL/inherit flag to config loading and selection-color resolution.
- Seed scoped `ghostty.conf` as comments only, including docs URL, commented option-as-alt, and UI-wins
  note. Edit Config opens it with the shared editor command in a 95% overlay, records original contents,
  and reloads on close only if changed, preserving zoom after a no-op edit.
- File/palette Reload Config and `config.reload` always re-read external sources, return/cache total
  libghostty diagnostics across all sources, clear all session zoom, post appearance change, and notify
  non-zero diagnostics. A config-directory change reloads both co-located files. Launch also reports
  cached diagnostics.
- **Process restore mode is frozen at launch; capture follows the configured next mode.** `none` restores fresh shells, `rerun` uses the captured-command path
  below, and `live` is zmx-backed. Settings changes apply after restart. A live request falls back to
  `none` when the bundled executable, zsh integration, or password-database login shell is unsupported, and
  Settings reports the reason. The requested-live latch still claims persisted daemons during fallback; only
  a deliberate `none` or `rerun` launch reaps them. Factories, control status, and reap read the immutable
  requested or active mode. Exit capture and `restore.capture` read the configured next-launch mode.
- **Command replay is launch-scoped; capture runs at two exits and on demand.**
  `AppDelegate.captureForegroundCommands` runs at three points: `applicationWillTerminate` before
  `saveAllOpen()`, the LAST window's `willClose` before its surface teardown, which precedes
  `applicationWillTerminate` and is therefore the only point where a close-the-last-window exit's
  commands are still readable, and `restore.capture` on demand, which exists for the exit that reaches
  neither: a force quit, a crash, a hard reset, a power loss. A system shutdown/restart/logout is NOT in
  that set — since #447 it reaches `applicationWillTerminate` like any quit — so do not re-motivate the
  command with an OS update. The on-demand arm changes nothing else: it fills the same
  slots, persists through the same `saveAllOpen`, and replay stays launch-only and one-shot.
  The two automatic exit arms run when the configured mode is `rerun` or `live`. The on-demand arm remains
  rerun-only: it refuses when `none` or `live` is configured and names that mode. Deliberately unlike a
  `session.restore` pin, which saves future rerun policy with an explanatory note, because a pin outlives
  the mode and a capture only goes stale.
  The `willClose` arm alone is guarded by `openIDs() == [windowID]` and skipped under `isTerminating`.
  A NON-last close captures nothing AND clears both persisted slots plus the pending pair: a launch
  restore can't tell that window's file from one open at exit, so its argv could replay via the
  never-windowless reopen fallback, and on demand a capture can now have written argv there mid-run.
  Ordinary and rerun argv comes from `ghostty_surface_foreground_pid`, `sysctl(KERN_PROCARGS2)`, and
  host-free parsing. Live panes use one fresh zmx leader snapshot, then the same sysctl parsing against the
  daemon-side leaders. A live hidden split is captured while its backing surface exists; an ordinary or
  rerun hidden split remains nil. Refresh failure or deadline expiry clears the affected slots rather than
  reading the resolver's retained map.
  Strip login `-` before shell recognition; a known shell with only flags is idle and omitted, while
  scripts/payload args remain, including `/bin/sh <script>`.
  System shutdown, restart, and logout skip quit confirmation so `applicationWillTerminate` can capture
  commands and flush stores. Force quit preserves earlier snapshots/cwd but skips this exit path.
  Replay arms ONLY on a launch restore: `session(from:launchRestore:)` copies
  `foregroundCommand`/`splitForegroundCommand` (like the pending override) under `launchRestore` alone,
  so a mid-run window reopen or Reopen Closed Item comes back a plain shell.
  Consumption is one-shot AND durable, and that rests on WHERE the launch arms it.
  `session(from:launchRestore:)` seeds the TRANSIENT `pendingForegroundCommand`/
  `pendingSplitForegroundCommand`, which `snapshot()` does not serialize, and leaves the persisted fields
  nil; `loadStore` strips the file in the same step.
  So no save landing between arming and the surface spawning can write the argv back — several do land
  there (`applyInactiveWindowSidebarHiding`, the debounced save `reselectIfSelectionHidden` schedules),
  and arming the persisted fields instead would let any of them resurrect it.
  A crash can then cost a restore but never repeat one; a failed strip disarms the pending slots rather
  than leaving a replay nothing recorded.
  Anything else that must cancel an armed replay clears those slots too, never the persisted fields:
  `recoverOrphanedWindows`, `Session.clearPendingRestoreOverrides` on the soft-close round trip, and
  `restore.clear`, which the socket can receive before the later windows' decks have mounted.
  Against STALE files from older builds, `loadStore` also rewrites a snapshot that carried captures on a
  mid-run reopen, and `recoverOrphanedWindows` drops captures while the sticky override still arms
  (a corrupt index must not re-execute a closed window's last command).
- Restore captured argv only in `rerun` or a wrapped `live` pane, and only when basename is absent from user
  `restore-denylist.conf`, seeded with `tmux`, `screen`, and `zellij`. A control character anywhere in the
  argv also refuses, matching what `session.restore set` rejects a pin for: the line is typed, so the line
  editor reads the byte before the shell parser and quoting cannot protect it. U+FFFD refuses with it,
  since `parseProcArgs` decodes lossily and replaying it would run a different argument. Both refuse at
  RENDER, keeping `hadForeground` true so a stale `initialCommand` stays preempted. A pin loaded from a
  snapshot never passed the dispatcher's check, so `restoreInput` applies it again at the sink; both share
  `CommandRestore.hasControlCharacter`. Feed captured argv once through
  shell-quoted `config.initial_input` in rerun mode, then nil it. A wrapped live pane consumes the pending
  argv only after configuration succeeds and passes it as a create-only zmx attach payload. An existing
  daemon ignores the payload; a missing daemon runs it, then starts the final integrated login shell.
  Fallback never consumes. Only one foreground process from a typed pipeline/compound command can be captured.
- `session.new --command` persists durable `initialCommand` and restores through shell-replacing
  `config.command`; fresh creation always runs, restored creation honors `rerun`, and captured
  foreground wins. Do not consume `initialCommand`; remove it only when primary exit promotes a split.
  `restore.capture`, `restore.clear` and tree foreground fields are the control surface; the tree fields
  report the live process, not the captured slot, which [[control-api]] keeps read-back-free by design.
- `newSessionDirectory` is raw `home|currentSession|custom`, with fixed custom path. Unknown/blank/missing
  values fall back home. Resolve once from active session's `focusedCwd` for every GUI creation path,
  including a right-clicked workspace; setters save only. Control `session.new --cwd` remains explicit
  and ignores this setting.
- `cursorStyle` is a raw string that `effectiveCursorStyle` recognizes only as `block|bar|underline`, and
  `cursorBlink` is ghostty's own `?bool`. Unlike the two keys above, neither is emitted unconditionally:
  only a RECOGNIZED style emits `cursor-style`, and `cursorBlink` emits whenever it is non-nil.
  nil, and any unoffered name including ghostty's real `block_hollow`, resolve to nil and emit nothing,
  leaving the config chain to pick the shape — an unknown value is stored yet still silent.
  `block_hollow` is excluded because an unfocused surface is already marked by drawing its cursor hollow.
  nil `cursorBlink` is a third state rather than off: the cursor blinks AND DEC mode 12 can still change it,
  while either explicit value takes DEC mode 12 away. `DECSCUSR` wins over all three.
- `inheritGlobalGhosttyConfig` defaults off. It changes which files load, so its setter saves then reloads
  unconditionally; it is not a config line or live mirror. Scoped config always loads.
- `attentionButtonEnabled` defaults off and mirrors to `GhosttyApp` for live titlebar redraw. Its three
  states belong to notifications.md; it opens an already-controllable attention surface.
- `DockBounce` is raw `off|once|untilFocused`, nil/unknown = off. `off`, not `none`, avoids
  `Optional.none`. Mirror it to `NotificationManager` for the next notification, without appearance
  redraw. The picker maps off to nil; behavior belongs to notifications.md.
- `notificationSoundName` is nil/empty silent. Mirror it to `NotificationManager`; it attaches to
  delivered banners in OSC/control paths and follows notification authorization/Focus. Picker None maps
  nil and previews.
- `confirmCloseSession` defaults off and is read on demand, without a mirror. Prompt only for GUI active
  close and sidebar row close; skip under XCUITest. Control `session.close` must never prompt.
- `hiddenInterfaceElements` stores raw names and preserves unknown values while toggling known ones; empty
  maps nil. Titlebar cases are `sidebarToggle`, `sessionName`, `windowName`, `recentSessions`, `scratch`,
  `split`, `dashboard`, `quickTerminal`; sidebar cases are `newWorkspace`, `newSession`, `flaggedView`,
  `focusFilter`, and row-level `workspaceAddSession`. Attention has its separate default-off setting.
- `InterfaceElement` owns section/display name; the tab iterates `allCases`. Mutate the raw set, then push
  resolved known values to `GhosttyApp`. SwiftUI gates with `shows(_:)`; the AppKit row "+" checks the
  mirror on hover. Titlebar group dividers appear only between adjacent groups that each retain at least
  two buttons, as computed by `titlebarGroupDividers`. Add a case/render gate only after user approval.
- `autoHideSidebarInactiveWindows` defaults off. On every become-key/main, not resign,
  `WindowLibrary.applyInactiveWindowSidebarHiding()` shows the active window and hides other open
  sidebars, even when frontmost id was pre-set. Enabling applies immediately. While on, manual hide is
  transient and refocus shows it; turning off leaves current hidden states. Persisted visibility changes
  already refresh the window-list cache.
- `welcomeShown` records that the first-run Help-extras alert has been shown; the launch that shows it
  writes true before running any installer. `FirstRunWelcome.isDue` also requires no prior-launch state
  (`settings.json`, `workspaces.json`, `windows/`) in the state directory, so an upgrading user whose
  settings predate the flag never sees it. Decide it in `agtermApp.init()`: the first launch saves its own
  window within a second of the scene appearing, which would read back as prior state.
  `WelcomeAlert` suppresses itself under XCUITest unless `AGTERM_UITEST_SHOW_WELCOME` is set.
- These settings are GUI-only unless the control catalog explicitly says otherwise. Do not add settings
  commands merely to mirror chrome; user actions already have control coverage.
