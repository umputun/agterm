import Foundation
import agtermCore

/// `ControlServer` adapter arms for `session.tint` and `workspace.tint`: target resolution plus the store
/// write. The dispatcher has already parsed the color and parts.
extension ControlServer {
    func setSessionTint(_ target: String?, window: String?, update: ControlTintUpdate) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session: \(target ?? "active")")
            }
            store.setTint(update.resolved(over: session.tint), forSession: id)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    func setWorkspaceTint(_ target: String?, window: String?, update: ControlTintUpdate) -> ControlResponse {
        resolver.resolveWorkspace(target, window: window) { store, id in
            let current = store.workspaces.first { $0.id == id }?.tint
            store.setTint(update.resolved(over: current), forWorkspace: id)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }
}
