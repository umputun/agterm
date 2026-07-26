import agtermCore
import Foundation

/// The sidebar's WORKSPACE focus filter for `AppActions` — the row menu's Focus/Unfocus, the
/// keybind/menu/palette entry point, and Clear Focus. Distinct from `AppActions+Focus.swift`, which owns
/// SESSION/PANE first-responder mechanics; this file only drives `AppStore`'s tree filter.
extension AppActions {
    /// Focus (or unfocus) a workspace in `store`'s window — collapses that sidebar's tree to the
    /// workspace's subtree, or clears focus when it is already the only marked workspace AND the filter is
    /// applied (marked-but-not-filtering re-applies instead of clearing, so the item still narrows). A
    /// replace-toggle: any other marked set is replaced by this one workspace. Driven by the sidebar
    /// workspace row's "Focus"/"Unfocus" context-menu item, which passes its OWN window-local store (like
    /// Close/Flag/Duplicate/Reveal) so a background window's row menu toggles the tree it was opened over
    /// rather than the frontmost window's. The toggle semantic itself lives in
    /// `AppStore.toggleFocusedWorkspace`, shared with `workspace.focus toggle`, so the GUI and the wire
    /// cannot mean different things by "toggle". Clean no-op on an unknown id (the store guards it).
    /// Ungated like the other store-scoped sidebar actions: a window renders no sidebar while its terminal
    /// zoom or dashboard is up, so the row menu is unreachable in exactly the state the gate covers, and
    /// the frontmost window's modal must not block a background window's row.
    func focusWorkspace(_ id: UUID, in store: AppStore) {
        store.toggleFocusedWorkspace(id)
    }

    /// Add or remove one workspace from `store`'s marked set, leaving the other members alone — the
    /// sidebar workspace row's "Add to Focus"/"Remove from Focus" context-menu item, which computes its
    /// own direction from that same store and so needs no toggle mode. Adding MARKS ONLY, never switching
    /// the filter on, so the rows of the workspaces still to be marked stay on screen; removing disables
    /// the filter once the set empties. Store-scoped and ungated for the same reasons as
    /// `focusWorkspace(_:in:)`. Clean no-op on an unknown id (the store guards it).
    func setFocusMembership(_ id: UUID, member: Bool, in store: AppStore) {
        store.setFocusMembership(id, member: member)
    }

    /// Focus (or unfocus) the current workspace (the one new sessions land in) — the entry point for the
    /// `focus_workspace` keybind, the View menu, and the action palette, which have no clicked row and so
    /// act on the frontmost window by definition. No-op when there is no current workspace.
    func focusActiveWorkspace() {
        guard uiActionsEnabled, let store, let id = store.currentWorkspaceID else { return }
        focusWorkspace(id, in: store)
    }

    /// Mark the current workspace (the one new sessions land in) as a set member, leaving the other
    /// members alone — the View menu and action-palette entry point, which have no clicked row and so
    /// target the frontmost window. The additive sibling of `focusActiveWorkspace`, which REPLACES the set
    /// with the current workspace. No-op when there is no current workspace.
    func addActiveWorkspaceToFocus() {
        guard uiActionsEnabled, let store, let id = store.currentWorkspaceID else { return }
        setFocusMembership(id, member: true, in: store)
    }

    /// Flip the focus filter on or off WITHOUT touching the marked set — the bottom-bar grid toggle, so
    /// peeking at the whole tree and coming back costs one click each way. The store refuses to enable an
    /// empty set, which is the same state the toggle renders disabled in, so the two agree by construction.
    /// Frontmost-scoped rather than taking a store: its callers are the menu bar and the palette (frontmost
    /// by definition) plus a bottom-bar BUTTON, and the click that fires a button in a background window
    /// has already made that window key — so the frontmost store is the clicked one. Only the row context
    /// menu, which a right-click opens WITHOUT raising the window, needs the explicit-store treatment.
    func toggleFocusFilter() {
        guard uiActionsEnabled, let store else { return }
        store.setFocusEnabled(!store.focusEnabled)
    }

    /// Clear the marked workspace set entirely, restoring the full tree. A plain menu/palette "Clear Focus"
    /// item — no sidebar row drives it, so it is frontmost-scoped like `toggleFocusFilter`. The store's own
    /// mutator is a clean no-op when nothing is marked. Distinct from `toggleFocusFilter`, which keeps the
    /// set and only stops applying it.
    func clearFocus() {
        guard uiActionsEnabled, let store else { return }
        store.clearFocus()
    }
}
