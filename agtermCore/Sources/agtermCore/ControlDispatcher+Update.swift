extension ControlDispatcher {
    func dispatchUpdateCheck(_ request: ControlRequest) -> ControlResponse {
        if request.target != nil || request.args?.window != nil {
            return ControlResponse(ok: false, error: "update.check takes no target or --window")
        }
        return actions.checkForUpdates()
    }
}
