import Foundation

/// RemoteCatalogEffects is what reconciling a remote window needs from the app: the command that attaches a
/// pane, and the surface work a model change cannot do alone.
@MainActor
public protocol RemoteCatalogEffects: AnyObject {
    /// attachCommand attaches a pane, taking its lead from whoever holds it when `claim` is set.
    func attachCommand(host: String, pane: CatalogPane, claim: Bool) -> String
    /// scratchAttachCommand attaches a row's server scratch: no lead, and a lost link keeps its screen for a reconnect.
    func scratchAttachCommand(host: String, pane: CatalogPane) -> String
    /// catalogRowAdded starts what a row runs beside its panes, its presentation stream, while it is live or its
    /// scratch runs: the server refuses a stream for a session with neither.
    func catalogRowAdded(_ session: Session)
    func catalogRowRemoved(_ sessionID: UUID)
    /// catalogRowEnded stops what a row ran beside its panes once it has ended and has no scratch; the row and its
    /// screens stay.
    func catalogRowEnded(_ sessionID: UUID)
    /// catalogPaneNeedsAttach asks for a fresh attach of a pane whose slot holds no live surface for it: its
    /// daemon changed, or a promotion moved a pane whose attach had not started into the primary slot.
    func catalogPaneNeedsAttach(_ identity: UUID, session: UUID)
    /// catalogBound reports the catalog the server named; false stops the mirror, another window showing it.
    func catalogBound(_ catalogID: UUID) -> Bool
    func catalogStateChanged(_ state: RemoteCatalogMirror.State)
    /// catalogViewStateChanged asks for the window's view state to be saved now: a detach must outlive the app.
    func catalogViewStateChanged()
    /// catalogWorkspaceCollapsed folds a shown workspace row, as a user's collapse does.
    func catalogWorkspaceCollapsed(_ id: UUID)
    /// catalogClaimLead takes the lead of a pane whose attach already started, as a key press on its cover does.
    func catalogClaimLead(_ identity: UUID, session: UUID)
}

extension RemoteCatalogEffects {
    public func catalogViewStateChanged() {}
    public func catalogWorkspaceCollapsed(_: UUID) {}
    public func scratchAttachCommand(host: String, pane: CatalogPane) -> String { attachCommand(host: host, pane: pane, claim: false) }
    public func catalogClaimLead(_: UUID, session _: UUID) {}
}

/// RemoteCatalogMirror keeps one remote window's store equal to its server's catalog. Frames move the mirrored
/// snapshot; the store is then brought to that snapshot by identity, so a row is removed only when its session
/// is, an ended session keeps its row and last screen, and attachment exits never change the layout.
@MainActor
public final class RemoteCatalogMirror {
    public enum State: Equatable, Sendable {
        case connecting
        case connected
        case disconnected(String)
        /// refused is final: the origin cannot serve a remote window, so nothing retries.
        case refused(String)

        public var isRefused: Bool {
            if case .refused = self { return true }
            return false
        }

        /// windowNotice is what the window says about its connection, nil once it is up.
        public func windowNotice(host: String) -> String? {
            switch self {
            case .connecting: "Connecting to \(host)…"
            case .connected: nil
            case .disconnected(let reason): "Disconnected: \(reason). Retrying."
            case .refused(let reason): reason
            }
        }
    }

    public let host: String
    /// originWindow is the window of a Mac origin this mirror shows, nil for agterm-server's one catalog.
    public let originWindow: UUID?
    public private(set) var state: State = .connecting
    public private(set) var catalog: CatalogSnapshot?
    /// originIsMac is set when the origin advertised a Mac catalog rather than agterm-server's.
    public private(set) var originIsMac = false
    /// needsSnapshot is set by a gap in the revisions; the transport answers by subscribing again.
    public private(set) var needsSnapshot = false
    /// onCatalogMoved runs after every revision the mirror takes, with true for a whole snapshot.
    public var onCatalogMoved: (@MainActor (Bool) -> Void)?
    weak var store: AppStore?
    weak var effects: (any RemoteCatalogEffects)?
    var viewState: RemoteWindowViewState
    private var chunks = CatalogChunks()
    private var helloEpoch: String?
    private let pool: SshConnectionPool?
    private var pendingSelection: (id: UUID, from: UUID?)?
    private var pendingCollapse: Set<UUID> = []
    private var windowViewApplied = false
    /// openClaim is set for a window the user just opened: the rows of its first snapshot take the lead.
    private var openClaim: Bool
    /// claimingAll marks the reconcile of that first snapshot.
    private var claimingAll = false
    /// pendingClaims are rows this Mac created whose reply came before the catalog brought them.
    private var pendingClaims: Set<UUID> = []
    /// pendingSplitClaims are rows whose split this Mac added, until the catalog brings the split.
    private var pendingSplitClaims: Set<UUID> = []

