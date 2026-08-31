import agtermCore
import Foundation
import os

private let logger = Logger(subsystem: "com.umputun.agterm", category: "SettingsModel")

/// Observable settings state for the Settings window, loaded from `SettingsStore` at init. Most mutations
/// persist and apply live through the shared config path. Restore mode is the exception: it persists for the
/// next launch because the current process uses one immutable mode.
@Observable
@MainActor
final class SettingsModel {
    /// A config reload broadcasts to every open window's surfaces and quick terminal, so settings apply live.
    private let library: WindowLibrary
    private let settingsStore: SettingsStore
    private(set) var settings: AppSettings

    /// The parsed keymap (built-in overrides + custom commands); `@Observable` so menu shortcuts re-render.
    private(set) var keymap: Keymap = Keymap(builtinOverrides: [:], commands: [])
    /// Problems found while parsing the keymap file, surfaced read-only in the Key Mapping settings tab.
    private(set) var keymapDiagnostics: [KeymapDiagnostic] = []

    /// Coalesces a burst of `previewTheme` calls into one `apply()` instead of rebuilding + reloading every
    /// surface per arrow keypress. `commitTheme` flushes it; `revertThemePreview` drops it.
    private let previewThemeDebouncer = Debouncer()
    private static let previewThemeDebounceInterval: TimeInterval = 0.07

    /// Coalesces the opacity/blur drag into one deferred `settings.json` write (previews apply per tick
    /// without saving). Covers KEYBOARD adjustment too — arrows don't fire the slider's `onEditingChanged`;
    /// a mouse release flushes it.
    private let backgroundSaveDebouncer = Debouncer()
    private static let backgroundSaveInterval: TimeInterval = 0.3

    /// Coalesces `.agtermSystemAppearanceChanged` (`SystemAppearanceObserver`'s app-level KVO on
    /// `NSApplication.effectiveAppearance`) into one re-apply per flip.
    private let appearanceDebouncer = Debouncer()
    private static let appearanceDebounceInterval: TimeInterval = 0.05

    /// The theme slots as of the last real persist, NOT updated by the live preview: the background-save
    /// debounce pins its snapshot to these, so a slider write mid-preview can't leak an uncommitted theme.
    private var committedTheme: String?
    private var committedDarkTheme: String?

    init(library: WindowLibrary, settingsStore: SettingsStore) {
        self.library = library
        self.settingsStore = settingsStore
        self.settings = settingsStore.load()
        self.committedTheme = settings.theme
        self.committedDarkTheme = settings.darkTheme
        // write NOW: GhosttyApp's loadConfig runs in applicationDidFinishLaunching, AFTER this App.init,
        // and the SEEDED default theme (agterm) is memory-only, never in settings.json — without this the
        // launch config carries no theme line and the terminal renders ghostty's built-in until the next
        // settings change. Idempotent: no-ops when the file already matches.
        _ = writeGhosttyConfig()
        // mirror the persisted settings into their shared channels before any settings change fires.
        applyWindowTranslucency()
        applyNotificationsEnabled()
        applyDockBounce()
        applyNotificationSound()
        applyToolbarMode()
        applyNotificationBadgeEnabled()
        applyInactivePaneMute()
        applySidebarBackgroundShift()
        applySidebarFontSize()
        applyInterfaceFontSize()
        applyQuickTerminalSizePercent()
        applyBaseFontSize()
        applyAgentStatusColors()
        applyAgentStatusShapes()
        applyWorkspaceRowClickExpands()
        applyAttentionButtonEnabled()
        applyInterfaceElements()
        applyAutoHideSidebarInactiveWindows()
        ensureStarterKeymap()
        loadKeymap()
        ensureStarterGhosttyConfig()
        ensureStarterRestoreDenylist()
        loadRestoreDenylist()
        // follow the macOS appearance: `SystemAppearanceObserver` posts the resolved `isDark`, threaded
        // straight into `appearanceChanged`.
        NotificationCenter.default.addObserver(forName: .agtermSystemAppearanceChanged, object: nil,
                                               queue: .main) { [weak self] note in
            guard let isDark = note.userInfo?["isDark"] as? Bool else { return }
            MainActor.assumeIsolated { self?.appearanceChanged(isDark: isDark) }
        }
    }

