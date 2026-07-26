import agtermCore
import Foundation

/// The sidebar's WORKSPACE focus filter for `AppActions` — the row menu's Focus/Unfocus, the
/// keybind/menu/palette entry point, and Clear Focus. Distinct from `AppActions+Focus.swift`, which owns
/// SESSION/PANE first-responder mechanics; this file only drives `AppStore`'s tree filter.
extension AppActions {
    /// Focus (or unfocus) a workspace — collapses the sidebar tree to that workspace's subtree, or clears
    /// focus when it is already the focused one. Driven by the sidebar workspace row's "Focus"/"Unfocus"
    /// context-menu item. Clean no-op on an unknown id.
    func focusWorkspace(_ id: UUID) {
        guard uiActionsEnabled else { return }
        guard let store, store.workspaces.contains(where: { $0.id == id }) else { return }
        store.setFocusedWorkspace(store.focusedWorkspaceID == id ? nil : id)
    }

    /// Focus (or unfocus) the current workspace (the one new sessions land in) — the entry point for the
    /// `focus_workspace` keybind, the View menu, and the action palette, which have no clicked row.
    /// No-op when there is no current workspace.
    func focusActiveWorkspace() {
        guard let id = store?.currentWorkspaceID else { return }
        focusWorkspace(id)
    }

    /// Clear any workspace focus, restoring the full tree. A plain menu/palette "Clear Focus" item (the
    /// bottom-bar pill's ✕ is the primary affordance); no-op when nothing is focused.
    func clearFocus() {
        guard uiActionsEnabled else { return }
        guard let store, store.focusedWorkspaceID != nil else { return }
        store.setFocusedWorkspace(nil)
    }
}
