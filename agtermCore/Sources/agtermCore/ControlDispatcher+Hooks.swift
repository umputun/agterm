extension ControlDispatcher {
    /// `hooks.reload` / `hooks.list` are app-global: a target or `--window` is refused before any action
    /// runs, so a caller cannot believe it reloaded one window's hooks.
    func dispatchHooksCommand(_ request: ControlRequest) -> ControlResponse {
        if request.target != nil || request.args?.window != nil {
            return ControlResponse(ok: false, error: "\(request.cmd.rawValue) takes no target or --window")
        }
        switch request.cmd {
        case .hooksReload: return actions.reloadHooks()
        case .hooksList: return actions.listHooks()
        default: return ControlResponse(ok: false, error: "unknown command \(request.cmd.rawValue)")
        }
    }
}
