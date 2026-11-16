import Foundation

/// RemoteOriginWindow picks which of a Mac host's windows a remote window shows, from that host's `window.list`.
public enum RemoteOriginWindow {
    /// Refusal is why no window was chosen; `ambiguous` is the one a picker answers by asking.
    public enum Refusal: Error, Equatable, Sendable {
        case ambiguous(String)
        case none(String)
        case unknown(String)

        public var message: String {
            switch self {
            case .ambiguous(let text), .none(let text), .unknown(let text): text
            }
        }
    }

    /// offered is the windows a picker lists: open and the host's own, in its order.
    public static func offered(_ windows: [ControlWindowNode]) -> [ControlWindowNode] {
        windows.filter { $0.open && $0.remote == nil }
    }

    /// choose resolves `requested` (an id or unique prefix) among `windows`, or takes the one offered window when
    /// nothing was requested.
    public static func choose(host: String, windows: [ControlWindowNode], requested: String?) -> Result<ControlWindowNode, Refusal> {
        guard let requested = requested?.trimmedOrNil else {
            let offered = offered(windows)
            guard let first = offered.first else { return .failure(.none("\(host) has no open window")) }
            guard offered.count > 1 else { return .success(first) }
            let names = offered.map { "\($0.id.prefix(8).lowercased()) \($0.name)" }.joined(separator: ", ")
            return .failure(.ambiguous("\(host) has \(offered.count) open windows; name one with --origin-window: \(names)"))
        }
        let ids = windows.compactMap { UUID(uuidString: $0.id) }
        guard case .resolved(let id) = ControlResolve.resolve(requested, candidates: ids, active: nil),
              let window = windows.first(where: { UUID(uuidString: $0.id) == id }) else {
            return .failure(.unknown("\(host) has no window \(requested)"))
        }
        if window.remote != nil { return .failure(.unknown("window \(window.name) on \(host) is a remote window itself")) }
        if !window.open { return .failure(.unknown("window \(window.name) is closed on \(host)")) }
        return .success(window)
    }
}
