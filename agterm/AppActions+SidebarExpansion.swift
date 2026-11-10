import agtermCore
import AppKit

extension AppActions {
    /// Expand every workspace in the frontmost window's sidebar. No-op when no window is open.
    func expandAllWorkspaces() {
        guard uiActionsEnabled else { return }
        guard let store else { return }
        expandAllWorkspaces(in: store)
    }

    /// Expand every workspace in `store`'s window sidebar. The sidebar owns the outline, so this posts a
    /// store-scoped notification and only that window's `WorkspaceSidebar.Coordinator` acts — how
    /// `sidebar.expand` targets a specific (default frontmost) window. No-op under the flat flagged list (no rows).
    func expandAllWorkspaces(in store: AppStore) {
        NotificationCenter.default.post(name: .agtermExpandWorkspaces, object: store)
    }

    /// Collapse every workspace except the active one in the frontmost window's sidebar. No-op with no window.
    func collapseOtherWorkspaces() {
        guard uiActionsEnabled else { return }
        guard let store else { return }
        collapseOtherWorkspaces(in: store)
    }

    /// Collapse every workspace except the current one in `store`'s window sidebar, keeping that one
    /// expanded and scrolled into view. Store-scoped like `expandAllWorkspaces(in:)`, no-op under the flat flagged list,
    /// and how `sidebar.collapse` targets a specific (default frontmost) window.
    func collapseOtherWorkspaces(in store: AppStore) {
        NotificationCenter.default.post(name: .agtermCollapseWorkspaces, object: store)
    }

    /// Fold or unfold the CURRENT workspace alone, for the keyless `toggle_workspace_collapse`, its View-menu
    /// item and its palette row. The per-workspace counterpart of Expand / Collapse Workspaces, which act on
    /// every row and deliberately keep this one open — so before this there was no built-in way to fold the
    /// workspace you are in. Needs workspace rows, matching those two and the rows it acts on. Targets what the row
    /// SHOWS (`isCurrentWorkspaceCollapsed`), not what is persisted: a reveal routinely leaves this workspace
    /// open on screen while its stored flag still says collapsed, and toggling the stored flag there costs the
    /// user a keystroke that changes nothing he can see.
    func toggleActiveWorkspaceCollapse() {
        guard uiActionsEnabled else { return }
        guard let store, store.rendersWorkspaceRows(flaggedLayout: GhosttyApp.shared.flaggedViewLayout),
              let id = store.currentWorkspaceID else { return }
        setWorkspaceExpanded(id, expanded: store.isCurrentWorkspaceCollapsed, in: store)
    }

    /// Collapse/expand a SINGLE workspace in `store`'s window sidebar — the shared path for
    /// `workspace.collapse`/`.expand` and for `toggleActiveWorkspaceCollapse` above (a GUI row click drives
    /// the outline directly instead). Persists
    /// `Workspace.isExpanded` DIRECTLY on the store (source of truth for the `collapsed` read-back,
    /// delta-guarded so it's idempotent), THEN posts a store-scoped notification so that window's Coordinator
    /// syncs the live outline row and its tracked expansion set. The persist must NOT ride the notification:
    /// the Coordinator is mounted only while `sidebarVisible`, so with the sidebar hidden a notification-only
    /// write drops silently and leaves the read-back stale. Mirrors `workspace.focus`/`session.resize`.
    func setWorkspaceExpanded(_ id: UUID, expanded: Bool, in store: AppStore) {
        store.setWorkspaceExpanded(id, expanded: expanded)
        NotificationCenter.default.post(
            name: .agtermSetWorkspaceExpanded, object: store,
            userInfo: [WorkspaceSidebar.Coordinator.workspaceIDUserInfoKey: id,
                       WorkspaceSidebar.Coordinator.expandedUserInfoKey: expanded])
    }
}
