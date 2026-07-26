import agtermCore
import Foundation

/// The sidebar's WORKSPACE focus filter for `AppActions` — the row menu's Focus/Unfocus, the
/// keybind/menu/palette entry point, and Clear Focus. Distinct from `AppActions+Focus.swift`, which owns
/// SESSION/PANE first-responder mechanics; this file only drives `AppStore`'s tree filter.
extension AppActions {
    /// Focus (or unfocus) a workspace — collapses the sidebar tree to that workspace's subtree, or clears
    /// focus when it is already the only marked workspace. A replace-toggle: any other marked set is
    /// replaced by this one workspace. Driven by the sidebar workspace row's "Focus"/"Unfocus"
    /// context-menu item. Clean no-op on an unknown id.
    func focusWorkspace(_ id: UUID) {
        guard uiActionsEnabled else { return }
        guard let store, store.workspaces.contains(where: { $0.id == id }) else { return }
        let onlyThisFocused = store.focusEnabled && store.focusedWorkspaceIDs == [id]
        store.setFocusedWorkspace(onlyThisFocused ? nil : id)
    }

    /// Add or remove one workspace from the marked set, leaving the other members alone — the sidebar
    /// workspace row's "Add to Focus"/"Remove from Focus" context-menu item, which computes its own
    /// direction and so needs no toggle mode. Adding also enables the filter; removing disables it once
    /// the set empties. Clean no-op on an unknown id.
    func setFocusMembership(_ id: UUID, member: Bool) {
        guard uiActionsEnabled else { return }
        guard let store, store.workspaces.contains(where: { $0.id == id }) else { return }
        store.setFocusMembership(id, member: member)
    }

    /// Focus (or unfocus) the current workspace (the one new sessions land in) — the entry point for the
    /// `focus_workspace` keybind, the View menu, and the action palette, which have no clicked row.
    /// No-op when there is no current workspace.
    func focusActiveWorkspace() {
        guard let id = store?.currentWorkspaceID else { return }
        focusWorkspace(id)
    }

    /// Flip the focus filter on or off WITHOUT touching the marked set — the bottom-bar grid toggle, so
    /// peeking at the whole tree and coming back costs one click each way. The store refuses to enable an
    /// empty set, which is the same state the toggle renders disabled in, so the two agree by construction.
    func toggleFocusFilter() {
        guard uiActionsEnabled else { return }
        guard let store else { return }
        store.setFocusEnabled(!store.focusEnabled)
    }

    /// Clear the marked workspace set entirely, restoring the full tree. A plain menu/palette "Clear Focus"
    /// item; no-op when nothing is marked and the filter is already off. Distinct from `toggleFocusFilter`,
    /// which keeps the set and only stops applying it.
    func clearFocus() {
        guard uiActionsEnabled else { return }
        guard let store, !store.focusedWorkspaceIDs.isEmpty || store.focusEnabled else { return }
        store.setFocusedWorkspace(nil)
    }
}
