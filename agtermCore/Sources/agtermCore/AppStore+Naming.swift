import Foundation

// MARK: - Naming

extension AppStore {
    /// Sets a session's custom name, with a blank value restoring its automatic display name.
    public func renameSession(_ sessionID: UUID, to name: String) {
        guard let session = session(withID: sessionID) else { return }
        // customName reaches {AGT_SESSION_NAME}, which expands unquoted into /bin/sh -c, so strip control
        // characters (a newline is a statement separator there) as the OSC path does. See TerminalText.
        let renamed = TerminalText.sanitized(name).trimmedOrNil
        guard session.customName != renamed else { return }
        session.customName = renamed
        scheduleTreeChanged()
        save()
    }

    /// Renames a workspace. Blank and same-value names are structural no-ops.
    public func renameWorkspace(_ workspaceID: UUID, to name: String) {
        // {AGT_WORKSPACE_NAME} expands unquoted into /bin/sh -c; strip control chars as the OSC path does (TerminalText).
        guard let trimmed = TerminalText.sanitized(name).trimmedOrNil,
              let index = workspaces.firstIndex(where: { $0.id == workspaceID }),
              workspaces[index].name != trimmed else { return }
        workspaces[index].name = trimmed
        scheduleTreeChanged()
        save()
    }
}
