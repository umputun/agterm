import Foundation
import agtermCore

/// `session.move` on the catalog, the forms and placement math of the Mac's sidebar.
extension ServerActions {
    static let companionMoveError = "a companion moves only among its siblings"

    public func moveSession(_ target: String?, window: String?, move: ControlSessionMove) -> ControlResponse {
        withSession(target, window: window) { session in
            let id = session.id
            switch move {
            case .reorder(let direction):
                store.reorderSession(id, direction)
            case .workspace(let workspace):
                switch resolveWorkspace(workspace) {
                case .failure(let refusal): return refusal.response
                case .success(let destination):
                    guard store.moveSession(id, toWorkspace: destination) else {
                        return ControlResponse(ok: false, error: Self.companionMoveError)
                    }
                }
            case .place(let anchor, let after):
                guard let source = store.sessionLocation(ofSession: id) else { return ControlResponse(ok: false, error: "no such session") }
                switch anchorLocation(anchor) {
                case .failure(let refusal): return refusal.response
                case .success(let location):
                    if let resolution = SidebarDrop.resolveRelative(
                        source: (workspace: source.workspace, index: source.index),
                        anchor: (workspace: location.workspace, index: location.index, count: location.count), placeAfter: after),
                       !store.moveSession(id, toWorkspace: resolution.workspace, at: resolution.destination) {
                        return ControlResponse(ok: false, error: Self.companionMoveError)
                    }
                }
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    public func moveSessions(_ targets: [String], window: String?, move: ControlSessionMove) -> ControlResponse {
        if let refusal = windowRefusal(window) { return refusal }
        let ids: [UUID]
        switch resolveSessionIDs(targets) {
        case .failure(let refusal): return refusal.response
        case .success(let resolved): ids = resolved
        }
        let affected: Int
        switch move {
        case .reorder:
            return ControlResponse(ok: false, error: "session.move --target can be repeated only with a workspace or --after/--before")
        case .workspace(let workspace):
            switch resolveWorkspace(workspace) {
            case .failure(let refusal): return refusal.response
            case .success(let destination): affected = store.moveSessions(ids, toWorkspace: destination)
            }
        case .place(let anchor, let after):
            let sources = ids.compactMap { id in
                store.sessionLocation(ofSession: id).map { SidebarDrop.SessionSource(workspace: $0.workspace, index: $0.index) }
            }
            guard sources.count == ids.count else { return ControlResponse(ok: false, error: "no such session") }
            switch anchorLocation(anchor) {
            case .failure(let refusal): return refusal.response
            case .success(let location):
                let drop = SidebarDrop.SessionDropTarget.sessionRow(workspace: location.workspace, sessionIndex: location.index,
                                                                    sessionCount: location.count)
                guard let resolution = SidebarDrop.resolveSessions(sources: sources, target: drop,
                                                                   childIndex: after ? SidebarDrop.onItemIndex : location.index) else {
                    return ControlResponse(ok: true, result: ControlResult(affected: 0))
                }
                affected = store.moveSessions(ids, toWorkspace: resolution.workspace, at: resolution.destination)
            }
        }
        if affected == 0, ids.allSatisfy({ store.session(withID: $0)?.parentID != nil }) {
            return ControlResponse(ok: false, error: Self.companionMoveError)
        }
        return ControlResponse(ok: true, result: ControlResult(affected: affected))
    }

    private func anchorLocation(_ anchor: String) -> Result<(workspace: UUID, index: Int, count: Int), ActionRefusal> {
        resolveSession(anchor).flatMap { session in
            store.sessionLocation(ofSession: session.id).map { .success($0) }
                ?? .refused(ControlResponse(ok: false, error: "no such session"))
        }
    }
}
