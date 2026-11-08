extension ControlDispatcher {
    func dispatchCompanionCommand(_ request: ControlRequest) async -> ControlResponse {
        switch request.cmd {
        case .sessionCompanionNew:
            return await dispatchCompanionNew(request)
        case .sessionCompanionPage:
            return await dispatchCompanionPage(request)
        case .sessionPage:
            return await dispatchPageSession(request)
        case .sessionCompanionDuplicate:
            return await actions.duplicateAsCompanion(request.target, window: request.args?.window,
                                                      select: request.args?.noSelect != true)
        case .sessionCompanionConvert:
            return actions.convertToCompanion(request.target, window: request.args?.window)
        case .sessionCompanionPageAttach:
            return actions.attachCompanionPage(request.target, window: request.args?.window)
        case .sessionCollapse:
            return actions.setSessionExpansion(request.target, window: request.args?.window, expanded: false)
        case .sessionExpand:
            return actions.setSessionExpansion(request.target, window: request.args?.window, expanded: true)
        default:
            return ControlResponse(ok: false, error: "unknown command \(request.cmd.rawValue)")
        }
    }

    private func dispatchCompanionPage(_ request: ControlRequest) async -> ControlResponse {
        switch Self.pageRowOptions(request.args, row: "page companion", needsPage: OverlayHtmlError.companionNeedsPage) {
        case .rejected(let response): return response
        case .options(let options): return await actions.createPageCompanion(request.target, window: request.args?.window, options: options)
        }
    }

    private func dispatchPageSession(_ request: ControlRequest) async -> ControlResponse {
        switch Self.pageRowOptions(request.args, row: "page session", needsPage: OverlayHtmlError.pageSessionNeedsPage) {
        case .rejected(let response): return response
        case .options(let options): return await actions.createPageSession(request.target, window: request.args?.window, options: options)
        }
    }

    private enum PageRowParse {
        case options(ControlSessionOverlayOpenOptions)
        case rejected(ControlResponse)

        static func reject(_ error: String) -> PageRowParse { .rejected(ControlResponse(ok: false, error: error)) }
    }

    // a page row's page is the row, so it is always full size and session-wide
    private static func pageRowOptions(_ args: ControlArgs?, row: String, needsPage: String) -> PageRowParse {
        let page: HtmlSource
        switch overlayContent(command: args?.command ?? "", args: args) {
        case .rejected(let response): return .rejected(response)
        case .program, .page(.image), .page(.markdown), .page(.text): return .reject(needsPage)
        case .page(let source): page = source
        }
        if args?.pane != nil || args?.sizePercent != nil || args?.width != nil || args?.height != nil {
            return .reject("a \(row) is full size: it takes no --pane, --size-percent, --width or --height")
        }
        if let color = args?.color, !WatermarkConfig.isValidColorHex(color) {
            return .reject("invalid color: \(color) (#rrggbb)")
        }
        return .options(ControlSessionOverlayOpenOptions(
            command: "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: args?.color,
            follow: args?.follow ?? false, pane: nil, page: page, navigation: args?.navigation ?? false,
            javascript: args?.javascript ?? false, chromeless: args?.chromeless ?? false,
            persistent: args?.persistent ?? false, browse: args?.browse ?? false))
    }

    // a companion lands under its parent, so a raw client's workspace or placement field is refused, not dropped
    private func dispatchCompanionNew(_ request: ControlRequest) async -> ControlResponse {
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
        return await actions.createCompanion(request.target, options: options, window: args?.window)
    }
}