    /// The frontmost session's focused-pane cwd, used only to seed directory-picking panels near the user's
    /// current work — Settings views need no library access of their own.
    var activeSessionCwd: String? { library.activeStore?.activeSession?.focusedCwd }

    /// The appearance side the last config feed applied, suppressing same-side reloads (KVO `[.initial]` at
    /// launch, plus coalesced bursts). Starts `false` because a host-loaded config always resolves LIGHT: a
    /// light launch skips the seeding reload, a dark launch takes exactly one (re-siding the chrome colors
    /// via the CONFIG_CHANGE clone). Read outside only by the UI-test `debug.appearance` probe (bare form).
    private(set) var lastAppliedIsDark = false

    /// Re-feed the config on a macOS appearance flip so libghostty re-resolves the dual theme — the
    /// system→settings half of light/dark sync. No-op unless following with both slots set, or when the
    /// side is unchanged (`lastAppliedIsDark`). The RAW `theme = light:,dark:` text is IDENTICAL across
    /// flips, so `writeGhosttyConfig()`/`apply()` would skip the reload — reload DIRECTLY instead; ghostty
    /// already recorded the scheme (`set_color_scheme`) and re-resolves on `update_config`. Debounced, the
    /// latest posted side wins. An automatic flip PRESERVES each session's ⌘+/⌘− zoom (unlike File ▸
    /// Reload / `config.reload`) — wiping it on an OS schedule would surprise. A zero-surface reload is
    /// safe: the app-scheme set re-sides the chrome clone. `isDark` is the KVO-delivered side, never
    /// re-read from a view (whose `effectiveAppearance` lags around sleep/wake).
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

    /// Whether the slot rendering RIGHT NOW is the dark one. The current-appearance picker and the theme
    /// preview target this slot so on-screen edits stick.
    private var rendersDarkSlot: Bool { settings.followSystemAppearance == true && GhosttyApp.currentIsDark() }

    /// Set the light/single slot — the control channel's `theme set <name>`. A name keeps the dark side
    /// (syncing stays on); nil ("default ghostty") clears everything, since a nil side can't be a dual slot.
    func setLightTheme(_ value: String?) {
        settings.theme = value
        if value == nil { settings.darkTheme = nil; settings.followSystemAppearance = nil }
        persistAndApply()
    }

    /// Set the dark slot — the control channel's `theme set --dark`. A name turns syncing on, seeding the
    /// light side from the current theme else `defaultLightTheme` (ghostty's built-in can't be a dual
    /// slot); `none`/nil turns syncing off.
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

    /// Settings picker 1: the theme for the CURRENT appearance (`rendersDarkSlot`), with no relabel.
    func setThemeForCurrentAppearance(_ value: String?) {
        if rendersDarkSlot { settings.darkTheme = value } else { settings.theme = value }
        persistAndApply()
    }

    /// Settings alternate picker (shown only while following): the theme for the OTHER appearance. Clearing
    /// the dark slot routes through `setDarkTheme(nil)` so following is never left ON with a nil dark slot.
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

    /// Settings "Follow system appearance" toggle. ON seeds the other slot from the current theme (a
    /// well-formed dual with no visual change). OFF collapses to the on-screen theme so there is no flip.
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

    /// The light side seeded when a dark theme is chosen while `theme` is nil/empty (ghostty's built-in
    /// cannot be a dual side); a bundled theme, so the pick composes a well-formed dual value.
    static let defaultLightTheme = "Builtin Light"

