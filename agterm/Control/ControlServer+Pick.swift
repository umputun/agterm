import agtermCore

/// App-side host for the per-window native picker. Argument validation and response routing stay in
/// `ControlDispatcher`; this layer resolves the target window and drives its registered controller.
extension ControlServer {
    func openPick(_ pick: PendingPick, window: String?, follow: Bool) -> ControlResponse {
        withPickController(window: window) { controller, windowID in
            guard controller.open(pick) else {
                return ControlResponse(ok: false, error: "pick already pending")
            }
            PickRegistry.shared.clearRetainedResult(for: windowID)

            if follow {
                WindowRegistry.shared.raise(windowID)
                selectPickWindow(windowID)
            }
            if library.activeWindowID == windowID {
                actions.palette?.close()
            }
            return ControlResponse(ok: true, result: ControlResult(id: pick.id))
        }
    }

    func pickResult(_ target: String, window: String?) -> ControlResponse {
        if let result = PickRegistry.shared.retainedResult(for: target) {
            return ControlResponse(ok: true, result: ControlResult(pick: result))
        }
        return withPickController(window: window) { controller, _ in
            guard let result = controller.result(for: target) else {
                return ControlResponse(ok: false, error: "unknown pick: \(target)")
            }
            return ControlResponse(ok: true, result: ControlResult(pick: result))
        }
    }

    func cancelPick(_ target: String, window: String?) -> ControlResponse {
        if PickRegistry.shared.retainedResult(for: target) != nil {
            return ControlResponse(ok: true)
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

    /// Make a followed picker window the logical frontmost target as well as raising its live NSWindow.
    /// AppKit does not publish `didBecomeKey` while the app is inactive, so control-driven presentation
    /// must mirror the `window.select` bookkeeping synchronously.
    private func selectPickWindow(_ windowID: WindowInfo.ID) {
        guard library.frontmostWindowID != windowID else { return }
        library.frontmostWindowID = windowID
        library.saveIndex()
        if GhosttyApp.shared.autoHideSidebarInactiveWindows {
            library.applyInactiveWindowSidebarHiding()
        }
    }
}