    public init(host: String, store: AppStore, effects: any RemoteCatalogEffects, viewState: RemoteWindowViewState,
                pool: SshConnectionPool? = nil, originWindow: UUID? = nil, claimOnOpen: Bool = false) {
        self.host = host
        self.originWindow = originWindow
        self.openClaim = claimOnOpen
        self.pool = pool
        self.store = store
        self.effects = effects
        self.viewState = viewState
        store.catalogState = state
        store.catalogDetachedSessions = Set(viewState.detachedSessions)
        store.catalogDetachedWorkspaces = Set(viewState.detachedWorkspaces)
    }

    /// checkVersions judges what the origin's `version` advertised before anything subscribes: `versions` from
    /// agterm-server, `mac` from a Mac app serving its windows. A refusal names the host and what it runs, and ends
    /// retries.
    @discardableResult
    public func checkVersions(_ versions: CatalogVersions?, mac: CatalogVersions? = nil, app: AppIdentity?) -> Bool {
        let refusal = Self.versionRefusal(host: host, versions: versions, mac: mac, app: app)
        if let refusal { setState(.refused(refusal)) }
        originIsMac = versions == nil && mac != nil
        return refusal == nil
    }

    static func versionRefusal(host: String, versions: CatalogVersions?, mac: CatalogVersions? = nil,
                               app: AppIdentity?) -> String? {
        let build = app.map { "agterm \($0.version)" } ?? "an agterm"
        guard let versions = versions ?? mac else {
            return "\(host) runs \(build), which cannot serve a remote window; update agterm there or run agterm-server"
        }
        guard versions.catalog >= 1, versions.catalog <= CatalogCodec.version else {
            return "\(host) speaks catalog \(versions.catalog), this Mac speaks catalog \(CatalogCodec.version)"
        }
        guard versions.protocolVersion >= 1 else {
            return "\(host) speaks presentation \(versions.protocolVersion), this Mac speaks presentation \(PresentationCodec.version)"
        }
        return nil
    }

    /// selectedSessionID is the window's selection, the baseline a created row is selected against.
    var selectedSessionID: UUID? { store?.selectedSessionID }

    /// ownsFlags is whether the server keeps flag and tint. One predating them sends no workspace tint, and its
    /// window keeps both on this Mac; a server always keeps a workspace, so its catalog tells which.
    public var ownsFlags: Bool { catalog?.workspaces.contains { $0.tint != nil } == true }

    /// allFlagged is whether every session of the server's workspace `id` is flagged, rows this window detached
    /// included; false for an empty or unknown one.
    public func allFlagged(inWorkspace id: UUID) -> Bool {
        guard let sessions = catalog?.workspaces.first(where: { $0.id == id })?.sessions, !sessions.isEmpty else { return false }
        return sessions.allSatisfy { $0.fields.flagged == true }
    }

    /// hasSessions is whether the server's workspace `id` has any session, rows this window detached included.
    public func hasSessions(inWorkspace id: UUID) -> Bool {
        catalog?.workspaces.first { $0.id == id }?.sessions.isEmpty == false
    }

    /// parkedFlags are the server's flagged sessions with no row here: those this window detached, and those not
    /// shown yet.
    var parkedFlags: Set<UUID> {
        guard let catalog, let store else { return [] }
        let flagged = catalog.workspaces.flatMap(\.sessions).filter { $0.fields.flagged == true }.map(\.fields.id)
        return Set(flagged.filter { store.session(withID: $0) == nil })
    }

    /// flaggedCount is how many sessions on the server are flagged, rows this window detached included.
    public var flaggedCount: Int { catalog?.workspaces.flatMap(\.sessions).count { $0.fields.flagged == true } ?? 0 }

