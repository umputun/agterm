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

    /// listLabel names a session in a list that drops the tree: `parent › child` for a companion. The
    /// sidebar tree, rename and Copy Name keep the bare `displayName`.
    public func listLabel(for session: Session) -> String {
        guard let parent = parent(of: session) else { return session.displayName }
        return "\(parent.displayName) › \(session.displayName)"
    }

    /// listOrdered sorts `sessions` A-Z by label for a flat list, each parent followed by its companions in
    /// input order, wherever they sit in the input; a companion listed without its parent sorts on its own label.
    public func listOrdered(_ sessions: [Session]) -> [Session] {
        let present = Set(sessions.map(\.id))
        var groups: [(label: String, members: [Session])] = []
        var groupOfParent: [UUID: Int] = [:]
        for session in sessions where session.parentID.map(present.contains) != true {
            groupOfParent[session.id] = groups.count
            groups.append((listLabel(for: session), [session]))
        }
        for session in sessions {
            guard let parentID = session.parentID, let group = groupOfParent[parentID] else { continue }
            groups[group].members.append(session)
        }
        return groups.enumerated().sorted { lhs, rhs in
            let order = lhs.element.label.localizedCaseInsensitiveCompare(rhs.element.label)
            return order == .orderedSame ? lhs.offset < rhs.offset : order == .orderedAscending
        }.flatMap(\.element.members)
    }

    /// The name of `workspaceID`; nil when it is gone, and when it is blank — `renameWorkspace` rejects a
    /// blank one, but `AppStore+PendingClose` rebuilds a `Workspace` from a snapshot without that guard.
    public func workspaceName(_ workspaceID: UUID) -> String? {
        workspaces.first(where: { $0.id == workspaceID })?.name.trimmedOrNil
    }
}
