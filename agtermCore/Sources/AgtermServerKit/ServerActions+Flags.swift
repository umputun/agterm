import Foundation
import agtermCore

extension ServerActions {
    /// setSessionFlag sets the flag `on|off|toggle`, or `clear`s every flag; `move` reorders a Mac's flagged view,
    /// which the server does not keep.
    public func setSessionFlag(_ target: String?, window: String?, mode: String?) -> ControlResponse {
        let mode = mode ?? "toggle"
        if mode == "clear" {
            if let refusal = windowRefusal(window) { return refusal }
            store.clearFlags()
            return ControlResponse(ok: true)
        }
        return withSession(target, window: window) { session in
            let want: Bool
            switch mode {
            case "on": want = true
            case "off": want = false
            case "toggle": want = !session.flagged
            default: return ControlResponse(ok: false, error: "invalid flag mode: \(mode)")
            }
            store.setFlag(want, forSession: session.id)
            return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
        }
    }

    public func setWorkspaceFlag(_ target: String?, window: String?, mode: ControlToggleMode) -> ControlResponse {
        withWorkspace(target, window: window) { id in
            store.applyWorkspaceFlag(mode, to: id)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    public func setSessionTint(_ target: String?, window: String?, update: ControlTintUpdate) -> ControlResponse {
        withSession(target, window: window) { session in
            store.setTint(update.resolved(over: session.tint), forSession: session.id)
            return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
        }
    }

    public func setWorkspaceTint(_ target: String?, window: String?, update: ControlTintUpdate) -> ControlResponse {
        withNamedWorkspace(target, window: window) { id in
            store.setTint(update.resolved(over: store.workspaces.first { $0.id == id }?.tint), forWorkspace: id)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }
}
