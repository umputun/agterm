// adapted from thdxg/macterm (MIT)

import agtermCore
import AppKit
import Foundation
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.umputun.agterm", category: "GhosttyApp")

/// Manages the libghostty application lifecycle: init, config, tick loop.
@MainActor
final class GhosttyApp {
    static let shared = GhosttyApp()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    /// Parse diagnostics from the most recent `loadConfig`, reset each load, across ALL sources (bundled
    /// defaults, `~/.config/ghostty/config`, the agterm-scoped `ghostty.conf`, the UI settings conf) —
    /// libghostty attributes none to a file. `reloadConfig` surfaces it for the Reload Config /
    /// `config.reload` warning; the Console log names the offending line.
    private(set) var lastConfigDiagnosticsCount = 0
    /// Terminal background from the resolved config; tints the window so the title bar blends with the
    /// terminal instead of the default titlebar material. Nil when unread.
    private(set) var terminalBackgroundColor: NSColor?
    /// Terminal foreground from the resolved config. The chrome (sidebar rows, title-bar text + buttons) uses
    /// it so non-terminal text tracks the theme, not the system label color. Nil when unread.
    private(set) var terminalForegroundColor: NSColor?
    /// Whether the active theme reads as dark, by perceived luminance of the WASHED sidebar background (theme
    /// background plus sidebar-tint wash) — the color the disclosure triangle sits on, so a strong tint pushing
    /// a near-threshold theme past the midpoint still classifies right. Pins AppKit-drawn chrome to the theme,
    /// not the macOS appearance, so a light theme under dark mode draws dark, visible chrome. Dark when unread.
    var terminalThemeIsDark: Bool {
        guard let bg = terminalBackgroundColor?.usingColorSpace(.sRGB) else { return true }
        let shiftAmount = AppSettings.sidebarShiftAmount(strength: sidebarBackgroundShift)
        return ThemeBrightness.isDark(red: Double(bg.redComponent), green: Double(bg.greenComponent),
                                      blue: Double(bg.blueComponent), shiftAmount: shiftAmount)
    }
    /// The theme's `selection-background`; the selected sidebar row's pill uses it to match the terminal's own
    /// selection. Nil when the theme doesn't set it (the row falls back to a soft white wash).
    private(set) var terminalSelectionBackgroundColor: NSColor?
    /// The selected sidebar row's text: theme `selection-foreground`, else a black/white contrast of the
    /// selection-background when only that is set. Nil if neither is set.
    private(set) var terminalSelectionForegroundColor: NSColor?
    /// Window translucency the chrome composites at the AppKit level — background opacity (0...1) + CGS blur
    /// radius, opaque by default. NOT ghostty-resolved: `WindowAppearance.sync` reads, `SettingsModel` writes.
    private(set) var windowOpacity: Double = 1
    private(set) var windowBlurRadius: Int = 0
    /// Title-bar row state: normal stacks the cwd subtitle, compact is one short row, hidden drops the row and
    /// the traffic lights for a full-bleed terminal; defaults `.compact` (a nil `settings.toolbarMode`). NOT
    /// ghostty-resolved: `SettingsModel` writes, the reader (`WindowContentView` / `WindowAppearance.sync`)
    /// mirrors it into view state, the re-render rides `.agtermAppearanceChanged` — the settings-mirrored
    /// pattern the properties below share.
    private(set) var toolbarMode: ToolbarMode = .compact
    /// Whether the sidebar draws the red unseen-notification count badge. The sidebar Coordinator reads it
    /// (gating the count to 0 when off); settings-mirrored like `toolbarMode`.
    private(set) var notificationBadgeEnabled: Bool = true
    /// Whether a restored pane re-runs its last clean-quit foreground command; the surface factories read it to
    /// decide whether to feed that command as `initial_input`. Affects only the next restore — no live
    /// re-render notification.
    private(set) var restoreRunningCommand: Bool = false
    /// Whether the window title bar shows the attention bell icon; off by default. The title bar reads it via
    /// `WindowContentView`'s mirrored chrome state; settings-mirrored like `toolbarMode`.
    private(set) var attentionButtonEnabled: Bool = false
    /// Which title-bar / sidebar chrome elements are hidden, empty by default. `WindowContentView` gates each
    /// element from its mirror; settings-mirrored like `toolbarMode`.
    private(set) var hiddenInterfaceElements: Set<InterfaceElement> = []
    /// Whether only the frontmost window shows its sidebar, collapsing every other open window's; off by
    /// default. `WindowAccessor.reportFrontmost` reads it per frontmost change to gate the `WindowLibrary`.
    private(set) var autoHideSidebarInactiveWindows: Bool = false
    /// Program basenames NOT to re-run on restore: the parsed user-editable `restore-denylist.conf` (seeded
    /// with the terminal multiplexers), read at launch only; consulted via `CommandRestore.shouldRestore`.
    private(set) var restoreDenylist: Set<String> = []
    /// Inactive-pane and panel-backdrop text mute strength on the 0...10 scale.
    /// `WindowContentView.muteWashOpacity` reads it (via `AppSettings.muteOpacity`); settings-mirrored
    /// like `toolbarMode`.
    private(set) var inactivePaneMuteStrength: Int = AppSettings.defaultInactivePaneMuteStrength
    /// How much darker/lighter the sidebar background is than the terminal (0...10, 5 = neutral). `ContentView`
    /// renders the wash via `AppSettings.sidebarShiftAmount`; settings-mirrored like `toolbarMode`.
    private(set) var sidebarBackgroundShift: Int = AppSettings.defaultSidebarBackgroundShift
    /// The sidebar row-text point size. The sidebar Coordinator reads it for each row's font and the derived
    /// row height (via `AppSettings.sidebarRowHeight`); settings-mirrored like `toolbarMode`.
    private(set) var sidebarFontSize: CGFloat = CGFloat(AppSettings.defaultSidebarFontSize)
    /// The base terminal font size in points (the Settings default; nil → the ghostty built-in). The renderer
    /// never reads it — it is the size a session with a nil `session.fontSize` reverts to, which the dashboard
    /// font-override clear needs to recognize its own async CELL_SIZE report (`pendingFontRestore`).
    private(set) var baseFontSize: Double = DashboardLayout.ghosttyDefaultFontSize
    /// The agent-status glyph colors — active defaults to a muted lavender-grey (`#DBD9E6`), blocked/completed
    /// to system orange/green. `StatusIconView` reads them when building the glyph, `SettingsModel` writes
    /// them (from the user's hex or the default); settings-mirrored like `toolbarMode`.
    static let defaultActiveStatusColor: NSColor = NSColor(agtermHex: "#DBD9E6") ?? .systemBlue
    private(set) var activeStatusColor: NSColor = GhosttyApp.defaultActiveStatusColor
    private(set) var blockedStatusColor: NSColor = .systemOrange
    private(set) var completedStatusColor: NSColor = .systemGreen
    /// The agent-status glyph silhouettes, nil meaning the built-in plain circle. The two render sites read
    /// them through `statusSymbolName(for:override:)`, `SettingsModel` writes them (tolerantly decoded from
    /// `AppSettings`); settings-mirrored like `toolbarMode`.
    private(set) var activeStatusShape: StatusShape?
    private(set) var blockedStatusShape: StatusShape?
    private(set) var completedStatusShape: StatusShape?
    let callbacks = GhosttyCallbacks()
    private var resourcesDir: String?

