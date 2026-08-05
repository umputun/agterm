---
paths:
  - "agterm/SettingsModel.swift"
  - "agterm/Views/SettingsView.swift"
  - "agterm/SettingsCatalog.swift"
  - "agterm/Views/WindowAppearance.swift"
  - "agterm/NSColor+AgtermHex.swift"
  - "agtermCore/Sources/agtermCore/AppSettings.swift"
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
  `effectiveToolbarMode` falls back through legacy `compactToolbar` (`false` = normal, nil/true = compact);
  writing a mode clears the legacy field.
- Default-on nil fields are `notificationsEnabled`, `notificationBadgeEnabled`, `rightClickPaste`, and
  `workspaceRowClickExpands`, whose mirror gates the sidebar row-click toggle only ([[sidebar]]).
  Default-off nil fields include attention button, Dock bounce, restore commands, global config
  inheritance, close confirmation, auto-follow, hidden inactive sidebars, and interface hiding.
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
- Non-Ghostty settings update app mirrors and `.agtermAppearanceChanged`, not surfaces. The mute wash
  fades text toward terminal color; with transparency it also tints the see-through area. Sidebar tint
  composes over opaque or blurred backgrounds; AppKit must leave the sidebar unfilled.
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
  Config. Appearance holds Terminal and Window. Interface groups `InterfaceElement`s two per row plus
  Multiple Windows. Notifications holds banner/badge/attention/bounce/sound. Agent Status holds
  colors/shapes, sound, auto-follow, and Reset. Key Mapping holds config directory, diagnostics, and Reload.
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
- In native fullscreen AppKit relocates the chrome into an `NSToolbarFullScreenWindow` child window, so the
  window's own view tree holds no `NSTitlebarContainerView` and the whole blend is skipped.
  Hidden toolbar mode falls back to that child, or `NSTitlebarBackgroundView` paints a hairline across the
  top edge of the full-bleed terminal. Other modes keep AppKit's own fullscreen rendering.
  Key the `_NSTitlebarDecorationView` suppression off the mode, never the traffic-light flag, whose
  fullscreen carve-out would un-hide what AppKit hides there itself.
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
- **Restore running commands is opt-in and clean-quit only.** Before `saveAllOpen()`,
  `applicationWillTerminate` captures each visible main/split foreground argv through
  `ghostty_surface_foreground_pid`, `sysctl(KERN_PROCARGS2)`, and host-free parsing. Capture no hidden
  split. A known shell with only flags is idle and omitted; scripts/payload args remain, including
  `/bin/sh <script>`. Strip login `-` before shell recognition. Force quit preserves snapshots/cwd but
  skips command capture.
- Restore only when the toggle is on and basename is absent from user
  `restore-denylist.conf`, seeded with `tmux`, `screen`, and `zellij`. Feed captured argv once through
  shell-quoted `config.initial_input` so exit returns to the shell, then nil it. Only one foreground
  process from a typed pipeline/compound command can be captured.
- `session.new --command` persists durable `initialCommand` and restores through shell-replacing
  `config.command`; fresh creation always runs, restored creation honors the toggle, and captured
  foreground wins. Do not consume `initialCommand`; remove it only when primary exit promotes a split.
  `restore.clear` and tree foreground fields are the control surface.
- `newSessionDirectory` is raw `home|currentSession|custom`, with fixed custom path. Unknown/blank/missing
  values fall back home. Resolve once from active session's `focusedCwd` for every GUI creation path,
  including a right-clicked workspace; setters save only. Control `session.new --cwd` remains explicit
  and ignores this setting.
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
