import Foundation

/// CatalogRowContext is what building or updating a catalog row needs beyond the catalog entry itself.
struct CatalogRowContext {
    let host: String
    let protocolVersion: Int
    let effects: any RemoteCatalogEffects
}

extension AppStore {
    /// isRemoteWindow is whether this store mirrors a server's catalog.
    public var isRemoteWindow: Bool { catalogState != nil }

    /// serverActionsBlocked is whether a remote window's server cannot be asked for an action now.
    public var serverActionsBlocked: Bool { catalogState.map { $0 != .connected } ?? false }

    /// canCloseWorkspace is whether Delete Workspace can run: a remote window can detach any shown workspace, its last
    /// included; a local window keeps its last workspace.
    public var canCloseWorkspace: Bool { isRemoteWindow ? !workspaces.isEmpty : canRemoveWorkspace }

    /// prepareCatalogWorkspaces removes the rows of sessions the catalog no longer has and adds or renames its
    /// workspaces. Workspaces it no longer has leave in `finishCatalogWorkspaces`, once their surviving rows
    /// have moved out.
    func prepareCatalogWorkspaces(_ catalog: [CatalogWorkspace], collapsed: Set<UUID>, removed: (UUID) -> Void) {
        let wanted = Set(catalog.flatMap(\.sessions).map(\.id))
        for session in workspaces.flatMap(\.sessions) where !wanted.contains(session.id) {
            removed(session.id)
            closeSessionRow(session.id)
        }
        var changed = false
        for (index, entry) in catalog.enumerated() {
            let name = TerminalText.sanitized(entry.name)
            if let existing = workspaces.firstIndex(where: { $0.id == entry.id }) {
                if workspaces[existing].name != name {
                    workspaces[existing].name = name
                    changed = true
                }
                continue
            }
            workspaces.insert(Workspace(id: entry.id, name: name, isExpanded: !collapsed.contains(entry.id)),
                              at: min(index, workspaces.count))
            changed = true
        }
        if changed { scheduleTreeChanged() }
    }

