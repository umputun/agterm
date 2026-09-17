import AppKit
import agtermCore

extension WorkspaceSidebar.Coordinator {
    /// The flagged view's layout while the sidebar shows it, nil in the ordinary tree. A change to THIS value,
    /// not to the global setting, is what re-shapes the outline: the setting is dormant under the ordinary tree.
    var flaggedLayout: FlaggedViewLayout? {
        store.sidebarMode == .flagged ? GhosttyApp.shared.flaggedViewLayout : nil
    }

    /// Whether the outline has workspace rows, the precondition of every expand/collapse path.
    var rendersWorkspaceRows: Bool {
        store.sidebarMode == .tree || flaggedLayout == .tree
    }

    /// The workspace rows and their session rows, in store order. The flagged tree reads ALL workspaces, not
    /// `visibleWorkspaces`: flagged mode ignores the focus filter, and a group with nothing flagged has no row.
    var workspaceProjection: [(workspace: Workspace, sessions: [Session])] {
        guard store.sidebarMode == .flagged else {
            return store.visibleWorkspaces.map { ($0, $0.sessions) }
        }
        return store.workspaces.compactMap { workspace in
            let flagged = workspace.sessions.filter(\.flagged)
            return flagged.isEmpty ? nil : (workspace, flagged)
        }
    }

    /// The unseen count a workspace row shows: its RENDERED children's. `Workspace.unseenCount` sums every
    /// session, so a flagged-tree header would otherwise report notifications from rows the view leaves out.
    func displayedUnseen(for workspace: Workspace) -> Int {
        guard flaggedLayout == .tree else { return workspace.unseenCount }
        return workspace.sessions.reduce(0) { $1.flagged ? $0 + $1.unseenCount : $0 }
    }
}
