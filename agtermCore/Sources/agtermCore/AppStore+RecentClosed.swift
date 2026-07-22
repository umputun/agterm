import Foundation

extension AppStore {
    @discardableResult
    public func restoreRecentClosed(_ item: RecentClosedItem) -> Bool {
        switch item.kind {
        case .session:
            guard let recent = item.session else { return false }
            if restoreOrSelectExistingRecentSession(recent) { return true }
            let index: Int
            if let existing = workspaces.firstIndex(where: { $0.id == recent.workspaceID }) {
                index = existing
            } else {
                let insertAt = max(0, min(recent.workspaceIndex, workspaces.count))
                workspaces.insert(rebuiltWorkspaceShell(id: recent.workspaceID, name: recent.workspaceName), at: insertAt)
                index = insertAt
            }
            let session = session(from: recent.snapshot)
            let insertAt = max(0, min(recent.sessionIndex, workspaces[index].sessions.count))
            workspaces[index].sessions.insert(session, at: insertAt)
            emitSessionCreated(session, workspace: workspaces[index].id)
            selectedSessionID = session.id
            replaceSidebarSelection(with: selectedSessionID)
            autoUnfocusIfOutsideFocus(selectedSessionID)
            recordRecency()
            save()
            return true
        case .workspace:
            guard let recent = item.workspace else { return false }
            if restoreOrSelectExistingRecentWorkspace(recent) { return true }
            var workspace = workspace(from: recent.snapshot)
            // a session of this snapshot may have been moved into another workspace that is itself pending
            // a close. its original object is alive in that record, so rebuild everything except it.
            let taken = Set(workspaces.flatMap(\.sessions).map(\.id)).union(pendingHeldSessionIDs())
            workspace.sessions.removeAll { taken.contains($0.id) }
            // Persistent Open Recent appends like most editors' recent-project flow:
            // reopening brings the workspace back without reshuffling current workspaces.
            workspaces.append(workspace)
            for session in workspace.sessions { emitSessionCreated(session, workspace: workspace.id) }
            if workspace.sessions.isEmpty { scheduleTreeChanged() }
            selectedSessionID = recent.selectedSessionID.flatMap { sessionID in
                workspace.sessions.contains { $0.id == sessionID } ? sessionID : nil
            } ?? workspace.sessions.first?.id
            replaceSidebarSelection(with: selectedSessionID)
            autoUnfocusIfOutsideFocus(selectedSessionID)
            recordRecency()
            save()
            return true
        }
    }

    private func restoreOrSelectExistingRecentSession(_ recent: RecentClosedSession) -> Bool {
        if let pendingID = pendingCloseID(containingSessionID: recent.snapshot.id) {
            return undoPendingClose(pendingID, selecting: recent.snapshot.id)
        }
        guard session(withID: recent.snapshot.id) != nil else { return false }
        selectSession(recent.snapshot.id)
        return true
    }

    private func restoreOrSelectExistingRecentWorkspace(_ recent: RecentClosedWorkspace) -> Bool {
        let sessionIDs = Set(recent.snapshot.sessions.map(\.id))
        // pending closes may hold this workspace, or any number of its sessions closed one at a time. undo
        // every match, not only the newest: an undo returns live sessions to the tree, and the merge below
        // skips rebuilding only what it can see there. a session left pending would be rebuilt from the
        // snapshot beside its live original, two objects under one id, and the original's surfaces torn
        // down once its grace expired. each undo drops its own record, so the loop drains them. falling
        // through matters too: returning an undo's result would report success while the caller deletes
        // the recent entry holding the sessions that undo did not restore.
        while let pendingID = pendingCloseID(forWorkspaceID: recent.snapshot.id, sessionIDs: sessionIDs) {
            undoPendingClose(pendingID)
        }
        if let index = workspaces.firstIndex(where: { $0.id == recent.snapshot.id }) {
            // reopening a session first rebuilds this workspace as a shell holding only that session, so
            // selecting without merging would drop the snapshot's other sessions while the caller deletes
            // the recent entry on success — their only copy. rebuild the ones that exist nowhere: not in
            // the tree, and not held by a pending close whose undo would reinsert the original.
            let taken = Set(workspaces.flatMap(\.sessions).map(\.id)).union(pendingHeldSessionIDs())
            let missing = recent.snapshot.sessions.filter { !taken.contains($0.id) }.map { session(from: $0) }
            workspaces[index].sessions.append(contentsOf: missing)
            for session in missing { emitSessionCreated(session, workspace: workspaces[index].id) }
            let target = recent.selectedSessionID.flatMap { id in
                workspaces[index].sessions.contains { $0.id == id } ? id : nil
            } ?? workspaces[index].sessions.first?.id
            if let target { selectSession(target) }
            save()
            return true
        }
        if let existingSession = workspaces.flatMap(\.sessions).first(where: { sessionIDs.contains($0.id) }) {
            selectSession(existingSession.id)
            return true
        }
        return false
    }

