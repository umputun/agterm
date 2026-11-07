import Foundation
import agtermCore

/// What a Mac attaching to this host asks for: the attachable sessions, and a presentation stream for one of them.
extension ServerActions {
    /// remoteTree lists this server's attachable sessions with the zmx and socket directory a Mac attaches through.
    /// A host is refused: the server answers for itself and never reaches out.
    public func remoteTree(host: String?) async -> ControlResponse {
        if host != nil { return ControlResponse(ok: false, error: "agterm-server lists only its own sessions") }
        guard let listed = try? panes.runner.list() else {
            return ControlResponse(ok: false, error: "could not read the zmx session list")
        }
        // an err row carries no client count: zmx listed the name but could not reach the daemon
        let running = Set(listed.filter { $0.clients != nil }.map(\.name))
        var daemons: [String: [String: String]] = [:]
        for session in store.workspaces.flatMap(\.sessions) {
            var roles = [(session.paneIdentity, "left")]
            if session.hasSplit, let split = session.splitPaneIdentity { roles.append((split, "right")) }
            for (identity, role) in roles where session.daemonBackedPanes.contains(identity) {
                let name = ZmxSupport.daemonName(for: identity)
                if running.contains(name) { daemons[session.id.uuidString, default: [:]][role] = name }
            }
        }
        let tree = store.controlTree(paneForeground: { _ in nil }, app: identity)
        let window = RemoteWindowProjection(id: catalog.id.uuidString, name: catalog.name, tree: tree)
        let endpoint = ControlZmxEndpoint(executable: panes.configuration.zmxPath,
                                          socketDirectory: panes.configuration.zmxSocketDirectory)
        return ControlResponse(ok: true, result: ControlResult(remote: RemoteTreeMerger.candidates(windows: [window], daemons: daemons,
                                                                                                    endpoint: endpoint, headless: true)))
    }

    /// openPresentation answers `zmx.present`; the stream starts once this reply is on the wire.
    public func openPresentation(session target: String) -> ControlResponse {
        switch resolveSession(target) {
        case .failure(let refusal): return refusal.response
        case .success(let session):
            // a session whose panes are gone keeps a stream while its scratch still runs
            guard session.allPanesBackedByZmx || session.scratchDaemon != nil else {
                return ControlResponse(ok: false, error: "session is not live-backed, so nothing can be attached to it")
            }
            return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
        }
    }
}
