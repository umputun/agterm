import Foundation
import agtermCore

/// `ControlServer` workspace-command adapter arms (create/select/rename/delete/move/focus and the
/// per-workspace collapse/expand). Split out of `ControlServer+SessionActions.swift` to keep that file
/// under the swiftlint size limit; these satisfy the `ControlActions` requirements whose conformance is
/// declared there. Each does only target resolution + the AppKit/store side effect — all validation/response
/// shaping lives host-free in `ControlDispatcher`. (The all-workspace `sidebar.expand`/`sidebar.collapse`
/// arms live in `ControlServer+AppCommands.swift`.)
extension ControlServer {
    func createWorkspace(window: String?, name: String?, collapsed: Bool) -> ControlResponse {
        // placement target: the window's frontmost store (or `args.window`'s). name defaults to
        // the auto-generated workspace name when none is given. `collapsed` seeds the workspace closed
        // so a script can fill it with `session.new --no-select` without it opening.
        resolver.resolvePlacementStore(window) { store in
            let name = trimmed(name) ?? store.defaultWorkspaceName
            let workspace = store.addWorkspace(name: name, collapsed: collapsed)
            return ControlResponse(ok: true, result: ControlResult(id: workspace.id.uuidString))
        }
    }

    func selectWorkspace(_ target: String?, window: String?) -> ControlResponse {
        // selecting a workspace selects its first session (workspace rows are not selectable on
        // their own); an empty workspace just clears nothing and reports the workspace id.
        resolver.resolveWorkspace(target, window: window) { store, id in
            if let first = store.workspaces.first(where: { $0.id == id })?.sessions.first {
                store.selectSession(first.id)
            }
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

    /// `workspace.move`: reorder a workspace among its siblings (`up`|`down`|`top`|`bottom`). `to` is
    /// required; an invalid direction errors. Resolves the workspace target via `resolveWorkspace`
    /// (honoring the global `--window` selector like other workspace commands).
    func moveWorkspace(_ target: String?, window: String?, direction dir: ReorderDirection) -> ControlResponse {
        return resolver.resolveWorkspace(target, window: window) { store, id in
            store.reorderWorkspace(id, dir)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Focus (or unfocus) a workspace — collapse the sidebar tree to the marked set, or restore the full
    /// tree. `mode` arrives already parsed and validated by `ControlDispatcher`: `on` replaces the set
    /// with the target and enables the filter, `off` drops the target from the set (disabling once it
    /// empties; a no-op when it was never marked), `toggle` replace-toggles (clears when the target is the
    /// only marked workspace and the filter is on, else replaces the set with it), and `add` inserts the
    /// target alongside the existing members. Delta-computed via the store mutators so a no-op mode skips
    /// the write (idempotent). The control half of the workspace row's Focus/Unfocus menu.
    func focusWorkspace(_ target: String?, window: String?, mode: WorkspaceFocusMode) -> ControlResponse {
        resolver.resolveWorkspace(target, window: window) { store, id in
            // the mutators are delta-guarded, so a no-op mode skips the write (idempotent)
            switch mode {
            case .on: store.setFocusedWorkspace(id)
            case .off: store.setFocusMembership(id, member: false)
            case .add: store.setFocusMembership(id, member: true)
            case .toggle:
                let onlyThisFocused = store.focusEnabled && store.focusedWorkspaceIDs == [id]
                store.setFocusedWorkspace(onlyThisFocused ? nil : id)
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// `workspace.filter`: turn a window's workspace focus filter on/off/toggle WITHOUT touching the
    /// marked set, so peeking at the whole tree and coming back costs one call. Window-scoped (no
    /// workspace target) — the `--window` selector picks the target like `sidebar.expand`/`sidebar.collapse`,
    /// defaulting to the frontmost. `AppStore.setFocusEnabled` is delta-guarded and REFUSES to enable an
    /// empty set, so `on` with nothing marked succeeds having changed nothing, keeping the documented
    /// `focused && workspaceFilter` read-back contract exact. No open window is an error rather than a
    /// silent no-op.
    func setWorkspaceFilter(window: String?, mode: ControlToggleMode) -> ControlResponse {
        if trimmed(window) == nil, library.activeStore == nil {
            return ControlResponse(ok: false, error: "no open window")
        }
        return resolver.resolvePlacementStore(window) { store in
            store.setFocusEnabled(mode.desiredValue(current: store.focusEnabled))
            return ControlResponse(ok: true)
        }
    }

    /// Collapse (`expanded: false`) or expand (`expanded: true`) a SINGLE workspace in a window's sidebar
    /// tree — the per-workspace analogue of the all-workspace `sidebar.expand`/`sidebar.collapse`. Resolves
    /// the target workspace via `resolveWorkspace` (honoring the global `--window` selector), then drives
    /// `AppActions.setWorkspaceExpanded(_:expanded:in:)`, which persists `Workspace.isExpanded` on the store
    /// directly (the source of truth for the `collapsed` read-back, so it works even when the target
    /// window's sidebar is hidden) and posts a store-scoped notification for the live outline sync.
    /// Idempotent (the store mutator is delta-guarded). Returns the workspace id; the read-back is the
    /// `tree` workspace node's `collapsed` field.
    func setWorkspaceExpansion(_ target: String?, window: String?, expanded: Bool) -> ControlResponse {
        resolver.resolveWorkspace(target, window: window) { store, id in
            actions.setWorkspaceExpanded(id, expanded: expanded, in: store)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }
}