    private func pendingCloseID(containingSessionID sessionID: UUID) -> UUID? {
        for id in pendingCloseOrder.reversed() {
            guard let record = pendingCloseRecords[id] else { continue }
            switch record {
            // A grace-period reopen restores the grouped batch close as one undo record, matching
            // workspace close behavior while the record is still pending.
            case .sessions(let close) where close.sessions.contains(where: { $0.session.id == sessionID }):
                return id
            case .workspace(let close) where close.workspace.sessions.contains(where: { $0.id == sessionID }):
                return id
            default:
                continue
            }
        }
        return nil
    }

    /// A pending close this workspace's restore should consume. Only records of the workspace itself: a
    /// foreign workspace that merely holds one of the snapshot's sessions (moved there before it closed)
    /// is a close the user meant, and undoing it would resurrect a workspace they deliberately dismissed.
    /// The merge treats such a session as occupied instead, so it is never rebuilt beside the original.
    private func pendingCloseID(forWorkspaceID workspaceID: UUID, sessionIDs: Set<UUID>) -> UUID? {
        for id in pendingCloseOrder.reversed() {
            guard let record = pendingCloseRecords[id] else { continue }
            switch record {
            case .workspace(let close) where close.workspace.id == workspaceID:
                return id
            // a grouped member qualifies only when it was closed FROM this workspace — the same
            // workspace-scoping as the singular record; undoing it restores its whole group.
            case .sessions(let close) where close.sessions.contains(where: {
                $0.workspaceID == workspaceID && sessionIDs.contains($0.session.id)
            }):
                return id
            default:
                continue
            }
        }
        return nil
    }

    @discardableResult
    func recordRecentClosedSession(_ session: Session,
                                   workspaceID: UUID,
                                   workspaceName: String,
                                   workspaceIndex: Int,
                                   sessionIndex: Int,
                                   id: UUID = UUID()) -> UUID? {
        guard let recentClosedStore else { return nil }
        recentClosedStore.record(RecentClosedItem(
            id: id,
            kind: .session,
            title: session.displayName,
            subtitle: workspaceName,
            session: RecentClosedSession(workspaceID: workspaceID,
                                         workspaceName: workspaceName,
                                         workspaceIndex: workspaceIndex,
                                         sessionIndex: sessionIndex,
                                         snapshot: sessionSnapshot(session))
        ))
        recentClosedDidChange?()
        return id
    }

    @discardableResult
    func recordRecentClosedWorkspace(_ workspace: Workspace,
                                     selectedSessionID: UUID?,
                                     id: UUID = UUID()) -> UUID? {
        guard let recentClosedStore else { return nil }
        let sessionCount = workspace.sessions.count
        recentClosedStore.record(RecentClosedItem(
            id: id,
            kind: .workspace,
            title: workspace.name,
            subtitle: "\(sessionCount) session\(sessionCount == 1 ? "" : "s")",
            workspace: RecentClosedWorkspace(snapshot: workspaceSnapshot(workspace), selectedSessionID: selectedSessionID)
        ))
        recentClosedDidChange?()
        return id
    }

    func removeRecentClosedItem(_ id: UUID) {
        guard let recentClosedStore else { return }
        recentClosedStore.remove(id)
        recentClosedDidChange?()
    }
}
