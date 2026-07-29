import agtermCore

/// App-side host for the per-window native picker. Argument validation and response routing stay in
/// `ControlDispatcher`; this layer resolves the target window and drives its registered controller.
extension ControlServer {
    func openPick(_ pick: PendingPick, window: String?, follow: Bool) -> ControlResponse {
        withPickController(window: window) { controller, windowID in
            guard controller.open(pick) else {
                return ControlResponse(ok: false, error: "pick already pending")
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

    func pickResult(_ target: String, window: String?) -> ControlResponse {
        if window == nil {
            if let live = PickRegistry.shared.livePick(for: target),
               let result = live.controller.result(for: target) {
                return ControlResponse(ok: true, result: ControlResult(pick: result))
            }
            if let retained = PickRegistry.shared.retainedResult(for: target) {
                return ControlResponse(ok: true, result: ControlResult(pick: retained.result))
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
            if PickRegistry.shared.retainedResult(for: target) != nil {
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
