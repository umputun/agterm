import agtermCore
import Foundation
import os

private let logger = Logger(subsystem: "com.umputun.agterm", category: "SettingsModel")

/// The observable settings state for the Settings window. Loads `AppSettings` from `SettingsStore`
/// at init; each mutation persists AND applies live to the running terminals.
///
/// Applying writes the ghostty settings file, rebuilds + broadcasts the config to every live
/// surface, and clears per-session font-size overrides (the shared `update_config` resets all
/// surfaces to the new default, so the persisted overrides are cleared to match).
@Observable
@MainActor
final class SettingsModel {
    /// The window library; a config reload broadcasts to the surfaces of EVERY open window (and
    /// every window's quick terminal), so a settings change updates all windows live.
    private let library: WindowLibrary
    private let settingsStore: SettingsStore
    private(set) var settings: AppSettings

    /// The parsed keymap (built-in overrides + custom commands). Driven `@Observable` so the
    /// data-driven menu shortcuts re-render on reload.
    private(set) var keymap: Keymap = Keymap(builtinOverrides: [:], commands: [])
    /// Problems found while parsing the keymap file, surfaced read-only in the Key Mapping settings tab.
    private(set) var keymapDiagnostics: [KeymapDiagnostic] = []

    /// Coalesces rapid theme-picker navigation/typing previews so a burst of `previewTheme` calls
    /// triggers a single `apply()` once the quiet window elapses, instead of rebuilding + reloading
    /// every surface on each arrow keypress. Commit flushes it; cancel drops it (see `commitTheme`
    /// and `revertThemePreview`).
    private let previewThemeDebouncer = Debouncer()
    private static let previewThemeDebounceInterval: TimeInterval = 0.07

    /// Coalesces the opacity/blur slider's live drag into a single deferred `settings.json` write: the
    /// preview methods apply each tick WITHOUT saving and reschedule this, so the disk write fires once
    /// the slider settles. This persists KEYBOARD adjustments too (arrow keys don't fire the slider's
    /// `onEditingChanged`), while a mouse release flushes it immediately via `commitBackgroundSettings`.
    private let backgroundSaveDebouncer = Debouncer()
    private static let backgroundSaveInterval: TimeInterval = 0.3

    /// Coalesces `.agtermSystemAppearanceChanged` into a single re-apply when the macOS light/dark
    /// appearance flips. Posted by the app-level KVO observer on `NSApplication.effectiveAppearance`
    /// (`SystemAppearanceObserver`); the debounce absorbs any rapid repeat post during the transition.
    private let appearanceDebouncer = Debouncer()
    private static let appearanceDebounceInterval: TimeInterval = 0.05

    /// The theme slots as of the last real persist (`persistAndApply`/`commitTheme`), NOT updated by the
    /// live theme preview. The opacity/blur background-save debounce persists a snapshot pinned to these
    /// values instead of the in-flight `settings.theme`/`darkTheme`, so a slider write firing mid-preview
    /// can't leak an uncommitted previewed theme to `settings.json` (the preview persists only on
    /// commit; Esc reverts it in memory, and disk must never have seen it).
    private var committedTheme: String?
    private var committedDarkTheme: String?

    init(library: WindowLibrary, settingsStore: SettingsStore) {
        self.library = library
        self.settingsStore = settingsStore
        self.settings = settingsStore.load()
        self.committedTheme = settings.theme
        self.committedDarkTheme = settings.darkTheme
        // write the ghostty config from the loaded settings NOW — before GhosttyApp boots and reads it
        // (its loadConfig runs in applicationDidFinishLaunching, AFTER this App.init). The SEEDED default
        // theme (agterm) lives only in memory (load() seeds it; it isn't in settings.json), so without
        // this the launch config carries no theme line and the terminal renders ghostty's built-in until
        // the first settings change rewrites the conf. Idempotent: writeGhosttyConfig no-ops when the file
        // already matches (e.g. a user with an explicit theme already has it on disk).
        _ = writeGhosttyConfig()
        // mirror the persisted window translucency + notification toggle + toolbar mode + badge
        // toggle into their shared channels at launch, before any settings change fires.
        applyWindowTranslucency()
        applyNotificationsEnabled()
        applyDockBounce()
        applyNotificationSound()
        applyToolbarMode()
        applyNotificationBadgeEnabled()
        applyInactivePaneMute()
        applySidebarBackgroundShift()
        applySidebarFontSize()
        applyBaseFontSize()
        applyAgentStatusColors()
        applyRestoreRunningCommand()
        applyAttentionButtonEnabled()
        applyInterfaceElements()
        // create the commented starter keymap on first launch, then load + parse it.
        ensureStarterKeymap()
        loadKeymap()
        // create the commented starter ghostty.conf on first launch (all comments, a no-op until edited).
        ensureStarterGhosttyConfig()
        // seed the restore-denylist.conf (multiplexers) on first launch, then parse it into GhosttyApp.
        ensureStarterRestoreDenylist()
        loadRestoreDenylist()
        // follow the macOS light/dark appearance: `SystemAppearanceObserver` (app-level KVO on
        // NSApp.effectiveAppearance) posts this with the resolved `isDark`; we re-feed the config so
        // libghostty re-resolves the dual `theme = light:,dark:` conditional to the new side. The side
        // rides the notification (the KVO-delivered value) and is threaded straight into the reload.
        NotificationCenter.default.addObserver(forName: .agtermSystemAppearanceChanged, object: nil,
                                               queue: .main) { [weak self] note in
            guard let isDark = note.userInfo?["isDark"] as? Bool else { return }
            MainActor.assumeIsolated { self?.appearanceChanged(isDark: isDark) }
        }
    }

