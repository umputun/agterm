import Foundation

// MARK: - Cross-store session transfer

/// The two halves of moving a live session between windows. Each store owns its own persisted snapshot, so
/// a transfer is detach-then-adopt rather than one mutation; `WindowLibrary` composes them.
extension AppStore {
    /// Removes a session from this store and hands the **instance** back with every surface intact, so the
    /// caller can insert it into another store's tree and keep the live shell. Unlike `closeSession` there is
    /// no teardown, no `sessionClosed` event and no Reopen Closed Item record — the session is not gone, it
    /// is leaving this window. Reselects through the close path when it was active, prunes recency and the
    /// sidebar selection. Nil for an unknown id.
    public func detachSession(_ sessionID: UUID) -> Session? {
        guard let location = location(ofSession: sessionID) else { return nil }
        let wasActive = selectedSessionID == sessionID
        let session = workspaces[location.workspaceIndex].sessions.remove(at: location.sessionIndex)
        removeFromRecency(sessionID)
        if wasActive {
            selectedSessionID = closeReselectionTarget(after: location)
            replaceSidebarSelection(with: selectedSessionID)
            disableFocusIfSelectionOutsideSet(selectedSessionID)
            recordRecency()
        } else {
            pruneSidebarSelection()
        }
        scheduleTreeChanged()
        save()
        return session
    }

    /// Inserts a session instance detached from another store. A nil workspace lands in `currentWorkspaceID`
    /// (which already falls back to the last workspace); `index` nil appends, else inserts at the clamped
    /// position. `select` makes it this window's active session, matching `addSession(select:)`. False when
    /// the workspace is unknown or an equal id is already here — adopting a duplicate would fork identity
    /// across two stores.
    @discardableResult
    public func adoptSession(_ session: Session, toWorkspace workspaceID: UUID? = nil, at index: Int? = nil,
                             select: Bool = false) -> Bool {
        guard self.session(withID: session.id) == nil else { return false }
        guard let targetID = workspaceID ?? currentWorkspaceID,
              let wsIndex = workspaces.firstIndex(where: { $0.id == targetID }) else { return false }
        let count = workspaces[wsIndex].sessions.count
        workspaces[wsIndex].sessions.insert(session, at: max(0, min(index ?? count, count)))
        if select {
            selectedSessionID = session.id
            replaceSidebarSelection(with: session.id)
            disableFocusIfSelectionOutsideSet(session.id) // the destination workspace may sit outside the marked set
            recordRecency()
        }
        scheduleTreeChanged()
        save()
        return true
    }
}
