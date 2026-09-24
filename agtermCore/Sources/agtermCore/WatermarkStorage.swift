import Foundation

/// Host-free on-disk location of rendered `.text` watermark PNGs — a `watermarks/` subdir of the state
/// directory (honoring `AGTERM_STATE_DIR` for test isolation, like the snapshot/settings files). Pure
/// Foundation (no AppKit), so the app-target renderer (`WatermarkRenderer`, which writes the PNGs) and
/// the host-free `AppStore` (which removes a session's PNG when the session is permanently destroyed)
/// share one path definition. Each function takes an optional `stateDir` override (default nil = the
/// `AGTERM_STATE_DIR`/app-support resolution) so tests can inject a temp directory without mutating
/// process-global env (parallel-safe).
public enum WatermarkStorage {
    /// `<stateDir>/watermarks` — NOT created. Use `ensureDirectory()` before writing.
    public static func directoryURL(stateDir: URL? = nil) -> URL {
        let base = stateDir
            ?? ProcessInfo.processInfo.environment["AGTERM_STATE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? PersistenceStore.defaultDirectory
        return base.appendingPathComponent("watermarks", isDirectory: true)
    }

    /// `directoryURL()`, created lazily (best effort). Called before rendering a `.text` PNG.
    @discardableResult
    public static func ensureDirectory(stateDir: URL? = nil) -> URL {
        let dir = directoryURL(stateDir: stateDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The rendered-text PNG path: `<stateDir>/watermarks/<sessionID>.png` for the session default, or
    /// `<sessionID>-<paneKey>.png` for a pane override (`Session.backgroundFileKey(for:)`).
    public static func renderedTextURL(sessionID: UUID, paneKey: String? = nil, stateDir: URL? = nil) -> URL {
        let name = paneKey.map { "\(sessionID.uuidString)-\($0)" } ?? sessionID.uuidString
        return directoryURL(stateDir: stateDir).appendingPathComponent("\(name).png")
    }

    /// Remove one rendered `.text` PNG (best effort): the session default's, or one pane override's. A no-op
    /// when none exists. A `.text` watermark always re-renders its PNG on apply, so an over-eager removal is
    /// self-healing.
    public static func removeRenderedText(sessionID: UUID, paneKey: String? = nil, stateDir: URL? = nil) {
        try? FileManager.default.removeItem(at: renderedTextURL(sessionID: sessionID, paneKey: paneKey,
                                                                stateDir: stateDir))
    }

    /// Remove every rendered `.text` PNG a session owns, default and pane overrides alike. For permanent
    /// session removal, which leaves nothing to re-render them.
    public static func removeAllRenderedText(sessionID: UUID, stateDir: URL? = nil) {
        let dir = directoryURL(stateDir: stateDir)
        let id = sessionID.uuidString
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where name == "\(id).png" || (name.hasPrefix("\(id)-") && name.hasSuffix(".png")) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}
