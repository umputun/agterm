extension ControlDispatcher {
    /// `recent.list` and `recent.clear` refuse a target; `--window` names a window whose host keeps its own
    /// list, a server window on a Mac. `recent.open` takes the entry as its target and a destination window, and
    /// `session.undo` the undo id a close answered.
    func dispatchRecentCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .sessionUndo:
            guard let undoID = request.target?.trimmedOrNil, undoID.lowercased() != "active" else {
                return ControlResponse(ok: false, error: "session.undo requires --target with the undo id a close answered")
            }
            return actions.undoClose(undoID)
        case .recentOpen:
            return actions.openRecentClosed(request.target, window: request.args?.window)
        case .recentList, .recentClear:
            if request.target != nil {
                return ControlResponse(ok: false, error: "\(request.cmd.rawValue) takes no target")
            }
            let window = request.args?.window
            guard window != nil else {
                return request.cmd == .recentList ? actions.listRecentClosed() : actions.clearRecentClosed()
            }
            return request.cmd == .recentList ? actions.listRecentClosed(window: window) : actions.clearRecentClosed(window: window)
        default:
            return ControlResponse(ok: false, error: "unknown command \(request.cmd.rawValue)")
        }
    }
}
