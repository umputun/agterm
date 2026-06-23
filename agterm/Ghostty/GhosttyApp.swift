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
    /// The terminal background color parsed from the resolved config. Used to tint the
    /// window so the title bar blends with the terminal instead of drawing the default
    /// titlebar material. Nil if the color couldn't be read.
    private(set) var terminalBackgroundColor: NSColor?
    /// The terminal foreground (text) color parsed from the resolved config. The chrome (sidebar row
    /// text + icons, title bar text + buttons) uses it so non-terminal text tracks the theme instead
    /// of the system label color. Nil if the color couldn't be read.
    private(set) var terminalForegroundColor: NSColor?
    /// The terminal selection-background color (theme `selection-background`). The selected sidebar row
    /// draws its pill in this color so it matches the terminal's own selection. Nil if the theme
    /// doesn't set it (the row falls back to a soft white wash).
    private(set) var terminalSelectionBackgroundColor: NSColor?
    /// The selected sidebar row's text color: the theme `selection-foreground`, or a black/white
    /// contrast of the selection-background when the theme sets only the background. Nil if neither set.
    private(set) var terminalSelectionForegroundColor: NSColor?
    /// Window translucency the chrome composites at the AppKit level — the background opacity
    /// (0...1) and CGS blur radius the Settings window last applied. NOT ghostty-resolved:
    /// `WindowAppearance.sync` reads these, `SettingsModel` writes them. Defaults are opaque.
    private(set) var windowOpacity: Double = 1
    private(set) var windowBlurRadius: Int = 0
    /// Whether the window chrome uses the compact title bar (single short row, smaller icons, no
    /// subtitle). NOT ghostty-resolved: `WindowAppearance.sync` reads it, `SettingsModel` writes it.
    private(set) var compactToolbar: Bool = false
    /// Whether the sidebar draws the red unseen-notification count badge. NOT ghostty-resolved: the
    /// sidebar Coordinator reads it (gating the count to 0 when off), `SettingsModel` writes it. The
    /// re-render rides the `.agtermAppearanceChanged` notification, like `compactToolbar`.
    private(set) var notificationBadgeEnabled: Bool = true
    /// The agent-status glyph colors (active/blocked/completed). NOT ghostty-resolved: `StatusIconView`
    /// reads them when building the glyph, `SettingsModel` writes them (resolved from the user's hex or
    /// the system default). The sidebar re-render rides the `.agtermAppearanceChanged` notification.
    private(set) var activeStatusColor: NSColor = .systemBlue
    private(set) var blockedStatusColor: NSColor = .systemOrange
    private(set) var completedStatusColor: NSColor = .systemGreen
    let callbacks = GhosttyCallbacks()
    private var resourcesDir: String?

    private init() {
        resolveResources()
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            logger.error("ghostty_init failed")
            return
        }
        guard let cfg = loadConfig() else {
            logger.error("ghostty_config_new failed")
            return
        }

        var rt = ghostty_runtime_config_s()
        rt.userdata = Unmanaged.passUnretained(self).toOpaque()
        rt.supports_selection_clipboard = true
        rt.wakeup_cb = { _ in GhosttyApp.shared.callbacks.wakeup() }
        rt.action_cb = { _, target, action in GhosttyApp.shared.callbacks.action(target: target, action: action) }
        rt.read_clipboard_cb = { ud, loc, state in GhosttyApp.shared.callbacks.readClipboard(ud: ud, location: loc, state: state) }
        rt.confirm_read_clipboard_cb = { ud, content, state, _ in
            GhosttyApp.shared.callbacks.confirmReadClipboard(ud: ud, content: content, state: state)
        }
        rt.write_clipboard_cb = { _, _, content, len, _ in
            GhosttyApp.shared.callbacks.writeClipboard(content: content, len: UInt(len))
        }
        rt.close_surface_cb = { ud, _ in GhosttyApp.shared.callbacks.closeSurface(ud: ud) }

        guard let createdApp = ghostty_app_new(&rt, cfg) else {
            logger.error("ghostty_app_new failed")
            ghostty_config_free(cfg)
            return
        }
        app = createdApp
        config = cfg
        resolveThemeColors(from: cfg)
        // demand-driven: no poll timer. ticks come from libghostty wakeups (coalesced in
        // GhosttyCallbacks.wakeup) and surfaces draw on GHOSTTY_ACTION_RENDER, matching Ghostty.app/conterm
        // — an idle terminal does no work, where a 120Hz poll ticked continuously.
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    /// Set the window translucency the chrome applies. Called by `SettingsModel` at launch and on
    /// every change; the actual window re-sync rides the `.agtermAppearanceChanged` notification.
    func setWindowTranslucency(opacity: Double, blurRadius: Int) {
        windowOpacity = opacity
        windowBlurRadius = blurRadius
    }

    /// Set whether the window chrome uses the compact title bar. Called by `SettingsModel` at launch
    /// and on every change; the window re-sync rides the `.agtermAppearanceChanged` notification.
    func setCompactToolbar(_ enabled: Bool) {
        compactToolbar = enabled
    }

    /// Set whether the sidebar draws the notification count badge. Called by `SettingsModel` at launch
    /// and on every change; the sidebar re-reconcile rides the `.agtermAppearanceChanged` notification.
    func setNotificationBadgeEnabled(_ enabled: Bool) {
        notificationBadgeEnabled = enabled
    }

    /// Set the agent-status glyph colors from the user's hex settings (nil/malformed → the system
    /// default). Called by `SettingsModel` at launch and on every change; the sidebar re-renders the
    /// glyphs on the `.agtermAppearanceChanged` notification.
    func setAgentStatusColors(activeHex: String?, blockedHex: String?, completedHex: String?) {
        activeStatusColor = NSColor(agtermHex: activeHex) ?? .systemBlue
        blockedStatusColor = NSColor(agtermHex: blockedHex) ?? .systemOrange
        completedStatusColor = NSColor(agtermHex: completedHex) ?? .systemGreen
    }

    // MARK: - Config

    /// Path to agterm's generated ghostty config (font/size/theme from the Settings window), in the
    /// same state directory as the workspace snapshot (honors `AGTERM_STATE_DIR` for tests).
    static var settingsConfigURL: URL {
        let dir = ProcessInfo.processInfo.environment["AGTERM_STATE_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? PersistenceStore.defaultDirectory
        return dir.appendingPathComponent("ghostty-settings.conf")
    }

    /// Rebuilds the config (re-reading the agterm settings file) and broadcasts it to the app and the
    /// given live surfaces — a live appearance change. Keeps the new config as `self.config`; the
    /// previous config is intentionally NOT freed: settings changes are rare and `update_config`
    /// has no documented ownership contract, so this matches the existing never-free pattern over
    /// risking a use-after-free.
    func reloadConfig(surfaces: [GhosttySurfaceView]) {
        guard let app, let newConfig = loadConfig() else { return }
        ghostty_app_update_config(app, newConfig)
        for surface in surfaces { surface.applyConfig(newConfig) }
        config = newConfig
        resolveThemeColors(from: newConfig)
    }

    /// Re-read the chrome colors (background, foreground, selection background/foreground) from a
    /// resolved config. Called at init and on every settings reload. `background`/`foreground` come
    /// from the resolved config; the selection colors are resolved separately (see below) because
    /// `ghostty_config_get` does not expose the optional `selection-*` keys.
    private func resolveThemeColors(from config: ghostty_config_t) {
        terminalBackgroundColor = Self.color(from: config, key: "background")
        terminalForegroundColor = Self.color(from: config, key: "foreground")
        let (selectionBackground, selectionForeground) = Self.resolveSelectionColors()
        terminalSelectionBackgroundColor = selectionBackground
        terminalSelectionForegroundColor = selectionForeground
            ?? selectionBackground.map(Self.contrastingText(for:))
    }

    /// The selection colors can't be read back through `ghostty_config_get` (it doesn't expose the
    /// optional `selection-background`/`selection-foreground` keys), so resolve them by reading the
    /// same config sources `loadConfig` loads — in the same order — plus the active theme file. An
    /// explicit `selection-*` line wins over the theme's; either color may be nil when unset.
    private static func resolveSelectionColors() -> (NSColor?, NSColor?) {
        var sources: [String] = []
        if let defaults = Bundle.main.url(forResource: "ghostty-defaults", withExtension: "conf") {
            sources.append(defaults.path)
        }
        sources.append((NSHomeDirectory() as NSString).appendingPathComponent(".config/ghostty/config"))
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
        // the theme file fills any selection color not set explicitly above.
        if (selBg == nil || selFg == nil), let themeName, !themeName.isEmpty,
           let themesDir = Bundle.main.url(forResource: "ghostty", withExtension: nil)?
               .appendingPathComponent("themes", isDirectory: true) {
            for (key, value) in keyValues(ofFileAt: themesDir.appendingPathComponent(themeName).path) {
                if key == "selection-background", selBg == nil { selBg = parseHexColor(value) }
                if key == "selection-foreground", selFg == nil { selFg = parseHexColor(value) }
            }
        }
        return (selBg, selFg)
    }

    /// Parse a ghostty-style config file into its `key = value` pairs in file order, skipping blank
    /// and `#` comment lines. Missing/unreadable files yield no pairs.
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

    /// Parse a `#rrggbb` or `#rgb` hex color (with or without the leading `#`) to an opaque sRGB
    /// `NSColor`, or nil if it isn't a valid hex triplet.
    private static func parseHexColor(_ value: String) -> NSColor? {
        var hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let int = UInt32(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((int >> 16) & 0xFF) / 255.0,
                       green: CGFloat((int >> 8) & 0xFF) / 255.0,
                       blue: CGFloat(int & 0xFF) / 255.0,
                       alpha: 1)
    }

    /// Black or white, whichever contrasts better with `color` by perceived luminance. The selected-row
    /// text falls back to this when the theme sets a selection-background but no selection-foreground.
    private static func contrastingText(for color: NSColor) -> NSColor {
        let c = color.usingColorSpace(.sRGB) ?? color
        let luminance = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return luminance > 0.6 ? .black : .white
    }

    private func loadConfig() -> ghostty_config_t? {
        guard let cfg = ghostty_config_new() else { return nil }

        // app's built-in defaults (terminal padding, etc.), loaded first so a
        // user's ~/.config/ghostty/config still overrides them.
        if let defaults = Bundle.main.url(forResource: "ghostty-defaults", withExtension: "conf") {
            defaults.path.withCString { ghostty_config_load_file(cfg, $0) }
        }

        // libghostty does NOT read the user's XDG config on its own, so we load
        // it explicitly when present, then resolve any `config-file` includes,
        // then finalize.
        let userPath = (NSHomeDirectory() as NSString).appendingPathComponent(".config/ghostty/config")
        if FileManager.default.fileExists(atPath: userPath) {
            userPath.withCString { ghostty_config_load_file(cfg, $0) }
        } else {
            logger.info("no user ghostty config at \(userPath, privacy: .public); using defaults")
        }

        // agterm's own appearance settings (Settings window: font / size / theme), loaded last so
        // they win over the user's ghostty config for the keys the UI manages.
        let settingsConf = Self.settingsConfigURL.path
        if FileManager.default.fileExists(atPath: settingsConf) {
            settingsConf.withCString { ghostty_config_load_file(cfg, $0) }
        }

        ghostty_config_load_recursive_files(cfg)
        ghostty_config_finalize(cfg)

        let diagCount = ghostty_config_diagnostics_count(cfg)
        for i in 0 ..< diagCount {
            let diag = ghostty_config_get_diagnostic(cfg, i)
            if let msg = diag.message {
                logger.warning("config: \(String(cString: msg), privacy: .public)")
            }
        }
        return cfg
    }

    /// Reads a named color key (e.g. `background`, `foreground`) from the resolved config as an
    /// opaque `NSColor`, or nil if the key isn't set.
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

    /// Candidate ghostty resource dirs, highest priority first. agterm ships the
    /// ghostty resources in its own bundle (downloaded by setup.sh) under
    /// `Contents/Resources/ghostty`, mirroring a real Ghostty.app, with the
    /// compiled terminfo DB at the sibling `Contents/Resources/terminfo`. The
    /// installed Ghostty.app dirs remain as fallbacks for an unprepared dev
    /// checkout.
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
        // Always resolve from our own candidates (bundle first), ignoring any
        // inherited GHOSTTY_RESOURCES_DIR. A stale value would otherwise shadow
        // our complete bundle and leave libghostty deriving a broken TERMINFO.
        //
        // We only set GHOSTTY_RESOURCES_DIR. TERMINFO is NOT set here on
        // purpose: libghostty unconditionally overwrites it at shell spawn with
        // dirname(GHOSTTY_RESOURCES_DIR)/terminfo, so any setenv here would be
        // clobbered. Because our resources dir is .../Resources/ghostty, that
        // derivation lands on .../Resources/terminfo — the sibling dir we ship.
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
    /// Posted after the ghostty config is reloaded from a settings change, so the SwiftUI chrome
    /// (the quick terminal backing) and the AppKit window appearance (title bar + window background →
    /// sidebar) re-read the new `GhosttyApp.terminalBackgroundColor` immediately instead of waiting
    /// for the window to re-key.
    static let agtermAppearanceChanged = Notification.Name("agterm.appearanceChanged")

    /// Posted when a window becomes frontmost (the active-window change is async, via the window's
    /// didBecomeKey), so the control server can refresh its cached `window.list` — whose `active` flag
    /// would otherwise stay stale until the next dispatched command.
    static let agtermWindowFrontmostChanged = Notification.Name("agterm.windowFrontmostChanged")

    /// Posted after `keymap.conf` is (re)loaded and reparsed, so the custom-command runner rebuilds its
    /// matcher and the action palette re-reads the custom commands. The data-driven menu shortcuts
    /// re-render on their own because they read the `@Observable` keymap directly.
    static let agtermKeymapChanged = Notification.Name("agterm.keymapChanged")
}
