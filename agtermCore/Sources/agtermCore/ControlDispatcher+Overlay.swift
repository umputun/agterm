import Foundation

extension ControlDispatcher {
    /// Validates the overlay commands before the host resolves the session or touches its slots.
    func dispatchSessionOverlayCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .sessionOverlayOpen:
            let command = request.args?.command ?? ""
            let page: HtmlSource?
            switch Self.overlayContent(command: command, args: request.args) {
            case .rejected(let response): return response
            case .program: page = nil
            case .page(let source): page = source
            }
            if let color = request.args?.color, !WatermarkConfig.isValidColorHex(color) {
                return ControlResponse(ok: false, error: "invalid color: \(color) (#rrggbb)")
            }
            let pane: OverlayPane?
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let parsed): pane = parsed
            }
            if pane != nil, request.args?.sizePercent != nil {
                return ControlResponse(ok: false, error: PaneOverlayError.sizePercentConflict)
            }
            let points = OverlayPointSize(width: request.args?.width, height: request.args?.height)
            if pane != nil, !points.isEmpty {
                return ControlResponse(ok: false, error: PaneOverlayError.pointsConflict)
            }
            if let percent = request.args?.sizePercent, !(1...100).contains(percent) {
                return ControlResponse(ok: false, error: "session.overlay.open: --size-percent must be 1...100")
            }
            if let failure = Self.overlayPointFailure(points) { return failure }
            if !points.isEmpty, request.args?.sizePercent == nil {
                return ControlResponse(ok: false, error: OverlayPointError.needsPercent)
            }
            return actions.openSessionOverlay(request.target, window: request.args?.window,
                                              options: ControlSessionOverlayOpenOptions(
                                                command: command,
                                                cwd: page == nil ? request.args?.cwd : nil,
                                                wait: request.args?.wait ?? false,
                                                sizePercent: request.args?.sizePercent,
                                                backgroundColor: request.args?.color,
                                                follow: request.args?.follow ?? false,
                                                pane: pane,
                                                page: page,
                                                navigation: request.args?.navigation ?? false,
                                                javascript: request.args?.javascript ?? false,
                                                chromeless: request.args?.chromeless ?? false,
                                                persistent: request.args?.persistent ?? false,
                                                browse: request.args?.browse ?? false,
                                                points: points
                                              ))
        case .sessionOverlayReload:
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let pane):
                return actions.reloadSessionOverlay(request.target, window: request.args?.window, pane: pane,
                                                    current: request.args?.current ?? false)
            }
        case .sessionOverlayNavigate:
            guard let navigation = request.args?.to.flatMap(HtmlNavigation.init(rawValue:)) else {
                return ControlResponse(ok: false, error: OverlayHtmlError.navigation)
            }
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let pane):
                return actions.navigateSessionOverlay(request.target, window: request.args?.window, pane: pane,
                                                      navigation: navigation)
            }
        case .sessionOverlayClose:
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let pane):
                return actions.closeSessionOverlay(request.target, window: request.args?.window, pane: pane)
            }
        case .sessionOverlayResize:
            // pane overlays are always full, so ANY `--pane` is refused here, valid spelling or not.
            if request.args?.pane != nil {
                return ControlResponse(ok: false, error: PaneOverlayError.resizeUnsupported)
            }
            let wantsFull = request.args?.full == true
            let percent = request.args?.sizePercent
            let points = OverlayPointSize(width: request.args?.width, height: request.args?.height)
            if wantsFull, percent != nil {
                return ControlResponse(ok: false, error: "session.overlay.resize: --full is mutually exclusive with --size-percent")
            }
            if wantsFull, !points.isEmpty {
                return ControlResponse(ok: false, error: OverlayPointError.fullConflict)
            }
            if !wantsFull, percent == nil, points.isEmpty {
                return ControlResponse(ok: false, error: "session.overlay.resize requires --size-percent, --width/--height or --full")
            }
            if let percent, !(1...100).contains(percent) {
                return ControlResponse(ok: false, error: "session.overlay.resize: --size-percent must be 1...100")
            }
            if let failure = Self.overlayPointFailure(points) { return failure }
            if points.isEmpty {
                return actions.resizeSessionOverlay(request.target, window: request.args?.window,
                                                    sizePercent: wantsFull ? nil : percent)
            }
            return actions.resizeSessionOverlay(request.target, window: request.args?.window,
                                                sizePercent: percent, points: points)
        case .sessionOverlayResult:
            if let page = request.args?.page {
                guard let id = UUID(uuidString: page) else { return ControlResponse(ok: false, error: OverlayHtmlError.invalidPageID) }
                return actions.htmlPageResult(id)
            }
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let pane):
                return actions.sessionOverlayResult(request.target, window: request.args?.window, pane: pane)
            }
        case .sessionOverlaySubmit:
            guard let value = request.args?.value else { return ControlResponse(ok: false, error: OverlayHtmlError.submitValue) }
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let pane):
                return actions.submitSessionOverlay(request.target, window: request.args?.window, pane: pane, value: value)
            }
        case .sessionOverlayCopy:
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let pane):
                return actions.copySessionOverlaySelection(request.target, window: request.args?.window, pane: pane)
            }
        case .sessionOverlayText:
            return dispatchSessionOverlayText(request)
        case .sessionOverlayHide, .sessionOverlayShow, .sessionOverlayToggle:
            let mode: OverlayVisibilityMode = request.cmd == .sessionOverlayHide ? .hide
                : (request.cmd == .sessionOverlayShow ? .show : .toggle)
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let pane):
                return actions.setSessionOverlayVisibility(request.target, window: request.args?.window, pane: pane,
                                                           mode: mode)
            }
        case .sessionOverlayJobRun:
            guard let job = request.target?.trimmedOrNil else {
                return ControlResponse(ok: false, error: "session.overlay.job.run requires a job id")
            }
            guard UUID(uuidString: job) != nil else { return ControlResponse(ok: false, error: "invalid job id") }
            return actions.claimOverlayJob(job)
        case .sessionOverlayPageServe:
            guard let token = request.target?.trimmedOrNil else {
                return ControlResponse(ok: false, error: "session.overlay.page.serve requires a page token")
            }
            guard UUID(uuidString: token) != nil else { return ControlResponse(ok: false, error: "invalid page token") }
            return actions.claimPageServe(token)
        default:
            preconditionFailure("dispatchSessionOverlayCommand called for \(request.cmd.rawValue)")
        }
    }

    enum OverlayContent {
        case rejected(ControlResponse)
        case program
        case page(HtmlSource)
    }

    private static func overlayPointFailure(_ points: OverlayPointSize) -> ControlResponse? {
        guard [points.width, points.height].allSatisfy({ ($0 ?? 1) > 0 }) else {
            return ControlResponse(ok: false, error: OverlayPointError.notPositive)
        }
        return nil
    }

    static func overlayContent(command: String, args: ControlArgs?) -> OverlayContent {
        let reject = { (error: String) in OverlayContent.rejected(ControlResponse(ok: false, error: error)) }
        switch (args?.html, args?.url) {
        case (nil, nil):
            if args?.navigation == true { return reject(OverlayHtmlError.navigationWithoutPage) }
            if args?.javascript == true { return reject(OverlayHtmlError.javascriptWithoutPage) }
            if args?.chromeless == true { return reject(OverlayHtmlError.chromelessRequiresFile) }
            if args?.persistent == true { return reject(OverlayHtmlError.persistentRequiresURL) }
            if args?.browse == true { return reject(OverlayHtmlError.browseRequiresURL) }
            return command.isEmpty ? reject("session.overlay.open requires a command") : .program
        case (.some, .some):
            return reject(OverlayHtmlError.htmlAndURL)
        case (.some(let html), nil):
            if !command.isEmpty { return reject(OverlayHtmlError.commandAndHtml) }
            if args?.wait == true { return reject(OverlayHtmlError.waitWithHtml) }
            if args?.chromeless == true, args?.navigation == true { return reject(OverlayHtmlError.chromelessWithNavigation) }
            if args?.persistent == true { return reject(OverlayHtmlError.persistentRequiresURL) }
            if args?.browse == true { return reject(OverlayHtmlError.browseRequiresURL) }
            if let error = HtmlOverlay.grantError(file: html, grantRoot: args?.cwd) {
                return reject("session.overlay.open: \(error)")
            }
            return .page(.file(path: html, grantRoot: args?.cwd))
        case (nil, .some(let text)):
            if !command.isEmpty { return reject(OverlayHtmlError.commandAndURL) }
            if args?.wait == true { return reject(OverlayHtmlError.waitWithURL) }
            if args?.cwd != nil { return reject(OverlayHtmlError.cwdWithURL) }
            if args?.chromeless == true, args?.navigation == true { return reject(OverlayHtmlError.chromelessWithNavigation) }
            if args?.chromeless == true, args?.browse == true { return reject(OverlayHtmlError.chromelessWithBrowse) }
            guard let url = HtmlSource.webURL(text) else { return reject(OverlayHtmlError.invalidURL) }
            if args?.chromeless == true, !HtmlSource.isLoopback(text) { return reject(OverlayHtmlError.chromelessRequiresLoopback) }
            return .page(.url(url))
        }
    }

    /// The extent is checked before the pane, so the same flags produce the same first error here and on
    /// `session.text`.
    private func dispatchSessionOverlayText(_ request: ControlRequest) -> ControlResponse {
        let all: Bool
        let lines: Int?
        switch parseBufferExtent(request.args) {
        case .rejected(let response): return response
        case .extent(let parsedAll, let parsedLines):
            all = parsedAll
            lines = parsedLines
        }
        switch parseOverlayPane(request.args?.pane) {
        case .rejected(let response): return response
        case .pane(let pane):
            return actions.readSessionOverlayText(request.target, window: request.args?.window,
                                                  options: ControlSessionOverlayTextOptions(pane: pane,
                                                                                            all: all,
                                                                                            lines: lines))
        }
    }
}