    func setNotificationsEnabled(_ value: Bool?) { settings.notificationsEnabled = value; persistAndApply() }
    /// Set the toolbar row mode (nil = compact). Nils the legacy `compactToolbar` shim so it evaporates
    /// from `settings.json` on the next save; the Settings picker maps `.compact` back to nil.
    func setToolbarMode(_ mode: ToolbarMode?) { settings.toolbarMode = mode?.rawValue; settings.compactToolbar = nil; persistAndApply() }
    func setNotificationBadgeEnabled(_ value: Bool?) { settings.notificationBadgeEnabled = value; persistAndApply() }
    func setDockBounce(_ mode: DockBounce?) { settings.dockBounce = mode?.rawValue; persistAndApply() }
    /// Persist the system sound played when a notification is delivered (nil/empty = none). Not a ghostty
    /// key; the `NotificationManager` mirror is read on the next notification, like `dockBounce`.
    func setNotificationSoundName(_ name: String?) { settings.notificationSoundName = name; persistAndApply() }
    func setMouseScrollMultiplier(_ value: Double?) { settings.mouseScrollMultiplier = value; persistAndApply() }
    // ghostty key (right-click-action): persistAndApply() rewrites the conf and reloads surfaces live.
    func setRightClickPaste(_ value: Bool?) { settings.rightClickPaste = value; persistAndApply() }
    // ghostty keys (cursor-style / cursor-style-blink). A reload re-applies both to the panes already
    // open, though only while a pane's cursor still follows the configured default: a program that set its
    // own shape with DECSCUSR keeps that until it resets.
    func setCursorStyle(_ value: AppSettings.CursorStyle?) { settings.cursorStyle = value?.rawValue; persistAndApply() }
    func setCursorBlink(_ value: Bool?) { settings.cursorBlink = value; persistAndApply() }
    // sidebar behavior, not a ghostty key; the Coordinator reads the mirror on the next click.
    func setWorkspaceRowClickExpands(_ value: Bool?) { settings.workspaceRowClickExpands = value; persistAndApply() }
    func setInactivePaneMuteStrength(_ value: Int?) { settings.inactivePaneMuteStrength = value; persistAndApply() }
    func setSidebarBackgroundShift(_ value: Int?) { settings.sidebarBackgroundShift = value; persistAndApply() }
    func setSidebarFontSize(_ value: Double?) { settings.sidebarFontSize = value; persistAndApply() }
    func setInterfaceFontSize(_ value: Double?) { settings.interfaceFontSize = value; persistAndApply() }
    func setQuickTerminalSizePercent(_ value: Int?) {
        settings.quickTerminalSizePercent = value
        persistAndApply()
    }
    /// Persist the policy for the next launch. The current process keeps `GhosttyApp.launchRestoreMode`.
    ///
    /// Rolls memory back on a failed write, like `AppStore.setRestoreCommand`: a Settings picker or a
    /// `restore.mode` read that reported the new mode while disk kept the old one would promise a next
    /// launch nothing is going to deliver. Returns whether it reached disk.
    @discardableResult
    func setRestoreMode(_ value: RestoreMode) -> Bool {
        let previousMode = settings.restoreMode
        let previousLegacy = settings.restoreRunningCommand
        settings.restoreMode = value
        settings.restoreRunningCommand = nil
        do {
            try settingsStore.save(settings)
            return true
        } catch {
            settings.restoreMode = previousMode
            settings.restoreRunningCommand = previousLegacy
            return false
        }
    }
    // chrome flag, not a ghostty key: persistAndApply() no-ops the config but rides .agtermAppearanceChanged.
    func setAttentionButtonEnabled(_ value: Bool?) { settings.attentionButtonEnabled = value; persistAndApply() }

    /// Persist whether only the frontmost window shows its sidebar. Not a ghostty key, so `persistAndApply()`
    /// only pushes the `GhosttyApp` mirror; turning it ON collapses every inactive sidebar at once, not at
    /// the next focus change.
    func setAutoHideSidebarInactiveWindows(_ value: Bool?) {
        settings.autoHideSidebarInactiveWindows = value
        persistAndApply()
        if value == true { library.applyInactiveWindowSidebarHiding() }
    }

