import Foundation
import agtermCore

/// Session effects a presenting Mac shows: status, context and notifications. The server keeps the state and
/// publishes it; nothing is drawn or played here.
extension ServerActions {
    /// setSessionStatus sets the indicator as the Mac does. A sound name is not checked here, the server having no
    /// sounds: it goes to the presenter with the status, which plays it or its own default.
    public func setSessionStatus(_ target: String?, window: String?, update: ControlSessionStatusUpdate) async -> ControlResponse {
        withSession(target, window: window) { session in
            let wasBlocked = session.agentIndicator.status == .blocked
            let pane = update.paneID.flatMap { session.paneRole(forToken: $0) } ?? update.pane
            let indicator = AgentIndicator(status: update.status, blink: update.blink ?? false, autoReset: update.autoReset ?? false,
                                           color: update.color, shape: update.shape, statusPane: pane)
            switch store.applyControlStatus(indicator, forSession: session.id, ifIdle: update.ifIdle) {
            case .refused(let owner):
                return ControlResponse(ok: false, error: "blocked status owned by pane \(owner.rawValue) " +
                    "(write from that pane to change it)")
            case .skipped:
                return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
            case .applied:
                break
            }
            let explicit = update.sound.flatMap { $0.isEmpty ? nil : $0 }
            if explicit != nil || (update.status == .blocked && !wasBlocked) {
                _ = store.presentStatusSoundRemotely(PresentationSound(name: explicit), in: session, pane: pane)
            }
            return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
        }
    }

    public func setSessionContext(_ target: String?, window: String?, context: String?) -> ControlResponse {
        withSession(target, window: window) { session in
            _ = store.setContext(context, forSession: session.id)
            return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
        }
    }

    /// sendNotification reaches the session's viewers live; one sent while none is connected is not kept for later.
    public func sendNotification(_ target: String?, window: String?, title: String?, body: String) -> ControlResponse {
        withSession(target, window: window) { session in
            session.unseenCount += 1
            store.recordNotificationEvent(forSession: session.id, title: title ?? "", body: body, origin: .control)
            return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
        }
    }
}
