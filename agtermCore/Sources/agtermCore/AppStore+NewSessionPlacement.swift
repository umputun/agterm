import Foundation

extension AppStore {
    /// The `addSession(at:)` slot for a new session in `workspaceID`: right after the selected session under
    /// `afterCurrent` when the selection lives in that workspace, else nil, which appends.
    public func newSessionInsertionIndex(inWorkspace workspaceID: UUID,
                                         placement: AppSettings.NewSessionPlacement) -> Int? {
        guard placement == .afterCurrent, let selectedSessionID,
              let location = sessionLocation(ofSession: selectedSessionID),
              location.workspace == workspaceID else { return nil }
        return location.index + 1
    }
}