    /// Show or hide one title-bar / sidebar-footer chrome element (an empty result maps back to nil so
    /// `settings.json` stays minimal). Not a ghostty key — it rides `.agtermAppearanceChanged`, so every
    /// window re-gates live. Mutates the RAW string set: `resolvedHiddenInterfaceElements` drops unknown
    /// names, which would erase an element a newer build hid.
    func setInterfaceElementVisible(_ element: InterfaceElement, visible: Bool) {
        var hidden = Set(settings.hiddenInterfaceElements ?? [])
        if visible { hidden.remove(element.rawValue) } else { hidden.insert(element.rawValue) }
        settings.hiddenInterfaceElements = hidden.isEmpty ? nil : hidden.sorted()
        persistAndApply()
    }

    /// Persist whether agterm inherits the user's global `~/.config/ghostty/config`, then FULLY reload. NOT
    /// a `ghosttyConfigLines()` key, so `persistAndApply`'s text-diff guard would skip the reload — but it
    /// changes WHICH files `loadConfig` reads, hence the unconditional path (like `setConfigDirectory`).
    /// nil/false = off: agterm stays self-contained, with the scoped `ghostty.conf` for customizations.
    func setInheritGlobalGhosttyConfig(_ value: Bool?) {
        settings.inheritGlobalGhosttyConfig = value
        try? settingsStore.save(settings)
        reloadGhosttyConfig()
    }
    func setActiveStatusColorHex(_ hex: String?) { settings.activeStatusColorHex = hex; persistAndApply() }
    func setBlockedStatusColorHex(_ hex: String?) { settings.blockedStatusColorHex = hex; persistAndApply() }
    func setCompletedStatusColorHex(_ hex: String?) { settings.completedStatusColorHex = hex; persistAndApply() }
    /// Persist an agent-status glyph silhouette as the `StatusShape` raw string (nil = the default plain
    /// circle, keeping `settings.json` minimal). `persistAndApply` repaints the visible glyphs live.
    func setActiveStatusShape(_ shape: StatusShape?) { settings.activeStatusShape = shape?.rawValue; persistAndApply() }
    func setBlockedStatusShape(_ shape: StatusShape?) { settings.blockedStatusShape = shape?.rawValue; persistAndApply() }
    func setCompletedStatusShape(_ shape: StatusShape?) { settings.completedStatusShape = shape?.rawValue; persistAndApply() }
    /// Persist the system sound played when a session enters `blocked` (nil/empty = none). Not a ghostty
    /// key and nothing renders it continuously, so it only saves — `ControlServer` reads it on demand.
    func setBlockedStatusSoundName(_ name: String?) { settings.blockedStatusSoundName = name; try? settingsStore.save(settings) }
    /// Persist where a new (⌘T) session opens (nil = home). Read only at the next `AppActions.newSession()`,
    /// so it just saves — no config rewrite or surface reload.
    func setNewSessionDirectory(_ value: String?) { settings.newSessionDirectory = value; try? settingsStore.save(settings) }
    /// Persist the fixed directory used when `newSessionDirectory` is `custom` (nil/empty falls back to home).
    func setNewSessionCustomDirectory(_ value: String?) { settings.newSessionCustomDirectory = value; try? settingsStore.save(settings) }
    /// Persist whether a GUI session close first asks for confirmation (nil = off). `AppActions` reads it on
    /// demand at close time, so it just saves.
    func setConfirmCloseSession(_ value: Bool?) { settings.confirmCloseSession = value; try? settingsStore.save(settings) }
    /// Persist whether GUI closes use the short undo grace period. nil = on; false = close immediately.
    func setCloseGraceUndoEnabled(_ value: Bool?) { settings.closeGraceUndoEnabled = value; try? settingsStore.save(settings) }
    /// Persist that the first-run welcome has been shown, so it never appears again on this state directory.
    func setWelcomeShown(_ value: Bool?) { settings.welcomeShown = value; try? settingsStore.save(settings) }
    /// Persist the user-idle auto-follow timeout (nil = off) and push it into every open window's `AppStore`
    /// (a newly opened window seeds itself via `applyAutoFollow(to:)`).
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

