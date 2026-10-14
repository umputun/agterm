extension ControlDispatcher {
    /// `recent.list` and `recent.clear` are app-global, so a target or `--window` is refused before any
    /// action runs. `recent.open` takes the entry as its target and a destination window.
    func dispatchRecentCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .recentOpen:
            return actions.openRecentClosed(request.target, window: request.args?.window)
        case .recentList, .recentClear:
            if request.target != nil || request.args?.window != nil {
                return ControlResponse(ok: false, error: "\(request.cmd.rawValue) takes no target or --window")
            }
            return request.cmd == .recentList ? actions.listRecentClosed() : actions.clearRecentClosed()
        default:
            return ControlResponse(ok: false, error: "unknown command \(request.cmd.rawValue)")
        }
    }
}
