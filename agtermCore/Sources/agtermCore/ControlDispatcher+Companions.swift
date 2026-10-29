extension ControlDispatcher {
    func dispatchCompanionCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .sessionCompanionNew:
            return dispatchCompanionNew(request)
        case .sessionCollapse:
            return actions.setSessionExpansion(request.target, window: request.args?.window, expanded: false)
        case .sessionExpand:
            return actions.setSessionExpansion(request.target, window: request.args?.window, expanded: true)
        default:
            return ControlResponse(ok: false, error: "unknown command \(request.cmd.rawValue)")
        }
    }

    // a companion lands under its parent, so a raw client's workspace or placement field is refused, not dropped
    private func dispatchCompanionNew(_ request: ControlRequest) -> ControlResponse {
        let args = request.args
        if args?.workspace != nil || args?.workspaceName != nil || args?.createWorkspace == true
            || args?.after != nil || args?.before != nil {
            return ControlResponse(ok: false, error: "a companion takes no workspace or placement: it lands under its parent")
        }
        if args?.wait == true, args?.command == nil {
            return ControlResponse(ok: false, error: "--wait requires --command")
        }
        let tint: SidebarTint?
        switch Self.creationTint(args) {
        case .success(let value): tint = value
        case .failure(let rejection): return ControlResponse(ok: false, error: rejection.message)
        }
        let options = CompanionOptions(cwd: args?.cwd, command: args?.command, name: args?.name,
                                       wait: args?.wait == true, select: args?.noSelect != true, tint: tint)
        return actions.createCompanion(request.target, options: options, window: args?.window)
    }
}