    /// Apply a new background opacity live WITHOUT saving — the live-drag half of the slider; each tick
    /// reschedules `backgroundSaveDebouncer`, so the disk write coalesces to one on settle.
    func previewBackgroundOpacity(_ value: Double?) {
        settings.backgroundOpacity = value
        apply()
        scheduleBackgroundSave()
    }

    /// Apply a new background blur live — the blur counterpart of `previewBackgroundOpacity`.
    func previewBackgroundBlur(_ value: Int?) {
        settings.backgroundBlur = value
        apply()
        scheduleBackgroundSave()
    }

    /// Persist the current opacity/blur NOW — the slider's `onEditingChanged` drag-end commit. Save-only:
    /// the value is already live from the preview applies.
    func commitBackgroundSettings() { backgroundSaveDebouncer.flush() }

    private func scheduleBackgroundSave() {
        backgroundSaveDebouncer.schedule(after: Self.backgroundSaveInterval) { [weak self] in
            guard let self else { return }
            // pin the theme to the last committed value — a live preview mutates it in place without
            // persisting. opacity/blur, what this save is for, keep their live values.
            var snapshot = settings
            snapshot.theme = committedTheme
            snapshot.darkTheme = committedDarkTheme
            try? settingsStore.save(snapshot)
        }
    }

    /// Apply a theme live WITHOUT persisting — the action-palette picker's preview half. Sets the
    /// CURRENT-appearance slot immediately (so a commit captures the latest even if the apply hasn't fired)
    /// but DEBOUNCES the expensive `apply()` and skips `settingsStore.save`, so browsing never touches
    /// `settings.json`. Enter commits via `commitTheme()`, Esc reverts via `revertThemePreview(theme:darkTheme:)`.
    func previewTheme(_ value: String?) {
        if rendersDarkSlot { settings.darkTheme = value } else { settings.theme = value }
        previewThemeDebouncer.schedule(after: Self.previewThemeDebounceInterval) { [weak self] in self?.apply() }
    }

    /// Restore BOTH theme slots IMMEDIATELY, cancelling any pending debounced preview — the picker's revert
    /// half (Esc / scrim / mode switch / unmount). Synchronous, so no queued preview fires after. Both
    /// slots, not just the on-screen one, or an appearance flip mid-preview strands a previewed value in
    /// the other; `AppActions` snapshots the pair on open and passes it straight back.
    func revertThemePreview(theme: String?, darkTheme: String?) {
        previewThemeDebouncer.cancel()
        settings.theme = theme
        settings.darkTheme = darkTheme
        apply()
    }

    /// Persist the picker's final theme — the commit half, on Enter. Only the slot rendering AT ENTER-TIME
    /// keeps its browsed value; the OTHER is restored to `nonActiveOriginal` (its value when the picker
    /// opened), or a mid-preview appearance flip persists an unconfirmed value into the off-screen slot
    /// that resurfaces on the next flip. Flushes the pending preview first, restores the off-screen slot,
    /// re-applies ONLY if that changed the config (the flip case), then saves; a no-flip commit is save-only.
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

    /// Flush pending debounced settings writes synchronously, from `applicationWillTerminate`: a KEYBOARD
    /// opacity/blur adjustment never fires the slider's drag-end commit, so quitting inside its ~0.3 s
    /// window would lose the write (the theme preview flushes alongside, for symmetry).
    func flushPendingSaves() {
        backgroundSaveDebouncer.flush()
        previewThemeDebouncer.flush()
    }

    /// Reset the whole Agent Status section (the "Reset to defaults" button): glyph colors, shapes, sound.
    func resetAgentStatus() {
        settings.activeStatusColorHex = nil
        settings.blockedStatusColorHex = nil
        settings.completedStatusColorHex = nil
        settings.activeStatusShape = nil
        settings.blockedStatusShape = nil
        settings.completedStatusShape = nil
        settings.blockedStatusSoundName = nil
        persistAndApply()
    }

    /// Persist a new config directory and reload BOTH co-located files so neither lags the change (each
    /// posts its own diagnostics banner). nil falls back to what `ConfigPaths.configDirectory` resolves.
    func setConfigDirectory(_ value: String?) {
        settings.configDirectory = value
        try? settingsStore.save(settings)
        reloadKeymap()
        reloadGhosttyConfig()
    }