    /// finishCatalogWorkspaces drops the workspaces the catalog no longer has and puts the rest in its order.
    func finishCatalogWorkspaces(_ catalog: [CatalogWorkspace]) {
        let order = catalog.map(\.id)
        let before = workspaces.map(\.id)
        workspaces.removeAll { !order.contains($0.id) }
        workspaces.sort { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
        if workspaces.map(\.id) != before { scheduleTreeChanged() }
    }

    /// moveCatalogSession puts an existing row at `index` of `workspaceID`, keeping its surfaces.
    func moveCatalogSession(_ session: Session, to workspaceID: UUID, at index: Int) {
        guard let destination = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        let current = workspaces[destination].sessions.firstIndex { $0.id == session.id }
        guard current != index else { return }
        for workspace in workspaces.indices { workspaces[workspace].sessions.removeAll { $0.id == session.id } }
        workspaces[destination].sessions.insert(session, at: min(index, workspaces[destination].sessions.count))
        scheduleTreeChanged()
    }

    /// insertCatalogSession creates the row for a catalog session, attaching each of its panes. An ended session
    /// gets a row and no attach.
    func insertCatalogSession(_ entry: CatalogSession, workspace workspaceID: UUID, at index: Int,
                              context: CatalogRowContext) -> Session {
        let host = context.host
        let fields = entry.fields
        let session = Session(id: fields.id, initialCwd: TerminalText.sanitized(fields.cwd),
                              customName: TerminalText.sanitized(fields.name).trimmedOrNil,
                              paneIdentity: entry.panes.first?.identity ?? fields.primary, remoteHost: host,
                              remoteSessionID: fields.id.uuidString, content: fields.page == nil ? .terminal : .page)
        session.parentID = fields.parent
        if fields.lifecycle == .ended {
            session.ended = true
            session.initialCommand = RemoteSession.endedCommand(host: host)
            session.commandWait = true
        } else if let primary = entry.panes.first {
            session.initialCommand = context.effects.attachCommand(host: host, pane: primary)
            session.commandWait = true
        }
        if fields.lifecycle == .live, entry.panes.count > 1 {
            addCatalogSplit(session, pane: entry.panes[1], fields: fields, context: context)
        }
        session.remotePresentation = RemotePresentationState(binding: Self.catalogBinding(entry, host: host,
                                                                                          protocolVersion: context.protocolVersion))
        if let at = workspaces.firstIndex(where: { $0.id == workspaceID }) {
            workspaces[at].sessions.insert(session, at: min(index, workspaces[at].sessions.count))
            emitSessionCreated(session, workspace: workspaceID)
        }
        applyCatalogScratch(session, fields.scratch, context: context)
        return session
    }

    /// updateCatalogSession moves an existing row to `entry`: name, cwd, parent, lifecycle, then its panes. It
    /// returns the panes that need a fresh attach. A live session listing no pane is between two catalog
    /// changes and keeps its layout, and an ended one keeps its surfaces, which hold the last screen.
    func updateCatalogSession(_ session: Session, to entry: CatalogSession, context: CatalogRowContext) -> [UUID] {
        let fields = entry.fields
        let host = context.host
        let name = TerminalText.sanitized(fields.name).trimmedOrNil
        if session.customName != name { session.customName = name }
        if session.currentCwd != fields.cwd { session.currentCwd = TerminalText.sanitized(fields.cwd) }
        if session.parentID != fields.parent { session.parentID = fields.parent }
        let presented = session.presentsCatalog
        applyCatalogScratch(session, fields.scratch, context: context)
        if fields.lifecycle == .ended {
            if !session.ended {
                session.ended = true
                // a pane that never started has no last screen to keep, and its daemon is gone
                if session.surface == nil { session.initialCommand = RemoteSession.endedCommand(host: host) }
                if session.hasSplit, session.splitSurface == nil {
                    session.splitInitialCommand = RemoteSession.endedCommand(host: host)
                }
                scheduleTreeChanged()
            }
            refreshCatalogOrigin(session, scratch: fields.scratch?.pane, host: host)
            // the stream outlives the panes while the scratch runs, and what it showed goes with it
            if presented, !session.presentsCatalog {
                withdrawRemoteReplicas(of: session)
                context.effects.catalogRowEnded(session.id)
            }
            if !presented, session.presentsCatalog { context.effects.catalogRowAdded(session) }
            return []
        }
        session.ended = false
        let previous = session.remotePresentation?.binding
        guard let primary = entry.panes.first else {
            refreshCatalogBinding(session, entry: entry, host: host)
            return []
        }
        var needsAttach: [UUID] = []
        if session.paneIdentity != primary.identity {
            if session.splitPaneIdentity == primary.identity {
                if entry.panes.count > 1, entry.panes[1].identity == session.paneIdentity {
                    swapPanes(session.id, allowingUnrealized: true)
                } else {
                    promoteSplit(session)
                    if session.surface == nil { needsAttach.append(primary.identity) }
                }
            } else {
                session.surface?.teardown()
                session.surface = nil
                session.paneIdentity = primary.identity
                session.initialCommand = context.effects.attachCommand(host: host, pane: primary)
                session.commandWait = true
                needsAttach.append(primary.identity)
            }
        }
        let split = entry.panes.count > 1 ? entry.panes[1] : nil
        if let split {
            if session.splitPaneIdentity != split.identity {
                if session.hasSplit { closeSplit(session.id) }
                addCatalogSplit(session, pane: split, fields: fields, context: context)
            } else {
                if let axis = fields.axis.flatMap(SplitAxis.init(rawValue:)), session.splitAxis != axis { session.splitAxis = axis }
                if session.isSplit != fields.shown { setSplitVisibility(session.id, shown: fields.shown) }
            }
        } else if session.hasSplit {
            closeSplit(session.id)
        }
        // a pane whose daemon or endpoint moved attaches again: one already running asks for a fresh attach, one
        // whose attach has not started gets the new command
        let endpointMoved = previous?.origin.map { $0.endpoint != primary.endpoint } ?? false
        for pane in entry.panes where endpointMoved || previous?.daemon(forLocalPane: pane.identity).map({ $0 != pane.daemon }) == true {
            if pane.identity == session.paneIdentity, session.surface == nil {
                session.initialCommand = context.effects.attachCommand(host: host, pane: pane)
            } else if pane.identity == session.splitPaneIdentity, session.splitSurface == nil {
                session.splitInitialCommand = context.effects.attachCommand(host: host, pane: pane)
            } else {
                needsAttach.append(pane.identity)
            }
        }
        refreshCatalogBinding(session, entry: entry, host: host)
        return Array(Set(needsAttach))
    }

    private func refreshCatalogBinding(_ session: Session, entry: CatalogSession, host: String) {
        guard let state = session.remotePresentation else { return }
        var updated = state
        updated.binding = Self.catalogBinding(entry, host: host, protocolVersion: state.binding.presentationVersion ?? 0)
        if updated != state { session.remotePresentation = updated }
    }

    /// applyCatalogScratch keeps a row's scratch on the server's: a shown one attaches its daemon, a hidden one keeps
    /// its surface, and a replaced or gone one closes it.
    private func applyCatalogScratch(_ session: Session, _ scratch: CatalogScratch?, context: CatalogRowContext) {
        if let current = session.scratchDaemon, current.identity != scratch?.pane.identity, !closeScratch(session.id) {
            // between two attaches there is no surface to close, and what the old scratch owned still goes
            if session.scratchActive { toggleScratch(session.id) }
            releaseScratchOwnedState(of: session, token: current.identity.uuidString)
        }
        if session.scratchDaemon?.identity != scratch?.pane.identity { session.scratchCommand = nil }
        let next = scratch.map { Session.ScratchDaemon(identity: $0.pane.identity, shown: $0.shown) }
        if session.scratchDaemon != next {
            session.scratchDaemon = next
            scheduleTreeChanged()
        }
        guard let scratch else { return }
        if scratch.shown, session.scratchSurface == nil, session.scratchCommand == nil {
            session.scratchCommand = context.effects.scratchAttachCommand(host: context.host, pane: scratch.pane)
        }
        if session.scratchActive != scratch.shown { toggleScratch(session.id) }
    }

    /// replaceScratchSurface drops a scratch surface whose attach ended without the scratch's own close, so the deck
    /// builds the next one from `command`; the scratch keeps its shown state and what its program owns.
    func replaceScratchSurface(_ session: Session, command: String) {
        if let old = session.scratchSurface {
            if session.searchSurface === old { session.clearSearch() }
            old.teardown()
        }
        session.scratchSurface = nil
        session.scratchStoppedGeneration = nil
        session.scratchCommand = command
        session.scratchGeneration += 1
    }

    private func addCatalogSplit(_ session: Session, pane: CatalogPane, fields: CatalogSessionFields,
                                 context: CatalogRowContext) {
        session.hasSplit = true
        session.splitPaneIdentity = pane.identity
        session.splitAxis = fields.axis.flatMap(SplitAxis.init(rawValue:)) ?? .leftRight
        session.splitInitialCommand = context.effects.attachCommand(host: context.host, pane: pane)
        session.splitCommandWait = true
        session.isSplit = fields.shown
        if fields.shown { emitPaneVisibility(.paneSplit, session: session, shown: true) }
    }

    /// refreshCatalogOrigin points an ended row at its running scratch's server; catalogBinding covers every other rebind.
    private func refreshCatalogOrigin(_ session: Session, scratch: CatalogPane?, host: String) {
        guard let scratch, let state = session.remotePresentation else { return }
        let origin = RemoteBinding.Origin(host: host, endpoint: scratch.endpoint, sessionName: session.id.uuidString)
        guard state.binding.origin != origin else { return }
        var updated = state
        updated.binding = state.binding.replacingOrigin(origin)
        session.remotePresentation = updated
    }

    /// catalogBinding ties a row to its catalog session; local and catalog identities are the same.
    static func catalogBinding(_ entry: CatalogSession, host: String, protocolVersion: Int) -> RemoteBinding {
        let daemons = Dictionary(entry.panes.map { ($0.identity, $0.daemon) }) { first, _ in first }
        let endpoint = (entry.panes.first ?? entry.fields.scratch?.pane)?.endpoint ?? entry.fields.page?.endpoint
        let origin = endpoint.map { RemoteBinding.Origin(host: host, endpoint: $0, sessionName: entry.id.uuidString) }
        return RemoteBinding(remoteSessionID: entry.id.uuidString, daemonsByLocalPane: daemons,
                             presentationVersion: protocolVersion, origin: origin, catalogOwned: true, originHeadless: true)
    }
}
