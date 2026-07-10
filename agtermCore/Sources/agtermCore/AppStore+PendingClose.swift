import Foundation

/// The kind of close currently available to undo.
public enum PendingCloseKind: String, Sendable {
    case session
    case workspace
}

/// Observable domain summary for the latest undoable close. The app target decides how to present it.
public struct PendingCloseSummary: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: PendingCloseKind
    public let title: String

    public init(id: UUID, kind: PendingCloseKind, title: String) {
        self.id = id
        self.kind = kind
        self.title = title
    }
}

enum PendingCloseRecord {
    case session(PendingSessionClose)
    case workspace(PendingWorkspaceClose)
}

struct PendingSessionClose {
    let session: Session
    let workspaceID: UUID
    let workspaceName: String
    let workspaceIndex: Int
    let sessionIndex: Int
}

struct PendingWorkspaceClose {
    let workspace: Workspace
    let workspaceIndex: Int
    let selectedSessionID: UUID?
}

extension AppStore {
    public static let pendingCloseGraceInterval: TimeInterval = 3

    /// Hide a session from the visible tree but keep its surfaces alive for a short undo window.
    /// If the grace expires, `finalizePendingClose` performs the same teardown as `closeSession`.
    @discardableResult
    public func softCloseSession(_ sessionID: UUID, grace: TimeInterval = AppStore.pendingCloseGraceInterval) -> Bool {
        guard let location = location(ofSession: sessionID) else { return false }
        let workspace = workspaces[location.workspaceIndex]
        let wasActive = selectedSessionID == sessionID
        let session = workspaces[location.workspaceIndex].sessions.remove(at: location.sessionIndex)
        let closeID = UUID()
        pendingCloseRecords[closeID] = .session(PendingSessionClose(
            session: session,
            workspaceID: workspace.id,
            workspaceName: workspace.name,
            workspaceIndex: location.workspaceIndex,
            sessionIndex: location.sessionIndex
        ))
        pendingCloseOrder.append(closeID)
        recordRecentClosedSession(session, workspaceID: workspace.id, workspaceName: workspace.name,
                                  workspaceIndex: location.workspaceIndex, sessionIndex: location.sessionIndex,
                                  id: closeID)
        if wasActive {
            selectedSessionID = reselectionTarget(after: location)
            autoUnfocusIfOutsideFocus(selectedSessionID)
            recordRecency()
        }
        showPendingCloseSummary(id: closeID)
        schedulePendingCloseFinalization(id: closeID, grace: grace)
        cancelPendingSave()
        return true
    }

    /// Hide a workspace from the visible tree but keep all of its sessions alive for a short undo window.
    /// The last workspace cannot be soft-closed, matching `removeWorkspace`.
    @discardableResult
    public func softRemoveWorkspace(_ workspaceID: UUID, grace: TimeInterval = AppStore.pendingCloseGraceInterval) -> Bool {
        guard canRemoveWorkspace, let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return false }
        let workspace = foldingPendingCloses(of: workspaces.remove(at: index))
        let removingActive = selectedSessionID.map { id in workspace.sessions.contains { $0.id == id } } ?? false
        let restoringSelection = removingActive ? selectedSessionID : nil
        if focusedWorkspaceID == workspaceID { focusedWorkspaceID = nil }
        if removingActive {
            let fallbackIndex = min(index, workspaces.count - 1)
            selectedSessionID = workspaces[fallbackIndex].sessions.first?.id
                ?? workspaces.first(where: { !$0.sessions.isEmpty })?.sessions.first?.id
            autoUnfocusIfOutsideFocus(selectedSessionID)
            recordRecency()
        }

