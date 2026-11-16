import Foundation
import Observation

/// CatalogProjection builds catalog rows from a store's model: agterm-server's whole store, or one Mac window, where
/// `OriginCatalogProjection` decides which rows and panes run.
@MainActor
public struct CatalogProjection {
    public let endpoint: ControlZmxEndpoint
    /// mail is a pane's unacked message count, nil at none.
    public let mail: (UUID) -> Int?

    public init(endpoint: ControlZmxEndpoint, mail: @escaping (UUID) -> Int?) {
        self.endpoint = endpoint
        self.mail = mail
    }

    public func workspace(_ workspace: Workspace, sessions: [CatalogSession]) -> CatalogWorkspace {
        CatalogWorkspace(id: workspace.id, name: workspace.name, tint: workspace.tint?.color.rawValue ?? "",
                         tintOn: workspace.tint?.parts.map(\.rawValue), sessions: sessions)
    }

    public func pane(_ identity: UUID) -> CatalogPane {
        CatalogPane(identity: identity, daemon: ZmxSupport.daemonName(for: identity), endpoint: endpoint,
                    pendingMessages: mail(identity))
    }

    /// session is `session`'s row with every pane it has, primary first; an ended or page row carries none.
    public func session(_ session: Session, scratch: Session.ScratchDaemon?) -> CatalogSession {
        let page = session.content == .page ? session.htmlOverlay.map { overlay in
            CatalogPage(kind: { if case .url = overlay.source { "url" } else { "file" } }(), identity: overlay.identity,
                        endpoint: endpoint)
        } : nil
        let fields = CatalogSessionFields(id: session.id, name: session.displayName, parent: session.parentID,
                                          cwd: session.effectiveCwd, primary: page == nil ? session.paneIdentity : session.id,
                                          axis: session.hasSplit ? session.splitAxis.rawValue : nil,
                                          shown: session.hasSplit && session.isSplit,
                                          lifecycle: session.ended ? .ended : .live,
                                          scratch: scratch.map { CatalogScratch(pane: scratchPane($0.identity), shown: $0.shown) },
                                          page: page, customName: session.customName ?? "", flagged: session.flagged,
                                          tint: session.tint?.color.rawValue ?? "", tintOn: session.tint?.parts.map(\.rawValue))
        let panes = session.ended || page != nil ? [] : Self.identities(of: session).map(pane)
        return CatalogSession(fields: fields, panes: panes)
    }

    /// scratchPane is agterm-server's scratch daemon, named apart from its panes'; a Mac's Live scratch is an
    /// ordinary pane daemon, so `OriginCatalogProjection` replaces it.
    func scratchPane(_ identity: UUID) -> CatalogPane {
        CatalogPane(identity: identity, daemon: ZmxSupport.scratchDaemonName(for: identity), endpoint: endpoint,
                    pendingMessages: mail(identity))
    }

    /// identities are `session`'s panes, primary first.
    public static func identities(of session: Session) -> [UUID] {
        [session.paneIdentity] + (session.hasSplit ? [session.splitPaneIdentity].compactMap { $0 } : [])
    }
}

/// CatalogPaneEvidence is which of a Mac's pane daemons run, from its zmx inventory, plus the panes a
/// `session restart` is replacing, which stay listed through the kill.
public struct CatalogPaneEvidence: Equatable, Sendable {
    public var running: Set<UUID>
    public var restarting: Set<UUID>

    public init(running: Set<UUID> = [], restarting: Set<UUID> = []) {
        self.running = running
        self.restarting = restarting
    }

    /// init takes the claimed, running daemons of `inventory`, the rule `zmx tree` lists by.
    public init(inventory: ZmxInventoryResult, restarting: Set<UUID> = []) {
        let running = inventory.rows.filter { $0.state == .claimed && $0.observation == .running }.compactMap(\.claim?.paneIdentity)
        self.init(running: Set(running), restarting: restarting)
    }

    public func runs(_ pane: UUID) -> Bool { running.contains(pane) || restarting.contains(pane) }
}

/// OriginCatalogProjection is one Mac window's catalog. A terminal row is listed once a pane or its scratch runs or a
/// pane's program exited held, then keeps every pane, a stopped one held, until it leaves the store; a companion is
/// listed only with its parent.
/// Observed, so a `CatalogPublisher` republishes when the evidence changes.
@Observable
@MainActor
public final class OriginCatalogProjection {
    public var evidence = CatalogPaneEvidence()
    @ObservationIgnored private var listed: Set<UUID> = []

    public init() {}

    public func workspaces(of store: AppStore, projection: CatalogProjection) -> [CatalogWorkspace] {
        let present = Set(store.workspaces.flatMap(\.sessions).map(\.id))
        listed.formIntersection(present)
        let rows = store.workspaces.map { workspace in
            (workspace, workspace.sessions.compactMap { row($0, projection: projection) })
        }
        let shown = Set(rows.flatMap(\.1).map(\.id))
        return rows.map { workspace, sessions in
            projection.workspace(workspace, sessions: sessions.filter { $0.fields.parent.map(shown.contains) ?? true })
        }
    }

    private func row(_ session: Session, projection: CatalogProjection) -> CatalogSession? {
        guard session.remoteHost == nil else { return nil }
        let scratch = session.localScratchIdentity.flatMap { evidence.runs($0) ? $0 : nil }
        var row = projection.session(session, scratch: scratch.map { Session.ScratchDaemon(identity: $0, shown: session.scratchActive) })
        if let scratch { row.fields.scratch?.pane = projection.pane(scratch) }
        guard session.content == .terminal else { return row }
        let identities = CatalogProjection.identities(of: session)
        // a pane that has not started yet stays out; one whose program exited and is held is listed, held
        let exited = [session.surface, session.splitSurface].contains { $0?.childExitHeld == true }
        guard listed.contains(session.id) || identities.contains(where: evidence.runs) || scratch != nil || exited else { return nil }
        listed.insert(session.id)
        row.panes = identities.map { identity in
            var pane = projection.pane(identity)
            if !evidence.runs(identity) { pane.held = true }
            return pane
        }
        if session.ended || row.panes.allSatisfy({ $0.held == true }) { row.fields.lifecycle = .ended }
        return row
    }
}
