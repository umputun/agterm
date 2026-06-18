// adapted from thdxg/macterm (MIT)

import AppKit
import Foundation
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.umputun.agt", category: "GhosttyApp")

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
    private var tickTimer: Timer?
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
        terminalBackgroundColor = Self.backgroundColor(from: cfg)

        // A main-RunLoop timer is proven to fire on the main thread, so
        // `assumeIsolated` is valid here (and ONLY here). 120Hz keeps latency
        // low without the scheduling overhead of `Task`/`DispatchQueue.async`.
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    // MARK: - Config

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

    /// Reads the `background` color from the resolved config as an opaque `NSColor`.
    private static func backgroundColor(from config: ghostty_config_t) -> NSColor? {
        let key = "background"
        var color = ghostty_config_color_s()
        let got = key.withCString { ghostty_config_get(config, &color, $0, UInt(key.utf8.count)) }
        guard got else { return nil }
        return NSColor(srgbRed: CGFloat(color.r) / 255.0,
                       green: CGFloat(color.g) / 255.0,
                       blue: CGFloat(color.b) / 255.0,
                       alpha: 1)
    }

    // MARK: - Resources

    /// Candidate ghostty resource dirs, highest priority first. agt ships the
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
