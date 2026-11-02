import Foundation

/// Each workspace remembers the last directory a local pane of it reported over OSC 7, so the
/// `currentSession` new-session mode can open there even after the workspace empties.
extension AppStore {
    /// Records `path`, reported by a primary or split pane of `sessionID`, as its workspace's remembered
    /// folder. A session attached from another Mac is skipped: its paths name the other machine. No `save()`,
    /// like the pane cwd it shadows: OSC 7 fires on every prompt.
    public func rememberFolder(_ path: String, reportedBy sessionID: UUID) {
        guard let location = location(ofSession: sessionID),
              workspaces[location.workspaceIndex].sessions[location.sessionIndex].remoteHost == nil,
              let folder = Workspace.normalizedFolder(path),
              workspaces[location.workspaceIndex].rememberedFolder != folder else { return }
        workspaces[location.workspaceIndex].rememberedFolder = folder
    }

    /// The remembered folder of `workspaceID`, nil when unset or the workspace is gone.
    public func rememberedFolder(ofWorkspace workspaceID: UUID) -> String? {
        workspaces.first { $0.id == workspaceID }?.rememberedFolder
    }

    /// The first workspace in sidebar order whose remembered folder is identical to `cwd` once normalized.
    public func workspaceID(rememberingFolder cwd: String) -> UUID? {
        guard let folder = Workspace.normalizedFolder(cwd) else { return nil }
        return workspaces.first { $0.rememberedFolder == folder }?.id
    }
}
