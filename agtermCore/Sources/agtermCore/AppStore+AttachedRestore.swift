import Foundation

/// Rows attached from another host in the launch snapshot: saved with their origin, attached again on relaunch.
extension AppStore {
    /// attachedSnapshots is `workspace`'s rows attached from another host, each with its place among the workspace's
    /// rows; nil when it has none.
    func attachedSnapshots(of workspace: Workspace) -> [AttachedSessionSnapshot]? {
        let rows = workspace.sessions.enumerated().compactMap { index, session -> AttachedSessionSnapshot? in
            session.attachedOrigin.map {
                AttachedSessionSnapshot(index: index, session: attachedSessionSnapshot(session), origin: $0,
                                        followedCompanions: session.followedCompanions.isEmpty ? nil : session.followedCompanions.sorted(),
                                        companionsBaselined: session.companionsBaselined ? true : nil)
            }
        }
        return rows.isEmpty ? nil : rows
    }

    private func attachedSessionSnapshot(_ session: Session) -> SessionSnapshot {
        let split = session.content == .terminal && session.hasSplit
        return SessionSnapshot(id: session.id, paneIdentity: session.content == .terminal ? session.paneIdentity : nil,
                               splitPaneIdentity: split ? session.splitPaneIdentity : nil, customName: session.customName,
                               cwd: Self.attachedCwd, isSplit: split ? session.isSplit : nil, hasSplit: split ? true : nil,
                               splitAxis: split ? session.splitAxis : nil, fontSize: session.fontSize,
                               splitRatio: split ? session.splitRatio : nil, flagged: session.flagged,
                               backgroundWatermark: session.backgroundWatermark,
                               paneBackgrounds: session.paneBackgrounds.persisted, context: session.context,
                               lastSelectedAt: session.lastSelectedAt?.timeIntervalSince1970, tint: session.tint,
                               parentID: session.parentID, collapsed: session.isExpanded ? nil : true,
                               ended: session.ended ? true : nil)
    }

    /// attachedSession rebuilds a saved attached row. A terminal row runs its saved attach lines again without a lead
    /// claim, reclaiming each pane's saved lead, and a page row waits for its origin to hand the page over.
    func attachedSession(from saved: AttachedSessionSnapshot) -> Session {
        let snapshot = saved.session
        let origin = saved.origin
        let page = origin.page == true
        let binding = origin.binding
        let splitIdentity = page || snapshot.hasSplit != true ? nil : snapshot.splitPaneIdentity
        let hasSplit = splitIdentity.flatMap(binding.daemon(forLocalPane:)) != nil
        let session = Session(id: snapshot.id, initialCwd: Self.attachedCwd, customName: snapshot.customName,
                              paneIdentity: snapshot.paneIdentity ?? UUID(), splitPaneIdentity: hasSplit ? splitIdentity : nil,
                              remoteHost: origin.host, remoteSessionID: origin.sessionID, content: page ? .page : .terminal)
        session.hasSplit = hasSplit
        session.isSplit = hasSplit && snapshot.isSplit == true
        session.splitAxis = hasSplit ? (snapshot.splitAxis ?? .leftRight) : .leftRight
        session.splitRatio = snapshot.splitRatio.map { min(AppStore.splitRatioMax, max(AppStore.splitRatioMin, $0)) }
        session.fontSize = snapshot.fontSize
        session.flagged = snapshot.flagged ?? false
        session.context = snapshot.context
        session.tint = snapshot.tint
        session.parentID = snapshot.parentID
        session.isExpanded = !(snapshot.collapsed ?? false)
        session.lastSelectedAt = snapshot.lastSelectedAt.map(Date.init(timeIntervalSince1970:))
        session.backgroundWatermark = snapshot.backgroundWatermark
        session.paneBackgrounds = PaneBackgrounds(left: snapshot.paneBackgrounds?.left,
                                                  right: hasSplit ? snapshot.paneBackgrounds?.right : nil)
        session.remotePresentation = RemotePresentationState(binding: binding)
        session.awaitsOriginCheck = true
        session.followedCompanions = Set(saved.followedCompanions ?? [])
        session.companionsBaselined = saved.companionsBaselined == true
        guard !page else {
            // a Mac's page row has no full stream (a root only observes membership), so its row says it waits for the
            // page until the origin hands it over
            session.remotePresentation?.connection = .connecting
            return session
        }
        session.commandWait = true
        guard let primary = attachLine(origin, pane: session.paneIdentity, role: .left) else {
            session.initialCommand = RemoteSession.endedCommand(host: origin.host)
            return session
        }
        session.initialCommand = primary
        if let split = session.splitPaneIdentity {
            session.splitInitialCommand = attachLine(origin, pane: split, role: .right)
            session.splitCommandWait = true
        }
        return session
    }

    // without a claim, so a lead someone used while this Mac was away stays theirs; the saved lead names the old
    // attach to take it back from, and zmx patch 0008 decides whether the current leader yields
    private func attachLine(_ origin: AttachedOriginSnapshot, pane: UUID, role: ZmxPaneRole) -> String? {
        guard let saved = origin.panes.first(where: { $0.pane == pane }) else { return nil }
        let lead = ZmxLeadAttachment(claim: false, reclaim: saved.lead)
        guard let line = try? RemoteSession.attachPaneCommand(host: origin.host, endpoint: origin.endpoint, daemon: saved.daemon,
                                                              session: origin.sessionName, pane: role, lead: lead) else { return nil }
        ZmxLeadBook.shared.begin(lead, pane: pane)
        return line
    }

    /// closeEndedAttachedRow closes row `id`, attached from another host, once its origin no longer has the session. Its
    /// companions stay, at the top level, and nothing goes to Recent Closed.
    public func closeEndedAttachedRow(_ id: UUID) {
        guard session(withID: id)?.attachedOrigin != nil else { return }
        _ = remoteSessionEnded(forSession: id)
        _ = closeExactly([id])
    }

    /// placingAttached puts each saved attached row back at its place among `sessions`, skipping an id already restored
    /// and a row saved ended, whose origin session is gone.
    func placingAttached(_ saved: [AttachedSessionSnapshot]?, among sessions: [Session], seen: inout Set<UUID>) -> [Session] {
        var placed = sessions
        for row in (saved ?? []).sorted(by: { $0.index < $1.index })
            where row.session.ended != true && seen.insert(row.session.id).inserted {
            placed.insert(attachedSession(from: row), at: min(max(row.index, 0), placed.count))
        }
        return placed
    }

    private static var attachedCwd: String { FileManager.default.homeDirectoryForCurrentUser.path }
}