    /// collapseWhenShown folds workspace `id`, created for this window with `--collapsed`, whether its row is already
    /// shown or arrives later.
    func collapseWhenShown(_ id: UUID) {
        guard let store else { return }
        guard store.workspaces.contains(where: { $0.id == id }) else {
            pendingCollapse.insert(id)
            return
        }
        effects?.catalogWorkspaceCollapsed(id)
    }

    /// selectWhenShown selects row `id` once the catalog brings it, unless the selection has moved from `baseline`,
    /// the one it had when the row was asked for.
    public func selectWhenShown(_ id: UUID, from baseline: UUID?) {
        guard let store, store.selectedSessionID == baseline else { return }
        guard store.session(withID: id) == nil else {
            store.selectSession(id)
            return
        }
        pendingSelection = (id, baseline)
    }

    /// claimLeadWhenShown takes the lead of a row this Mac created on a Mac origin, now or once the catalog brings it.
    /// A reconnect drops a claim still waiting for its row.
    public func claimLeadWhenShown(_ id: UUID) {
        guard originIsMac, let store, let effects else { return }
        guard let row = store.session(withID: id), let entry = catalog?.session(id) else {
            pendingClaims.insert(id)
            return
        }
        store.claimCatalogLead(row, panes: entry.panes, host: host, effects: effects)
    }

    /// claimSplitWhenShown takes the lead of the split this Mac added to row `id` on a Mac origin, now or once the
    /// catalog lists it running, which comes after a held first listing while its daemon starts; the row's primary
    /// keeps whoever leads it.
    public func claimSplitWhenShown(_ id: UUID) {
        guard originIsMac else { return }
        pendingSplitClaims.insert(id)
        claimPendingSplit(id)
    }

    private func claimPendingSplit(_ id: UUID) {
        guard let store, let effects, let row = store.session(withID: id), row.hasSplit, !row.ended,
              let split = catalog?.session(id)?.panes.dropFirst().first, split.identity == row.splitPaneIdentity,
              split.held != true else { return }
        pendingSplitClaims.remove(id)
        store.claimCatalogLead(row, panes: [split], host: host, effects: effects)
    }

    /// subscribing marks a new stream: until its snapshot arrives the window shows Connecting, keeping its rows.
    public func subscribing() {
        pendingClaims.removeAll()
        pendingSplitClaims.removeAll()
        guard !isRefused else { return }
        needsSnapshot = false
        chunks = CatalogChunks()
        helloEpoch = nil
        setState(.connecting)
    }

    /// connectionLost keeps the last rows and screens and shows Disconnected; nothing is queued for the server.
    public func connectionLost(_ reason: String) {
        guard !isRefused else { return }
        setState(.disconnected(reason))
    }

    /// receive takes one stream frame and returns what to send back.
    public func receive(_ frame: CatalogFrame) -> CatalogFrame? {
        guard !isRefused else { return nil }
        switch frame {
        case .hello(let hello):
            if let refusal = Self.versionRefusal(host: host, versions: hello.versions, app: nil) {
                setState(.refused(refusal))
                return nil
            }
            helloEpoch = hello.epoch
        case .snapshot(let snapshot):
            take(snapshot)
        case .chunk(let index, let data):
            do { try chunks.add(index: index, data: data) } catch { needsSnapshot = true }
        case .commit(let epoch, let rev, let count):
            do { take(try chunks.commit(epoch: epoch, rev: rev, chunks: count)) } catch { needsSnapshot = true }
        case .delta(let epoch, let rev, let change):
            guard advance(epoch: epoch, rev: rev) else { return nil }
            catalog?.apply(change)
            catalog?.rev = rev
            reconcile()
            onCatalogMoved?(false)
        case .refused(let reason, let final):
            if final { setState(.refused(reason)) } else { connectionLost(reason) }
        case .unknown(_, let epoch, let rev):
            // a newer server's change this Mac cannot read moves the cursor past it; the next snapshot heals it
            if let epoch, let rev, advance(epoch: epoch, rev: rev) {
                catalog?.rev = rev
                onCatalogMoved?(false)
            }
        case .ping: return .ack
        case .ack: break
        }
        return nil
    }

    private var isRefused: Bool { state.isRefused }

