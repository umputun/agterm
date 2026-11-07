import Foundation

/// CatalogRowContext is what building or updating a catalog row needs beyond the catalog entry itself.
struct CatalogRowContext {
    let host: String
    let protocolVersion: Int
    let effects: any RemoteCatalogEffects
}

extension AppStore {
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
                              paneIdentity: entry.panes.first?.identity ?? fields.primary, remoteHost: host)
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
        if fields.lifecycle == .ended {
            if !session.ended {
                session.ended = true
                // a pane that never started has no last screen to keep, and its daemon is gone
                if session.surface == nil { session.initialCommand = RemoteSession.endedCommand(host: host) }
                if session.hasSplit, session.splitSurface == nil {
                    session.splitInitialCommand = RemoteSession.endedCommand(host: host)
                }
                withdrawRemoteReplicas(of: session)
                context.effects.catalogRowEnded(session.id)
                scheduleTreeChanged()
            }
            return []
        }
        session.ended = false
        guard let primary = entry.panes.first else { return [] }
        var needsAttach: [UUID] = []
        let previous = session.remotePresentation?.binding
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
        if let state = session.remotePresentation {
            var updated = state
            updated.binding = Self.catalogBinding(entry, host: host, protocolVersion: state.binding.presentationVersion ?? 0)
            if updated != state { session.remotePresentation = updated }
        }
        return Array(Set(needsAttach))
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

    /// catalogBinding ties a row to its catalog session; local and catalog identities are the same.
    static func catalogBinding(_ entry: CatalogSession, host: String, protocolVersion: Int) -> RemoteBinding {
        let daemons = Dictionary(entry.panes.map { ($0.identity, $0.daemon) }) { first, _ in first }
        let origin = entry.panes.first.map {
            RemoteBinding.Origin(host: host, endpoint: $0.endpoint, sessionName: entry.id.uuidString)
        }
        return RemoteBinding(remoteSessionID: entry.id.uuidString, daemonsByLocalPane: daemons,
                             presentationVersion: protocolVersion, origin: origin, catalogOwned: true)
    }
}
