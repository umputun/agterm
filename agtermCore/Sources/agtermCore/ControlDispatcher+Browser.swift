extension ControlDispatcher {
    /// `browser.clear` is app-global: one saved store serves every window, so a target or `--window` is
    /// refused before any action runs.
    func dispatchBrowserCommand(_ request: ControlRequest) async -> ControlResponse {
        if request.target != nil || request.args?.window != nil {
            return ControlResponse(ok: false, error: "\(request.cmd.rawValue) takes no target or --window")
        }
        return await actions.clearBrowser()
    }
}
