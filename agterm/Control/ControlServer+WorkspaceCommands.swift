import Foundation
import agtermCore

/// `ControlServer` workspace-command adapter arms (create/select/rename/delete/move/focus and per-workspace
/// collapse/expand), split out of `ControlServer+SessionActions.swift` for the file size limit; they satisfy
/// the `ControlActions` conformance declared there. Each does only target resolution + the AppKit/store side
/// effect — validation/response shaping is host-free in `ControlDispatcher`, and the all-workspace
/// `sidebar.expand`/`sidebar.collapse` arms live in `ControlServer+AppCommands.swift`.
extension ControlServer {
    func createWorkspace(window: String?, name: String?, collapsed: Bool) -> ControlResponse {
        // `collapsed` seeds the workspace closed so a script can fill it with `session.new --no-select`
        // without it opening, and for the same reason keeps it OUT of the focus set — widening a script's
        // marked set would contradict the flag. a plain create keeps the auto-reveal, matching the GUI's New
        // Workspace button: a foreground create must not land invisibly behind an applied filter.
        resolver.resolvePlacementStore(window) { store in
            let name = trimmed(name) ?? store.defaultWorkspaceName
            let workspace = store.addWorkspace(name: name, collapsed: collapsed, revealNewWorkspace: !collapsed)
            return ControlResponse(ok: true, result: ControlResult(id: workspace.id.uuidString))
        }
    }

    func selectWorkspace(_ target: String?, window: String?) -> ControlResponse {
        // selecting a workspace selects its first session (workspace rows are not selectable on
        // their own); an empty workspace just clears nothing and reports the workspace id.
        resolver.resolveWorkspace(target, window: window) { store, id in
            store.selectWorkspace(id)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    func renameWorkspace(_ target: String?, window: String?, name: String) -> ControlResponse {
        resolver.resolveWorkspace(target, window: window) { store, id in
            store.renameWorkspace(id, to: name)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    func deleteWorkspace(_ target: String?, window: String?) -> ControlResponse {
        // honors keep-at-least-one; returns an error rather than the GUI confirm alert.
        resolver.resolveWorkspace(target, window: window) { store, id in
            guard store.canRemoveWorkspace else {
                return ControlResponse(ok: false, error: "cannot delete last workspace")
            }
            store.removeWorkspace(id)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// `workspace.move`: reorder a workspace among its siblings (`up`|`down`|`top`|`bottom`); `to` is required
    /// and an invalid direction errors. Resolved via `resolveWorkspace`, honoring the `--window` selector.
    func moveWorkspace(_ target: String?, window: String?, direction dir: ReorderDirection) -> ControlResponse {
        return resolver.resolveWorkspace(target, window: window) { store, id in
            store.reorderWorkspace(id, dir)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Mark or unmark a workspace in the sidebar focus SET; `mode` arrives parsed and validated by
    /// `ControlDispatcher`. `on` replaces the set with the target and APPLIES the filter; `toggle`
    /// replace-toggles, clearing when the target is the only marked workspace and the filter applies, else
    /// replacing and applying; `off` drops the target (the filter switches off once the set empties, a no-op
    /// when never marked); `add` inserts alongside existing members leaving the flag EXACTLY as it was, so a
    /// script builds a set with repeated `add` calls and applies it with one `workspace.filter on`. The whole
    /// mapping is host-free in `AppStore.applyFocusMode` (delta-guarded, so every mode is idempotent), leaving
    /// this arm target resolution. Control half of the row's Focus/Unfocus + Add to/Remove from Focus menu.
    func focusWorkspace(_ target: String?, window: String?, mode: ControlWorkspaceFocusMode) -> ControlResponse {
        resolver.resolveWorkspace(target, window: window) { store, id in
            store.applyFocusMode(mode, to: id)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// `workspace.filter`: turn a window's focus filter on/off/toggle WITHOUT touching the marked set, so
    /// peeking at the whole tree and back costs one call. Window-scoped (no workspace target); `--window`
    /// picks it like `sidebar.expand`/`sidebar.collapse`, default frontmost. `AppStore.setFocusEnabled` is
    /// delta-guarded and REFUSES to enable an empty set, so `on` with nothing marked succeeds having changed
    /// nothing, keeping the `ControlWorkspaceNode.focused` row-visibility contract exact. No window is an error.
    func setWorkspaceFilter(window: String?, mode: ControlToggleMode) -> ControlResponse {
        resolver.resolveOpenPlacementStore(window) { store in
            store.applyWorkspaceFilter(mode)
            return ControlResponse(ok: true)
        }
    }

    /// Collapse (`expanded: false`) or expand (`expanded: true`) a SINGLE workspace in a window's sidebar tree
    /// — the per-workspace analogue of `sidebar.expand`/`sidebar.collapse`. Resolved via `resolveWorkspace`
    /// (honoring `--window`), then `AppActions.setWorkspaceExpanded(_:expanded:in:)` persists
    /// `Workspace.isExpanded` on the store directly — the source of truth for the `collapsed` read-back, so it
    /// works with that window's sidebar hidden — and posts a store-scoped notification for the live outline
    /// sync. Idempotent (the store mutator is delta-guarded); returns the workspace id.
    func setWorkspaceExpansion(_ target: String?, window: String?, expanded: Bool) -> ControlResponse {
        resolver.resolveWorkspace(target, window: window) { store, id in
            actions.setWorkspaceExpanded(id, expanded: expanded, in: store)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }
}