    private init() {
        resolveResources()
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            logger.error("ghostty_init failed")
            return
        }
        let configInputs = Self.resolveConfigInputs()
        guard let cfg = loadConfig(configInputs) else {
            logger.error("ghostty_config_new failed")
            return
        }

        var rt = ghostty_runtime_config_s()
        rt.userdata = Unmanaged.passUnretained(self).toOpaque()
        rt.supports_selection_clipboard = true
        rt.wakeup_cb = { _ in GhosttyApp.shared.callbacks.wakeup() }
        rt.action_cb = { _, target, action in GhosttyApp.shared.callbacks.action(target: target, action: action) }
        rt.read_clipboard_cb = { ud, loc, state in GhosttyApp.shared.callbacks.readClipboard(ud: ud, location: loc, state: state) }
        rt.confirm_read_clipboard_cb = { ud, content, state, request in
            GhosttyApp.shared.callbacks.confirmReadClipboard(ud: ud, content: content, state: state, request: request)
        }
        rt.write_clipboard_cb = { ud, _, content, len, confirm in
            GhosttyApp.shared.callbacks.writeClipboard(ud: ud, content: content, len: UInt(len), confirm: confirm)
        }
        rt.close_surface_cb = { ud, _ in GhosttyApp.shared.callbacks.closeSurface(ud: ud) }

