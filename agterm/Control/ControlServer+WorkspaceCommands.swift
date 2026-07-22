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

    /// Focus (or unfocus) a workspace — collapse the sidebar tree to that workspace's subtree, or restore
    /// the full tree. `mode` is `on|off|toggle`: `on` focuses the target, `off` unfocuses it only when it
    /// is the currently focused one (a no-op otherwise), `toggle` flips. Delta-computed via
    /// `AppStore.setFocusedWorkspace` so a no-op mode skips the write (idempotent). An unknown mode is an
    /// error. The control half of the workspace row's Focus/Unfocus menu + the pill ✕.
    func focusWorkspace(_ target: String?, window: String?, mode: String?) -> ControlResponse {
        let mode = mode ?? "toggle"
        return resolver.resolveWorkspace(target, window: window) { store, id in
            let want: UUID?
            switch mode {
            case "on": want = id
            case "off": want = store.focusedWorkspaceID == id ? nil : store.focusedWorkspaceID
            case "toggle": want = store.focusedWorkspaceID == id ? nil : id
            default: return ControlResponse(ok: false, error: "invalid focus mode: \(mode)")
            }
            store.setFocusedWorkspace(want) // no-op + no save when unchanged (idempotent)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
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