    /// Re-read `keymap.conf` and post `.agtermKeymapChanged` so the custom-command runner and action palette
    /// rebuild (menu shortcuts re-render off the `@Observable` `keymap`). Parse errors/conflicts surface as
    /// a banner, safe here because this runtime path runs after notification registration — the startup
    /// path posts from the scene `.task` instead.
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

    /// The resolved agterm-scoped `ghostty.conf` path: `<config dir>/ghostty.conf`, beside `keymap.conf`.
    private func ghosttyConfigURL() -> URL {
        ConfigPaths.ghosttyConfigPath(configDirectory: configDirectoryURL())
    }

    /// The resolved `ghostty.conf` path, exposed for the Edit ghostty.conf action (the overlay command).
    var ghosttyConfigPath: String { ghosttyConfigURL().path }

    /// The resolved restore-denylist path: `<config dir>/restore-denylist.conf`.
    private func restoreDenylistURL() -> URL {
        ConfigPaths.restoreDenylistPath(configDirectory: configDirectoryURL())
    }

    /// Read `restore-denylist.conf` into `GhosttyApp.shared.restoreDenylist`; a missing/unreadable file
    /// yields an empty denylist (restore everything). Read at launch, so an edit takes effect on the next.
    private func loadRestoreDenylist() {
        let text = (try? String(contentsOf: restoreDenylistURL(), encoding: .utf8)) ?? ""
        GhosttyApp.shared.setRestoreDenylist(CommandRestore.parseDenylist(text))
    }

    /// Write a commented starter `restore-denylist.conf` (and its directory) when none exists, listing the
    /// terminal multiplexers — the one class of program that just starts a fresh empty session on re-run.
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

