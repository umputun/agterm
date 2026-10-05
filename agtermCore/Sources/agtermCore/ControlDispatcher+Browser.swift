extension ControlDispatcher {
    /// The `browser.*` commands are app-global: one saved store and one link-open setting serve every
    /// window, so a target or `--window` is refused before any action runs.
    func dispatchBrowserCommand(_ request: ControlRequest) async -> ControlResponse {
        if request.target != nil || request.args?.window != nil {
            return ControlResponse(ok: false, error: "\(request.cmd.rawValue) takes no target or --window")
        }
        guard request.cmd == .browserLinks else { return await actions.clearBrowser() }
        guard let raw = request.args?.mode else { return actions.linkOpenMode(nil) }
        guard let mode = LinkOpenMode(rawValue: raw) else {
            return ControlResponse(ok: false, error: "invalid link mode: \(raw)")
        }
        return actions.linkOpenMode(mode)
    }
}
