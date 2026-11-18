import Foundation

extension Session {
    /// showsOriginSession says whether this row presents origin session `id` of `host`'s zmx at `endpoint`.
    public func showsOriginSession(_ id: String, host: String, endpoint: ControlZmxEndpoint) -> Bool {
        guard remoteHost == host, let binding = remotePresentation?.binding else { return false }
        return binding.remoteSessionID == id && binding.origin?.endpoint == endpoint
    }

    /// isOriginlessCatalogRow matches on host and session id alone: a catalog row with no pane has no endpoint to compare.
    fileprivate func isOriginlessCatalogRow(_ id: String, host: String) -> Bool {
        guard remoteHost == host, let binding = remotePresentation?.binding, binding.catalogOwned, binding.origin == nil else {
            return false
        }
        return binding.remoteSessionID == id
    }
}

extension WindowLibrary {
    /// shownOriginSessions are the origin session ids of `host`'s zmx at `endpoint` that an open row anywhere here
    /// shows, as canonical UUID strings.
    public func shownOriginSessions(host: String, endpoint: ControlZmxEndpoint) -> Set<String> {
        Set(originRows(host: host, endpoint: endpoint).compactMap { $0.remotePresentation.map { Self.originID($0.binding.remoteSessionID) } })
    }

    /// rowsShowingOrigin are the open rows here showing origin session `id` of `host`'s zmx at `endpoint`, matched on
    /// the id in either case.
    public func rowsShowingOrigin(_ id: String, host: String, endpoint: ControlZmxEndpoint) -> [Session] {
        let wanted = Self.originID(id)
        return originRows(host: host, endpoint: endpoint).filter { $0.remotePresentation.map { Self.originID($0.binding.remoteSessionID) } == wanted }
    }

    private func originRows(host: String, endpoint: ControlZmxEndpoint) -> [Session] {
        allOpenSessions().filter { $0.remoteHost == host && $0.remotePresentation?.binding.origin?.endpoint == endpoint }
    }

    private static func originID(_ id: String) -> String { UUID(uuidString: id)?.uuidString ?? id }
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
            onOrigin = binding.remotePane(forLocal: pane) != nil || pane == clicked.originScratch
        }
        guard onOrigin else {
            return windowID(forSession: id).map { SessionLinkTarget(windowID: $0, sessionID: id) }
        }
        guard let host = clicked.remoteHost, let endpoint = clicked.remotePresentation?.binding.origin?.endpoint else { return nil }
        var target: SessionLinkTarget?
        for window in openIDs() {
            guard let store = store(for: window) else { continue }
            for row in store.workspaces.flatMap(\.sessions)
            where row.showsOriginSession(id.uuidString, host: host, endpoint: endpoint) || row.isOriginlessCatalogRow(id.uuidString, host: host) {
                guard target == nil else { return nil }
                target = SessionLinkTarget(windowID: window, sessionID: row.id)
            }
        }
        return target
    }
}
