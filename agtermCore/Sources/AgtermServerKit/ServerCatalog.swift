import Foundation
import agtermCore

extension ServerActions {
    public func catalogSubscribe() -> ControlResponse { ControlResponse(ok: true) }

    /// catalogVersions is what this server advertises on `version` and in every catalog snapshot.
    var catalogVersions: CatalogVersions {
        CatalogVersions(server: identity.version, protocolVersion: PresentationCodec.version, catalog: CatalogCodec.version)
    }

    /// catalogWorkspaces is the headless store as the catalog: workspaces and sessions in order, each live session
    /// with its left pane and, while it has a split, its right one. An ended session and a page row list no pane.
    func catalogWorkspaces() -> [CatalogWorkspace] {
        let endpoint = ControlZmxEndpoint(executable: panes.configuration.zmxPath,
                                          socketDirectory: panes.configuration.zmxSocketDirectory)
        let projection = CatalogProjection(endpoint: endpoint) { pane in
            let count = MessageBus.shared.pending(for: pane)
            return count > 0 ? count : nil
        }
        return store.workspaces.map { workspace in
            projection.workspace(workspace, sessions: workspace.sessions.map { projection.session($0, scratch: $0.scratchDaemon) })
        }
    }
}
