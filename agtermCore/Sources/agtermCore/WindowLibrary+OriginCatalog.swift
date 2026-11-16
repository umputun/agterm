import Foundation

/// OriginCatalogRefusal is why a Mac does not serve a window's catalog. Only a closed window may open again, so it
/// is the one a viewer keeps retrying.
public enum OriginCatalogRefusal: Error, Equatable {
    case notLive
    case noWindow
    case unknown(String)
    case remote(String)
    case closed(String)

    public var final: Bool {
        if case .closed = self { return false }
        return true
    }

    public func message(host: String) -> String {
        switch self {
        case .notLive: "\(host) does not run Live sessions, which a remote window needs"
        case .noWindow: "the request names no window on \(host)"
        case .unknown(let window): "\(host) has no window \(window)"
        case .remote(let name): "window \(name) on \(host) is a remote window itself"
        case .closed(let name): "window \(name) is closed on \(host)"
        }
    }
}

extension WindowLibrary {
    /// originCatalogStore resolves the window a viewer's hello names, by id, to the store its catalog is built from.
    public func originCatalogStore(window: String?, liveActive: Bool) -> Result<(id: UUID, store: AppStore), OriginCatalogRefusal> {
        guard liveActive else { return .failure(.notLive) }
        guard let window else { return .failure(.noWindow) }
        guard let entry = UUID(uuidString: window).flatMap({ id in windows.first { $0.id == id } }) else {
            return .failure(.unknown(window))
        }
        guard !entry.isRemote else { return .failure(.remote(entry.name)) }
        guard let store = store(for: entry.id) else { return .failure(.closed(entry.name)) }
        return .success((entry.id, store))
    }
}