    /// The frontmost session's focused-pane cwd, used only to seed directory-picking panels near the
    /// user's current work. Settings views still mutate through this model; they don't need library access.
    var activeSessionCwd: String? { library.activeStore?.activeSession?.focusedCwd }

    /// The appearance side the last config feed applied, used to suppress redundant re-posts of
    /// `.agtermSystemAppearanceChanged` on the same side (KVO `[.initial]` seeds one at launch, and the
    /// debounce can coalesce a burst). Starts `false` because a host-loaded config is always resolved to
    /// the LIGHT side: a light launch then skips the seeding reload entirely, while a dark launch takes
    /// exactly one (which re-sides the chrome colors via the CONFIG_CHANGE clone). Read-only outside: the
    /// UI-test-only `debug.appearance` probe (bare form) reports it so a test can assert a flip drove the reload.
    private(set) var lastAppliedIsDark = false

    /// Re-feed the config on a macOS appearance flip so libghostty re-resolves the dual theme to the new
    /// side — the system→settings half of light/dark sync. A no-op unless following with both slots set,
    /// and a no-op when the appearance side hasn't actually changed since the last feed (see
    /// `lastAppliedIsDark`). The config file holds the RAW `theme = light:,dark:` value and is IDENTICAL
    /// across flips, so `writeGhosttyConfig()` would no-op and `apply()` would skip the reload; reload
    /// DIRECTLY instead. ghostty already recorded the new scheme (`set_color_scheme`) and re-resolves
    /// when we re-feed the config via `update_config`. Debounced because a burst can arrive (KVO
    /// `[.initial]` at launch, plus the seam); the latest posted side wins. Unlike an explicit File ▸
    /// Reload / `config.reload`, an automatic flip PRESERVES each session's ⌘+/⌘− zoom — silently wiping
    /// it on an OS schedule would be a surprise.
    ///
    /// `isDark` is the KVO-delivered side (from `SystemAppearanceObserver`), threaded straight into the
    /// reload so libghostty is set to exactly this side — never re-read from a view, whose
    /// `effectiveAppearance` can lag around sleep/wake. This makes `lastAppliedIsDark` equal the applied
    /// side by construction. A zero-surface reload is safe (the app-scheme set re-sides the chrome clone).
    private func appearanceChanged(isDark: Bool) {
        guard settings.followSystemAppearance == true, settings.theme != nil, settings.darkTheme != nil else { return }
        appearanceDebouncer.schedule(after: Self.appearanceDebounceInterval) { [weak self] in
            guard let self else { return }
            guard isDark != lastAppliedIsDark else { return }
            reloadConfigPreservingSessionZoom(isDark: isDark)
            NotificationCenter.default.post(name: .agtermAppearanceChanged, object: nil)
        }
    }

    func setFontFamily(_ value: String?) { settings.fontFamily = value; persistAndApply() }
    func setFontSize(_ value: Double?) { settings.fontSize = value; persistAndApply() }

    /// Whether the slot rendering RIGHT NOW is the dark one: following AND the app is in dark mode. The
    /// current-appearance picker and the theme preview target this slot so on-screen edits stick.
    private var rendersDarkSlot: Bool { settings.followSystemAppearance == true && GhosttyApp.currentIsDark() }

    /// Set the light/single slot — the control channel's `theme set <name>`. A name keeps the dark side
    /// (syncing stays on); nil ("default ghostty") clears everything, since a nil side can't be a dual
    /// slot.
    func setLightTheme(_ value: String?) {
        settings.theme = value
        if value == nil { settings.darkTheme = nil; settings.followSystemAppearance = nil }
        persistAndApply()
    }

    /// Set the dark slot — the control channel's `theme set --dark`. A name turns syncing on (the light
    /// side seeds from the current theme, else `defaultLightTheme`, since ghostty's built-in can't be a
    /// dual slot); `none`/nil turns syncing off and drops the dark slot.
    func setDarkTheme(_ value: String?) {
        if let value {
            if settings.theme?.isEmpty ?? true { settings.theme = Self.defaultLightTheme }
            settings.darkTheme = value
            settings.followSystemAppearance = true
        } else {
            settings.darkTheme = nil
            settings.followSystemAppearance = nil
        }
        persistAndApply()
    }

    /// Set both sides at once, in a single apply — the control channel's `theme set --light --dark`.
    func setSystemThemes(light: String, dark: String) {
        settings.theme = light
        settings.darkTheme = dark
        settings.followSystemAppearance = true
        persistAndApply()
    }

    /// Settings picker 1: the theme for the CURRENT appearance (no relabel). While following in dark mode
    /// this edits the dark slot; otherwise the light/single `theme`.
    func setThemeForCurrentAppearance(_ value: String?) {
        if rendersDarkSlot { settings.darkTheme = value } else { settings.theme = value }
        persistAndApply()
    }

