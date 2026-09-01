import Foundation

extension ControlDispatcher {
    /// `restore.mode` and the `zmx` group. Split out of `ControlDispatcher.swift` so that file stays inside
    /// the 1000-line limit, following `+Hud` and `+Pick`.
    func dispatchZmxCommand(_ request: ControlRequest) async -> ControlResponse {
        switch request.cmd {
        case .zmxTree:
            // no host is this app's own attachable sessions, which is also exactly what a `zmx tree HOST`
            // runs on the far side
            return await actions.remoteTree(host: request.args?.host?.trimmedOrNil)
        case .zmxAttach:
            guard let host = request.args?.host?.trimmedOrNil else {
                return ControlResponse(ok: false, error: "zmx.attach requires a host")
            }
            // no `active` default: the target names a session on ANOTHER machine, which nothing local
            // could resolve for the caller
            guard let session = request.target?.trimmedOrNil else {
                return ControlResponse(ok: false, error: "zmx.attach requires a remote session")
            }
            // the unresolved case names the id it could not find, so a control character here would reach
            // a terminal through that message
            guard RemoteSession.isPlain(session) else {
                return ControlResponse(ok: false, error: "invalid remote session")
            }
            return await actions.attachRemoteSession(host: host, session: session)
        default:
            return dispatchLocalZmxCommand(request)
        }
    }

    private func dispatchLocalZmxCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .restoreMode:
            guard let raw = request.args?.mode else { return actions.readRestoreMode() }
            // parsed strictly, unlike `RestoreMode`'s lossy decoder: a typo must not silently select
            // `none`, the one mode whose next launch reaps every detached daemon
            guard let mode = RestoreMode(rawValue: raw) else {
                return ControlResponse(ok: false, error: "invalid restore mode: \(raw)")
            }
            return actions.setRestoreMode(mode)
        case .zmxList:
            return actions.listZmxDaemons()
        case .zmxPrune:
            return actions.pruneZmxDaemons()
        case .zmxKill:
            // no `active` or left-pane default: this destroys a backend process rather than a model object,
            // reaching claims no window shows and every client attached to the daemon
            guard let target = request.target, !target.isEmpty else {
                return ControlResponse(ok: false, error: "zmx.kill requires an explicit --target")
            }
            guard let rawPane = request.args?.pane, let pane = ZmxPaneRole(controlName: rawPane) else {
                return ControlResponse(ok: false, error: "zmx.kill requires --pane left|right")
            }
            guard request.args?.force == true else {
                return ControlResponse(ok: false, error: "zmx.kill requires --force")
            }
            return actions.killZmxDaemon(target: target, window: request.args?.window, pane: pane)

        default:
            preconditionFailure("unexpected zmx command: \(request.cmd.rawValue)")
        }
    }
}
