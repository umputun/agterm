import Foundation

/// RemoteDetachedItem is a detached workspace or session a remote window can reattach: one whose record is still in
/// the catalog and whose workspace and parent are shown.
public struct RemoteDetachedItem: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case session, workspace
    }

    public let kind: Kind
    public let id: UUID
    public let name: String
    public let ended: Bool
}

/// RemoteCloseScope is what closing a remote row reaches on the server: the row and, for a parent, every companion
/// in the catalog, detached ones included; `live` is whether any of them still runs.
public struct RemoteCloseScope: Equatable, Sendable {
    public let sessions: [UUID]
    public let live: Bool
}

extension RemoteCatalogMirror {
    /// detach hides sessions on this Mac and leaves them running on the server; a parent takes its companions with it.
    /// Nothing is sent, so it works while disconnected.
    public func detach(sessions ids: [UUID]) {
        store?.catalogDetachedSessions.formUnion(ids)
        detachChanged()
    }

    public func detach(workspace id: UUID) {
        store?.catalogDetachedWorkspaces.insert(id)
        detachChanged()
    }

    /// reattach shows a detached session again, answering why it cannot while its workspace or parent stays detached.
    public func reattach(session id: UUID) -> String? {
        guard let store, store.catalogDetachedSessions.contains(id) else { return "the session is not detached" }
        if let workspace = catalog?.workspaces.first(where: { $0.sessions.contains { $0.id == id } }),
           store.catalogDetachedWorkspaces.contains(workspace.id) {
            return "its workspace is detached; reattach the workspace"
        }
        if let parent = catalog?.session(id)?.fields.parent, store.catalogDetachedSessions.contains(parent) {
            return "its parent is detached; reattach the parent"
        }
        if catalog?.session(id)?.fields.lifecycle == .ended {
            return "the session has ended; session.close removes its record"
        }
        store.catalogDetachedSessions.remove(id)
        detachChanged()
        return nil
    }

    public func reattach(workspace id: UUID) -> String? {
        guard let store, store.catalogDetachedWorkspaces.contains(id) else { return "the workspace is not detached" }
        store.catalogDetachedWorkspaces.remove(id)
        detachChanged()
        return nil
    }

    /// detachedItems lists what can be reattached, in catalog order. A session under a detached workspace or parent is
    /// not listed: reattaching it is refused until that ancestor is reattached.
    public var detachedItems: [RemoteDetachedItem] {
        guard let catalog, let store else { return [] }
        var items: [RemoteDetachedItem] = []
        for workspace in catalog.workspaces {
            if store.catalogDetachedWorkspaces.contains(workspace.id) {
                items.append(RemoteDetachedItem(kind: .workspace, id: workspace.id, name: TerminalText.sanitized(workspace.name), ended: false))
                continue
            }
            for session in workspace.sessions where store.catalogDetachedSessions.contains(session.id) {
                if let parent = session.fields.parent, store.catalogDetachedSessions.contains(parent) { continue }
                items.append(RemoteDetachedItem(kind: .session, id: session.id, name: TerminalText.sanitized(session.fields.name),
                                                ended: session.fields.lifecycle == .ended))
            }
        }
        return items
    }

    /// canTerminateWorkspace is whether the server would delete a workspace: it keeps at least one, counting the ones
    /// this window detached.
    public var canTerminateWorkspace: Bool { (catalog?.workspaces.count ?? 0) > 1 }

    /// closeScope is what closing row `id` reaches on the server, nil for a row the catalog does not hold.
    public func closeScope(session id: UUID) -> RemoteCloseScope? {
        guard let catalog, let entry = catalog.session(id) else { return nil }
        let companions = entry.fields.parent == nil ? catalog.workspaces.flatMap(\.sessions).filter { $0.fields.parent == id } : []
        let group = [entry] + companions
        // a running scratch is live work, so an ended row that still has one is asked about, never cleaned up
        return RemoteCloseScope(sessions: group.map(\.id), live: group.contains { $0.fields.lifecycle == .live || $0.fields.scratch != nil })
    }

    /// scratchAttachmentStopped marks row `id`'s scratch attach as ended while the catalog still lists that scratch,
    /// answering its identity to reconnect; nil when the catalog no longer has it.
    public func scratchAttachmentStopped(of id: UUID) -> UUID? {
        guard let row = store?.session(withID: id), row.scratchSurface != nil, let scratch = catalog?.session(id)?.fields.scratch,
              row.scratchDaemon?.identity == scratch.pane.identity else { return nil }
        row.scratchStoppedGeneration = row.scratchGeneration
        return scratch.pane.identity
    }

    /// replaceScratchAttachment swaps a stopped scratch attach for a fresh one, leaving the scratch shown or hidden as
    /// the catalog has it. False when the catalog changed that scratch or another attach already replaced it.
    public func replaceScratchAttachment(of id: UUID, identity: UUID) -> Bool {
        guard let store, let effects, let row = store.session(withID: id), let scratch = catalog?.session(id)?.fields.scratch,
              scratch.pane.identity == identity, row.scratchDaemon?.identity == identity,
              row.scratchStoppedGeneration == row.scratchGeneration else { return false }
        store.replaceScratchSurface(row, command: effects.scratchAttachCommand(host: host, pane: scratch.pane))
        return true
    }

    /// shownCatalog is the catalog without what this window detached, after forgetting detached ids whose records the
    /// catalog no longer holds and keeping the views of the rows and workspaces the detach hides, defaults included.
    func shownCatalog(_ catalog: CatalogSnapshot, in store: AppStore) -> [CatalogWorkspace] {
        let all = catalog.workspaces.flatMap(\.sessions)
        let sessions = store.catalogDetachedSessions.intersection(all.map(\.id))
        let workspaces = store.catalogDetachedWorkspaces.intersection(catalog.workspaces.map(\.id))
        if sessions != store.catalogDetachedSessions || workspaces != store.catalogDetachedWorkspaces {
            store.catalogDetachedSessions = sessions
            store.catalogDetachedWorkspaces = workspaces
            effects?.catalogViewStateChanged()
        }
        let shown = catalog.workspaces.filter { !workspaces.contains($0.id) }.map { workspace in
            var copy = workspace
            copy.sessions = workspace.sessions.filter { !sessions.contains($0.id) && !($0.fields.parent.map(sessions.contains) ?? false) }
            return copy
        }
        let hidden = Set(all.map(\.id)).subtracting(shown.flatMap(\.sessions).map(\.id))
        for id in hidden where store.catalogHiddenViews[id] == nil {
            let view = store.session(withID: id).map(RemoteWindowViewState.SessionView.init(of:)) ?? viewState.sessions[id]
            if let view { store.catalogHiddenViews[id] = view }
        }
        let records = Set(all.map(\.id))
        store.catalogHiddenViews = store.catalogHiddenViews.filter { records.contains($0.key) }
        for id in workspaces where store.catalogHiddenCollapsed[id] == nil {
            let local = store.workspaces.first { $0.id == id }
            store.catalogHiddenCollapsed[id] = local.map { !$0.isExpanded } ?? viewState.collapsedWorkspaces.contains(id)
        }
        let workspaceRecords = Set(catalog.workspaces.map(\.id))
        store.catalogHiddenCollapsed = store.catalogHiddenCollapsed.filter { workspaceRecords.contains($0.key) }
        return shown
    }

    private func detachChanged() {
        reconcile()
        store?.scheduleTreeChanged()
        effects?.catalogViewStateChanged()
    }
}