    /// Settings alternate picker (shown only while following): the theme for the OTHER appearance.
    /// Clearing the dark slot (nil while the alternate IS the dark slot) routes through `setDarkTheme(nil)`
    /// so following can never be left ON with `darkTheme == nil` — the picker has no such row today, but the
    /// setter stays consistent regardless of what a future caller passes.
    func setAlternateTheme(_ value: String?) {
        if rendersDarkSlot {
            settings.theme = value          // the alternate is the LIGHT slot while rendering dark
        } else if value == nil {
            setDarkTheme(nil)               // clearing the dark slot turns following off (reuses the tested path)
            return
        } else {
            settings.darkTheme = value
        }
        persistAndApply()
    }

    /// Settings "Follow system appearance" toggle. ON seeds the other slot from the current theme (both
    /// start equal — a well-formed dual with no visual change; the user then picks the alternative). OFF
    /// collapses to the on-screen theme so there is no flip and `theme` always holds one meaningful value.
    func setFollowSystemAppearance(_ on: Bool) {
        if on {
            if settings.theme?.isEmpty ?? true { settings.theme = Self.defaultLightTheme }
            settings.darkTheme = settings.darkTheme ?? settings.theme
            settings.followSystemAppearance = true
        } else {
            if GhosttyApp.currentIsDark() { settings.theme = settings.darkTheme ?? settings.theme }
            settings.darkTheme = nil
            settings.followSystemAppearance = nil
        }
        persistAndApply()
    }

    /// The light side seeded when a dark theme is chosen while the theme is nil/empty (ghostty
    /// built-in, which cannot be a dual side) — a bundled light theme so the pick composes a
    /// well-formed dual value.
    static let defaultLightTheme = "Builtin Light"

    func setNotificationsEnabled(_ value: Bool?) { settings.notificationsEnabled = value; persistAndApply() }
    /// Set the toolbar row mode (nil = the default = compact). Nils the legacy `compactToolbar` shim so
    /// it evaporates from `settings.json` on the next save; the Settings Picker maps `.compact` back to nil.
    func setToolbarMode(_ mode: ToolbarMode?) { settings.toolbarMode = mode?.rawValue; settings.compactToolbar = nil; persistAndApply() }
    func setNotificationBadgeEnabled(_ value: Bool?) { settings.notificationBadgeEnabled = value; persistAndApply() }
    func setDockBounce(_ mode: DockBounce?) { settings.dockBounce = mode?.rawValue; persistAndApply() }
    /// Persist the system sound played when a notification is delivered (nil/empty = none). Not a ghostty
    /// key; the `NotificationManager` mirror is read on the next notification, like `dockBounce`.
    func setNotificationSoundName(_ name: String?) { settings.notificationSoundName = name; persistAndApply() }
    func setMouseScrollMultiplier(_ value: Double?) { settings.mouseScrollMultiplier = value; persistAndApply() }
    // ghostty key (right-click-action): persistAndApply() rewrites the conf and reloads surfaces live.
    func setRightClickPaste(_ value: Bool?) { settings.rightClickPaste = value; persistAndApply() }
    func setInactivePaneMuteStrength(_ value: Int?) { settings.inactivePaneMuteStrength = value; persistAndApply() }
    func setSidebarBackgroundShift(_ value: Int?) { settings.sidebarBackgroundShift = value; persistAndApply() }
    func setSidebarFontSize(_ value: Double?) { settings.sidebarFontSize = value; persistAndApply() }
    // not a ghostty key, so persistAndApply()'s writeGhosttyConfig() no-ops and no surface reload fires.
    func setRestoreRunningCommand(_ value: Bool?) { settings.restoreRunningCommand = value; persistAndApply() }
    // chrome flag, not a ghostty key: persistAndApply() no-ops the config but rides .agtermAppearanceChanged.
    func setAttentionButtonEnabled(_ value: Bool?) { settings.attentionButtonEnabled = value; persistAndApply() }

    /// Show or hide a single title-bar / sidebar-footer chrome element, then persist. Toggling `visible`
    /// off adds the element to `hiddenInterfaceElements`, on removes it; an empty result maps back to nil so
    /// `settings.json` stays minimal. A GUI-only chrome flag, not a ghostty key — `persistAndApply()`
    /// no-ops the config text but rides `.agtermAppearanceChanged` so every window re-gates the element live.
    /// Mutates the RAW string set (not `resolvedHiddenInterfaceElements`, which drops unknown names) so a
    /// future element hidden by a newer build survives a toggle here instead of being erased.
    func setInterfaceElementVisible(_ element: InterfaceElement, visible: Bool) {
        var hidden = Set(settings.hiddenInterfaceElements ?? [])
        if visible { hidden.remove(element.rawValue) } else { hidden.insert(element.rawValue) }
        settings.hiddenInterfaceElements = hidden.isEmpty ? nil : hidden.sorted()
        persistAndApply()
    }

