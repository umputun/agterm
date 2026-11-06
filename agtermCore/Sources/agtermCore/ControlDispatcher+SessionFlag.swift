extension ControlDispatcher {
    /// `session.flag` passes `on|off|toggle|clear` through unchanged; `move` needs exactly one of
    /// `--before`/`--after`, and either anchor outside `move` is refused.
    func dispatchSessionFlag(_ request: ControlRequest) -> ControlResponse {
        let args = request.args
        let anchors = [args?.before, args?.after].compactMap { $0 }
        guard args?.mode == "move" else {
            guard anchors.isEmpty else {
                return ControlResponse(ok: false, error: "--before and --after apply only to session.flag move")
            }
            return actions.setSessionFlag(request.target, window: args?.window, mode: args?.mode)
        }
        guard anchors.count == 1, let anchor = anchors.first else {
            return ControlResponse(ok: false, error: "session.flag move requires exactly one of --before or --after")
        }
        return actions.moveFlaggedSession(request.target, window: args?.window, anchor: anchor,
                                          placement: args?.before != nil ? .before : .after)
    }
}
