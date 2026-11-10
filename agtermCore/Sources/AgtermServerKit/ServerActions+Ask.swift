import Foundation
import agtermCore

/// Asks on agterm-server are session-bound like picks: drawn by the Mac presenting the session, which answers here.
extension ServerActions {
    public func openAsk(_ ask: PendingAsk, target: String?, window: String?,
                        placement: ControlAskPlacement, follow _: Bool) -> ControlResponse {
        if target == nil, ask.style != .terminal {
            return ControlResponse(ok: false, error: "ask.open needs --target on agterm-server, which has no window to show it in")
        }
        return withSession(target, window: window) { session in
            switch session.panePlacement(placement.pane, paneID: placement.paneID, requireVisible: false,
                                         invalidPaneError: "ask pane must be left or right") {
            case .rejected(let response):
                return response
            case let .resolved(identity, pane):
                // a request no frame can carry would wait for a presenter forever
                guard PresentationAsk(ask, pane: identity.map { .identity($0) }, owner: .max).fitsFrames() else {
                    return ControlResponse(ok: false, error: "ask is too large to send to a Mac")
                }
                let opened = ControlResponse(ok: true, result: ControlResult(id: ask.id, pane: pane?.rawValue))
                switch store.openRemoteAsk(ask, in: session, paneIdentity: identity, window: catalog.id) {
                case .opened:
                    armDeadline(ask.id, ask.deadline)
                    return opened
                case .slotTaken: return ControlResponse(ok: false, error: "ask already pending")
                case .tooLarge: return ControlResponse(ok: false, error: "ask is too large to send to the connected Mac")
                case .notPresented, .formUnsupported, .otherUnsupported:
                    // held until a presenter that can show it takes the session, or its deadline
                    guard store.openUnpresentedAsk(ask, in: session, paneIdentity: identity, window: catalog.id) else {
                        return ControlResponse(ok: false, error: "ask already pending")
                    }
                    armDeadline(ask.id, ask.deadline)
                    return opened
                }
            }
        }
    }

    public func askResult(_ target: String, window: String?) -> ControlResponse {
        if let refusal = windowRefusal(window) { return refusal }
        guard let retained = AskRegistry.shared.result(for: target), retained.windowID == catalog.id else {
            return ControlResponse(ok: false, error: "unknown ask: \(target)")
        }
        return ControlResponse(ok: true, result: ControlResult(ask: retained.result))
    }

    public func cancelAsk(_ target: String, window: String?) -> ControlResponse {
        if let refusal = windowRefusal(window) { return refusal }
        guard let retained = AskRegistry.shared.result(for: target), retained.windowID == catalog.id else {
            return ControlResponse(ok: false, error: "unknown ask: \(target)")
        }
        guard retained.result.result == .pending else { return ControlResponse(ok: true) }
        if case .session(let id, _) = AskRegistry.shared.owner(for: target) {
            store.session(withID: id)?.cancelAsk(id: target)
        }
        return ControlResponse(ok: true)
    }

    /// wireAskOwners lets the process-wide registry read this store's pending asks, keeping the resolver it had
    /// for any other catalog.
    func wireAskOwners() {
        let earlier = AskRegistry.shared.resolveOwner
        AskRegistry.shared.resolveOwner = { [weak store, catalogID = catalog.id] owner in
            guard case .session(let id, let window) = owner, window == catalogID else { return earlier(owner) }
            return store?.session(withID: id)?.askPending
        }
    }
}