    /// Persist whether agterm inherits the user's global `~/.config/ghostty/config` and FULLY reload the
    /// ghostty config so the change takes effect live. NOT a `ghosttyConfigLines()` key, so
    /// `persistAndApply`'s text-diff guard would skip the reload — but it changes WHICH files `loadConfig`
    /// reads, so it takes the unconditional reload path (like `setConfigDirectory`). nil/false = off (the
    /// default): agterm stays self-contained; the scoped `ghostty.conf` is the place for customizations.
    func setInheritGlobalGhosttyConfig(_ value: Bool?) {
        settings.inheritGlobalGhosttyConfig = value
        try? settingsStore.save(settings)
        reloadGhosttyConfig()
    }
    func setActiveStatusColorHex(_ hex: String?) { settings.activeStatusColorHex = hex; persistAndApply() }
    func setBlockedStatusColorHex(_ hex: String?) { settings.blockedStatusColorHex = hex; persistAndApply() }
    func setCompletedStatusColorHex(_ hex: String?) { settings.completedStatusColorHex = hex; persistAndApply() }
    /// Persist the system sound played when a session enters `blocked` (nil/empty = none). Not a ghostty
    /// key and nothing renders it continuously, so it only saves — `ControlServer` reads it on demand.
    func setBlockedStatusSoundName(_ name: String?) { settings.blockedStatusSoundName = name; try? settingsStore.save(settings) }
    /// Persist where a new (⌘T) session opens (nil = the home default). Not a ghostty key and nothing
    /// renders it continuously — it only affects the NEXT new session, read then by `AppActions.newSession()`
    /// — so it just saves (no config rewrite / surface reload).
    func setNewSessionDirectory(_ value: String?) { settings.newSessionDirectory = value; try? settingsStore.save(settings) }
    /// Persist the fixed directory used when `newSessionDirectory` is `custom` (nil/empty falls back to home).
    func setNewSessionCustomDirectory(_ value: String?) { settings.newSessionCustomDirectory = value; try? settingsStore.save(settings) }
    /// Persist whether closing a session from the GUI first asks for confirmation (nil = off). Not a ghostty
    /// key and nothing renders it continuously — `AppActions` reads it on demand at close time — so it just saves.
    func setConfirmCloseSession(_ value: Bool?) { settings.confirmCloseSession = value; try? settingsStore.save(settings) }
    /// Persist whether GUI closes use the short undo grace period. nil = on; false = close immediately.
    func setCloseGraceUndoEnabled(_ value: Bool?) { settings.closeGraceUndoEnabled = value; try? settingsStore.save(settings) }
    /// Persist the user-idle auto-follow timeout (nil = off) and fan it out to every open window's store.
    /// Not a ghostty key — a per-window `AppStore` behavior — so it just saves, then pushes the resolved
    /// timeout into the live stores (a newly opened window seeds itself via `applyAutoFollow(to:)`).
    func setAutoFollowAttention(_ value: String?) {
        settings.autoFollowAttention = value
        try? settingsStore.save(settings)
        applyAutoFollowToAllWindows()
    }
    /// Persist whether auto-follow stays put on a running (`active`) session (nil/false = off) and fan it out.
    func setAutoFollowStayOnActive(_ value: Bool?) {
        settings.autoFollowStayOnActive = value
        try? settingsStore.save(settings)
        applyAutoFollowToAllWindows()
    }

    /// Apply a new background opacity live WITHOUT an immediate save — the live-drag half of the opacity
    /// slider. Updates translucency on every drag tick (apply-without-save) and schedules a debounced
    /// write, so the window updates continuously while the disk write coalesces to one once the slider
    /// settles (covering keyboard arrow adjustments, which never fire `onEditingChanged`). A mouse
    /// release flushes it immediately via `commitBackgroundSettings`. Mirrors the theme apply/save split.
    func previewBackgroundOpacity(_ value: Double?) {
        settings.backgroundOpacity = value
        apply()
        scheduleBackgroundSave()
    }

    /// Apply a new background blur live, the counterpart of `previewBackgroundOpacity`: apply-without-save
    /// plus a debounced write flushed on drag-end.
    func previewBackgroundBlur(_ value: Int?) {
        settings.backgroundBlur = value
        apply()
        scheduleBackgroundSave()
    }

    /// Persist the current opacity/blur NOW — the slider's `onEditingChanged` drag-end commit. Flushes
    /// the pending debounced write so a mouse release saves immediately (save-only; the value is already
    /// live from the preview applies, so no redundant re-apply).
    func commitBackgroundSettings() { backgroundSaveDebouncer.flush() }

    private func scheduleBackgroundSave() {
        backgroundSaveDebouncer.schedule(after: Self.backgroundSaveInterval) { [weak self] in
            guard let self else { return }
            // pin the theme to the last committed value: a theme preview mutates settings.theme in
            // place WITHOUT persisting, so saving the live settings here would leak an uncommitted
            // preview to disk. Opacity/blur (what this save is for) keep their live values.
            var snapshot = settings
            snapshot.theme = committedTheme
            snapshot.darkTheme = committedDarkTheme
            try? settingsStore.save(snapshot)
        }
    }

    /// Apply a theme live WITHOUT persisting it — the live-preview half of the action-palette theme
    /// picker (navigation/typing). Sets `settings.theme` immediately (so a commit captures the latest
    /// even if the apply hasn't fired yet) but DEBOUNCES the expensive `apply()` (config rewrite +
    /// surface reload + chrome refresh), so a burst of arrow/typing previews coalesces to one reload
    /// once the quiet window elapses. Skips `settingsStore.save`, so navigating themes doesn't touch
    /// `settings.json`; the picker commits with `commitTheme()` on Enter (which flushes the pending
    /// apply) or reverts with `revertThemePreview(theme:darkTheme:)` on Esc (restoring both captured
    /// slots). Writes the CURRENT-appearance slot (the dark slot while following in dark mode, else
    /// `theme`) so the preview renders on screen.
    func previewTheme(_ value: String?) {
        if rendersDarkSlot { settings.darkTheme = value } else { settings.theme = value }
        previewThemeDebouncer.schedule(after: Self.previewThemeDebounceInterval) { [weak self] in self?.apply() }
    }