    /// The commented starter `restore-denylist.conf` text.
    private func starterRestoreDenylistText() -> String {
        """
        # restore-denylist.conf: programs NOT to re-run in rerun restore mode. One command name per line,
        # matched on the command's basename. Blank lines and lines
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

    /// Rebuild the ghostty config from all sources (re-reading the externally edited agterm-scoped
    /// `ghostty.conf`) and broadcast it to every live surface, clearing per-session font overrides.
    /// UNCONDITIONAL, unlike `apply()`'s unchanged-text skip — an external edit always has something to
    /// re-read. Posts `.agtermAppearanceChanged` for the chrome, and a warning banner on diagnostics.
    /// Returns the diagnostic count (0 = clean) across ALL config sources, since libghostty diagnostics
    /// carry no source-file attribution. Drives File ▸ Reload Config, the Edit-ghostty overlay close, a
    /// Key Mapping directory change, and the `config.reload` control command.
    @discardableResult
    func reloadGhosttyConfig() -> Int {
        let count = reloadConfigClearingSessionZoom()
        NotificationCenter.default.post(name: .agtermAppearanceChanged, object: nil)
        if count > 0 { NotificationManager.shared.notifyConfigDiagnostics(count: count) }
        return count
    }

    /// Clear every session's ⌘+/⌘− zoom BEFORE rebuilding + rebroadcasting the config, returning the
    /// rebuilt config's diagnostic count. The ORDER is load-bearing: the reload re-asserts each surface's
    /// per-session overlay (`reapplySessionConfigIfNeeded`), re-emitting `font-size` from
    /// `session.fontSize` — clearing first makes that read nil, so a watermarked pane drops its zoom on
    /// screen and the snapshot persists `fontSize == nil` in agreement (resetting AFTER leaves the surface
    /// zoomed while the model says nil). Both EXPLICIT callers funnel here; the automatic appearance flip
    /// is the one exception (`reloadConfigPreservingSessionZoom`).
    @discardableResult
    private func reloadConfigClearingSessionZoom() -> Int {
        // every reload re-sides the config to the CURRENT appearance, so record it on ALL reload paths,
        // not just the flip, or `appearanceChanged()`'s same-side suppression fires one spurious reload.
        let isDark = GhosttyApp.currentIsDark()
        lastAppliedIsDark = isDark
        // open windows reset live, closed ones by rewriting their snapshot file (the shared config reset
        // every surface to the default size, so a closed window mustn't reopen later overriding the new default).
        library.resetSessionFontSizesAllWindows()
        return GhosttyApp.shared.reloadConfig(surfaces: liveSurfaces(), isDark: isDark)
    }

    /// The appearance-flip variant: re-feeds the config so libghostty re-resolves the dual theme but KEEPS
    /// every session's ⌘+/⌘− zoom — after the broadcast `reapplySessionConfigIfNeeded` re-emits each
    /// session's `fontSize` per surface. An automatic OS flip (or a dark launch's seeding reload) must not
    /// silently wipe zoom; only explicit reloads carry that contract. The latch records the `isDark`
    /// actually applied.
    private func reloadConfigPreservingSessionZoom(isDark: Bool) {
        GhosttyApp.shared.reloadConfig(surfaces: liveSurfaces(), isDark: isDark)
        lastAppliedIsDark = isDark
    }

    /// Read `keymap.conf` into `keymap` + `keymapDiagnostics`. A MISSING file is not an error (empty keymap,
    /// no diagnostics); one that EXISTS but can't be read (permissions, invalid UTF-8) becomes a single
    /// line-0 diagnostic so the warning banner fires.
    private func loadKeymap() {
        let loaded = KeymapStore(configDirectory: configDirectoryURL()).load()
        keymap = loaded.keymap
        keymapDiagnostics = loaded.diagnostics
    }

    /// Write a commented starter `keymap.conf` (and its directory) when none exists, documenting every
    /// built-in action name + default, the `map`/`command` syntax, and the `{AGT_X}` tokens.
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

    /// Write a commented starter `ghostty.conf` (and its directory) when none exists. Seeded AFTER
    /// GhosttyApp's first `loadConfig`, but harmless: the starter is all comments, a no-op.
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

    /// The commented starter `ghostty.conf` text; every line is a comment, so a fresh file is a no-op.
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
        # NOTE: Values agterm emits from Settings load after this file and win. See the current list at
        # https://agterm.com/docs#ghostty; put other keys here.
        #
        # NOT SUPPORTED: the `ssh-env` and `ssh-terminfo` shell-integration features. They work by
        # wrapping `ssh` as a call to the `ghostty` CLI absent from agterm's bundle,
        # so agterm forces them back off. Your other shell-integration-features flags are kept.

        """
    }

    private func persistAndApply() {
        try? settingsStore.save(settings)
        committedTheme = settings.theme
        committedDarkTheme = settings.darkTheme
        apply()
    }

    /// Apply the current `settings` to the running app WITHOUT persisting: rewrite the ghostty config and
    /// rebroadcast (only when the generated text changed), then refresh translucency, toggles and chrome.
    private func apply() {
        // rebuild only when the generated config TEXT changed: an opacity drag within the translucent
        // range, or a blur change, leaves it identical, and re-syncing the window alone avoids a rebuild
        // (which resets every surface to the default font size) per slider tick.
        let opacityBefore = GhosttyApp.shared.windowOpacity
        if writeGhosttyConfig() {
            reloadConfigClearingSessionZoom()
        }
        applyWindowTranslucency()
        // a `.color` background bakes the window opacity into its per-surface `background-opacity` at
        // apply time, so re-assert on any opacity change: reloadConfig's own re-assert runs BEFORE
        // `applyWindowTranslucency` updates the opacity, and a within-range drag doesn't reload at all.
        // Guarded to `.color` so other sessions aren't rebuilt per tick (blur composites in AppKit).
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
        applyInterfaceFontSize()
        applyQuickTerminalSizePercent()
        applyBaseFontSize()
        applyAgentStatusColors()
        applyAgentStatusShapes()
        applyWorkspaceRowClickExpands()
        applyAttentionButtonEnabled()
        applyInterfaceElements()
        applyAutoHideSidebarInactiveWindows()
        // refresh the chrome (title bar + sidebar + quick terminal) for the new terminal color,
        // translucency and toolbar style now, not at the next window re-key.
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
        GhosttyApp.shared.setToolbarMode(settings.effectiveToolbarMode)
    }

