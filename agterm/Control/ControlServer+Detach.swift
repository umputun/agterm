import Foundation
import agtermCore

extension ControlServer {
    func detachSessions(_ targets: [String], window: String?) -> ControlResponse {
        var owner: AppStore?
        var ids: [UUID] = []
        for target in targets {
            guard case .success(let (store, id)) = resolver.resolveSessionTarget(target, window: window) else {
                return resolver.resolveSession(target, window: window) { _, _ in ControlResponse(ok: true) }
            }
            guard owner == nil || owner === store else {
                return ControlResponse(ok: false, error: "session.detach takes sessions of one window")
            }
            owner = store
            if !ids.contains(id) { ids.append(id) }
        }
        guard let mirror = owner?.remoteActions?.mirror else { return ControlActionsDefaultsRefusal.detach("session.detach") }
        mirror.detach(sessions: ids)
        return ControlResponse(ok: true, result: ControlResult(affected: ids.count))
    }

    func reattachSession(_ target: String, window: String?) -> ControlResponse {
        reattach(target, kind: .session, window: window) { mirror, id in mirror.reattach(session: id) }
    }

    func detachWorkspace(_ target: String?, window: String?) -> ControlResponse {
        resolver.resolveWorkspace(target, window: window) { store, id in
            guard let mirror = store.remoteActions?.mirror else { return ControlActionsDefaultsRefusal.detach("workspace.detach") }
            mirror.detach(workspace: id)
            return ControlResponse(ok: true)
        }
    }

    func reattachWorkspace(_ target: String, window: String?) -> ControlResponse {
        reattach(target, kind: .workspace, window: window) { mirror, id in mirror.reattach(workspace: id) }
    }

    func dismissRemoteUnknown(window: String?) -> ControlResponse {
        resolver.resolvePlacementStore(window) { store in
            guard let remote = store.remoteActions else { return ControlActionsDefaultsRefusal.detach("window.remote.dismiss") }
            let count = remote.unknownCount
            remote.dismissUnknown()
            return ControlResponse(ok: true, result: ControlResult(text: "\(count) dismissed"))
        }
    }

    private func reattach(_ target: String, kind: WindowLibrary.DetachedKind, window: String?,
                          _ body: (RemoteCatalogMirror, UUID) -> String?) -> ControlResponse {
        var windowID: UUID?
        if let window = window?.trimmingCharacters(in: .whitespaces), !window.isEmpty {
            switch resolver.resolveWindowID(window) {
            case .failure(let response): return response
            case .success(let id): windowID = id
            }
        }
        switch library.resolveDetached(target, kind: kind, window: windowID) {
        case .failure(let failure):
            return ControlResponse(ok: false, error: failure.message)
        case .success(let (store, id)):
            guard let mirror = store.remoteActions?.mirror else { return ControlResponse(ok: false, error: "the window is closing") }
            if let refusal = body(mirror, id) { return ControlResponse(ok: false, error: refusal) }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }
}

/// ControlActionsDefaultsRefusal words a detach command's answer for a local window's row like the protocol's default.
private enum ControlActionsDefaultsRefusal {
    static func detach(_ command: String) -> ControlResponse {
        ControlResponse(ok: false, error: "\(command) acts only on a remote window")
    }
}
