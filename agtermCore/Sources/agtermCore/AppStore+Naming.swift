import Foundation

// MARK: - Naming

extension AppStore {
    /// Sets a session's custom name, with a blank value restoring its automatic display name.
    public func renameSession(_ sessionID: UUID, to name: String) {
        guard let session = session(withID: sessionID) else { return }
        // customName feeds {AGT_SESSION_NAME}; see TerminalText.
        let renamed = TerminalText.sanitized(name).trimmedOrNil
        guard session.customName != renamed else { return }
        session.customName = renamed
        scheduleTreeChanged()
        save()
    }

    /// Renames a workspace. Blank and same-value names are structural no-ops.
    public func renameWorkspace(_ workspaceID: UUID, to name: String) {
        // the name feeds {AGT_WORKSPACE_NAME}; see TerminalText.
        guard let trimmed = TerminalText.sanitized(name).trimmedOrNil,
              let index = workspaces.firstIndex(where: { $0.id == workspaceID }),
              workspaces[index].name != trimmed else { return }
        workspaces[index].name = trimmed
        scheduleTreeChanged()
        save()
    }

    /// The sidebar labels for `sessionIDs`, in the order given, skipping ids no longer in the tree.
    ///
    /// A session's label is `displayName` — the manual rename if there is one, else the pane's terminal
    /// title, else the cwd basename — so this is what the row actually reads, not the stored `customName`
    /// (usually nil) nor `{AGT_SESSION_NAME}` (the title alone).
    public func sessionDisplayNames(_ sessionIDs: [UUID]) -> [String] {
        sessionIDs.compactMap { session(withID: $0)?.displayName }
    }

    /// The name of `workspaceID`, or nil when it is gone.
    public func workspaceName(_ workspaceID: UUID) -> String? {
        workspaces.first(where: { $0.id == workspaceID })?.name
    }
}