        guard let createdApp = ghostty_app_new(&rt, cfg) else {
            logger.error("ghostty_app_new failed")
            ghostty_config_free(cfg)
            return
        }
        app = createdApp
        config = cfg
        // boot: no surface yet, so the NSApp read is the only side source and nothing rendered can disagree.
        resolveThemeColors(from: cfg, inputs: configInputs, isDark: Self.currentIsDark())
        // demand-driven, no poll timer (like Ghostty.app/conterm): ticks come from libghostty wakeups
        // (coalesced in GhosttyCallbacks.wakeup), surfaces draw on GHOSTTY_ACTION_RENDER — idle costs nothing.
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    /// Set the window translucency the chrome applies. `SettingsModel` calls this and every setter below at
    /// launch and on each change; the window re-syncs on `.agtermAppearanceChanged`.
    func setWindowTranslucency(opacity: Double, blurRadius: Int) {
        windowOpacity = opacity
        windowBlurRadius = blurRadius
    }

    func setToolbarMode(_ mode: ToolbarMode) {
        toolbarMode = mode
    }

    func setNotificationBadgeEnabled(_ enabled: Bool) {
        notificationBadgeEnabled = enabled
    }

    func setRestoreRunningCommand(_ enabled: Bool) {
        restoreRunningCommand = enabled
    }

    func setAttentionButtonEnabled(_ enabled: Bool) {
        attentionButtonEnabled = enabled
    }

    func setHiddenInterfaceElements(_ elements: Set<InterfaceElement>) {
        hiddenInterfaceElements = elements
    }

    func setAutoHideSidebarInactiveWindows(_ enabled: Bool) {
        autoHideSidebarInactiveWindows = enabled
    }

    func setRestoreDenylist(_ denylist: Set<String>) {
        restoreDenylist = denylist
    }

    func setInactivePaneMuteStrength(_ strength: Int) {
        inactivePaneMuteStrength = strength
    }

    func setSidebarBackgroundShift(_ strength: Int) {
        sidebarBackgroundShift = strength
    }

    func setBaseFontSize(_ size: Double?) {
        baseFontSize = size ?? DashboardLayout.ghosttyDefaultFontSize
    }

    func setSidebarFontSize(_ size: Double) {
        // clamp so both readers (row font AND row height) see an in-range value: the Settings stepper bounds
        // 9...20, but a hand-edited settings.json must not draw a giant font in the clamped row
        // (sidebarRowHeight clamps its own copy).
        sidebarFontSize = CGFloat(AppSettings.clampSidebarFontSize(size))
    }

    /// Set the agent-status glyph colors from the user's hex settings; nil or malformed → the system default.
    func setAgentStatusColors(activeHex: String?, blockedHex: String?, completedHex: String?) {
        activeStatusColor = NSColor(agtermHex: activeHex) ?? GhosttyApp.defaultActiveStatusColor
        blockedStatusColor = NSColor(agtermHex: blockedHex) ?? .systemOrange
        completedStatusColor = NSColor(agtermHex: completedHex) ?? .systemGreen
    }

    func setAgentStatusShapes(active: StatusShape?, blocked: StatusShape?, completed: StatusShape?) {
        activeStatusShape = active
        blockedStatusShape = blocked
        completedStatusShape = completed
    }

    /// The SF Symbol for a status glyph, honoring a per-call shape OVERRIDE from `session.status --shape` (on
    /// the ephemeral `AgentIndicator`). Precedence — override, else this status's Settings shape, else the
    /// plain circle — lives in host-free `AgentStatus.symbolName(override:configured:)`; this supplies only the
    /// mirrored Settings value. Shared by the sidebar `StatusIconView` and SwiftUI `StatusGlyph` against drift.
    func statusSymbolName(for status: AgentStatus, override shape: StatusShape?) -> String {
        let configured: StatusShape?
        switch status {
        case .active: configured = activeStatusShape
        case .blocked: configured = blockedStatusShape
        case .completed: configured = completedStatusShape
        case .idle: configured = nil
        }
        return status.symbolName(override: shape, configured: configured)
    }

