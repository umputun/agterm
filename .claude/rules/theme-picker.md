---
paths:
  - "agterm/Views/Palette.swift"
  - "agterm/SettingsModel.swift"
  - "agterm/SettingsCatalog.swift"
  - "agterm/AppActions.swift"
---

## Theme picker

- **A live-preview theme picker as a third command-palette mode.**
  The `.themes` `PaletteMode` (alongside `.actions`/`.sessions`, `Palette.swift`) reuses the SAME `CommandPalette`
  fuzzy-search/list/nav view; only theme mode carries the live preview.
  Its rows = `AppActions.paletteThemes()` (a leading "default ghostty" = nil/no-theme + one per `SettingsCatalog.themeNames()`,
  the current one badged `current`).
  The theme NAMES never pollute the action palette — only a single **"Select Theme…"** launcher item
  appears in `paletteActions()` (and the View ▸ Select Theme… menu item + the keyless `BuiltinAction.selectTheme`).
  The launcher opens the picker via `AppActions.openThemePalette()` → `palette.open(.themes)` dispatched
  ASYNC (the launcher runs inside the action palette's `runItem`, which closes that palette right after;
  the async open lets `.themes` re-open a tick later as a FRESH view — empty query,
  not the launcher's search text).
- **Preview/commit/cancel, themes-only.**
  Two optional hooks the View invokes ONLY when `mode == .themes`: `PaletteItem.onSelect` (fired on selection
  change → `AppActions.previewTheme(name)`) and a mode-level cancel.
  `previewTheme` = `SettingsModel.previewTheme` sets `settings.theme = name` immediately but DEBOUNCES
  the live `apply()` (~0.07 s) so a burst of nav/typing previews coalesces to one surface reload — applied
  WITHOUT `settingsStore.save` (`persistAndApply` was split into `save(); apply()` so preview can apply-without-persist).
  Enter/click commits via `commitThemePreview()` → `SettingsModel.commitTheme()`,
  which FLUSHES the pending debounced apply (so the latest theme is live NOW) then `save()`s.
  Any dismiss without a commit — Esc, scrim tap, switch to another palette mode,
  unmount — reverts via `cancelThemePreview()` → `previewThemeImmediate(original)`,
  which CANCELS the pending debounce and re-applies the theme captured on open SYNCHRONOUSLY (no debounce
  lag, no stuck last-preview).
  `AppActions` owns the session state (`themePreviewActive` + `themePreviewOriginal`);
  `SettingsModel` stays stateless about it.
  The View wires it through `syncThemeSession()` (begin + select the current theme's row on enter,
  cancel on leave — called from `.onAppear`/`.onChange(of: mode)`) + `.onDisappear { cancelThemePreview() }`
  + the `onChange(of: selection)` preview call.
  The picker opens with the CURRENT theme's row selected (via `currentThemeID`),
  so it doesn't preview-jump to "default ghostty".
  **Typing also previews:** `onChange(of: query)` resets `selection = 0` then calls `previewSelected()`
  — because a filter re-orders the list so the item AT index 0 changes while `selection` STAYS 0,
  `onChange(of: selection)` doesn't fire, so the new top match would never preview on filtering alone
  (only on arrow-nav).
  `previewSelected()` fires `filtered[selection].onSelect?()` explicitly (a no-op for non-theme palettes,
  whose items carry no `onSelect`).
- **Focus invariant (load-bearing).**
  `AppActions.focusActiveSession` early-returns when `palette?.mode != nil` — NEVER grab terminal first
  responder while a palette is open.
  Without it, the launcher path breaks: closing the action palette fires `ContentView`'s close-restore
  (`onChange(palette.mode == nil) { focusActiveSession() }`), whose ~12×0.03s `makeFirstResponder(terminal)`
  RETRY loop out-races the just-opened picker's field focus, so the picker can't be typed into (the terminal
  behind it eats the keys).
  The guard also kills the retry the instant `.themes` opens AND blocks any focus steal during a live
  preview reload.
- **Default theme = the bundled `agterm` theme (NOT ghostty's built-in).**
  `AppSettings.defaultTheme = "agterm"` (host-free), and `SettingsStore.load()` seeds it on a fresh install
  (missing/corrupt `settings.json` → `AppSettings(theme: defaultTheme)`).
  It is NOT baked into the `AppSettings()` memberwise default — that stays `theme == nil` so `ghosttyConfigLines()`'s
  "nil = no theme line" invariant (and its tests) hold; the seed lives ONLY in the fresh-load path.
  So `theme == nil` means ghostty's built-in (the picker's "default ghostty" row);
  the agterm default is a real seeded value, and the picker opens on the "agterm" row for a fresh install.
  An EXISTING `settings.json` with `theme` absent decodes to nil (ghostty built-in) — an existing user
  is never silently re-themed.
  `theme.set` with no name still sets nil (ghostty built-in / "default ghostty"),
  distinct from the seeded app default.
- **Control parity = the commit, not the preview**
  (preview is interactive-only): `theme.set`/`theme.list` (see the Control API catalog for the four-point
  audit).
  The font-zoom reset on a theme change (any `apply()` that changes the config text runs `resetSessionFontSizesAllWindows`)
  applies to the preview too — navigating the picker clears per-session ⌘+/⌘− zoom and Esc does not bring
  it back; accepted (matches the Settings-picker behavior, a colors-only reload isn't cheaply available
  from libghostty).

