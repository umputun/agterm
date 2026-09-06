import Foundation
import agtermCore

extension ControlServer {
    func openAsk(_ ask: PendingAsk, target: String?, window: String?,
                 placement: ControlAskPlacement, follow: Bool) -> ControlResponse {
        if let target {
            return resolver.resolveSession(target, window: window) { store, id in
                presentAsk(ask, in: store, sessionID: id, placement: placement, follow: follow)
            }
        }
        return resolver.resolveOpenPlacementStore(window) { store in
            presentAsk(ask, in: store, sessionID: nil, placement: placement, follow: follow)
        }
    }

    private func presentAsk(_ ask: PendingAsk, in store: AppStore, sessionID: UUID?,
                            placement: ControlAskPlacement, follow: Bool) -> ControlResponse {
        guard let windowID = library.windowID(for: store) else {
            return ControlResponse(ok: false, error: "no open window")
        }
        guard let controller = PickRegistry.shared.controller(for: windowID) else {
            return ControlResponse(ok: false, error: "no ask surface")
        }
        var anchor: AskAnchor?
        if let sessionID {
            guard let session = store.session(withID: sessionID) else {
                return ControlResponse(ok: false, error: "no such session")
            }
            guard store.selectedSessionID == sessionID,
                  TerminalZoomRegistry.shared.controller(for: windowID)?.target == nil,
                  DashboardControllerRegistry.shared.controller(for: windowID)?.isOpen != true else {
                return ControlResponse(ok: false, error: "session not visible")
            }
            switch resolvePanePlacement(placement.pane, paneID: placement.paneID, in: session,
                                        requireVisible: true, invalidPaneError: "ask pane must be left or right") {
            case let .resolved(identity, pane):
                anchor = AskAnchor(sessionID: sessionID, pane: pane, paneIdentity: identity)
            case .rejected(let response):
                return response
            }
        }
        let pending = PendingAsk(id: ask.id, title: ask.title, message: ask.message, buttons: ask.buttons,
                                 defaultID: ask.defaultID, cancelID: ask.cancelID, destructiveID: ask.destructiveID,
                                 anchor: anchor)
        guard controller.openAsk(pending) else {
            return ControlResponse(ok: false, error: controller.pending != nil ? "pick already pending" : "ask already pending")
        }
        if follow {
            WindowRegistry.shared.raise(windowID)
            takeFrontmost(windowID)
        }
        if library.activeWindowID == windowID {
            actions.palette?.close()
        }
        return ControlResponse(ok: true, result: ControlResult(id: ask.id, pane: anchor?.pane?.rawValue))
    }

    func askResult(_ target: String, window: String?) -> ControlResponse {
        if window == nil {
            if let live = PickRegistry.shared.liveAsk(for: target),
               let result = live.controller.askResult(for: target) {
                return ControlResponse(ok: true, result: ControlResult(ask: result))
            }
            if let retained = PickRegistry.shared.retainedAskResult(for: target) {
                return ControlResponse(ok: true, result: ControlResult(ask: retained.result))
            }
            return ControlResponse(ok: false, error: "unknown ask: \(target)")
        }
        if let retained = PickRegistry.shared.retainedAskResult(for: target) {
            return resolver.resolveWindowID(window) { windowID in
                guard windowID == retained.windowID else {
                    return ControlResponse(ok: false, error: "unknown ask: \(target)")
                }
                return ControlResponse(ok: true, result: ControlResult(ask: retained.result))
            }
        }
        return withAskController(window: window) { controller in
            guard let result = controller.askResult(for: target) else {
                return ControlResponse(ok: false, error: "unknown ask: \(target)")
            }
            return ControlResponse(ok: true, result: ControlResult(ask: result))
        }
    }

    func cancelAsk(_ target: String, window: String?) -> ControlResponse {
        if window == nil {
            if let live = PickRegistry.shared.liveAsk(for: target) {
                if live.controller.pendingAsk?.id == target { live.controller.cancelAsk() }
                return ControlResponse(ok: true)
            }
            if PickRegistry.shared.retainedAskResult(for: target) != nil {
                return ControlResponse(ok: true)
            }
            return ControlResponse(ok: false, error: "unknown ask: \(target)")
        }
        if let retained = PickRegistry.shared.retainedAskResult(for: target) {
            return resolver.resolveWindowID(window) { windowID in
                windowID == retained.windowID
                    ? ControlResponse(ok: true)
                    : ControlResponse(ok: false, error: "unknown ask: \(target)")
            }
        }
        return withAskController(window: window) { controller in
            guard controller.askResult(for: target) != nil else {
                return ControlResponse(ok: false, error: "unknown ask: \(target)")
            }
            if controller.pendingAsk?.id == target { controller.cancelAsk() }
            return ControlResponse(ok: true)
        }
    }

    private func withAskController(window: String?, _ body: (PickController) -> ControlResponse) -> ControlResponse {
        resolver.resolveOpenPlacementStore(window) { store in
            guard let windowID = library.windowID(for: store) else {
                return ControlResponse(ok: false, error: "no open window")
            }
            guard let controller = PickRegistry.shared.controller(for: windowID) else {
                return ControlResponse(ok: false, error: "no ask surface")
            }
            return body(controller)
        }
    }
}
