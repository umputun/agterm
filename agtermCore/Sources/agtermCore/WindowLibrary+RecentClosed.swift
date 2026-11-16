import Foundation

/// RecentClosedWindowRefusal is why a window could not reopen one of its own Recent Closed entries.
public enum RecentClosedWindowRefusal: Error, Equatable, Sendable {
    case notFound, lacksParent, elsewhere, failed

    public var message: String {
        switch self {
        case .notFound: "no such entry in this window's Recent Closed"
        case .lacksParent: "parent session is not open or in Recent Closed"
        case .elsewhere: "the entry's workspace or parent session is in another window; reopen it from that window"
        case .failed: "could not reopen the entry"
        }
    }
}

extension WindowLibrary {
    /// noteOriginRecentID records that `host` keeps its session `sessionID`, closed here, as its entry `recentID`.
    public func noteOriginRecentID(_ recentID: String, host: String, sessionID: String) {
        recentClosedStore.setOriginRecentID(recentID, host: host, sessionID: sessionID)
        refreshRecentClosedItems()
    }

    /// noteAttachedUndo keeps `undo` for ⌘Z in window `window` until its host's grace ends, when it leaves by itself.
    /// Replies can arrive out of order, so the list is kept ordered by when each terminate was asked for.
    public func noteAttachedUndo(_ undo: AttachedUndo, window: UUID, grace: TimeInterval = AppStore.pendingCloseGraceInterval) {
        var undos = attachedUndos[window] ?? []
        undos.insert(undo, at: undos.lastIndex { $0.initiated <= undo.initiated }.map { $0 + 1 } ?? 0)
        attachedUndos[window] = undos
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(grace))
            self?.dropAttachedUndo(undo, window: window)
        }
    }

    /// takeAttachedUndo removes and answers window `window`'s most recently asked-for attached undo.
    public func takeAttachedUndo(window: UUID) -> AttachedUndo? {
        guard let undo = attachedUndos[window]?.last else { return nil }
        dropAttachedUndo(undo, window: window)
        return undo
    }

    private func dropAttachedUndo(_ undo: AttachedUndo, window: UUID) {
        attachedUndos[window]?.removeAll { $0 == undo }
        if attachedUndos[window]?.isEmpty == true { attachedUndos[window] = nil }
    }

    /// removeRemoteRecentClosed drops an attached row's entry once its session is shown here again.
    public func removeRemoteRecentClosed(_ id: UUID) {
        recentClosedStore.remove(id)
        refreshRecentClosedItems()
    }

    /// undoPendingClose undoes the pending close `id` in the open store holding it; false when none does.
    public func undoPendingClose(_ id: UUID) -> Bool {
        openStores().contains { $0.undoPendingClose(id) }
    }

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
        reopenRecentClosedOutcome(itemID, into: targetStore)?.window
    }

    /// `reopenRecentClosedReportingWindow` plus whether the entry left the list. That is read from the
    /// reloaded list rather than the restore's coverage, because a failed write keeps the entry on disk.
    public func reopenRecentClosedOutcome(_ itemID: UUID, into targetStore: AppStore? = nil) -> RecentClosedReopen? {
        refreshRecentClosedItems()
        guard let item = recentClosedItems.first(where: { $0.id == itemID }) else { return nil }
        // a lone companion reopens only under its parent: a live one, or the entry holding the parent reopened
        // first, the parent's own or its removed workspace's
        if let parentID = item.session?.snapshot.parentID, openStores().allSatisfy({ $0.session(withID: parentID) == nil }) {
            guard let parentItem = recentClosedItems.first(where: { $0.restoresSession(parentID) }),
                  reopenRecentClosedOutcome(parentItem.id, into: targetStore) != nil else { return nil }
            refreshRecentClosedItems()
        }
        guard let item = recentClosedItems.first(where: { $0.id == itemID }),
              let store = restoreDestination(for: item, requested: targetStore),
              let windowID = windowID(for: store)
        else { return nil }
        let outcome = store.restoreRecentClosed(item, occupiedElsewhere: sessionIDsHeld(outside: store))
        guard outcome.restored else { return nil }
        if outcome.complete { recentClosedStore.remove(itemID) }
        refreshRecentClosedItems()
        return RecentClosedReopen(window: windowID, complete: !recentClosedItems.contains { $0.id == itemID })
    }

    /// recentClosedItemLacksParent says `itemID` is a lone companion whose parent is neither open nor held by
    /// another entry, the one reopen that cannot proceed.
    public func recentClosedItemLacksParent(_ itemID: UUID) -> Bool {
        guard let parentID = recentClosedItems.first(where: { $0.id == itemID })?.session?.snapshot.parentID,
              openStores().allSatisfy({ $0.session(withID: parentID) == nil }) else { return false }
        return !recentClosedItems.contains { $0.restoresSession(parentID) }
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

    /// recentClosedItems(inWindow:) is the window's own list, the one a remote window on another Mac mirrors:
    /// entries closed in it, never a remote row's entry or one saved before windows were recorded.
    public func recentClosedItems(inWindow window: UUID) -> [RecentClosedItem] {
        recentClosedItems.filter { $0.window == window }
    }

    public func clearRecentClosedItems(inWindow window: UUID) {
        recentClosedStore.clear(window: window)
        refreshRecentClosedItems()
    }

    /// reopenRecentClosed(_:inWindow:) reopens one of the window's own entries into it, and refuses one the
    /// restore-destination rule would send to another window, where the person at this Mac would not see it.
    public func reopenRecentClosed(_ itemID: UUID, inWindow window: UUID) -> Result<RecentClosedReopen, RecentClosedWindowRefusal> {
        refreshRecentClosedItems()
        guard let store = store(for: window),
              let item = recentClosedItems(inWindow: window).first(where: { $0.id == itemID }) else { return .failure(.notFound) }
        guard !recentClosedItemLacksParent(itemID) else { return .failure(.lacksParent) }
        guard !reopensElsewhere(item, than: store) else { return .failure(.elsewhere) }
        guard let outcome = reopenRecentClosedOutcome(itemID, into: store) else { return .failure(.failed) }
        return .success(outcome)
    }

    // a lone companion whose parent is closed follows the parent's entry, which reopens first
    private func reopensElsewhere(_ item: RecentClosedItem, than store: AppStore) -> Bool {
        if let parentID = item.session?.snapshot.parentID, openStores().allSatisfy({ $0.session(withID: parentID) == nil }),
           let parentItem = recentClosedItems.first(where: { $0.id != item.id && $0.restoresSession(parentID) }) {
            return reopensElsewhere(parentItem, than: store)
        }
        return restoreDestination(for: item, requested: store) !== store
    }

    /// Which store restores `item`, in priority order: the window holding the session itself, then the one
    /// holding its workspace, then the requested store. Session before workspace because an old snapshot
    /// can leave one session in two windows, where the stale workspace rebuilds the copy just closed.
    private func restoreDestination(for item: RecentClosedItem, requested: AppStore?) -> AppStore? {
        if item.kind == .session, let id = item.session?.snapshot.id, let owner = store(holdingSession: id) {
            return owner
        }
        if let parentID = item.session?.snapshot.parentID {
            return openStores().first { $0.session(withID: parentID) != nil }
        }
        if let owner = storeHoldingWorkspace(of: item) { return owner }
        // a closed item is always this Mac's own, and a remote window holds only its server's rows
        let fallback = requested ?? activeStore
        guard let fallback, isRemoteStore(fallback) else { return fallback }
        return openStores().first { !isRemoteStore($0) }
    }

    func isRemoteStore(_ store: AppStore) -> Bool {
        windowID(for: store).flatMap { id in windows.first { $0.id == id } }?.isRemote == true
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
    public func store(holdingSession sessionID: UUID) -> AppStore? {
        openStores().first {
            $0.session(withID: sessionID) != nil || $0.pendingCloseSession(withID: sessionID) != nil
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

extension RecentClosedItem {
    /// restoresSession says the entry rebuilds session `id`: a recorded parent may sit inside an entry as a companion,
    /// since Convert to Companion nests it after the record.
    public func restoresSession(_ id: UUID) -> Bool {
        switch kind {
        case .session: session?.snapshot.id == id || session?.companions?.contains { $0.id == id } == true
        case .workspace: workspace?.snapshot.sessions.contains { $0.id == id } == true
        }
    }
}
