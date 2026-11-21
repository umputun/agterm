import Foundation
import agtermCore

/// Undo and Reopen Closed on agterm-server. An undoable close keeps its sessions and their daemons for the store's
/// grace; a reopened entry whose daemons already ended gets a fresh login shell in each pane, in its saved directory.
extension ServerActions {
    public func closeSession(_ target: String?, window: String?, undoable: Bool) -> ControlResponse {
        guard undoable else { return closeSession(target, window: window) }
        return withSession(target, window: window) { session in
            let closing = [session.id] + store.companions(of: session.id).map(\.id)
            guard store.softCloseSession(session.id) else { return ControlResponse(ok: false, error: "could not close session") }
            let recentID = store.pendingRecentID(ofClosedSession: session.id)?.uuidString
            let journaled = keepsGrace(closing)
            return ControlResponse(ok: true, result: ControlResult(
                id: session.id.uuidString, affected: closing.count > 1 ? closing.count : nil, undoable: journaled,
                closed: closing.map(\.uuidString), recentID: recentID,
                undoID: journaled ? store.pendingCloseID(ofSession: session.id)?.uuidString : nil))
        }
    }

    public func closeSessions(_ targets: [String], window: String?, undoable: Bool) -> ControlResponse {
        guard undoable else { return closeSessions(targets, window: window) }
        if let refusal = windowRefusal(window) { return refusal }
        let ids: [UUID]
        switch resolveSessionIDs(targets) {
        case .failure(let refusal): return refusal.response
        case .success(let resolved): ids = resolved
        }
        guard ids.count > 1 else {
            guard let id = ids.first else { return ControlResponse(ok: false, error: "session.close requires at least one --target") }
            return closeSession(id.uuidString, window: window, undoable: true)
        }
        let named = Set(ids)
        let roots = ids.filter { store.session(withID: $0)?.parentID.map(named.contains) != true }
        let closing = roots.flatMap { [$0] + store.companions(of: $0).map(\.id) }
        let closed = store.softCloseSessions(ids) ? closing : []
        let journaled = !closed.isEmpty && keepsGrace(closed)
        return ControlResponse(ok: true, result: ControlResult(
            affected: closed.count, undoable: journaled, closed: closed.map(\.uuidString),
            undoID: journaled ? closed.first.flatMap(store.pendingCloseID(ofSession:))?.uuidString : nil))
    }

    public func undoClose(_ undoID: String) -> ControlResponse {
        guard let id = UUID(uuidString: undoID) else { return ControlResponse(ok: false, error: "invalid undo id: \(undoID)") }
        let history = recentClosed?.load() ?? []
        guard store.undoPendingClose(id) else { return ControlResponse(ok: false, error: AppStore.closeNoLongerUndoable) }
        guard isDurable(keeping: history) else { return ControlResponse(ok: false, error: Self.notSaved) }
        return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
    }

    public func listRecentClosed() -> ControlResponse {
        guard let recentClosed else { return Self.noHistory }
        return ControlResponse(ok: true, result: ControlResult(recent: recentClosed.load().map(ControlRecentItem.init)))
    }

    public func listRecentClosed(window: String?) -> ControlResponse {
        windowRefusal(window) ?? listRecentClosed()
    }

    public func clearRecentClosed() -> ControlResponse {
        guard let recentClosed else { return Self.noHistory }
        recentClosed.clear()
        guard recentClosed.load().isEmpty else { return ControlResponse(ok: false, error: "could not clear recent items") }
        return ControlResponse(ok: true)
    }

    public func clearRecentClosed(window: String?) -> ControlResponse {
        windowRefusal(window) ?? clearRecentClosed()
    }

    /// openRecentClosed reopens an entry as the Mac does, a companion's recorded parent first. The entries leave the
    /// list only once every pane they rebuilt has started; a pane that cannot start ends what this reopen rebuilt.
    public func openRecentClosed(_ target: String?, window: String?) -> ControlResponse {
        if let refusal = windowRefusal(window) { return refusal }
        guard let recentClosed else { return Self.noHistory }
        let items = recentClosed.load()
        let id: UUID
        switch RecentClosedTarget.resolve(target, in: items) {
        case .failure(let error): return ControlResponse(ok: false, error: error.message)
        case .success(let resolved): id = resolved
        }
        guard let item = items.first(where: { $0.id == id }) else { return ControlResponse(ok: false, error: "could not reopen \(id.uuidString)") }
        var reopen = RecentReopen()
        if let refusal = reopenRecent(id, into: &reopen) {
            for session in reopen.rebuilt where store.session(withID: session) != nil { store.discardSession(session) }
            return refusal
        }
        guard isDurable(keeping: items) else { return ControlResponse(ok: false, error: Self.notSaved) }
        for entry in reopen.entries { recentClosed.remove(entry) }
        let open = ControlRecentOpen(item: ControlRecentItem(item), window: catalog.id.uuidString, complete: true)
        return ControlResponse(ok: true, result: ControlResult(recentOpen: open))
    }

