import Foundation

extension ControlDispatcher {
    func dispatchDetachCommand(_ request: ControlRequest) -> ControlResponse {
        let window = request.args?.window
        switch request.cmd {
        case .sessionDetach:
            let targets = request.args?.targets ?? [request.target ?? "active"]
            guard !targets.isEmpty else { return ControlResponse(ok: false, error: "session.detach requires at least one --target") }
            return actions.detachSessions(targets, window: window)
        case .sessionReattach:
            guard let target = Self.detachedTarget(request) else {
                return ControlResponse(ok: false, error: "session.reattach requires a detached session's id")
            }
            return actions.reattachSession(target, window: window)
        case .workspaceDetach:
            return actions.detachWorkspace(request.target, window: window)
        case .workspaceReattach:
            guard let target = Self.detachedTarget(request) else {
                return ControlResponse(ok: false, error: "workspace.reattach requires a detached workspace's id")
            }
            return actions.reattachWorkspace(target, window: window)
        case .windowRemoteDismiss:
            return actions.dismissRemoteUnknown(window: request.target)
        default:
            return ControlResponse(ok: false, error: "unknown command \(request.cmd.rawValue)")
        }
    }

    /// detachedTarget is a reattach's id or prefix; a hidden row is never `active`.
    private static func detachedTarget(_ request: ControlRequest) -> String? {
        guard let target = request.target?.trimmedOrNil, target.lowercased() != "active" else { return nil }
        return target
    }
}
