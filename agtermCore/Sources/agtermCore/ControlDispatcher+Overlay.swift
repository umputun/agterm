import Foundation

extension ControlDispatcher {
    /// Validates the overlay commands before the host resolves the session or touches its slots.
    func dispatchSessionOverlayCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .sessionOverlayOpen:
            guard let command = request.args?.command, !command.isEmpty else {
                return ControlResponse(ok: false, error: "session.overlay.open requires a command")
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
            if let percent = request.args?.sizePercent, !(1...100).contains(percent) {
                return ControlResponse(ok: false, error: "session.overlay.open: --size-percent must be 1...100")
            }
            return actions.openSessionOverlay(request.target, window: request.args?.window,
                                              options: ControlSessionOverlayOpenOptions(
                                                command: command,
                                                cwd: request.args?.cwd,
                                                wait: request.args?.wait ?? false,
                                                sizePercent: request.args?.sizePercent,
                                                backgroundColor: request.args?.color,
                                                follow: request.args?.follow ?? false,
                                                pane: pane
                                              ))
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
            if wantsFull, percent != nil {
                return ControlResponse(ok: false, error: "session.overlay.resize: --full is mutually exclusive with --size-percent")
            }
            if !wantsFull, percent == nil {
                return ControlResponse(ok: false, error: "session.overlay.resize requires --size-percent or --full")
            }
            if let percent, !(1...100).contains(percent) {
                return ControlResponse(ok: false, error: "session.overlay.resize: --size-percent must be 1...100")
            }
            return actions.resizeSessionOverlay(request.target, window: request.args?.window,
                                                sizePercent: wantsFull ? nil : percent)
        case .sessionOverlayResult:
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let pane):
                return actions.sessionOverlayResult(request.target, window: request.args?.window, pane: pane)
            }
        case .sessionOverlayCopy:
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let pane):
                return actions.copySessionOverlaySelection(request.target, window: request.args?.window, pane: pane)
            }
        case .sessionOverlayText:
            return dispatchSessionOverlayText(request)
        case .sessionOverlayJobRun:
            guard let job = request.target?.trimmedOrNil else {
                return ControlResponse(ok: false, error: "session.overlay.job.run requires a job id")
            }
            guard UUID(uuidString: job) != nil else { return ControlResponse(ok: false, error: "invalid job id") }
            return actions.claimOverlayJob(job)
        default:
            preconditionFailure("dispatchSessionOverlayCommand called for \(request.cmd.rawValue)")
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