    private static let noHistory = ControlResponse(ok: false, error: "agterm-server keeps no Recent Closed list here")
    private static let notSaved = "the change is open here but was not saved; Recent Closed keeps the sessions"

    /// keepsGrace keeps a fresh undoable close only once the journal names it; when that write fails, the close of
    /// `sessions` is made final at once, leaving every other pending close as it was.
    private func keepsGrace(_ sessions: [UUID]) -> Bool {
        guard pendingCloses?.record(store) ?? true else {
            for id in sessions { _ = store.finalizePendingClose(ofSession: id) }
            return false
        }
        noteSoftClose()
        return true
    }

    /// isDurable confirms a change the store made in memory once the catalog and the journal are both written. When
    /// either write fails it puts back the entries of `history` the change removed, so a restart that ends those
    /// sessions still leaves them in Recent Closed.
    private func isDurable(keeping history: [RecentClosedItem]) -> Bool {
        if store.saveChecked(), pendingCloses?.record(store) ?? true { return true }
        guard let recentClosed else { return false }
        let kept = Set(recentClosed.load().map(\.id))
        for item in history.reversed() where !kept.contains(item.id) { recentClosed.record(item) }
        return false
    }

    /// RecentReopen collects what one `recent.open` restored: the entries to drop once it succeeds and the sessions
    /// it rebuilt, which a failure ends again.
    private struct RecentReopen {
        var entries: [UUID] = []
        var rebuilt: [UUID] = []
    }

    private func reopenRecent(_ id: UUID, into reopen: inout RecentReopen) -> ControlResponse? {
        let items = recentClosed?.load() ?? []
        guard let item = items.first(where: { $0.id == id }) else { return ControlResponse(ok: false, error: "could not reopen \(id.uuidString)") }
        if let parentID = item.session?.snapshot.parentID, store.session(withID: parentID) == nil {
            guard let parentItem = items.first(where: { $0.restoresSession(parentID) }) else {
                return ControlResponse(ok: false, error: "parent session is not open or in Recent Closed")
            }
            if let refusal = reopenRecent(parentItem.id, into: &reopen) { return refusal }
        }
        let before = Set(store.workspaces.flatMap(\.sessions).map(\.id))
        guard store.restoreRecentClosed(item) else { return ControlResponse(ok: false, error: "could not reopen \(id.uuidString)") }
        reopen.entries.append(id)
        let rebuilt = store.workspaces.flatMap(\.sessions).filter { !before.contains($0.id) && $0.daemonBackedPanes.isEmpty }
        reopen.rebuilt += rebuilt.map(\.id)
        for session in rebuilt where session.content != .page {
            if let refusal = startRestoredPanes(session) { return ControlResponse(ok: false, error: refusal) }
            store.resumeEndedSession(session.id)
        }
        return nil
    }

    // a reopened pane gets a plain shell: the program it ran ended with its daemon
    private func startRestoredPanes(_ session: Session) -> String? {
        let workspace = store.sessionLocation(ofSession: session.id)?.workspace
        var roles: [(UUID, StatusPane)] = [(session.paneIdentity, .left)]
        if session.hasSplit, let split = session.splitPaneIdentity { roles.append((split, .right)) }
        for (identity, pane) in roles {
            let directory = session.cwd(for: pane == .left ? .left : .right)
            if let refusal = panes.start(.init(identity: identity, session: session, workspace: workspace, pane: pane, directory: directory)) {
                return refusal
            }
        }
        return nil
    }

    /// noteSoftClose rewrites the pending-close journal once the store's grace has finalized the close, which no
    /// served command does.
    private func noteSoftClose() {
        let delay = AppStore.pendingCloseGraceInterval + 0.5
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            pendingCloses?.record(store)
        }
    }
}
