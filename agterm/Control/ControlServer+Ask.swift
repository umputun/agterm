import Foundation
import agtermCore

extension ControlServer {
    func openAsk(_ ask: PendingAsk, target: String?, window: String?,
                 placement: ControlAskPlacement, follow: Bool) -> ControlResponse {
        if ask.style == .terminal {
            return resolver.resolveSession(target, window: window) { store, id in
                presentTerminalAsk(ask, in: store, sessionID: id, placement: placement, follow: follow)
            }
        }
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
                                 defaultID: ask.defaultID, destructiveID: ask.destructiveID, style: ask.style, align: ask.align,
                                 width: ask.width, anchor: anchor)
        guard controller.openAsk(pending) else {
            return ControlResponse(ok: false, error: controller.pendingAsk != nil ? "ask already pending" : "pick already pending")
        }
        AskRegistry.shared.register(id: ask.id, owner: .window(windowID))
        if follow {
            WindowRegistry.shared.raise(windowID)
            takeFrontmost(windowID)
        }
        if library.activeWindowID == windowID {
            actions.palette?.close()
        }
        return ControlResponse(ok: true, result: ControlResult(id: ask.id, pane: anchor?.pane?.rawValue))
    }

    private func presentTerminalAsk(_ ask: PendingAsk, in store: AppStore, sessionID: UUID,
                                    placement: ControlAskPlacement, follow: Bool) -> ControlResponse {
        guard let session = store.session(withID: sessionID), let windowID = library.windowID(for: store) else {
            return ControlResponse(ok: false, error: "no such session")
        }
        let identity: UUID?
        let pane: OverlayPane?
        switch resolvePanePlacement(placement.pane, paneID: placement.paneID, in: session,
                                    requireVisible: true, invalidPaneError: "ask pane must be left or right") {
        case let .resolved(resolvedIdentity, resolvedPane):
            identity = resolvedIdentity
            pane = resolvedPane
        case .rejected(let response): return response
        }
        guard session.openAsk(ask, paneIdentity: identity) else { return ControlResponse(ok: false, error: "ask already pending") }
        AskRegistry.shared.register(id: ask.id, owner: .session(sessionID, window: windowID))
        if follow {
            WindowRegistry.shared.raise(windowID)
            takeFrontmost(windowID)
        }
        return ControlResponse(ok: true, result: ControlResult(id: ask.id, pane: pane?.rawValue))
    }

    func askResult(_ target: String, window: String?) -> ControlResponse {
        withAskResult(target, window: window) { result in
            ControlResponse(ok: true, result: ControlResult(ask: result))
        }
    }

    func cancelAsk(_ target: String, window: String?) -> ControlResponse {
        withAskResult(target, window: window) { result in
            guard result.result == .pending else { return ControlResponse(ok: true) }
            switch AskRegistry.shared.owner(for: target) {
            case .window(let windowID):
                let controller = PickRegistry.shared.controller(for: windowID)
                if controller?.pendingAsk?.id == target { controller?.cancelAsk() }
            case .session(let sessionID, let windowID):
                library.store(for: windowID)?.session(withID: sessionID)?.cancelAsk(id: target)
            case nil: return ControlResponse(ok: false, error: "unknown ask: \(target)")
            }
            return ControlResponse(ok: true)
        }
    }

    private func withAskResult(_ id: String, window: String?, _ body: (ControlAskResult) -> ControlResponse) -> ControlResponse {
        guard let retained = AskRegistry.shared.result(for: id) else { return ControlResponse(ok: false, error: "unknown ask: \(id)") }
        guard let window else { return body(retained.result) }
        return resolver.resolveWindowID(window) { windowID in
            guard windowID == retained.windowID else { return ControlResponse(ok: false, error: "unknown ask: \(id)") }
            return body(retained.result)
        }
    }
}
