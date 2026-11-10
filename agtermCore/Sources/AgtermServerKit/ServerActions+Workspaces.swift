import Foundation
import agtermCore

/// The workspace commands agterm-server serves.
extension ServerActions {
    public func createWorkspace(window: String?, name: String?, collapsed: Bool) -> ControlResponse {
        createWorkspace(window: window, name: name, collapsed: collapsed, tint: nil)
    }

    public func createWorkspace(window: String?, name: String?, collapsed: Bool, tint: SidebarTint?) -> ControlResponse {
        if let refusal = windowRefusal(window) { return refusal }
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? store.defaultWorkspaceName
        let workspace = store.addWorkspace(name: name, collapsed: collapsed, revealNewWorkspace: false, tint: tint)
        return ControlResponse(ok: true, result: ControlResult(id: workspace.id.uuidString))
    }

    public func renameWorkspace(_ target: String?, window: String?, name: String) -> ControlResponse {
        withWorkspace(target, window: window) { id in
            store.renameWorkspace(id, to: name)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    public func deleteWorkspace(_ target: String?, window: String?) -> ControlResponse {
        withWorkspace(target, window: window) { id in
            guard store.canRemoveWorkspace else { return ControlResponse(ok: false, error: "cannot delete last workspace") }
            store.removeWorkspace(id)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    public func moveWorkspace(_ target: String?, window: String?, direction: ReorderDirection) -> ControlResponse {
        withWorkspace(target, window: window) { id in
            store.reorderWorkspace(id, direction)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    func withWorkspace(_ target: String?, window: String?, _ body: (UUID) -> ControlResponse) -> ControlResponse {
        if let refusal = windowRefusal(window) { return refusal }
        switch resolveWorkspace(target) {
        case .success(let id): return body(id)
        case .failure(let refusal): return refusal.response
        }
    }

    /// resolveWorkspace resolves a workspace id, prefix or `active`, the store's current workspace.
    func resolveWorkspace(_ target: String?) -> Result<UUID, ActionRefusal> {
        let target = target ?? "active"
        let resolution = ControlResolve.resolve(target, candidates: store.workspaces.map(\.id), active: store.currentWorkspaceID)
        guard case .resolved(let id) = resolution else {
            return .refused(ControlResponse(ok: false, error: ControlResolve.errorMessage(noun: "workspace", target: target,
                                                                                          resolution: resolution)))
        }
        return .success(id)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