    /// Restore BOTH theme slots IMMEDIATELY (no debounce), cancelling any pending debounced preview — the
    /// revert half of the picker (Esc / scrim / mode switch / unmount). Synchronous so the captured pair
    /// is restored with no debounce lag and no queued preview fires afterwards. Writes both slots (not
    /// the on-screen one) so an appearance flip mid-preview can't leave a previewed value in the wrong
    /// slot — `AppActions` snapshots the pair on open and passes it straight back.
    func revertThemePreview(theme: String?, darkTheme: String?) {
        previewThemeDebouncer.cancel()
        settings.theme = theme
        settings.darkTheme = darkTheme
        apply()
    }

    /// Persist the picker's final theme — the commit half, called on Enter after one or more
    /// `previewTheme` applies. Only the slot rendering AT ENTER-TIME (the active slot) keeps its browsed
    /// value; the OTHER slot is restored to `nonActiveOriginal` (its value when the picker opened). Without
    /// that, a mid-preview appearance flip that browsed a value into the off-screen slot would persist it
    /// even though it was never confirmed, and it would resurface on the next flip — the commit-side twin
    /// of the `revertThemePreview` bug. Flushes any pending debounced preview first (so the active slot's
    /// latest value is live), restores the off-screen slot, re-applies ONLY if that changed the config
    /// (the flip case — so the dual line on disk matches, and the reverted slot won't resurface), then
    /// writes `settings.json`. The common no-flip commit stays save-only (nothing to restore, no reload).
    func commitTheme(nonActiveOriginal: (theme: String?, dark: String?)) {
        previewThemeDebouncer.flush()
        let restored: Bool
        if rendersDarkSlot {
            restored = settings.theme != nonActiveOriginal.theme
            settings.theme = nonActiveOriginal.theme
        } else {
            restored = settings.darkTheme != nonActiveOriginal.dark
            settings.darkTheme = nonActiveOriginal.dark
        }
        if restored { apply() }
        try? settingsStore.save(settings)
        committedTheme = settings.theme
        committedDarkTheme = settings.darkTheme
    }

    /// Flush any pending debounced settings writes synchronously — the quit path. The opacity/blur
    /// slider's debounced `settings.json` write (and the theme preview, for symmetry) holds a pending
    /// save for ~0.3 s after a KEYBOARD adjustment, which never fires the slider's drag-end commit;
    /// quitting within that window would otherwise lose it. Called from `applicationWillTerminate`.
    func flushPendingSaves() {
        backgroundSaveDebouncer.flush()
        previewThemeDebouncer.flush()
    }

    /// Reset the whole Agent Status section to defaults (the "Reset to defaults" button): the three glyph
    /// colors back to the system defaults AND the blocked sound back to none.
    func resetAgentStatus() {
        settings.activeStatusColorHex = nil
        settings.blockedStatusColorHex = nil
        settings.completedStatusColorHex = nil
        settings.blockedStatusSoundName = nil
        persistAndApply()
    }

    /// Persist a new config directory (where `keymap.conf` and `ghostty.conf` live) and reload BOTH
    /// co-located files from it, so neither lags behind a directory change (each reload posts its own
    /// diagnostics banner). A nil value falls back to the default location resolved by
    /// `ConfigPaths.configDirectory`.
    func setConfigDirectory(_ value: String?) {
        settings.configDirectory = value
        try? settingsStore.save(settings)
        reloadKeymap()
        reloadGhosttyConfig()
    }

    /// Re-read and re-parse `keymap.conf`, then post `.agtermKeymapChanged` so the custom-command
    /// runner rebuilds and the action palette re-reads the custom commands. The data-driven menu
    /// shortcuts re-render on their own (they read the `@Observable` `keymap`). Surfaces any parse
    /// errors or conflicts as a banner — this runtime reload path runs after notification registration,
    /// so it's safe to post here (the startup path posts from the scene `.task` instead).
    func reloadKeymap() {
        loadKeymap()
        NotificationCenter.default.post(name: .agtermKeymapChanged, object: nil)
        if !keymapDiagnostics.isEmpty {
            NotificationManager.shared.notifyKeymapDiagnostics(count: keymapDiagnostics.count)
        }
    }

