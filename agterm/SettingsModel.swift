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
    /// and `previewThemeImmediate`).
    private let previewThemeDebouncer = Debouncer()
    private static let previewThemeDebounceInterval: TimeInterval = 0.07

    /// Coalesces the opacity/blur slider's live drag into a single deferred `settings.json` write: the
    /// preview methods apply each tick WITHOUT saving and reschedule this, so the disk write fires once
    /// the slider settles. This persists KEYBOARD adjustments too (arrow keys don't fire the slider's
    /// `onEditingChanged`), while a mouse release flushes it immediately via `commitBackgroundSettings`.
    private let backgroundSaveDebouncer = Debouncer()
    private static let backgroundSaveInterval: TimeInterval = 0.3

    /// The theme as of the last real persist (`persistAndApply`/`commitTheme`), NOT updated by the
    /// live theme preview. The opacity/blur background-save debounce persists a snapshot pinned to
    /// this value instead of the in-flight `settings.theme`, so a slider write firing mid-preview
    /// can't leak an uncommitted previewed theme to `settings.json` (the preview persists only on
    /// commit; Esc reverts it in memory, and disk must never have seen it).
    private var committedTheme: String?

    init(library: WindowLibrary, settingsStore: SettingsStore) {
        self.library = library
        self.settingsStore = settingsStore
        self.settings = settingsStore.load()
        self.committedTheme = settings.theme
        // write the ghostty config from the loaded settings NOW — before GhosttyApp boots and reads it
        // (its loadConfig runs in applicationDidFinishLaunching, AFTER this App.init). The SEEDED default
        // theme (agterm) lives only in memory (load() seeds it; it isn't in settings.json), so without
        // this the launch config carries no theme line and the terminal renders ghostty's built-in until
        // the first settings change rewrites the conf. Idempotent: writeGhosttyConfig no-ops when the file
        // already matches (e.g. a user with an explicit theme already has it on disk).
        _ = writeGhosttyConfig()
        // mirror the persisted window translucency + notification toggle + compact toolbar + badge
        // toggle into their shared channels at launch, before any settings change fires.
        applyWindowTranslucency()
        applyNotificationsEnabled()
        applyCompactToolbar()
        applyNotificationBadgeEnabled()
        applyInactivePaneMute()
        applySidebarBackgroundShift()
        applyAgentStatusColors()
        // create the commented starter keymap on first launch, then load + parse it.
        ensureStarterKeymap()
        loadKeymap()
    }

    func setFontFamily(_ value: String?) { settings.fontFamily = value; persistAndApply() }
    func setFontSize(_ value: Double?) { settings.fontSize = value; persistAndApply() }
    func setTheme(_ value: String?) { settings.theme = value; persistAndApply() }
    func setNotificationsEnabled(_ value: Bool?) { settings.notificationsEnabled = value; persistAndApply() }
    func setCompactToolbar(_ value: Bool?) { settings.compactToolbar = value; persistAndApply() }
    func setNotificationBadgeEnabled(_ value: Bool?) { settings.notificationBadgeEnabled = value; persistAndApply() }
    func setMouseScrollMultiplier(_ value: Double?) { settings.mouseScrollMultiplier = value; persistAndApply() }
    func setInactivePaneMuteStrength(_ value: Int?) { settings.inactivePaneMuteStrength = value; persistAndApply() }
    func setSidebarBackgroundShift(_ value: Int?) { settings.sidebarBackgroundShift = value; persistAndApply() }
    func setActiveStatusColorHex(_ hex: String?) { settings.activeStatusColorHex = hex; persistAndApply() }
    func setBlockedStatusColorHex(_ hex: String?) { settings.blockedStatusColorHex = hex; persistAndApply() }
    func setCompletedStatusColorHex(_ hex: String?) { settings.completedStatusColorHex = hex; persistAndApply() }

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
            try? settingsStore.save(snapshot)
        }
    }

    /// Apply a theme live WITHOUT persisting it — the live-preview half of the action-palette theme
    /// picker (navigation/typing). Sets `settings.theme` immediately (so a commit captures the latest
    /// even if the apply hasn't fired yet) but DEBOUNCES the expensive `apply()` (config rewrite +
    /// surface reload + chrome refresh), so a burst of arrow/typing previews coalesces to one reload
    /// once the quiet window elapses. Skips `settingsStore.save`, so navigating themes doesn't touch
    /// `settings.json`; the picker commits with `commitTheme()` on Enter (which flushes the pending
    /// apply) or reverts with `previewThemeImmediate(original)` on Esc.
    func previewTheme(_ value: String?) {
        settings.theme = value
        previewThemeDebouncer.schedule(after: Self.previewThemeDebounceInterval) { [weak self] in self?.apply() }
    }

    /// Apply a theme live IMMEDIATELY (no debounce), cancelling any pending debounced preview — the
    /// revert half of the picker (Esc / scrim / mode switch / unmount). Synchronous so the original
    /// theme is restored with no debounce lag and no queued preview fires afterwards.
    func previewThemeImmediate(_ value: String?) {
        previewThemeDebouncer.cancel()
        settings.theme = value
        apply()
    }

    /// Persist the current settings — the commit half of the theme picker, called on Enter after one
    /// or more `previewTheme` applies. Flushes any pending debounced preview first, so the latest
    /// previewed theme is live NOW, then writes `settings.json`.
    func commitTheme() {
        previewThemeDebouncer.flush()
        try? settingsStore.save(settings)
        committedTheme = settings.theme
    }

    /// Flush any pending debounced settings writes synchronously — the quit path. The opacity/blur
    /// slider's debounced `settings.json` write (and the theme preview, for symmetry) holds a pending
    /// save for ~0.3 s after a KEYBOARD adjustment, which never fires the slider's drag-end commit;
    /// quitting within that window would otherwise lose it. Called from `applicationWillTerminate`.
    func flushPendingSaves() {
        backgroundSaveDebouncer.flush()
        previewThemeDebouncer.flush()
    }

    /// Clear all three agent-status colors back to the system defaults (the "Reset to defaults" button).
    func resetStatusColors() {
        settings.activeStatusColorHex = nil
        settings.blockedStatusColorHex = nil
        settings.completedStatusColorHex = nil
        persistAndApply()
    }

    /// Persist a new config directory (where `keymap.conf` lives) and reload the keymap from it. A nil
    /// value falls back to the default location resolved by `ConfigPaths.configDirectory`.
    func setConfigDirectory(_ value: String?) {
        settings.configDirectory = value
        try? settingsStore.save(settings)
        reloadKeymap()
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

    /// The resolved keymap file path: `<config dir>/keymap.conf`, where the config dir honors the
    /// explicit setting, else `AGTERM_STATE_DIR/config` (test isolation), else `~/.config/agterm`.
    private func keymapURL() -> URL {
        let configDir = ConfigPaths.configDirectory(
            setting: settings.configDirectory,
            stateDir: ProcessInfo.processInfo.environment["AGTERM_STATE_DIR"],
            home: FileManager.default.homeDirectoryForCurrentUser)
        return ConfigPaths.keymapPath(configDirectory: configDir)
    }

    /// The resolved `keymap.conf` path, exposed for the Edit Keymap action (the overlay command).
    var keymapPath: String { keymapURL().path }

    /// Read `keymap.conf` and parse it into `keymap` + `keymapDiagnostics`. A MISSING file is not an
    /// error: it yields an empty keymap with no diagnostics (the starter file is created at init). A
    /// file that EXISTS but can't be read (permissions, invalid UTF-8) is surfaced as a single line-0
    /// diagnostic so the warning banner fires, rather than being silently treated as missing.
    private func loadKeymap() {
        let url = keymapURL()
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let parsed = parseKeymap(text)
            keymap = parsed.keymap
            keymapDiagnostics = parsed.diagnostics
        } catch {
            keymap = Keymap(builtinOverrides: [:], commands: [])
            guard FileManager.default.fileExists(atPath: url.path) else {
                // truly missing — not an error.
                keymapDiagnostics = []
                return
            }
            keymapDiagnostics = [KeymapDiagnostic(line: 0, message: "could not read keymap.conf: \(error.localizedDescription)")]
        }
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
            try starterKeymapText().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            logger.notice("could not write starter keymap at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The commented starter `keymap.conf`: the two-verb syntax, every `BuiltinAction` raw name with
    /// its shipped default chord (or "no default"), and the `{AGT_X}` token list. Every line is a
    /// comment so a fresh file rebinds nothing.
    private func starterKeymapText() -> String {
        // pad the action name column to the longest raw name (+ a 2-space gutter) so a future action
        // longer than any current one can never silently truncate.
        let nameColumnWidth = (BuiltinAction.allCases.map { $0.rawValue.count }.max() ?? 0) + 2
        let actionLines = BuiltinAction.allCases.map { action -> String in
            // a default whose key can't round-trip through the keymap grammar (e.g. increase_font_size's
            // `+`, which clashes with the `+` separator) is documented as not file-expressible rather
            // than printed as an unparseable token like `cmd++`.
            let chord = action.defaultChord.map(chordSyntax) ?? "(no default)"
            return "#   \(action.rawValue.padding(toLength: nameColumnWidth, withPad: " ", startingAt: 0))\(chord)"
        }.joined(separator: "\n")
        let tokenLines = CommandContext.tokenNames.map { "#   {\($0)}" }.joined(separator: "\n")

        return """
        # agterm keymap — a kitty-flavored config for rebinding built-in shortcuts and defining
        # custom shell commands. Edit this file and run View ▸ Reload Keymap (or `agtermctl keymap
        # reload`) to apply. Blank lines and lines starting with `#` are ignored.
        #
        # Two verbs:
        #
        #   map <chord> <action>
        #       Rebind a built-in action to a single chord (no leader sequences for built-ins).
        #       Chords use kitty syntax: mods joined by `+`, e.g. `cmd+shift+d`, `ctrl+\\``.
        #       Mods: ctrl, cmd, opt, shift. Example:
        #
        #           map cmd+shift+d  toggle_split
        #
        #   command "<name>" [chord] <shell...>
        #       Define a custom command, shown in the action palette marked `custom`. The quoted
        #       name may contain spaces. An optional chord (single chord OR a leader like `ctrl+a>g`)
        #       binds it to a key; the chord MUST include a modifier (a bare key is rejected and the
        #       line becomes palette-only). Omit the chord for a palette-only command. The rest of the
        #       line is run via `/bin/sh -c`. Examples:
        #
        #           command "Open in Zed"  cmd+shift+e  open -a Zed {AGT_SESSION_PWD}
        #           command "Lazygit"      ctrl+a>g     lazygit
        #           command "Deploy"                    ./deploy.sh
        #
        # Built-in actions (raw name → shipped default chord):
        #
        \(actionLines)
        #
        # Custom-command tokens (expanded in the shell line and exported as $AGT_X env vars):
        #
        \(tokenLines)
        #
        # NOTE: a {AGT_X} token is substituted RAW into the /bin/sh line — convenient, but unsafe for
        # content you don't control. {AGT_SELECTION} is the obvious case, but a remote host can also set
        # the session title (OSC) and the working directory (OSC 7), so {AGT_SESSION_NAME} and
        # {AGT_SESSION_PWD} are equally unsafe raw. For any such content prefer the matching $AGT_X
        # environment variable, QUOTED, e.g. "$AGT_SELECTION".
        #
        # Uncomment and edit a line below to start.
        # map cmd+shift+d toggle_split

        """
    }

    /// Render a `Chord` back into the kitty syntax the user writes (`cmd+shift+d`), for the starter
    /// file's documentation of the default shortcuts. Mods are ordered ctrl, cmd, opt, shift. Returns
    /// `(not expressible)` when the chord's key is a grammar separator (`+`/`>`) that can't round-trip
    /// through `parseKeybind` — e.g. increase_font_size's `+`, which would render as the unparseable
    /// `cmd++`.
    private func chordSyntax(_ chord: Chord) -> String {
        var parts: [String] = []
        if chord.mods.contains(.control) { parts.append("ctrl") }
        if chord.mods.contains(.command) { parts.append("cmd") }
        if chord.mods.contains(.option) { parts.append("opt") }
        if chord.mods.contains(.shift) { parts.append("shift") }
        parts.append(chord.key)
        let rendered = parts.joined(separator: "+")
        // verify the rendered string round-trips: a key like `+`/`>` produces an unparseable token.
        guard parseKeybind(rendered) == [chord] else { return "(not expressible)" }
        return rendered
    }

    private func persistAndApply() {
        try? settingsStore.save(settings)
        committedTheme = settings.theme
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
        if writeGhosttyConfig() {
            GhosttyApp.shared.reloadConfig(surfaces: liveSurfaces())
            // clear per-session font overrides in EVERY window — open ones live, closed ones by
            // rewriting their snapshot file (the shared config reset every surface to the default
            // size, so a closed window mustn't reopen later overriding the new default).
            library.resetSessionFontSizesAllWindows()
        }
        applyWindowTranslucency()
        applyNotificationsEnabled()
        applyCompactToolbar()
        applyNotificationBadgeEnabled()
        applyInactivePaneMute()
        applySidebarBackgroundShift()
        applyAgentStatusColors()
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

    private func applyCompactToolbar() {
        GhosttyApp.shared.setCompactToolbar(settings.compactToolbar ?? false)
    }

    private func applyNotificationBadgeEnabled() {
        GhosttyApp.shared.setNotificationBadgeEnabled(settings.notificationBadgeEnabled ?? true)
    }

    private func applyInactivePaneMute() {
        GhosttyApp.shared.setInactivePaneMuteStrength(
            settings.inactivePaneMuteStrength ?? AppSettings.defaultInactivePaneMuteStrength)
    }

    private func applySidebarBackgroundShift() {
        GhosttyApp.shared.setSidebarBackgroundShift(
            settings.sidebarBackgroundShift ?? AppSettings.defaultSidebarBackgroundShift)
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
