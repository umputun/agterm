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
        let mail = { (pane: UUID) -> Int? in
            let count = MessageBus.shared.pending(for: pane)
            return count > 0 ? count : nil
        }
        return store.workspaces.map { workspace in
            CatalogWorkspace(id: workspace.id, name: workspace.name, tint: workspace.tint?.color.rawValue ?? "",
                             tintOn: workspace.tint?.parts.map(\.rawValue), sessions: workspace.sessions.map { session in
                var identities = [session.paneIdentity]
                if session.hasSplit, let split = session.splitPaneIdentity { identities.append(split) }
                let panes = session.ended || session.content == .page ? [] : identities.map {
                    CatalogPane(identity: $0, daemon: ZmxSupport.daemonName(for: $0), endpoint: endpoint, pendingMessages: mail($0))
                }
                let scratch = session.scratchDaemon.map {
                    CatalogScratch(pane: CatalogPane(identity: $0.identity, daemon: ZmxSupport.scratchDaemonName(for: $0.identity),
                                                     endpoint: endpoint, pendingMessages: mail($0.identity)), shown: $0.shown)
                }
                let page = session.content == .page ? session.htmlOverlay.map { overlay in
                    CatalogPage(kind: { if case .url = overlay.source { "url" } else { "file" } }(), identity: overlay.identity,
                                endpoint: endpoint)
                } : nil
                let fields = CatalogSessionFields(id: session.id, name: session.displayName, parent: session.parentID,
                                                  cwd: session.effectiveCwd, primary: page == nil ? session.paneIdentity : session.id,
                                                  axis: session.hasSplit ? session.splitAxis.rawValue : nil,
                                                  shown: session.hasSplit && session.isSplit,
                                                  lifecycle: session.ended ? .ended : .live, scratch: scratch, page: page,
                                                  customName: session.customName ?? "", flagged: session.flagged,
                                                  tint: session.tint?.color.rawValue ?? "", tintOn: session.tint?.parts.map(\.rawValue))
                return CatalogSession(fields: fields, panes: panes)
            })
        }
    }
}
