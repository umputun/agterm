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

    /// renderedTextURL is `<stateDir>/watermarks/<sessionID>.png` for the session default, or
    /// `<sessionID>-<paneKey>.png` for a pane override (`Session.backgroundFileKey(for:)`).
    public static func renderedTextURL(sessionID: UUID, paneKey: String? = nil, stateDir: URL? = nil) -> URL {
        let name = paneKey.map { "\(sessionID.uuidString)-\($0)" } ?? sessionID.uuidString
        return directoryURL(stateDir: stateDir).appendingPathComponent("\(name).png")
    }

    /// removeRenderedText deletes the default's or one pane override's PNG; the next apply re-renders it.
    public static func removeRenderedText(sessionID: UUID, paneKey: String? = nil, stateDir: URL? = nil) {
        try? FileManager.default.removeItem(at: renderedTextURL(sessionID: sessionID, paneKey: paneKey,
                                                                stateDir: stateDir))
    }

    /// removeAllRenderedText deletes every PNG a session owns, for permanent session removal.
    public static func removeAllRenderedText(sessionID: UUID, stateDir: URL? = nil) {
        let dir = directoryURL(stateDir: stateDir)
        let id = sessionID.uuidString
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where name == "\(id).png" || (name.hasPrefix("\(id)-") && name.hasSuffix(".png")) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}