    /// advance accepts the next revision of the mirrored epoch; another epoch or a gap asks for a snapshot,
    /// and a revision already seen is dropped.
    private func advance(epoch: String, rev: Int) -> Bool {
        guard let catalog, !needsSnapshot else { return false }
        guard epoch == catalog.epoch, rev == catalog.rev + 1 else {
            if epoch != catalog.epoch || rev > catalog.rev + 1 { needsSnapshot = true }
            return false
        }
        return true
    }

    private func take(_ snapshot: CatalogSnapshot) {
        if let helloEpoch, helloEpoch != snapshot.epoch {
            needsSnapshot = true
            return
        }
        guard effects?.catalogBound(snapshot.catalogID) != false else {
            setState(.refused("another window already shows the catalog of \(host)"))
            return
        }
        catalog = snapshot
        needsSnapshot = false
        store?.catalogMirrored = true
        claimingAll = openClaim && originIsMac
        openClaim = false
        reconcile()
        claimingAll = false
        if !windowViewApplied, let store {
            windowViewApplied = true
            viewState.applyWindow(to: store, parked: parkedFlags)
        }
        setState(.connected)
        onCatalogMoved?(true)
    }

    /// selectRow keeps a selection that still names a row, else takes the saved one, else the first row.
    private func selectRow() {
        guard let store, store.selectedSessionID.flatMap(store.session(withID:)) == nil else { return }
        let saved = viewState.selectedSessionID.flatMap(store.session(withID:))
        if let target = saved ?? store.workspaces.flatMap(\.sessions).first { store.selectSession(target.id) }
    }

    private func setState(_ next: State) {
        guard next != state else { return }
        state = next
        store?.catalogState = next
        store?.scheduleTreeChanged()
        effects?.catalogStateChanged(next)
    }

    // MARK: reconcile

    func reconcile() {
        guard let catalog, let store, let effects else { return }
        let shown = shownCatalog(catalog, in: store)
        var collapsed = Set(viewState.collapsedWorkspaces)
        for (id, isCollapsed) in store.catalogHiddenCollapsed {
            if isCollapsed { collapsed.insert(id) } else { collapsed.remove(id) }
        }
        collapsed.formUnion(pendingCollapse)
        pendingCollapse.subtract(shown.map(\.id))
        let flaggedOrder = store.flaggedOrder
        store.prepareCatalogWorkspaces(shown, collapsed: collapsed) { removed in
            effects.catalogRowRemoved(removed)
        }
        store.keepFlaggedSlots(of: parkedFlags, from: flaggedOrder)
        for workspace in shown {
            store.catalogHiddenCollapsed[workspace.id] = nil
            if store.catalogHiddenFocus.remove(workspace.id) != nil { store.markFocusMember(workspace.id) }
        }
        defer { store.finishCatalogWorkspaces(shown) }
        let context = CatalogRowContext(host: host, protocolVersion: catalog.versions.protocolVersion, effects: effects,
                                        headless: !originIsMac)
        for workspace in shown {
            for (index, session) in workspace.sessions.enumerated() {
                if let local = store.session(withID: session.id) {
                    store.moveCatalogSession(local, to: workspace.id, at: index)
                    for pane in store.updateCatalogSession(local, to: session, context: context) {
                        effects.catalogPaneNeedsAttach(pane, session: local.id)
                    }
                    if pendingSplitClaims.contains(local.id) { claimPendingSplit(local.id) }
                    continue
                }
                let claim = originIsMac && (pendingClaims.remove(session.id) != nil || claimingAll)
                let row = store.insertCatalogSession(session, workspace: workspace.id, at: index, context: context, claim: claim)
                if let kept = store.catalogHiddenViews.removeValue(forKey: row.id) { kept.apply(to: row) } else { viewState.apply(to: row) }
                if row.presentsCatalog { effects.catalogRowAdded(row) }
            }
        }
        if let pending = pendingSelection, store.session(withID: pending.id) != nil {
            pendingSelection = nil
            if store.selectedSessionID == pending.from { store.selectSession(pending.id) }
        }
        selectRow()
        // a pane the catalog dropped gives its channel back; the attaches above leased the ones it lists
        let sessions = shown.flatMap(\.sessions)
        let panes = (sessions.flatMap(\.panes) + sessions.compactMap(\.fields.scratch?.pane)).map { "pane:\($0.identity)" }
        pool?.retain(Set(panes), prefix: "pane:")
    }
}
