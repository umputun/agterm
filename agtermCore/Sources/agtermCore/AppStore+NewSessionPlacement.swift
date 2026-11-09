import Foundation

extension AppStore {
    /// newSessionInsertionIndex returns the slot after the selection in `workspaceID` for `afterCurrent`,
    /// or nil to append.
    public func newSessionInsertionIndex(inWorkspace workspaceID: UUID,
                                         placement: AppSettings.NewSessionPlacement) -> Int? {
        guard placement == .afterCurrent, let selectedSessionID,
              let location = sessionLocation(ofSession: selectedSessionID),
              location.workspace == workspaceID else { return nil }
        return location.index + 1
    }

    /// newSessionDirectorySource is the session whose cwd a "current session" new session in `workspaceID`
    /// inherits. Like placement, it takes the selection only inside that workspace; otherwise it takes the
    /// workspace's most recent session, or its first when none is recent. Only an empty workspace falls
    /// back to the selection.
    public func newSessionDirectorySource(inWorkspace workspaceID: UUID) -> Session? {
        let sessions = workspaces.first(where: { $0.id == workspaceID })?.sessions ?? []
        guard !sessions.isEmpty else { return activeSession }
        if let active = activeSession, sessions.contains(where: { $0.id == active.id }) { return active }
        let recent = sessionRecency.top(1, in: Set(sessions.map(\.id))).first
        return sessions.first(where: { $0.id == recent }) ?? sessions.first
    }
}
