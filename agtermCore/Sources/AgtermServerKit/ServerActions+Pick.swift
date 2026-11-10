import Foundation
import agtermCore

extension ServerActions {
    public func openPick(_: PendingPick, window _: String?, follow _: Bool) -> ControlResponse {
        ControlResponse(ok: false, error: "pick.open needs --session on agterm-server, which has no window to show it in")
    }

    public func openPick(_ pick: PendingPick, session target: String, window: String?, follow: Bool) -> ControlResponse {
        withSession(target, window: window) { session in
            guard PresentationPick(pick, owner: .max, follow: follow).fitsFrame else {
                return ControlResponse(ok: false, error: "pick is too large to send to a Mac")
            }
            switch store.presentPickRemotely(pick, in: session, window: nil, follow: follow) {
            case false?: return ControlResponse(ok: false, error: "pick already pending")
            case true?: break
            case nil:
                guard SessionPickBook.shared.openUnpresented(pick, session: session.id, follow: follow) else {
                    return ControlResponse(ok: false, error: "pick already pending")
                }
            }
            armDeadline(pick.id, pick.deadline)
            return ControlResponse(ok: true, result: ControlResult(id: pick.id))
        }
    }

    /// armDeadline ends the ask or pick `id` at its deadline; an answer or offer reaching it first checks the
    /// deadline itself, so this only covers one nobody touches.
    func armDeadline(_ id: String, _ deadline: Date?) {
        guard let deadline else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((max(deadline.timeIntervalSinceNow, 0) + 0.05) * 1_000_000_000))
            self?.store.expireInteraction(id, now: Date())
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
