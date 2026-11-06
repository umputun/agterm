import AppKit
import agtermCore

extension Notification.Name {
    /// Posted by `AppActions.setSessionExpanded` with the store as object and the parent id and state in userInfo.
    static let agtermSetSessionExpanded = Notification.Name("agterm.setSessionExpanded")
}

extension WorkspaceSidebar.Coordinator {
    static let sessionIDUserInfoKey = "agterm.sessionID"

    @objc func setSessionExpandedNotified(_ notification: Notification) {
        guard let id = notification.userInfo?[Self.sessionIDUserInfoKey] as? UUID,
              let expanded = notification.userInfo?[Self.expandedUserInfoKey] as? Bool else { return }
        if expanded { expandedParentIDs.insert(id) } else { expandedParentIDs.remove(id) }
        guard let outline = outlineView, let node = nodeCache[id], outline.row(forItem: node) >= 0 else { return }
        let suppressed = suppressExpansionPersist
        suppressExpansionPersist = true
        defer { suppressExpansionPersist = suppressed }
        if expanded { outline.expandItem(node) } else { outline.collapseItem(node) }
    }

    /// Companions nest under their parent only in the ordinary tree; flagged layouts list them unindented.
    var nestsCompanions: Bool { store.sidebarMode == .tree }

    /// The companions a parent row must surface while its own companion rows are folded away.
    func foldedAttention(forSession id: UUID) -> [Session] {
        guard nestsCompanions, !expandedParentIDs.contains(id) else { return [] }
        return store.companionsNeedingAttention(of: id)
    }

    /// The session rows of one workspace, each companion nested under the parent row it follows.
    func sessionNodes(for sessions: [Session]) -> [SidebarNode] {
        var rows: [SidebarNode] = []
        for session in sessions {
            let row = node(for: session.id, kind: .session)
            row.children = []
            if nestsCompanions, let parentID = session.parentID, let parent = rows.last, parent.id == parentID {
                parent.children.append(row)
            } else {
                rows.append(row)
            }
        }
        return rows
    }

    // a parent under a folded workspace has no row to expand, so this runs again whenever the workspace opens
    func applyParentExpansion(under workspace: SidebarNode) {
        guard let outline = outlineView, outline.isItemExpanded(workspace) else { return }
        let suppressed = suppressExpansionPersist
        suppressExpansionPersist = true
        defer { suppressExpansionPersist = suppressed }
        for parent in workspace.children where !parent.children.isEmpty {
            let open = expandedParentIDs.contains(parent.id)
            if open, !outline.isItemExpanded(parent) { outline.expandItem(parent) }
            if !open, outline.isItemExpanded(parent) { outline.collapseItem(parent) }
        }
    }

    func parentExpansionChanged(_ parent: SidebarNode, expanded: Bool) {
        if expanded { expandedParentIDs.insert(parent.id) } else { expandedParentIDs.remove(parent.id) }
        if !suppressExpansionPersist { store.setSessionExpanded(parent.id, expanded: expanded) }
        guard let outline = outlineView, case let row = outline.row(forItem: parent), row >= 0,
              let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCellView else { return }
        cell.setCompanionMarker(foldedAttention(forSession: parent.id).map(\.displayName))
    }
}
