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

- Settings persist in agtermCore: `AppSettings` (Codable value type, optional fields,
  NO version field — optionality is the forward-compat) + `SettingsStore` (JSON at `<stateDir>/settings.json`,
  `AGTERM_STATE_DIR`-isolated, mirrors `PersistenceStore`).
  Fields: `fontFamily`/`fontSize`/`theme` + `backgroundOpacity` (0...1) / `backgroundBlur` (CGS radius)
  + `notificationsEnabled` / `compactToolbar` / `notificationBadgeEnabled` / `attentionButtonEnabled`
  + the agent-status glyph colors `activeStatusColorHex`/`blockedStatusColorHex`/`completedStatusColorHex`
  (nil defaults: `notificationsEnabled`/`notificationBadgeEnabled` = on,
  `compactToolbar` = compact [the app default — `?? true`; an explicit `false` is the tall non-compact
  bar], `attentionButtonEnabled` = off, the `*ColorHex` = default tint, active `#DBD9E6` + blocked/completed
  system orange/green; NOT ghostty keys) + `mouseScrollMultiplier` (ghostty `mouse-scroll-multiplier`)
  + `inactivePaneMuteStrength` (0...10 inactive-split-pane text mute, nil = default 5,
  NOT a ghostty key) + `sidebarBackgroundShift` (0...10 sidebar lighter/darker tint relative to the terminal,
  nil = default 5 = neutral, NOT a ghostty key).
  The three `*StatusColorHex` (`#RRGGBB`, nil = active `#DBD9E6` muted lavender-grey + system amber/green)
  color the sidebar agent-status glyph: `SettingsModel` passes the hex to `GhosttyApp.setAgentStatusColors`
  which resolves to `NSColor` (so `SettingsModel` stays AppKit-free, the `NSColor`↔hex helper is `NSColor+AgtermHex`),
  `StatusIconView` reads it when drawing, and a change rides `.agtermAppearanceChanged` → the Coordinator's
  `reapplyStatusGlyphs()` sweep (the colors are global, not per-row, so `reconcile`'s diff can't see
  them).
  Settings → Agent Status drives them with a Reset-to-defaults button (clears all three
  to nil), plus a **Blocked sound** picker bound to `AppSettings.blockedStatusSoundName` (nil/"None"
  = no sound, the default; else a system sound name).
  `SettingsModel.setBlockedStatusSoundName` only SAVES (not a ghostty key,
  nothing renders it continuously); `ControlServer.setSessionStatus` reads `settingsModel.settings.blockedStatusSoundName`
  on demand and plays it via `StatusSoundPlayer.shared` ONLY when a session TRANSITIONS into `blocked`
  (a `wasBlocked` read of the session's current status BEFORE the mutation gates it,
  so a repeated `blocked` set does NOT replay the default) and no per-call `--sound` was given — the
  precedence is the host-free `AgentStatus.effectiveSound(perCall:blockedDefault:)` (explicit per-call
  wins; an empty per-call value counts as unset; the default is blocked-only and the transition gate
  lives in the server).
  The picker previews the sound on selection (plays it via `StatusSoundPlayer.shared`).
  GUI-only and keep-in-sync EXEMPT, same as the status colors (only `theme.set`/`config.reload` touch
  settings over the socket); the per-status sound already has full control coverage via `session.status --sound`.
  `notificationBadgeEnabled` (nil = on) gates the sidebar's red unseen-count pill (session rows + workspace
  roll-up), render-only — `unseenCount` keeps tracking so re-enabling instantly shows current counts;
  distinct from `notificationsEnabled` (which gates the OS banner) and does NOT gate the always-on agent-status
  glyph.
  `AppSettings.ghosttyConfigLines()` (host-free, unit-tested) emits `key = value` lines RAW — no quotes,
  because ghostty takes the whole line remainder as the value (confirmed against the bundled conf + theme
  files), so names with spaces (`3024 Night`) must not be quoted.
  `mouseScrollMultiplier` is the ONE field always emitted: nil emits the default `mouse-scroll-multiplier = 3`
  (a bare value applied to both the notched wheel and the trackpad) rather than being omitted,
  so the default speed is effective rather than ghostty's per-device defaults (discrete 3 / precision
  1) — a consequence is it overrides any `mouse-scroll-multiplier` in the user's own `~/.config/ghostty/config`.
  The General → Scrolling stepper (1...10, default 3) maps 3 back to nil so `settings.json` stays minimal;
  the emitted value is 3 either way.
  The Appearance → Panes slider (0...10, default 5) maps 5 back to nil the same way;
  it drives `GhosttyApp.inactivePaneMuteStrength` (mirrored into `WindowContentView` view state on `.agtermAppearanceChanged`,
  like `compactToolbar`/`notificationBadgeEnabled`), and `ContentView.paneDim` washes the inactive split
  pane with `terminalColor` at `AppSettings.muteOpacity(strength:)` (host-free,
  unit-tested: 0→0 renders nothing, 5→0.4 = the historical default, 10→0.8) so the inactive pane's TEXT
  mutes toward the background (`bg→bg` unchanged, `text→bg` dimmer) while the background stays put —
  the way other terminals dim an inactive pane.
  NOT a ghostty key, so `writeGhosttyConfig` no-ops and no surface reload fires (only the `.agtermAppearanceChanged`
  re-render).
  Caveat: in translucent-window mode the surface background is transparent,
  so the wash tints the inactive pane's see-through area slightly toward the theme color (the old `Color.black`
  dim darkened it instead — not a regression).
  The Appearance → Window → Sidebar Tint slider (0...10, default 5 = neutral) maps 5 back to nil the
  same way; it drives `GhosttyApp.sidebarBackgroundShift` (mirrored into `WindowContentView.sidebarShift`
  on `.agtermAppearanceChanged`, like `inactivePaneMuteStrength`), and `ContentView.sidebarTintWash`
  washes the sidebar column with black (darker, >5) or white (lighter, <5) at `abs(AppSettings.sidebarShiftAmount(strength:))`
  (host-free, unit-tested: signed, ±0.30 at the ends, 5→0) — a `.background` BEHIND the transparent outline
  + bottom bar, so the whole column (NOT the title strip, deliberately left uniform with the terminal)
  reads as one surface a touch lighter/darker WITHOUT tinting row text.
  Compositing the wash over the window background equals blending the terminal color toward black/white
  and works identically over an opaque OR a translucent+blurred backdrop,
  so it composes with opacity/blur instead of fighting it; `WindowAppearance.syncSidebarBackground` keeps
  the sidebar see-through (no AppKit fill — the wash is the single tint layer).
  NOT a ghostty key (only the `.agtermAppearanceChanged` re-render).
  Translucency is composited at the AppKit window level, NOT by the renderer:
  when `backgroundOpacity < 1`, `ghosttyConfigLines()` pins `background-opacity = 0` + `background-blur = 0`
  so ghostty draws fully transparent and the window's tinted background is the single translucent layer
  (no double-tint); at full opacity those lines are omitted and the renderer paints its own background
  as before.
