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

    private var visibleSidebarSessionIDs: [UUID] {
        navigableSessions.map(\.id)
    }
}
