import Foundation

extension ControlDispatcher {
    /// `restore.mode` and the `zmx` group. Split out of `ControlDispatcher.swift` so that file stays inside
    /// the 1000-line limit, following `+Hud` and `+Pick`.
    func dispatchZmxCommand(_ request: ControlRequest) -> ControlResponse {
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