- The app target's `SettingsModel` (`@Observable`) loads `AppSettings`, and on every change:
  saves (the opacity/blur sliders are the exception — see the end of this bullet),
  writes `ghostty-settings.conf` (loaded LAST in `GhosttyApp.loadConfig`,
  so the UI wins over the user's `~/.config/ghostty/config` for the keys it manages).
  It calls `GhosttyApp.reloadConfig` (rebuild + `ghostty_app_update_config` + `ghostty_surface_update_config`
  on every live surface) + `AppStore.resetSessionFontSizes()` ONLY when the generated config TEXT actually
  changed — a window-opacity drag within the translucent range, or a blur change,
  leaves the config identical, so it skips the surface rebuild (and the zoom reset) and just re-syncs
  the window.
  The shared config resets every surface to the default size, so when it does reload,
  per-session cmd-+/- overrides are cleared to match (user-approved simplification — no per-surface config
  / zoom preservation).
  Opacity/blur are NOT ghostty-resolved, so `SettingsModel` mirrors them into `GhosttyApp.windowOpacity`/`windowBlurRadius`
  (the shared channel the window chrome reads) at launch and on every change.
  The opacity/blur Settings sliders are the one exception to save-on-every-change:
  their bindings call `previewBackgroundOpacity`/`previewBackgroundBlur` (apply WITHOUT save) on every
  drag tick and DEBOUNCE the `settings.json` write (~0.3 s), so a drag coalesces to a single write on
  settle — which also persists keyboard arrow adjustments that never fire the slider's `onEditingChanged`;
  a mouse release flushes it immediately via `commitBackgroundSettings()`.
- `GhosttyApp.reloadConfig` keeps the new config as `self.config` and does NOT free the previous one:
  `update_config` has no documented ownership contract and the existing code never frees on success,
  so this matches that (crash-safe over a negligible leak on a rare settings change).
- The terminal color isn't observable, so a settings change posts `.agtermAppearanceChanged`:
  `ContentView` mirrors the color into `terminalColor` view state (the quick terminal's opaque backing
  re-renders with the new color) and `TitleProbeView` re-applies the window appearance.
  Without this the chrome only refreshed when the window next re-keyed.
  UI is the standard SwiftUI `Settings` scene (Cmd+,) with a 5-tab `TabView` (frame 480×600).
  An explicit `TabView(selection:)` binding (`@State` default `.general`) suppresses SwiftUI's
  `com_apple_SwiftUI_Settings_selectedTabIndex` auto-persistence, so the window always opens on General
  instead of restoring the last-used tab.
  **General** (a **Scrolling** section with the scroll-speed slider, a **Sessions** section with the
  restore-running-commands toggle, and a **Ghostty Config** section with the inherit-global-config toggle).
  **Appearance** (a **Terminal** section — font/size/theme via `NSFontManager` monospaced families +
  the bundled `ghostty/themes` dir, `SettingsCatalog` — a **Window** section with the compact-toolbar
  toggle + background opacity/blur sliders + the Sidebar Tint slider, and a **Panes** section with the
  inactive-pane-mute slider).
  **Notifications** (a **Notifications** section with the banner / badge / attention-indicator toggles).
  **Agent Status** (a **Colors** section with the three glyph color pickers, a **Sound** section with
  the blocked-sound picker, and a trailing **Reset** that clears both back to defaults).
  **Key Mapping** (the config directory holding `keymap.conf` + a read-only diagnostics list + a Reload
  button — see the Keymap section).
  Captions under controls are kept to a single terse line and dropped entirely from self-explanatory
  controls (font/theme/opacity/sidebar-tint/colors), so each tab fits without scrolling.
  The notification toggle (`AppSettings.notificationsEnabled`, nil = on) is mirrored to `NotificationManager.bannersEnabled`
  by `SettingsModel`; it gates only the OS banner, never the badge, and is NOT a ghostty config key (no
  reload).
  The badge toggle (`AppSettings.notificationBadgeEnabled`, nil = on) is mirrored into the non-observable
  `GhosttyApp.notificationBadgeEnabled` flag by `SettingsModel.applyNotificationBadgeEnabled`;
  because that flag isn't `@Observable`, a flip rides the `.agtermAppearanceChanged` notification the
  same way `compactToolbar` does — the sidebar Coordinator's `appearanceChanged` calls `reconcile()`,
  and the gated `RowContent.unseen` (0 when off via `effectiveUnseen`) reloads the affected badge rows.
  NOT a ghostty config key.
- **Window translucency (`WindowAppearance.sync`).**
  Below full opacity the window goes `isOpaque = false` with `backgroundColor = terminalColor.withAlphaComponent(opacity)`
  (the single tinted layer), applies the blur via the private `CGSSetWindowBackgroundBlurRadius` SPI
  (`dlsym`-resolved once, no-op if absent — adapted from macterm, its `fatalError` softened to a graceful
  return), and hides `NSTitlebarBackgroundView` so the tint runs continuously under the titlebar;
  at full opacity it restores the original opaque/solid path and clears the blur.
  The macOS-26 `NavigationSplitView` sidebar is a Liquid Glass container (`NSContainerConcentricGlassEffectView : NSGlassEffectView`)
  that WRAPS the sidebar content (an ancestor, so it can't be hidden), and is NOT flattenable to the
  window tint; `sidebarGlass(in:)` finds it by walking up from the tagged `agterm-sidebar-scroll` view,
  and when translucent sets its `style = .clear` (the see-through variant) + `tintColor = terminalColor.withAlphaComponent(opacity)`
  so the sidebar reads as the same translucent surface (its blur stays Liquid Glass,
  not the window CGS blur — close, not pixel-identical).
  All of this re-applies on every `sync`, which `TitleProbeView` already drives on window key/main/fullscreen
  transitions + `.agtermAppearanceChanged`.
- **`configDirectory` + the keymap (see the Keymap section).**
  `AppSettings.configDirectory: String?` (nil = the default) holds the directory that contains `keymap.conf`.
  `SettingsModel` resolves it through the host-free `ConfigPaths.configDirectory(setting:stateDir:home:)`
  (explicit setting → `<AGTERM_STATE_DIR>/config` for test isolation → `~/.config/agterm`) and `ConfigPaths.keymapPath(...)`
  (`<dir>/keymap.conf`), loads + `parseKeymap`s it at init into the `@Observable` `keymap`/`keymapDiagnostics`,
  and on first launch writes a fully-commented starter `keymap.conf` (`ensureStarterKeymap` — never overwrites
  an existing file; documents every `BuiltinAction` raw name + default chord and the `{AGT_X}` token
  list, so a fresh file rebinds nothing).
  `setConfigDirectory(_:)` persists + reloads; the Key Mapping tab's directory picker drives it.
  Unlike the other settings, a keymap change is NOT a ghostty config rewrite (no `persistAndApply`/surface
  reload) — it posts `.agtermKeymapChanged` (co-located in `GhosttyApp.swift`'s `Notification.Name` extension)
  and the `@Observable keymap` drives the rest.
- **`<configDir>/ghostty.conf` (agterm-scoped ghostty config, co-located with `keymap.conf`).** A config
  layer between the (opt-in) global ghostty config and agterm's UI settings,
  and the agterm customization point: `GhosttyApp.loadConfig` loads `ghostty-defaults.conf` → `~/.config/ghostty/config`
  (ONLY when `inheritGlobalGhosttyConfig` is on — OFF by default; see that field) → `<configDir>/ghostty.conf`
  → `ghostty-settings.conf` (UI), each overriding the last, so `ghostty.conf` overrides the bundled defaults
  (and the global config when inherited) for ANY key, but agterm's UI-managed keys (font/theme/opacity/blur/scroll)
  still WIN because the settings conf loads LAST.
  The scoped `ghostty.conf` is ALWAYS loaded; skipped only when absent (the starter is comment-only,
  so a fresh install is a no-op).
  Scoped to agterm only — the standalone Ghostty.app never reads it.
  `GhosttyApp.resolveConfigInputs()` (a FUNCTION, not a computed property,
  since it reads `settings.json` via `SettingsStore().load()`) returns `ConfigInputs{scopedURL, inheritGlobalConfig}`
  — resolving the scoped path SELF-CONTAINED (`configDirectory` + `ConfigPaths.configDirectory(setting:stateDir:home:)`
  + the `ConfigPaths.ghosttyConfigPath` helper) AND the inherit flag in ONE settings load,
  because `loadConfig` runs before any `SettingsModel` exists (its first `GhosttyApp.shared` touch is
  inside `SettingsModel.init`).
  It is resolved ONCE per config build and THREADED to `loadConfig(_:)` and `resolveSelectionColors(ghosttyConfigPath:inheritGlobalConfig:)`
  (whose `sources` array gets the global path ONLY when inherited, then the scoped path,
  then the settings conf), so a single reload reads `settings.json` at most once.
  `SettingsModel.ensureStarterGhosttyConfig` (mirrors `ensureStarterKeymap`) seeds a comment-only starter
  on first launch (header link to `https://ghostty.org/docs/config`, a commented `# macos-option-as-alt = true`,
  a note that the UI keys win) — never overwrites an existing file, seeded at `SettingsModel.init` AFTER
  `loadConfig` already ran (harmless, all comments).
  **Edit/Reload mirror the keymap surfaces** (the keymap's `editorCommand(forKeymapPath:)` was generalized
  to `editorCommand(forPath:)`, `$0` label `agterm-config-edit`, shared by both).
  `AppActions.editGhosttyConfig` (File ▸ Edit ghostty.conf… + the ⌃⇧P palette,
  GUI-only, keep-in-sync EXEMPT like Edit Keymap) opens `ghostty.conf` in `$EDITOR` via a 95% overlay;
  the target + the file's opening contents ride `ghosttyEditOverlaySession`/`ghosttyEditOverlaySnapshot`
  and `WindowContentView`'s overlay-close `onChange` calls `reloadGhosttyConfigIfEdited` on close (reloads
  only when the file CHANGED since the editor opened, so a no-op editor session keeps per-session font
  zoom) then clears it.
  `AppActions.reloadGhosttyConfig` (`@discardableResult -> Int`, returning the diagnostic count;
  File ▸ Reload Config + the palette + the overlay close + the `config.reload` control command) → `SettingsModel.reloadGhosttyConfig`
  → `GhosttyApp.reloadConfig(surfaces:)` (`@discardableResult -> Int`, returning + caching `lastConfigDiagnosticsCount`)
  + `resetSessionFontSizesAllWindows()` + `.agtermAppearanceChanged`; a non-zero count posts `NotificationManager.notifyConfigDiagnostics(count:)`
  from `SettingsModel.reloadGhosttyConfig` (mirroring `reloadKeymap`, so EVERY caller surfaces it — incl.
  a Key Mapping directory change via `setConfigDirectory`, which now reloads BOTH co-located files).
  The count spans ALL config sources (libghostty diagnostics carry NO source-file attribution),
  NOT just `ghostty.conf`, so the banner/godoc/`config.reload` say "ghostty config",
  not "ghostty.conf".
  The EXPLICIT Reload Config / `config.reload` reload is UNCONDITIONAL (`ghostty.conf` is edited externally,
  so there is always something to re-read) and clears per-session ⌘+/⌘− zoom like any config reload;
  only the editor round-trip is guarded by the unchanged-file check.
  The whole-config diagnostics banner ALSO fires at launch (`agtermApp` posts `notifyConfigDiagnostics`
  when `GhosttyApp.shared.lastConfigDiagnosticsCount > 0` after the first config build).
  See the Control API catalog for the `config.reload` four-point audit.
- **`restoreRunningCommand` (re-run the foreground command on restart, opt-in,
  General tab).** `AppSettings.restoreRunningCommand: Bool?` (nil = off) gates capturing each pane's
  foreground command at clean quit and re-running it on the next launch.
  NOT a ghostty key (`writeGhosttyConfig` no-ops, no surface reload).
  CAPTURE: `AppDelegate.applicationWillTerminate` — only when the flag is on — walks every open store's
  session surfaces and sets `Session.foregroundCommand`/`splitForegroundCommand` (persisted on `SessionSnapshot`)
  BEFORE `saveAllOpen()`, via `ForegroundProcess.command(for:shellBasename:)` (`ghostty_surface_foreground_pid`
  → `sysctl(KERN_PROCARGS2)` → host-free `CommandRestore.parseProcArgs`;
  returns nil only for an IDLE shell-at-prompt via `CommandRestore.isIdleShell` — a known shell with
  NO payload argument after argv0, only option flags.
  A shell RUNNING a script is NOT idle and IS captured: a `#!/bin/sh` wrapper like the `cld` claude-code
  launcher has foreground argv `['/bin/sh', '/usr/local/bin/cld', …]`, which earlier was wrongly skipped
  because `basename('/bin/sh')` is `sh` — `isIdleShell` keeps it because of the script-path argument).
  The walk uses `WindowLibrary.allOpenSessions()` and captures the SPLIT command ONLY when `session.isSplit`
  (a hidden split isn't recreated at restore, so capturing it would leave a stale command to fire on
  the next manual ⌘D — `clearSavedCommands` shares the same `allOpenSessions` walk).
  A login shell's argv0 is dash-decorated (`/usr/bin/login … exec -l /bin/zsh` → argv0 `-/bin/zsh`,
  whose basename splits on `/` to `zsh`; `isKnownShell` ALSO strips a leading `-` so a bare `-zsh` form
  is recognized too), so an idle pane captures nil and stays a plain shell — verified via `tree --json`.
  A force-quit/crash skips `applicationWillTerminate`, so it loses commands (sessions + cwd still restore
  from the debounced snapshot) — best-effort by design.
  RESTORE: the surface factories (`makeSurface`/`makeSplitSurface`) read the persisted command,
  gate on `GhosttyApp.shared.restoreRunningCommand` (mirrored by `SettingsModel.applyRestoreRunningCommand`,
  like `notificationBadgeEnabled`) + the host-free `CommandRestore.shouldRestore(argv:denylist:)` check
  against the user-editable `restore-denylist.conf` (NO built-in list — `SettingsModel.loadRestoreDenylist`
  parses `<configDir>/restore-denylist.conf` at launch via `CommandRestore.parseDenylist` and mirrors
  it into `GhosttyApp.shared.restoreDenylist`, seeded with the terminal multiplexers `tmux`/`screen`/`zellij`
  by `ensureStarterRestoreDenylist`; everything not listed — `python manage.py runserver`,
  `node server.js`, a REPL — restores), and feed it to the login shell via `config.initial_input` = `CommandRestore.shellQuotedLine(argv) + "\n"`
  (NOT `config.command`, which would replace the shell + close on exit; `initial_input` re-runs inside
  the shell so exit returns to a prompt).
  The captured field is consumed run-once in the factory (read-then-nil,
  like `scratchCommand`) so a later structural save can't re-fire it.
  The SAME toggle ALSO gates the OTHER restore path: a `session.new --command` session persists its command
  (`SessionSnapshot.initialCommand`) and re-runs it on restore via `config.command` (the shell-replacing,
  close-on-exit path — the opposite of the foreground path's `initial_input`), because a command that
  exec-replaces the shell is invisible to the foreground-pid capture.
  That path is gated by the transient `Session.wasRestored` (a fresh command session always runs; a restored
  one honors the toggle), and a live captured foreground preempts the persisted `initialCommand`.
  Unlike `foregroundCommand`, `initialCommand` is NOT consumed — it is the durable creation identity,
  re-emitted by every `snapshot()`, so the opt-out is per-restart (re-enabling the toggle brings the command
  session back); it is dropped only when the command pane exits into a promoted split (`closePrimaryPane`).
  All decision logic (parse/shell-detect/denylist/quote) is host-free in `CommandRestore` (unit-tested);
  the app target owns only the C-boundary + Darwin syscall.
  ONLY a single-process command restores faithfully — a typed pipeline/compound line captures one process.
  The SETTINGS TOGGLE is GUI-only (no `settings.*` control surface; only `theme.set`/`config.reload`
  touch settings), but the feature DOES have a control surface: `restore.clear` clears the saved commands
  and live `foreground`/`splitForeground` ride `tree`/`ControlSessionNode` (see the Control API catalog's
  `restore.clear` four-point audit) — the agent-skill was updated accordingly.
- **`inheritGlobalGhosttyConfig` (load the user's global `~/.config/ghostty/config`,
  opt-in, General tab).** `AppSettings.inheritGlobalGhosttyConfig: Bool?` (nil = OFF) gates whether `loadConfig`
  reads the user's GLOBAL ghostty config (see the `<configDir>/ghostty.conf` bullet for the layering).
  OFF by default so agterm is self-contained: a config written for the standalone Ghostty.app does NOT
  silently change agterm, which also keeps bug reports legible (the colors a user sees are agterm's own
  unless they opt in).
  The agterm-scoped `<configDir>/ghostty.conf` is ALWAYS loaded regardless and is the documented customization
  point.
  Resolved at config-LOAD time (via `resolveConfigInputs`), NOT a live `GhosttyApp` mirror and NOT a
  `ghosttyConfigLines()` key — so `setInheritGlobalGhosttyConfig` saves `settings.json` then calls `reloadGhosttyConfig()`
  UNCONDITIONALLY (like `setConfigDirectory`), because it changes WHICH files load and `persistAndApply`'s
  text-diff guard would otherwise skip the reload.
  The SETTINGS TOGGLE is GUI-only and keep-in-sync EXEMPT (like `restoreRunningCommand`'s toggle — only
  `theme.set`/`config.reload` touch settings over the socket).
  Default-off + round-trip covered host-free in `AppSettingsTests`; the file-gating itself is app-target
  (manually/build verified, no app unit-test host).
- **`attentionButtonEnabled` (titlebar attention bell, opt-in, Notifications tab).**
  `AppSettings.attentionButtonEnabled: Bool?` (nil = OFF, the default-off precedent like `restoreRunningCommand`/`inheritGlobalGhosttyConfig`,
  NOT `notificationBadgeEnabled`'s default-ON) gates the title-bar bell icon that reflects the window's
  `AppStore.attentionSessions` at a glance (empty → dimmed/disabled, non-empty → enabled,
  any blocked → filled-amber).
  NOT a ghostty key (`writeGhosttyConfig` no-ops, no surface reload).
  It is the non-observable chrome-mirror pattern: `SettingsModel.setAttentionButtonEnabled` saves + `applyAttentionButtonEnabled`
  pushes `settings.attentionButtonEnabled ?? false` into the `GhosttyApp.attentionButtonEnabled` flag
  (alongside `applyCompactToolbar`/`applyNotificationBadgeEnabled`), so a flip rides `.agtermAppearanceChanged`
  and `WindowContentView` re-reads the mirror to re-render the titlebar live — exactly like `compactToolbar`/`notificationBadgeEnabled`.
  The Notifications tab's Notifications-section `Toggle("Show attention indicator")` uses the default-OFF binding (get
  `?? false`, set `$0 ? true : nil`, mirroring `restoreRunningCommand`/`inheritGlobalGhosttyConfig`,
  NOT `notificationBadgeEnabled`).
  GUI-only and keep-in-sync EXEMPT (the bell just opens the already-controllable attention palette /
  `session.select`; only `theme.set`/`config.reload` touch settings over the socket).
  See the Notifications section for the bell's three states and the Menu/actions section for the `.attention`
  palette it opens.
- **A Settings toggle's DESCRIPTION stays single-line short-form** — a terse hint, not a manual.
  No detailed multi-line explanation of what the toggle does and no cross-refs to other toggles;
  keep the minimal style (see also the flag-description convention).

