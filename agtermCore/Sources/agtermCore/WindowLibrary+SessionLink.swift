import Foundation

extension Session {
    /// showsOriginSession says whether this row presents origin session `id` of `host`'s zmx at `endpoint`.
    public func showsOriginSession(_ id: String, host: String, endpoint: ControlZmxEndpoint) -> Bool {
        guard remoteHost == host, let binding = remotePresentation?.binding else { return false }
        return binding.remoteSessionID == id && binding.origin?.endpoint == endpoint
    }
}

/// SessionLinkTarget is the open window and live row a clicked session link selects.
public struct SessionLinkTarget: Equatable, Sendable {
    public let windowID: UUID
    public let sessionID: UUID
}

extension WindowLibrary {
    public func sessionLinkTarget(_ id: UUID, from origin: LinkPolicy.ClickOrigin, pane: UUID?) -> SessionLinkTarget? {
        let clickedID: UUID
        switch origin {
        case .pane(let session), .remotePane(let session), .scratch(let session): clickedID = session
        case .hud, .programOverlay, .quick: return nil
        }
        guard let clicked = store(forSession: clickedID)?.session(withID: clickedID) else { return nil }
        let onOrigin: Bool
        if clicked.remoteHost == nil {
            onOrigin = false
        } else if case .scratch = origin {
            onOrigin = clicked.remotePresentation?.binding.catalogOwned == true
        } else {
            guard let binding = clicked.remotePresentation?.binding, let pane else { return nil }
            onOrigin = binding.remotePane(forLocal: pane) != nil
        }
        guard onOrigin else {
            return windowID(forSession: id).map { SessionLinkTarget(windowID: $0, sessionID: id) }
        }
        guard let host = clicked.remoteHost, let endpoint = clicked.remotePresentation?.binding.origin?.endpoint else { return nil }
        var target: SessionLinkTarget?
        for window in openIDs() {
            guard let store = store(for: window) else { continue }
            for row in store.workspaces.flatMap(\.sessions) where row.showsOriginSession(id.uuidString, host: host, endpoint: endpoint) {
                guard target == nil else { return nil }
                target = SessionLinkTarget(windowID: window, sessionID: row.id)
            }
        }
        return target
    }
}
