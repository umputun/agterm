import Foundation
import agtermCore

/// Picks on agterm-server are session-bound: drawn by the Mac presenting the session, or refused while none is.
extension ServerActions {
    public func openPick(_: PendingPick, window _: String?, follow _: Bool) -> ControlResponse {
        ControlResponse(ok: false, error: "pick.open needs --session on agterm-server, which has no window to show it in")
    }

    public func openPick(_ pick: PendingPick, session target: String, window: String?, follow: Bool) -> ControlResponse {
        withSession(target, window: window) { session in
            switch store.presentPickRemotely(pick, in: session, window: nil, follow: follow) {
            case true?: ControlResponse(ok: true, result: ControlResult(id: pick.id))
            case false?: ControlResponse(ok: false, error: "pick already pending")
            case nil: ControlResponse(ok: false, error: "no connected Mac to show the pick")
            }
        }
    }

    public func pickResult(_ target: String, window: String?) -> ControlResponse {
        if let refusal = windowRefusal(window) { return refusal }
        guard let result = SessionPickBook.shared.result(for: target) else {
            return ControlResponse(ok: false, error: "unknown pick: \(target)")
        }
        return ControlResponse(ok: true, result: ControlResult(pick: result))
    }

    public func cancelPick(_ target: String, window: String?) -> ControlResponse {
        if let refusal = windowRefusal(window) { return refusal }
        return SessionPickBook.shared.cancel(target) ? ControlResponse(ok: true) : ControlResponse(ok: false, error: "unknown pick: \(target)")
    }
}
