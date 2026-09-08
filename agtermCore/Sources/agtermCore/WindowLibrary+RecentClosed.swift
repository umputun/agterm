import Foundation

extension WindowLibrary {
    @discardableResult
    public func reopenRecentClosed(_ itemID: UUID, into targetStore: AppStore? = nil) -> Bool {
        reopenRecentClosedReportingWindow(itemID, into: targetStore) != nil
    }

    @discardableResult
    public func reopenLatestRecentClosed(into targetStore: AppStore? = nil) -> Bool {
        reopenLatestRecentClosedReportingWindow(into: targetStore) != nil
    }

    /// Reopen `itemID`, answering the window it was restored into so the caller can reveal it, or nil when
    /// nothing was restored. The window is not always the requested one: an entry whose workspace another
    /// window still holds is restored there, since two objects under one id make every id-keyed lookup
    /// answer with whichever window sorts first.
    ///
    /// The entry survives an incomplete restore. A snapshot member left in no window would otherwise become
    /// unreachable the moment the entry went, so Reopen stays available to finish the job.
    public func reopenRecentClosedReportingWindow(_ itemID: UUID, into targetStore: AppStore? = nil) -> UUID? {
        refreshRecentClosedItems()
        guard let item = recentClosedItems.first(where: { $0.id == itemID }),
              let store = restoreDestination(for: item, requested: targetStore),
              let windowID = windowID(for: store)
        else { return nil }
        let outcome = store.restoreRecentClosed(item, occupiedElsewhere: sessionIDsHeld(outside: store))
        guard outcome.restored else { return nil }
        if outcome.complete { recentClosedStore.remove(itemID) }
        refreshRecentClosedItems()
        return windowID
    }

    /// `reopenRecentClosedReportingWindow` over the newest entry.
    public func reopenLatestRecentClosedReportingWindow(into targetStore: AppStore? = nil) -> UUID? {
        refreshRecentClosedItems()
        guard let item = recentClosedItems.first else { return nil }
        return reopenRecentClosedReportingWindow(item.id, into: targetStore)
    }

    public func clearRecentClosedItems() {
        recentClosedStore.clear()
        refreshRecentClosedItems()
    }

    /// Which store restores `item`, in priority order: the window holding the session itself, then the one
    /// holding its workspace, then the requested store. Session before workspace because an old snapshot
    /// can leave one session in two windows, where the stale workspace rebuilds the copy just closed.
    private func restoreDestination(for item: RecentClosedItem, requested: AppStore?) -> AppStore? {
        if item.kind == .session, let id = item.session?.snapshot.id, let owner = storeHoldingSession(id) {
            return owner
        }
        if let owner = storeHoldingWorkspace(of: item) { return owner }
        return requested ?? activeStore
    }

    /// The open store holding `item`'s workspace: the workspace id itself for a workspace entry, the parent
    /// workspace for a session entry. Walks `openIDs()` so the answer never depends on dictionary order.
    private func storeHoldingWorkspace(of item: RecentClosedItem) -> AppStore? {
        let workspaceID: UUID?
        switch item.kind {
        case .session: workspaceID = item.session?.workspaceID
        case .workspace: workspaceID = item.workspace?.snapshot.id
        }
        guard let workspaceID else { return nil }
        return openStores().first {
            $0.workspaces.contains { $0.id == workspaceID } || $0.pendingHoldsWorkspace(workspaceID)
        }
    }

    /// The open store holding `sessionID`, live or parked in a pending close.
    private func storeHoldingSession(_ sessionID: UUID) -> AppStore? {
        openStores().first {
            $0.session(withID: sessionID) != nil || $0.pendingHeldSessionIDs().contains(sessionID)
        }
    }

    /// Every session id held by an open store other than `store`, live or parked in a pending close. The
    /// restoring store must rebuild none of these.
    private func sessionIDsHeld(outside store: AppStore) -> Set<UUID> {
        var ids: Set<UUID> = []
        for other in openStores() where other !== store {
            ids.formUnion(other.workspaces.flatMap(\.sessions).map(\.id))
            ids.formUnion(other.pendingHeldSessionIDs())
        }
        return ids
    }

    /// The open stores in window order.
    private func openStores() -> [AppStore] {
        openIDs().compactMap { store(for: $0) }
    }
}
