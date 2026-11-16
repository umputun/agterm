import Foundation

extension AppStore {
    /// Replaces the transient sidebar selection with ids from the current visible sidebar projection.
    public func setSidebarSelection(_ ids: [UUID]) {
        sidebarSelectionRaw = ids
    }

    /// Replaces the transient sidebar selection with a single active row.
    public func replaceSidebarSelection(with sessionID: UUID?) {
        sidebarSelectionRaw = sessionID.map { [$0] } ?? []
    }

    /// Context-menu target resolution for sidebar session commands.
    public func sidebarSelectionTargets(forContextSession clickedID: UUID?) -> [UUID] {
        let selectionIDs = sidebarSelectionIDs
        if let clickedID, selectionIDs.contains(clickedID) { return selectionIDs }
        if let clickedID, visibleSidebarSessionIDs.contains(clickedID) { return [clickedID] }
        if !selectionIDs.isEmpty { return selectionIDs }
        guard let selectedSessionID, visibleSidebarSessionIDs.contains(selectedSessionID) else { return [] }
        return [selectedSessionID]
    }

    /// The selected session ids that are still visible in the current sidebar mode/focus.
    public var sidebarSelectionIDs: [UUID] {
        let requested = Set(sidebarSelectionRaw)
        let normalized = visibleSidebarSessionIDs.filter { requested.contains($0) }
        guard let selectedSessionID else { return [] }
        return normalized.contains(selectedSessionID) ? normalized : []
    }

    func pruneSidebarSelection() {
        sidebarSelectionRaw = sidebarSelectionIDs
    }

    /// preservingSelection runs `body`, a change made from another Mac, without moving what the person at this window
    /// is looking at: selected row, sidebar selection, filter, fresh workspace and recency come back, and nothing in
    /// between is reported as a selection. A workspace undo or Recent Closed brought back keeps its focus mark, a new
    /// workspace's reveal is dropped, and when `body` removed the selected row its reselection stands and is reported.
    public func preservingSelection<T>(_ body: () async -> T) async -> T {
        let selected = selectedSessionID, sidebar = sidebarSelectionRaw, enabled = focusEnabled
        let focused = focusedWorkspaceIDs, fresh = freshWorkspaceID, recency = sessionRecency
        restoringSelection = true
        let result = await body()
        guard selected.map({ session(withID: $0) != nil }) ?? true else {
            restoringSelection = false
            if selectedSessionID != selected {
                activeSession?.lastSelectedAt = Date()
                emitSessionSelected(previous: selected)
            }
            return result
        }
        let revealed = freshWorkspaceID == fresh ? nil : freshWorkspaceID
        selectedSessionID = selected
        restoringSelection = false
        let live = Set(workspaces.flatMap(\.sessions).map(\.id))
        let liveWorkspaces = Set(workspaces.map(\.id))
        sidebarSelectionRaw = sidebar.filter(live.contains)
        focusedWorkspaceIDs = focused.union(focusedWorkspaceIDs.subtracting([revealed].compactMap { $0 })).intersection(liveWorkspaces)
        focusEnabled = enabled && !focusedWorkspaceIDs.isEmpty
        freshWorkspaceID = fresh.flatMap { liveWorkspaces.contains($0) ? $0 : nil }
        sessionRecency = RecencyStack(limit: recency.limit, items: recency.items.filter(live.contains))
        return result
    }

    private var visibleSidebarSessionIDs: [UUID] {
        navigableSessions.map(\.id)
    }
}