    /// The resolved config directory: the explicit setting, else `AGTERM_STATE_DIR/config` (test
    /// isolation), else `~/.config/agterm`. Both `keymap.conf` and `ghostty.conf` live here.
    private func configDirectoryURL() -> URL {
        ConfigPaths.configDirectory(
            setting: settings.configDirectory,
            stateDir: ProcessInfo.processInfo.environment["AGTERM_STATE_DIR"],
            home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// The resolved keymap file path: `<config dir>/keymap.conf`.
    private func keymapURL() -> URL {
        ConfigPaths.keymapPath(configDirectory: configDirectoryURL())
    }

    /// The resolved `keymap.conf` path, exposed for the Edit Keymap action (the overlay command).
    var keymapPath: String { keymapURL().path }

    /// The resolved agterm-scoped `ghostty.conf` path: `<config dir>/ghostty.conf`, co-located with
    /// `keymap.conf`.
    private func ghosttyConfigURL() -> URL {
        ConfigPaths.ghosttyConfigPath(configDirectory: configDirectoryURL())
    }

    /// The resolved `ghostty.conf` path, exposed for the Edit ghostty.conf action (the overlay command).
    var ghosttyConfigPath: String { ghosttyConfigURL().path }

    /// The resolved restore-denylist path: `<config dir>/restore-denylist.conf`.
    private func restoreDenylistURL() -> URL {
        ConfigPaths.restoreDenylistPath(configDirectory: configDirectoryURL())
    }

    /// Read + parse `restore-denylist.conf` and mirror it into `GhosttyApp.shared.restoreDenylist` (the
    /// set the restore factories consult). A missing/unreadable file yields an empty denylist (restore
    /// everything). Read at launch; an edit takes effect on the next launch (restore is launch-time).
    private func loadRestoreDenylist() {
        let text = (try? String(contentsOf: restoreDenylistURL(), encoding: .utf8)) ?? ""
        GhosttyApp.shared.setRestoreDenylist(CommandRestore.parseDenylist(text))
    }

    /// On first launch, if `restore-denylist.conf` does not exist, create the config directory and write
    /// a commented starter listing the terminal multiplexers (the one class of program that just starts a
    /// fresh empty session on re-run). Never overwrites an existing file.
    private func ensureStarterRestoreDenylist() {
        let url = restoreDenylistURL()
        if FileManager.default.fileExists(atPath: url.path) { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try starterRestoreDenylistText().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            logger.notice("could not write starter restore-denylist at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The commented starter `restore-denylist.conf`: a header explaining the format, the terminal
    /// multiplexers as active default entries, and commented examples the user can uncomment.
    private func starterRestoreDenylistText() -> String {
        """
        # restore-denylist.conf — programs NOT to re-run when "Restore running commands on restart"
        # is on. One command name per line, matched on the command's basename. Blank lines and lines
        # starting with # are ignored. Read at launch; edits take effect on the next launch.
        #
        # Terminal multiplexers just start a fresh, empty session when re-run (your old session is gone),
        # so they are listed by default — delete a line to let it restore:
        tmux
        screen
        zellij
        #
        # Add anything else you would rather start fresh, e.g. an editor or pager:
        # vim
        # less

        """
    }

    /// Rebuild the ghostty config from all sources (re-reading the agterm-scoped `ghostty.conf` the user
    /// just edited) and broadcast it to every live surface, clearing per-session font overrides like a
    /// settings change. Unconditional — unlike `apply()`, which skips the reload when the generated
    /// settings text is unchanged; `ghostty.conf` is edited externally, so there is always something to
    /// re-read. Posts `.agtermAppearanceChanged` so the chrome picks up any color change, and a warning
    /// banner on diagnostics (mirroring `reloadKeymap`, so every caller surfaces them — this runtime path
    /// runs after notification registration, so posting here is safe). Returns the rebuilt config's
    /// diagnostic count (0 = clean), counted across ALL config sources (libghostty diagnostics carry no
    /// source-file attribution, so it is not specific to `ghostty.conf`). Drives File ▸ Reload Config, the
    /// Edit-ghostty overlay close, a Key Mapping directory change, and the `config.reload` control command.
    @discardableResult
    func reloadGhosttyConfig() -> Int {
        let count = reloadConfigClearingSessionZoom()
        NotificationCenter.default.post(name: .agtermAppearanceChanged, object: nil)
        if count > 0 { NotificationManager.shared.notifyConfigDiagnostics(count: count) }
        return count
    }

    /// Clears every session's per-session ⌘+/⌘− zoom BEFORE rebuilding + rebroadcasting the ghostty
    /// config to the live surfaces, returning the rebuilt config's diagnostic count. The ORDER is
    /// load-bearing: `reloadConfig` re-asserts each surface's per-session overlay (`reapplySessionConfigIfNeeded`),
    /// which re-emits `font-size` from `session.fontSize`. Clearing the override FIRST makes that re-emit
    /// read nil — so a watermarked pane drops its zoom on screen and the snapshot persists `fontSize == nil`
    /// in agreement, matching the documented "reload clears per-session zoom" contract (resetting AFTER would
    /// leave the surface zoomed while the model said nil). The EXPLICIT reload callers — `reloadGhosttyConfig`
    /// and `apply()` — funnel through here so neither can drift back to reload-then-reset; the automatic
    /// appearance flip is the one deliberate exception (`reloadConfigPreservingSessionZoom`).
    @discardableResult
    private func reloadConfigClearingSessionZoom() -> Int {
        // every reload re-sides the config (surface schemes + the CONFIG_CHANGE chrome clone) to the
        // CURRENT appearance, so record the side here — for ALL reload paths, not just the appearance
        // flip — to keep `appearanceChanged()`'s same-side suppression from firing one spurious reload
        // later. The app-level `NSApp.effectiveAppearance` (via `currentIsDark()`) is the single source.
        let isDark = GhosttyApp.currentIsDark()
        lastAppliedIsDark = isDark
        // open windows reset live, closed ones by rewriting their snapshot file (the shared config reset
        // every surface to the default size, so a closed window mustn't reopen later overriding the new default).
        library.resetSessionFontSizesAllWindows()
        return GhosttyApp.shared.reloadConfig(surfaces: liveSurfaces(), isDark: isDark)
    }

    /// The appearance-flip variant of the reload above: re-feeds the config so libghostty re-resolves
    /// the dual theme, but KEEPS every session's ⌘+/⌘− zoom — after the shared-config broadcast,
    /// `reapplySessionConfigIfNeeded` re-emits the session's `fontSize` per surface (the same
    /// round-trip that re-asserts watermarks). An automatic OS flip (or the launch seeding reload of a
    /// dark launch) must not silently wipe zoom; only the explicit reloads carry the documented
    /// zoom-clearing contract. The latch records the `isDark` we actually applied (the KVO-delivered
    /// side threaded through the reload), so "latch == applied side" holds for ALL reload paths — there
    /// is one source now, so the poster-vs-rendered divergence the old two-source design feared is gone.
    private func reloadConfigPreservingSessionZoom(isDark: Bool) {
        GhosttyApp.shared.reloadConfig(surfaces: liveSurfaces(), isDark: isDark)
        lastAppliedIsDark = isDark
    }

    /// Read `keymap.conf` and parse it into `keymap` + `keymapDiagnostics`. A MISSING file is not an
    /// error: it yields an empty keymap with no diagnostics (the starter file is created at init). A
    /// file that EXISTS but can't be read (permissions, invalid UTF-8) is surfaced as a single line-0
    /// diagnostic so the warning banner fires, rather than being silently treated as missing.
    private func loadKeymap() {
        let loaded = KeymapStore(configDirectory: configDirectoryURL()).load()
        keymap = loaded.keymap
        keymapDiagnostics = loaded.diagnostics
    }

    /// On first launch, if `keymap.conf` does not exist, create the config directory and write a
    /// commented starter file documenting every built-in action name + default, the `map`/`command`
    /// syntax, and the `{AGT_X}` tokens. Never overwrites an existing file.
    private func ensureStarterKeymap() {
        let url = keymapURL()
        if FileManager.default.fileExists(atPath: url.path) { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try ConfigPaths.starterKeymapConf().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            logger.notice("could not write starter keymap at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// On first launch, if `ghostty.conf` does not exist, create the config directory and write a
    /// commented starter file pointing at ghostty's config docs with an example override. Never
    /// overwrites an existing file. (Seeded after GhosttyApp's first `loadConfig` runs, but harmless:
    /// the starter is all comments — a no-op — exactly like the starter keymap.)
    private func ensureStarterGhosttyConfig() {
        let url = ghosttyConfigURL()
        if FileManager.default.fileExists(atPath: url.path) { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try starterGhosttyConfigText().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            logger.notice("could not write starter ghostty.conf at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The commented starter `ghostty.conf`: a header linking ghostty's config docs, a commented
    /// example override, and a note that agterm's UI-managed keys win over this file. Every line is a
    /// comment so a fresh file changes nothing.
    private func starterGhosttyConfigText() -> String {
        """
        # agterm-scoped ghostty config — applies ONLY to agterm, not the standalone Ghostty.app.
        # Put any ghostty config key here to override agterm's bundled defaults and your global
        # ~/.config/ghostty/config. Full key reference: https://ghostty.org/docs/config
        #
        # Edit this file and run File ▸ Reload Config (or relaunch) to apply. Blank lines and lines
        # starting with `#` are ignored. Most keys apply to open terminals on reload, but layout keys
        # (window-padding-*) and shell-spawn keys (term, shell-integration-features) only take effect in
        # a new session/window or after a relaunch.
        #
        # Example — make the macOS Option key send Alt (uncomment to enable):
        # macos-option-as-alt = true
        #
        # NOTE: agterm's UI-managed keys (font, theme, background opacity/blur, scroll speed) are set
        # in Settings and always win over this file — set those in Settings, everything else here.

        """
    }

    private func persistAndApply() {
        try? settingsStore.save(settings)
        committedTheme = settings.theme
        committedDarkTheme = settings.darkTheme
        apply()
    }

    /// Apply the current `settings` to the running app WITHOUT persisting: rewrite the ghostty config
    /// and rebroadcast it to every live surface (only when the generated text changed), then refresh
    /// the window translucency, toggles, and chrome. Split out of `persistAndApply` so the theme
    /// picker can preview-apply without writing `settings.json`.
    private func apply() {
        // only rebuild + rebroadcast the ghostty config (which resets every surface to the default
        // font size) when the generated config TEXT actually changed. A window-opacity drag within
        // the translucent range, or a blur change, leaves the config identical — re-syncing the
        // window alone is enough and avoids hammering surface rebuilds on every slider tick.
        let opacityBefore = GhosttyApp.shared.windowOpacity
        if writeGhosttyConfig() {
            reloadConfigClearingSessionZoom()
        }
        applyWindowTranslucency()
        // a `.color` session background bakes the window opacity into its per-surface `background-opacity`
        // at apply time, so re-assert those surfaces whenever the opacity changed — reloadConfig's own
        // re-assert (when the config text changed) runs BEFORE `applyWindowTranslucency` updates the
        // opacity, and a within-range slider drag doesn't reload at all, so neither path alone keeps a
        // color session tracking the slider. Guarded to `.color` surfaces so a plain/image/text session
        // isn't rebuilt on every opacity tick (blur composites at the AppKit level and needs no re-emit).
        if GhosttyApp.shared.windowOpacity != opacityBefore {
            for surface in liveSurfaces() { surface.reapplyColorBackgroundIfNeeded() }
        }
        applyNotificationsEnabled()
        applyDockBounce()
        applyNotificationSound()
        applyToolbarMode()
        applyNotificationBadgeEnabled()
        applyInactivePaneMute()
        applySidebarBackgroundShift()
        applySidebarFontSize()
        applyBaseFontSize()
        applyAgentStatusColors()
        applyRestoreRunningCommand()
        applyAttentionButtonEnabled()
        applyInterfaceElements()
        // refresh the app chrome (title bar + sidebar + quick terminal) with the new terminal color,
        // window translucency, and toolbar style immediately, rather than only when the window next
        // re-keys. The title-bar re-sync and the cwd-subtitle drop both ride this notification.
        NotificationCenter.default.post(name: .agtermAppearanceChanged, object: nil)
    }

    private func applyWindowTranslucency() {
        GhosttyApp.shared.setWindowTranslucency(opacity: settings.backgroundOpacity ?? 1,
                                                blurRadius: settings.backgroundBlur ?? 0)
    }

    private func applyNotificationsEnabled() {
        NotificationManager.shared.bannersEnabled = settings.notificationsEnabled ?? true
    }

    private func applyDockBounce() {
        NotificationManager.shared.dockBounce = settings.effectiveDockBounce
    }

    private func applyNotificationSound() {
        NotificationManager.shared.notificationSoundName = settings.notificationSoundName
    }

    private func applyToolbarMode() {
        // effectiveToolbarMode resolves nil (and the legacy compactToolbar shim) to the concrete mode.
        GhosttyApp.shared.setToolbarMode(settings.effectiveToolbarMode)
    }

    private func applyNotificationBadgeEnabled() {
        GhosttyApp.shared.setNotificationBadgeEnabled(settings.notificationBadgeEnabled ?? true)
    }

    private func applyRestoreRunningCommand() {
        GhosttyApp.shared.setRestoreRunningCommand(settings.restoreRunningCommand ?? false)
    }

    private func applyAttentionButtonEnabled() {
        GhosttyApp.shared.setAttentionButtonEnabled(settings.attentionButtonEnabled ?? false)
    }

    private func applyInterfaceElements() {
        GhosttyApp.shared.setHiddenInterfaceElements(settings.resolvedHiddenInterfaceElements)
    }

    /// Push the current auto-follow configuration into a single window's store. Called when a window's
    /// store is first resolved (`ContentView.resolveStore`) so a newly opened window honors the setting:
    /// the store is built host-free in `WindowLibrary` and can't read these settings itself, so — unlike
    /// the chrome flags that ride a `GhosttyApp` mirror — the value is pushed straight into the store.
    func applyAutoFollow(to store: AppStore) {
        let timeout = AppSettings.AutoFollowAttention(tolerant: settings.autoFollowAttention).timeout
        store.setAutoFollow(timeout: timeout, stayOnActive: settings.autoFollowStayOnActive ?? false)
    }

    /// Fan the current auto-follow configuration out to every open window's store — the settings-change
    /// broadcast (and the launch seed, called from the scene `.task` once the model is wired). Idempotent:
    /// re-pushing the same values is a no-op in `AppStore.setAutoFollow`. Distinct name from the single-window
    /// `applyAutoFollow(to:)` so the fan-out and the one-store push don't read as arity-overloaded twins.
    func applyAutoFollowToAllWindows() {
        for store in library.openIDs().compactMap({ library.store(for: $0) }) {
            applyAutoFollow(to: store)
        }
    }

    private func applyInactivePaneMute() {
        GhosttyApp.shared.setInactivePaneMuteStrength(
            settings.inactivePaneMuteStrength ?? AppSettings.defaultInactivePaneMuteStrength)
    }

    private func applySidebarBackgroundShift() {
        GhosttyApp.shared.setSidebarBackgroundShift(
            settings.sidebarBackgroundShift ?? AppSettings.defaultSidebarBackgroundShift)
    }

    private func applySidebarFontSize() {
        GhosttyApp.shared.setSidebarFontSize(settings.sidebarFontSize ?? AppSettings.defaultSidebarFontSize)
    }

    private func applyBaseFontSize() {
        GhosttyApp.shared.setBaseFontSize(settings.fontSize)
    }

    private func applyAgentStatusColors() {
        GhosttyApp.shared.setAgentStatusColors(activeHex: settings.activeStatusColorHex,
                                               blockedHex: settings.blockedStatusColorHex,
                                               completedHex: settings.completedStatusColorHex)
    }

    /// Write the ghostty config lines (font/size/theme + the translucency pins) to the file
    /// `GhosttyApp.loadConfig` reads. Returns true if the file content changed, so the caller can
    /// skip the expensive reload when it didn't.
    private func writeGhosttyConfig() -> Bool {
        let url = GhosttyApp.settingsConfigURL
        // emit the raw single/dual theme — no appearance resolution here. A dual value is stable across
        // flips, so `appearanceChanged` reloads directly (this file's text doesn't change on a flip).
        let text = settings.ghosttyConfigLines().joined(separator: "\n") + "\n"
        if (try? String(contentsOf: url, encoding: .utf8)) == text { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    /// All live ghostty surfaces across every open window: each session's primary + split surface in
    /// every open window's store, plus every open window's quick terminal. A config reload therefore
    /// broadcasts to all windows, not just the frontmost one.
    private func liveSurfaces() -> [GhosttySurfaceView] {
        var views = library.openIDs()
            .compactMap { library.store(for: $0) }
            .flatMap(\.workspaces)
            .flatMap(\.sessions)
            .flatMap { [$0.surface, $0.splitSurface, $0.scratchSurface] }
            .compactMap { $0 as? GhosttySurfaceView }
        views += QuickTerminalRegistry.shared.allControllers().compactMap { $0.currentSurface() }
        return views
    }
}
