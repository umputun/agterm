import Foundation
import agtermCore

/// App-side host for the per-window native picker. Argument validation and response routing stay in
/// `ControlDispatcher`; this layer resolves the target window and drives its registered controller.
extension ControlServer {
    func openPick(_ pick: PendingPick, window: String?, follow: Bool) -> ControlResponse {
        timed(openWindowPick(pick, window: window, follow: follow), deadline: pick.deadline) { [weak self] in
            _ = self?.cancelPick(pick.id, window: nil)
        }
    }

    private func openWindowPick(_ pick: PendingPick, window: String?, follow: Bool) -> ControlResponse {
        withPickController(window: window) { controller, windowID in
            guard controller.open(pick) else {
                return ControlResponse(ok: false, error: controller.pendingAsk != nil ? "ask already pending" : "pick already pending")
            }

            if follow {
                WindowRegistry.shared.raise(windowID)
                takeFrontmost(windowID)
            }
            if library.activeWindowID == windowID {
                actions.palette?.close()
            }
            return ControlResponse(ok: true, result: ControlResult(id: pick.id))
        }
    }

    /// openPick bound to a session: its presenter draws it when the session presents remotely, otherwise the
    /// session's own window does, whichever window is frontmost.
    func openPick(_ pick: PendingPick, session target: String, window: String?, follow: Bool) -> ControlResponse {
        timed(openSessionPick(pick, session: target, window: window, follow: follow), deadline: pick.deadline) { [weak self] in
            _ = self?.cancelPick(pick.id, window: nil)
        }
    }

    private func openSessionPick(_ pick: PendingPick, session target: String, window: String?, follow: Bool) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else { return ControlResponse(ok: false, error: "no such session") }
            let windowID = library.windowID(for: store)
            switch store.presentPickRemotely(pick, in: session, window: windowID, follow: follow) {
            case true?: return ControlResponse(ok: true, result: ControlResult(id: pick.id))
            case false?: return ControlResponse(ok: false, error: "pick already pending")
            case nil: break
            }
            guard let windowID, let controller = PickRegistry.shared.controller(for: windowID) else {
                return ControlResponse(ok: false, error: "no pick surface")
            }
            if let error = SessionPickBook.shared.openLocal(pick, session: id, window: windowID, controller: controller) {
                return ControlResponse(ok: false, error: error)
            }
            if follow {
                WindowRegistry.shared.raise(windowID)
                takeFrontmost(windowID)
            }
            if library.activeWindowID == windowID { actions.palette?.close() }
            return ControlResponse(ok: true, result: ControlResult(id: pick.id))
        }
    }

    /// Takes a session's presenter-held pick back into the session's window after the presenter refused it
    /// (`refused`) or was lost; one that cannot be shown there ends cancelled.
    func takeBackRemotePick(forSession id: UUID, refused: PresentationPickRef? = nil) {
        let windowID = library.store(forSession: id).flatMap { library.windowID(for: $0) }
        SessionPickBook.shared.handBack(session: id, refused: refused, to: PickRegistry.shared.controller(for: windowID),
                                        window: windowID)
    }

    /// showReplicaPick shows a pick `id`'s origin handed over in the window holding the attached row. A busy
    /// window refuses it, unless the origin is headless and has no screen to take it back to: there it waits.
    func showReplicaPick(_ pick: PresentationPick, forSession id: UUID) -> Bool {
        guard let store = library.store(forSession: id), let binding = store.session(withID: id)?.remotePresentation?.binding,
              let windowID = library.windowID(for: store),
              let controller = PickRegistry.shared.controller(for: windowID),
              binding.originHeadless || !controller.modalPending else { return false }
        let shown = SessionPickBook.shared.openReplica(pick, session: id, window: windowID, controller: controller) { [weak self] body in
            self?.remoteClients[id]?.answer(body)
        }
        guard shown else { return false }
        if pick.follow == true {
            WindowRegistry.shared.raise(windowID)
            takeFrontmost(windowID)
        }
        if library.activeWindowID == windowID { actions.palette?.close() }
        return true
    }

    func pickResult(_ target: String, window: String?) -> ControlResponse {
        if window == nil {
            if let live = PickRegistry.shared.livePick(for: target),
               let result = live.controller.result(for: target) {
                return ControlResponse(ok: true, result: ControlResult(pick: result))
            }
            if let retained = PickRegistry.shared.retainedResult(for: target) {
                return ControlResponse(ok: true, result: ControlResult(pick: retained.result))
            }
            if let result = SessionPickBook.shared.result(for: target) {
                return ControlResponse(ok: true, result: ControlResult(pick: result))
            }
            return ControlResponse(ok: false, error: "unknown pick: \(target)")
        }
        if let retained = PickRegistry.shared.retainedResult(for: target) {
            return resolver.resolveWindowID(window) { windowID in
                guard windowID == retained.windowID else {
                    return ControlResponse(ok: false, error: "unknown pick: \(target)")
                }
                return ControlResponse(ok: true, result: ControlResult(pick: retained.result))
            }
        }
        if let result = SessionPickBook.shared.result(for: target) {
            return resolver.resolveWindowID(window) { windowID in
                guard SessionPickBook.shared.window(of: target) == windowID else {
                    return ControlResponse(ok: false, error: "unknown pick: \(target)")
                }
                return ControlResponse(ok: true, result: ControlResult(pick: result))
            }
        }
        return withPickController(window: window) { controller, _ in
            guard let result = controller.result(for: target) else {
                return ControlResponse(ok: false, error: "unknown pick: \(target)")
            }
            return ControlResponse(ok: true, result: ControlResult(pick: result))
        }
    }

    func cancelPick(_ target: String, window: String?) -> ControlResponse {
        if window == nil {
            if let live = PickRegistry.shared.livePick(for: target) {
                if live.controller.pending?.id == target { live.controller.cancel() }
                return ControlResponse(ok: true)
            }
            if PickRegistry.shared.retainedResult(for: target) != nil || SessionPickBook.shared.cancel(target) {
                return ControlResponse(ok: true)
            }
            return ControlResponse(ok: false, error: "unknown pick: \(target)")
        }
        if let retained = PickRegistry.shared.retainedResult(for: target) {
            return resolver.resolveWindowID(window) { windowID in
                windowID == retained.windowID
                    ? ControlResponse(ok: true)
                    : ControlResponse(ok: false, error: "unknown pick: \(target)")
            }
        }
        if SessionPickBook.shared.result(for: target) != nil {
            return resolver.resolveWindowID(window) { windowID in
                guard SessionPickBook.shared.window(of: target) == windowID else {
                    return ControlResponse(ok: false, error: "unknown pick: \(target)")
                }
                SessionPickBook.shared.cancel(target)
                return ControlResponse(ok: true)
            }
        }
        return withPickController(window: window) { controller, _ in
            guard controller.result(for: target) != nil else {
                return ControlResponse(ok: false, error: "unknown pick: \(target)")
            }
            if controller.pending?.id == target {
                controller.cancel()
            }
            return ControlResponse(ok: true)
        }
    }

    private func withPickController(
        window: String?,
        _ body: (PickController, WindowInfo.ID) -> ControlResponse
    ) -> ControlResponse {
        guard library.activeStore != nil else {
            return ControlResponse(ok: false, error: "no open window")
        }
        return resolver.resolvePlacementStore(window) { store in
            guard let windowID = library.windowID(for: store) else {
                return ControlResponse(ok: false, error: "no open window")
            }
            guard let controller = PickRegistry.shared.controller(for: windowID) else {
                return ControlResponse(ok: false, error: "no pick surface")
            }
            return body(controller, windowID)
        }
    }
}
