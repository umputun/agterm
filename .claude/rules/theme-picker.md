---
paths:
  - "agterm/Views/Palette.swift"
  - "agterm/SettingsModel.swift"
  - "agterm/SettingsCatalog.swift"
  - "agterm/AppActions*.swift"
---

## Theme picker

- `.themes` is the live-preview `PaletteMode` beside `.actions` and `.sessions`. It reuses
  `CommandPalette`; `AppActions.paletteThemes()` supplies "default ghostty" (`nil`), catalog themes, and
  the `current` badge. Theme names stay out of the action palette, which contains only keyless
  `BuiltinAction.selectTheme` ("Select Theme..."); the View menu exposes the same launcher.
  `openThemePalette()` dispatches `palette.open(.themes)` asynchronously so the action palette can close
  before a fresh theme view opens with an empty query.
- Theme-only `PaletteItem.onSelect` and mode-cancel hooks implement preview. `previewTheme` changes the
  active slot immediately and debounces `apply()` by about 0.07 seconds without saving. Enter/click
  flushes the pending apply, restores a mid-preview off-screen slot from
  `nonActiveOriginal`, reapplies only when that restoration changes the dual line, then saves. Any other
  dismissal cancels the debounce and synchronously restores both slots captured at open.
- `AppActions` owns `themePreviewActive` and the captured `(theme, darkTheme)` pair;
  `SettingsModel` is stateless. `syncThemeSession()` begins/selects on enter and cancels on leave through
  `.onAppear`, mode changes, and `.onDisappear`. The full pair is required when macOS changes appearance
  mid-preview. The picker opens on `currentThemeID`, not "default ghostty".
- Query changes reset `selection` to 0 and call `previewSelected()` explicitly. Filtering can replace
  index 0 without changing its numeric selection, so selection observation alone misses typing previews.
  Non-theme items have no `onSelect`.
- **`focusActiveSession` must return while any palette mode is open.** Closing the action palette starts
  a roughly 12 x 0.03-second terminal-focus retry; without the guard it outraces the new search field and
  also steals focus during preview reloads.
- `AppSettings.defaultTheme` is bundled `"agterm"`, seeded only by `SettingsStore.load()` for
  missing/corrupt settings. Keep the memberwise `AppSettings()` default at `theme == nil`, which means no
  config line and Ghostty's built-in theme. Existing files with no theme remain nil; `theme.set` without
  a name also chooses nil.
- Appearance following uses `theme` as the single/light slot, `darkTheme` as the dark slot, and
  `followSystemAppearance` (`nil`/false by default). `ghosttyConfigLines()` has no `isDark`; it emits
  either one raw `theme = light:NAME,dark:NAME` conditional or the single theme.
- `SystemAppearanceObserver` watches app-level `NSApplication.effectiveAppearance` via KVO and posts the
  settled `isDark`. When following with both slots set and the side differs from the last feed,
  `SettingsModel.appearanceChanged` calls `reloadConfigPreservingSessionZoom`, which sets app and surface
  color schemes and directly re-feeds `update_config`. Direct feeding is required because the raw config
  text does not change. It reapplies per-session `font-size`; only explicit reloads clear zoom. Never move
  this to a view observer, which can wedge after sleep/wake. `AppearanceFlipUITests` uses
  `debug.appearance`.
- `activeTheme(isDark:)` selects the palette badge/row only. `ThemeName.resolved(from:isDark:)`, from #146, is the
  sole dual parser, used by `GhosttyApp.resolveSelectionColors` for sidebar colors from the raw theme
  line. Do not restore `ThemeResolution`, `AppSettings.dualThemeSides`, or legacy dual-string migration.
- Settings `settings-theme` edits the current slot. `settings-follow-appearance` starts off; enabling
  seeds the other slot, disabling collapses to the visible theme without a flip.
  `settings-theme-dark` appears only while following and edits the other appearance. The primary picker
  offers nil only when not following because dual conditionals need two named themes.
- Palette preview writes the visible slot; commit persists it and restores the captured off-screen slot.
  The effective row opens selected, so its initial preview is a no-op. A config-changing preview also
  clears per-session font zoom, and cancel does not restore zoom; this matches Settings because
  libghostty has no cheap colors-only reload.
- Control parity applies to commits through `theme.set`/`theme.list`, not interactive previews. Use the
  Control API four-point audit.