        let closeID = UUID()
        pendingCloseRecords[closeID] = .workspace(PendingWorkspaceClose(
            workspace: workspace,
            workspaceIndex: index,
            selectedSessionID: restoringSelection
        ))
        pendingCloseOrder.append(closeID)
        recordRecentClosedWorkspace(workspace, selectedSessionID: restoringSelection, id: closeID)
        showPendingCloseSummary(id: closeID)
        schedulePendingCloseFinalization(id: closeID, grace: grace)
        cancelPendingSave()
        return true
    }

    /// Undo the latest pending close, or a specific pending-close record when `id` is supplied.
    @discardableResult
    public func undoPendingClose(_ id: UUID? = nil) -> Bool {
        let closeID = id ?? pendingCloseSummary?.id
        guard let closeID, let record = pendingCloseRecords.removeValue(forKey: closeID) else { return false }
        pendingCloseTasks.removeValue(forKey: closeID)?.cancel()
        pendingCloseOrder.removeAll { $0 == closeID }
        switch record {
        case .session(let close):
            restorePendingSession(close)
        case .workspace(let close):
            restorePendingWorkspace(close)
        }
        removeRecentClosedItem(closeID)
        if pendingCloseSummary?.id == closeID { promotePendingCloseSummary() }
        save()
        return true
    }

    func finalizePendingClose(_ id: UUID) {
        guard let record = pendingCloseRecords.removeValue(forKey: id) else { return }
        pendingCloseTasks.removeValue(forKey: id)?.cancel()
        pendingCloseOrder.removeAll { $0 == id }
        switch record {
        case .session(let close):
            hardFinalizePendingSession(close.session)
        case .workspace(let close):
            hardFinalizePendingWorkspace(close.workspace)
        }
        if pendingCloseSummary?.id == id { promotePendingCloseSummary() }
        save()
    }

    public func finalizeAllPendingCloses() {
        for id in Array(pendingCloseRecords.keys) {
            finalizePendingClose(id)
        }
    }

    private func showPendingCloseSummary(id: UUID) {
        guard let record = pendingCloseRecords[id] else { return }
        pendingCloseSummary = summary(for: id, record: record)
    }

    private func promotePendingCloseSummary() {
        guard let id = pendingCloseOrder.last, let record = pendingCloseRecords[id] else {
            pendingCloseSummary = nil
            return
        }
        pendingCloseSummary = summary(for: id, record: record)
    }

    private func summary(for id: UUID, record: PendingCloseRecord) -> PendingCloseSummary {
        switch record {
        case .session(let close):
            return PendingCloseSummary(id: id, kind: .session, title: close.session.displayName)
        case .workspace(let close):
            return PendingCloseSummary(id: id, kind: .workspace, title: close.workspace.name)
        }
    }

    private func schedulePendingCloseFinalization(id: UUID, grace: TimeInterval) {
        pendingCloseTasks[id]?.cancel()
        let delay = UInt64(max(0, grace) * 1_000_000_000)
        pendingCloseTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            self?.finalizePendingClose(id)
        }
    }

    /// Absorb any pending close of the same workspace into the copy being closed now, dropping the
    /// superseded record. Undoing a session close rebuilds a missing workspace as a shell, so closing that
    /// shell while the earlier record still waits out its grace would leave two pending records sharing a
    /// workspace id. Both key one Open Recent entry by that id (`RecentClosedStore.record` dedupes on it),
    /// so the newer snapshot would evict the older one and its sessions would survive nowhere once both
    /// records finalize. The copy closed now is the newer state, so its name, expansion and session order
    /// lead; the superseded record's sessions follow.
    private func foldingPendingCloses(of workspace: Workspace) -> Workspace {
        var folded = workspace
        for closeID in pendingCloseOrder {
            guard case .workspace(let close)? = pendingCloseRecords[closeID], close.workspace.id == workspace.id else { continue }
            pendingCloseRecords.removeValue(forKey: closeID)
            pendingCloseTasks.removeValue(forKey: closeID)?.cancel()
            let present = Set(folded.sessions.map(\.id))
            folded.sessions.append(contentsOf: close.workspace.sessions.filter { !present.contains($0.id) })
        }
        pendingCloseOrder.removeAll { pendingCloseRecords[$0] == nil }
        return folded
    }

    /// Session ids a pending close still holds. They are absent from the tree, but their live objects are
    /// intact and an undo reinserts them, so a restore that rebuilt one from a snapshot would put two
    /// objects under a single id. Callers union this with the tree's ids to decide what is already taken.
    func pendingHeldSessionIDs() -> Set<UUID> {
        var held: Set<UUID> = []
        for record in pendingCloseRecords.values {
            switch record {
            case .session(let close):
                held.insert(close.session.id)
            case .workspace(let close):
                held.formUnion(close.workspace.sessions.map(\.id))
            }
        }
        return held
    }

    /// A workspace to stand in for one a restore needs but the tree no longer holds. Prefer the newest
    /// description of it: a pending close of that same workspace carries its live name and expansion state,
    /// and once those finalize an Open Recent snapshot still does. `name` is the caller's older copy, used
    /// only when neither describes the workspace.
    func rebuiltWorkspaceShell(id: UUID, name: String) -> Workspace {
        for closeID in pendingCloseOrder.reversed() {
            guard case .workspace(let close)? = pendingCloseRecords[closeID], close.workspace.id == id else { continue }
            return Workspace(id: id, name: close.workspace.name, isExpanded: close.workspace.isExpanded)
        }
        if let snapshot = recentClosedStore?.load().compactMap(\.workspace).first(where: { $0.snapshot.id == id })?.snapshot {
            return Workspace(id: id, name: snapshot.name, isExpanded: !(snapshot.collapsed ?? false))
        }
        return Workspace(id: id, name: name)
    }

    private func restorePendingSession(_ close: PendingSessionClose) {
        let workspaceIndex: Int
        if let existing = workspaces.firstIndex(where: { $0.id == close.workspaceID }) {
            workspaceIndex = existing
        } else {
            let insertAt = max(0, min(close.workspaceIndex, workspaces.count))
            workspaces.insert(rebuiltWorkspaceShell(id: close.workspaceID, name: close.workspaceName), at: insertAt)
            workspaceIndex = insertAt
        }
        let insertAt = max(0, min(close.sessionIndex, workspaces[workspaceIndex].sessions.count))
        workspaces[workspaceIndex].sessions.insert(close.session, at: insertAt)
        selectedSessionID = close.session.id
        autoUnfocusIfOutsideFocus(selectedSessionID)
        recordRecency()
    }

    private func restorePendingWorkspace(_ close: PendingWorkspaceClose) {
        // an undone session close, or an Open Recent restore, rebuilds a missing workspace by id as a
        // shell holding just that session. merge into the shell instead of inserting a second workspace
        // sharing its id: every id-keyed lookup resolves the first match, so a duplicate would strand the
        // other copy's sessions. the shell was seeded from this record, and anything the user changed on
        // it since is newer, so its name and expansion state stand. the shell also keeps its slot, so
        // `workspaceIndex` and this record's session order are not honored. the filter is defensive: a
        // session held by this record cannot already be live elsewhere.
        if let existing = workspaces.firstIndex(where: { $0.id == close.workspace.id }) {
            let live = Set(workspaces.flatMap(\.sessions).map(\.id))
            workspaces[existing].sessions.append(contentsOf: close.workspace.sessions.filter { !live.contains($0.id) })
        } else {
            let insertAt = max(0, min(close.workspaceIndex, workspaces.count))
            workspaces.insert(close.workspace, at: insertAt)
        }
        guard let target = close.selectedSessionID ?? close.workspace.sessions.first?.id else { return }
        selectedSessionID = target
        autoUnfocusIfOutsideFocus(selectedSessionID)
        recordRecency()
    }

    private func hardFinalizePendingSession(_ session: Session) {
        session.surface?.teardown()
        session.splitSurface?.teardown()
        session.overlaySurface?.teardown()
        session.scratchSurface?.teardown()
        WatermarkStorage.removeRenderedText(sessionID: session.id)
        removeFromRecency(session.id)
    }

    private func hardFinalizePendingWorkspace(_ workspace: Workspace) {
        for session in workspace.sessions {
            hardFinalizePendingSession(session)
        }
    }

}