    private func applyNotificationBadgeEnabled() {
        GhosttyApp.shared.setNotificationBadgeEnabled(settings.notificationBadgeEnabled ?? true)
    }

    private func applyWorkspaceRowClickExpands() {
        GhosttyApp.shared.setWorkspaceRowClickExpands(settings.workspaceRowClickExpands ?? true)
    }

    private func applyAttentionButtonEnabled() {
        GhosttyApp.shared.setAttentionButtonEnabled(settings.attentionButtonEnabled ?? false)
    }

    private func applyInterfaceElements() {
        GhosttyApp.shared.setHiddenInterfaceElements(settings.resolvedHiddenInterfaceElements)
    }

    private func applyAutoHideSidebarInactiveWindows() {
        GhosttyApp.shared.setAutoHideSidebarInactiveWindows(settings.autoHideSidebarInactiveWindows ?? false)
    }

    /// Push the current auto-follow configuration into one window's store, from `ContentView.resolveStore`
    /// so a newly opened window honors the setting. The store is host-free and can't read settings itself.
    func applyAutoFollow(to store: AppStore) {
        let timeout = AppSettings.AutoFollowAttention(tolerant: settings.autoFollowAttention).timeout
        store.setAutoFollow(timeout: timeout, stayOnActive: settings.autoFollowStayOnActive ?? false)
    }

    /// Fan auto-follow out to every open window's store — the settings-change broadcast and the launch seed
    /// from the scene `.task`. Idempotent: re-pushing the same values no-ops in `AppStore.setAutoFollow`.
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
        GhosttyApp.shared.setSidebarFontSize(settings.effectiveSidebarFontSize)
    }

    private func applyInterfaceFontSize() {
        GhosttyApp.shared.setInterfaceFontSize(settings.effectiveInterfaceFontSize)
    }

    private func applyQuickTerminalSizePercent() {
        GhosttyApp.shared.setQuickTerminalSizePercent(settings.effectiveQuickTerminalSizePercent)
    }

    private func applyBaseFontSize() {
        GhosttyApp.shared.setBaseFontSize(settings.fontSize)
    }

    private func applyAgentStatusColors() {
        GhosttyApp.shared.setAgentStatusColors(activeHex: settings.activeStatusColorHex,
                                               blockedHex: settings.blockedStatusColorHex,
                                               completedHex: settings.completedStatusColorHex)
    }

    private func applyAgentStatusShapes() {
        GhosttyApp.shared.setAgentStatusShapes(active: settings.effectiveStatusShape(for: .active),
                                               blocked: settings.effectiveStatusShape(for: .blocked),
                                               completed: settings.effectiveStatusShape(for: .completed))
    }

    /// Write the ghostty config lines (font/size/theme + the translucency pins) to the file
    /// `GhosttyApp.loadConfig` reads. Returns true when the content changed, so the caller can skip the reload.
    private func writeGhosttyConfig() -> Bool {
        let url = GhosttyApp.settingsConfigURL
        // emit the raw single/dual theme, no appearance resolution: a dual value is stable across flips,
        // so `appearanceChanged` reloads directly rather than diffing this text.
        let text = settings.ghosttyConfigLines().joined(separator: "\n") + "\n"
        if (try? String(contentsOf: url, encoding: .utf8)) == text { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    /// Every live ghostty surface: all open windows' sessions (primary + split + scratch) and quick terminals.
    private func liveSurfaces() -> [GhosttySurfaceView] {
        var views = library.openIDs()
            .compactMap { library.store(for: $0) }
            .flatMap(\.workspaces)
            .flatMap(\.sessions)
            .flatMap { [$0.surface, $0.splitSurface, $0.scratchSurface] }
            .compactMap { $0 as? GhosttySurfaceView }
        views += [QuickTerminalController.shared.currentSurface()].compactMap { $0 }
        return views
    }
}