    /// The configured tint for a status glyph. `idle` never renders a glyph (filtered out before any glyph is
    /// built), so its `.clear` is a benign unused default.
    func statusColor(for status: AgentStatus) -> NSColor {
        switch status {
        case .active: return activeStatusColor
        case .blocked: return blockedStatusColor
        case .completed: return completedStatusColor
        case .idle: return .clear
        }
    }

    /// The tint for a status glyph, honoring a per-call `#rrggbb` OVERRIDE from `session.status --color` (set
    /// on the ephemeral `AgentIndicator`); a valid override wins, nil or malformed falls back to the
    /// Settings-configured `statusColor(for:)`.
    func statusColor(for status: AgentStatus, override hex: String?) -> NSColor {
        NSColor(agtermHex: hex) ?? statusColor(for: status)
    }

    // MARK: - Config

    /// Path to agterm's generated ghostty config (font/size/theme from the Settings window), in the same state
    /// directory as the workspace snapshot (honors `AGTERM_STATE_DIR` for tests).
    static var settingsConfigURL: URL {
        let dir = ProcessInfo.processInfo.environment["AGTERM_STATE_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? PersistenceStore.defaultDirectory
        return dir.appendingPathComponent("ghostty-settings.conf")
    }

    /// The config inputs resolved from `settings.json` in ONE read: the agterm-scoped `ghostty.conf` URL
    /// (`<configDir>/ghostty.conf`, beside `keymap.conf`) and whether to inherit the GLOBAL
    /// `~/.config/ghostty/config` (`inheritGlobalGhosttyConfig`, default off). Resolved once per config build
    /// and threaded onward, so a reload reads `settings.json` at most once. Self-contained because
    /// `loadConfig` runs before any `SettingsModel` exists (its init is the first touch of `GhosttyApp.shared`):
    /// reads the persisted `configDirectory` + flag via `settingsStore()`, keymap precedence (explicit setting
    /// → `AGTERM_STATE_DIR/config` → `~/.config/agterm`).
    struct ConfigInputs {
        let scopedURL: URL
        let inheritGlobalConfig: Bool
    }

    static func resolveConfigInputs() -> ConfigInputs {
        let settings = settingsStore().load()
        let configDir = ConfigPaths.configDirectory(
            setting: settings.configDirectory,
            stateDir: ProcessInfo.processInfo.environment["AGTERM_STATE_DIR"],
            home: FileManager.default.homeDirectoryForCurrentUser)
        return ConfigInputs(scopedURL: ConfigPaths.ghosttyConfigPath(configDirectory: configDir),
                            inheritGlobalConfig: settings.inheritGlobalGhosttyConfig ?? false)
    }

    /// The persisted settings store, rooted the SAME way `agtermApp.init` builds it: `AGTERM_STATE_DIR` when
    /// set (test isolation), else Application Support — the SAME `settings.json` the active `SettingsModel`
    /// reads. A bare `SettingsStore()` would read the app-support file even under `AGTERM_STATE_DIR` isolation,
    /// ignoring (or leaking in) an explicit `configDirectory` and pointing the two at different `ghostty.conf`.
    private static func settingsStore() -> SettingsStore {
        ProcessInfo.processInfo.environment["AGTERM_STATE_DIR"]
            .map { SettingsStore(directory: URL(fileURLWithPath: $0, isDirectory: true)) } ?? SettingsStore()
    }

    /// Rebuilds the config (re-reading the agterm settings file) and broadcasts it to the app and the given
    /// live surfaces. Keeps the new config as `self.config`; the previous one is never freed — `update_config`
    /// has no documented ownership contract and settings changes are rare, so leaking beats risking a
    /// use-after-free. Returns the rebuilt config's diagnostic count (0 = clean) so Reload Config can warn.
    @discardableResult
    func reloadConfig(surfaces: [GhosttySurfaceView], isDark: Bool) -> Int {
        // no app (pre-`ghostty_app_new`) or a failed config allocation: nothing was re-read, so report the last
        // known count. Both unreachable in practice — boot precedes any reload, allocation fails only on OOM.
        guard let app else { return lastConfigDiagnosticsCount }
        let inputs = Self.resolveConfigInputs()
        guard let newConfig = loadConfig(inputs) else { return lastConfigDiagnosticsCount }
        // re-assert the app + each surface's light/dark scheme from the authoritative `isDark` (KVO-delivered,
        // else `currentIsDark()`) BEFORE feeding the config: libghostty re-resolves a dual `theme =
        // light:,dark:` against the recorded conditional state, so a stale side derives the wrong theme.
        // Setting the APP scheme too keeps a ZERO-surface reload chrome-correct — the CONFIG_CHANGE clone below
        // resolves to `isDark`, re-siding the sidebar/titlebar on a dark launch before any surface exists.
        // Each set no-ops when unchanged; the config re-feed is what re-renders.
        ghostty_app_set_color_scheme(app, isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
        for surface in surfaces { surface.syncColorScheme(isDark: isDark) }
        ghostty_app_update_config(app, newConfig)
        // ghostty answers update_config with a synchronous app-target CONFIG_CHANGE carrying the config it
        // APPLIED (the dual theme resolved to the current appearance side). Read the chrome colors from THAT
        // clone: newConfig is always finalized with the default LIGHT conditional state, so reading it in dark
        // mode tints the sidebar/titlebar light while the terminal renders dark. Nil without a conditional.
        let derivedConfig = callbacks.takeDerivedAppConfig()
        for surface in surfaces { surface.applyConfig(newConfig) }
        config = newConfig
        // refresh the chrome colors BEFORE the watermark re-assert below: a default-tinted `.text` watermark
        // re-renders its PNG from `terminalForegroundColor`, so a stale foreground lags one reload behind a
        // theme change. The selection colors re-side from the passed-in `isDark`, never re-read from a view.
        resolveThemeColors(from: derivedConfig ?? newConfig, inputs: inputs, isDark: isDark)
        if let derivedConfig { ghostty_config_free(derivedConfig) }
        // the broadcast pushes the shared config (no background image, default font size) to every surface,
        // wiping per-surface watermarks and zoom — re-assert them after. No-op without either; on the
        // zoom-clearing reload paths the per-session fontSize was already nil'd, so only watermarks re-apply.
        for surface in surfaces { surface.reapplySessionConfigIfNeeded() }
        return lastConfigDiagnosticsCount
    }

    /// Inputs of the most recent config load, cached so `refreshSelectionColors` can re-resolve the selection
    /// colors after a live color change without a full config reload.
    private var lastConfigInputs: ConfigInputs?

    /// Re-read the chrome colors from a resolved config; called at init and on every settings reload.
    /// `background`/`foreground` come from the config, the selection colors via `resolveSelectionColors`.
    private func resolveThemeColors(from config: ghostty_config_t, inputs: ConfigInputs, isDark: Bool) {
        lastConfigInputs = inputs
        terminalBackgroundColor = Self.color(from: config, key: "background")
        terminalForegroundColor = Self.color(from: config, key: "foreground")
        refreshSelectionColors(isDark: isDark)
    }

    /// Re-resolve the selection chrome colors for the given appearance side, so the selected-row pill follows a
    /// light/dark theme flip. `isDark` is explicit at every call site (the reload threads the KVO-delivered
    /// side) — no defaulted appearance read a future caller could pick up. No-op until a config has loaded.
    func refreshSelectionColors(isDark: Bool) {
        guard let inputs = lastConfigInputs else { return }
        let (selectionBackground, selectionForeground) = Self.resolveSelectionColors(
            ghosttyConfigPath: inputs.scopedURL.path, inheritGlobalConfig: inputs.inheritGlobalConfig,
            isDark: isDark)
        terminalSelectionBackgroundColor = selectionBackground
        terminalSelectionForegroundColor = selectionForeground
            ?? selectionBackground.map(Self.contrastingText(for:))
    }

    /// Whether the app is currently in the dark appearance. `NSApp` is an implicitly-unwrapped global still nil
    /// during the very early `GhosttyApp.shared` init (it boots from `SettingsModel.init`, before AppKit wires
    /// `NSApp`), so chain through it safely; that early window resolves no theme (ghostty picks the side from
    /// the color scheme set at surface creation), so the light default there is harmless.
    static func currentIsDark() -> Bool {
        guard let appearance = NSApp?.effectiveAppearance else { return false }
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// `ghostty_config_get` doesn't expose the optional `selection-background`/`selection-foreground` keys, so
    /// resolve them by re-reading the sources `loadConfig` loads, in the same order, plus the active theme
    /// file. An explicit `selection-*` line wins over the theme's; either may be nil. A `light:…,dark:…` theme
    /// resolves via `isDark`; the global config counts only when `inheritGlobalConfig` is on, as in `loadConfig`.
    ///
    /// Known limitation: only top-level files are scanned — the `config-file` includes
    /// `ghostty_config_load_recursive_files` expands are NOT followed, so a `selection-*` behind one is missed
    /// and the sidebar pill falls back.
    private static func resolveSelectionColors(ghosttyConfigPath: String, inheritGlobalConfig: Bool,
                                               isDark: Bool) -> (NSColor?, NSColor?) {
        var sources: [String] = []
        if let defaults = Bundle.main.url(forResource: "ghostty-defaults", withExtension: "conf") {
            sources.append(defaults.path)
        }
        if inheritGlobalConfig {
            sources.append((NSHomeDirectory() as NSString).appendingPathComponent(".config/ghostty/config"))
        }
        sources.append(ghosttyConfigPath)
        sources.append(settingsConfigURL.path)

        var themeName: String?
        var selBg: NSColor?
        var selFg: NSColor?
        for path in sources {
            for (key, value) in keyValues(ofFileAt: path) {
                switch key {
                case "theme": themeName = value
                case "selection-background": selBg = parseHexColor(value)
                case "selection-foreground": selFg = parseHexColor(value)
                default: break
                }
            }
        }
        // the theme file fills any selection color not set explicitly above; the settings conf carries the raw
        // dual `theme = light:,dark:` (ghostty picks the terminal side itself), so pick the appearance side.
        if selBg == nil || selFg == nil, let themeName, !themeName.isEmpty,
           let themesDir = Bundle.main.url(forResource: "ghostty", withExtension: nil)?
               .appendingPathComponent("themes", isDirectory: true) {
            let effectiveName = ThemeName.resolved(from: themeName, isDark: isDark)
            for (key, value) in keyValues(ofFileAt: themesDir.appendingPathComponent(effectiveName).path) {
                if key == "selection-background", selBg == nil { selBg = parseHexColor(value) }
                if key == "selection-foreground", selFg == nil { selFg = parseHexColor(value) }
            }
        }
        return (selBg, selFg)
    }

    /// Parse a ghostty-style config file into its `key = value` pairs in file order, skipping blank and `#`
    /// comment lines. Missing/unreadable files yield no pairs.
    private static func keyValues(ofFileAt path: String) -> [(String, String)] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { return nil }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            return (key, value)
        }
    }

    /// Parse a `#rrggbb` or `#rgb` hex color (with or without the leading `#`) to an opaque sRGB `NSColor`,
    /// or nil if it isn't a valid hex triplet.
    private static func parseHexColor(_ value: String) -> NSColor? {
        var hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let int = UInt32(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((int >> 16) & 0xFF) / 255.0,
                       green: CGFloat((int >> 8) & 0xFF) / 255.0,
                       blue: CGFloat(int & 0xFF) / 255.0,
                       alpha: 1)
    }

    /// Black or white, whichever contrasts better with `color` by WCAG relative luminance — used by the
    /// selected-row text when the theme sets a selection-background but no selection-foreground, and by the
    /// dashboard status pill over an arbitrary fill. Gamma-linearized luminance, not a raw luma average: a
    /// plain cutoff reads a saturated mid-tone like `systemGreen` as "dark" and picks unreadable white-on-green.
    static func contrastingText(for color: NSColor) -> NSColor {
        let c = color.usingColorSpace(.sRGB) ?? color
        func linear(_ v: CGFloat) -> Double {
            let d = Double(v)
            return d <= 0.03928 ? d / 12.92 : pow((d + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent)
            + 0.0722 * linear(c.blueComponent)
        // 0.179 is the crossover where contrast against black equals contrast against white.
        return luminance > 0.179 ? .black : .white
    }

    /// A per-surface config: the SAME base files as `loadConfig` plus an overlay (a session's
    /// `background-image*` + font-size lines, from `WatermarkConfig.overlayText`) written to a temp file,
    /// loaded LAST so it wins over the settings conf, then deleted (`load_file` reads synchronously). The
    /// caller (`GhosttySurfaceView`) owns and frees the returned config. An empty overlay yields the plain base
    /// config (used to CLEAR a watermark). `lastConfigDiagnosticsCount` is preserved so a per-surface build
    /// can't clobber what `config.reload` reports. Nil on allocation failure.
    func configWithOverlay(_ overlayText: String) -> ghostty_config_t? {
        var overlayPath: String?
        if !overlayText.isEmpty {
            let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("agterm-wm-\(UUID().uuidString).conf")
            do {
                try overlayText.write(toFile: tmp, atomically: true, encoding: .utf8)
                overlayPath = tmp
            } catch {
                logger.warning("watermark overlay write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let savedCount = lastConfigDiagnosticsCount
        let cfg = loadConfig(Self.resolveConfigInputs(), extraOverlayPath: overlayPath)
        lastConfigDiagnosticsCount = savedCount
        if let overlayPath { try? FileManager.default.removeItem(atPath: overlayPath) }
        return cfg
    }

    private func loadConfig(_ inputs: ConfigInputs, extraOverlayPath: String? = nil) -> ghostty_config_t? {
        guard let cfg = ghostty_config_new() else { return nil }

        // app defaults (terminal padding, etc.) first, so the scoped and opted-in global configs override them.
        if let defaults = Bundle.main.url(forResource: "ghostty-defaults", withExtension: "conf") {
            defaults.path.withCString { ghostty_config_load_file(cfg, $0) }
        }

        // the user's GLOBAL ~/.config/ghostty/config is OFF by default — a config written for the standalone
        // Ghostty.app must not silently change agterm. libghostty does NOT read the XDG config on its own, so
        // load it explicitly when opted in; `config-file` includes resolve below.
        if inputs.inheritGlobalConfig {
            let userPath = (NSHomeDirectory() as NSString).appendingPathComponent(".config/ghostty/config")
            if FileManager.default.fileExists(atPath: userPath) {
                userPath.withCString { ghostty_config_load_file(cfg, $0) }
            } else {
                logger.info("inherit on, but no user ghostty config at \(userPath, privacy: .public)")
            }
        }

        // agterm-scoped ghostty.conf (beside keymap.conf), ALWAYS loaded regardless of the inherit toggle:
        // after the optional global config so it wins over that and the bundled defaults for any key, but
        // BEFORE agterm's UI settings so the Settings picker still wins for what it manages. Skipped when
        // absent; the seeded starter is comment-only, so a fresh install is a no-op.
        let scopedPath = inputs.scopedURL.path
        if FileManager.default.fileExists(atPath: scopedPath) {
            scopedPath.withCString { ghostty_config_load_file(cfg, $0) }
        }

        // agterm's own appearance settings (font/size/theme), loaded last so the UI-managed keys win.
        let settingsConf = Self.settingsConfigURL.path
        if FileManager.default.fileExists(atPath: settingsConf) {
            settingsConf.withCString { ghostty_config_load_file(cfg, $0) }
        }

        // a per-surface overlay, loaded LAST so it wins over everything above; only `configWithOverlay` passes
        // it, the app/global build leaves it nil.
        if let extraOverlayPath, FileManager.default.fileExists(atPath: extraOverlayPath) {
            extraOverlayPath.withCString { ghostty_config_load_file(cfg, $0) }
        }

        ghostty_config_load_recursive_files(cfg)
        ghostty_config_finalize(cfg)

        let diagCount = ghostty_config_diagnostics_count(cfg)
        lastConfigDiagnosticsCount = Int(diagCount)
        for i in 0 ..< diagCount {
            let diag = ghostty_config_get_diagnostic(cfg, i)
            if let msg = diag.message {
                logger.warning("config: \(String(cString: msg), privacy: .public)")
            }
        }
        return cfg
    }

    /// A named color key (e.g. `background`, `foreground`) from the resolved config as an opaque `NSColor`,
    /// or nil if the key isn't set.
    private static func color(from config: ghostty_config_t, key: String) -> NSColor? {
        var color = ghostty_config_color_s()
        let got = key.withCString { ghostty_config_get(config, &color, $0, UInt(key.utf8.count)) }
        guard got else { return nil }
        return NSColor(srgbRed: CGFloat(color.r) / 255.0,
                       green: CGFloat(color.g) / 255.0,
                       blue: CGFloat(color.b) / 255.0,
                       alpha: 1)
    }

    // MARK: - Resources

    /// Candidate ghostty resource dirs, highest priority first. agterm ships its own (from setup.sh) at
    /// `Contents/Resources/ghostty`, mirroring a real Ghostty.app, with the compiled terminfo DB at the sibling
    /// `Contents/Resources/terminfo`; the installed Ghostty.app dirs are dev-checkout fallbacks.
    private static let resourcePaths: [String] = {
        var paths: [String] = []
        if let resources = Bundle.main.resourceURL?.path {
            paths.append(resources + "/ghostty")
        }
        paths.append("/Applications/Ghostty.app/Contents/Resources/ghostty")
        paths.append(NSHomeDirectory() + "/Applications/Ghostty.app/Contents/Resources/ghostty")
        return paths
    }()

    private func resolveResources() {
        // resolve from our own candidates (bundle first), ignoring any inherited GHOSTTY_RESOURCES_DIR: a stale
        // one shadows our complete bundle and leaves libghostty deriving a broken TERMINFO. TERMINFO itself is
        // never set here — libghostty overwrites it at shell spawn with dirname(GHOSTTY_RESOURCES_DIR)/terminfo,
        // clobbering any setenv, and our .../Resources/ghostty makes that land on the terminfo we ship beside it.
        let resolver = GhosttyResourceResolver(
            candidates: Self.resourcePaths,
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
        guard let dir = resolver.resolve() else {
            unsetenv("GHOSTTY_RESOURCES_DIR")
            return
        }
        resourcesDir = dir
        setenv("GHOSTTY_RESOURCES_DIR", dir, 1)
    }
}

extension Notification.Name {
    /// Posted after a settings-driven config reload, so the SwiftUI chrome (the quick-terminal backing) and the
    /// AppKit window appearance (title bar + window background → sidebar) re-read the new
    /// `GhosttyApp.terminalBackgroundColor` at once instead of waiting for the window to re-key.
    static let agtermAppearanceChanged = Notification.Name("agterm.appearanceChanged")

    /// Posted by `SystemAppearanceObserver` (app-level KVO on `NSApplication.effectiveAppearance`) on every
    /// macOS light/dark change and once at launch, carrying the resolved `isDark` in userInfo. `SettingsModel`
    /// then re-resolves the active side of a `theme = light:,dark:` pair and rewrites+reloads the config — the
    /// pinned libghostty doesn't switch the dual conditional at runtime, so agterm drives the swap. KVO
    /// delivers the settled value across sleep/wake, unlike per-view `viewDidChangeEffectiveAppearance`, which
    /// wedges. Also posted by the `debug.appearance` UI-test seam. System→settings, vs settings→chrome above.
    static let agtermSystemAppearanceChanged = Notification.Name("agterm.systemAppearanceChanged")

    /// Posted by `SystemAccessibilityObserver` on a macOS accessibility display-option change. AppKit consumers
    /// re-read Reduce Transparency / Reduce Motion from `NSWorkspace`; SwiftUI views use their native
    /// accessibility environment values.
    static let agtermAccessibilityDisplayOptionsChanged =
        Notification.Name("agterm.accessibilityDisplayOptionsChanged")

    /// Posted when a window becomes frontmost (async, via the window's didBecomeKey), so the control server can
    /// refresh its cached `window.list` — its `active` flag would otherwise stay stale until the next command.
    static let agtermWindowFrontmostChanged = Notification.Name("agterm.windowFrontmostChanged")

    /// Posted by `WindowRegistry` when a window's NSWindow attaches or detaches, so the control server can
    /// refresh its cached `window.list`. A window is "open" (its store loaded) well before its NSWindow exists,
    /// so `window.new` caches a node with no `geometry`/`fullscreen`/`zoomed`/`minimized` and nothing else
    /// refreshes it: `newWindow()` pre-sets `frontmostWindowID`, so the first `didBecomeKey` is a no-change
    /// skipping `.agtermWindowFrontmostChanged`, and a new window has no saved frame, so no `didMove`/
    /// `didResize` fires either.
    static let agtermWindowAttachmentChanged = Notification.Name("agterm.windowAttachmentChanged")

    /// Posted after `keymap.conf` is (re)loaded and reparsed, so the custom-command runner rebuilds its matcher
    /// and the action palette re-reads the custom commands. The data-driven menu shortcuts re-render on their
    /// own from the `@Observable` keymap.
    static let agtermKeymapChanged = Notification.Name("agterm.keymapChanged")
}
