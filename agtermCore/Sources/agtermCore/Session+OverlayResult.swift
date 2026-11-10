import Foundation

extension Session {
    /// overlayResult answers `session.overlay.result` for the slot `pane` names (nil for session-wide): the exit code
    /// of the program that ran there, or why there is none.
    public func overlayResult(pane: OverlayPane?) -> ControlResponse {
        if remoteOverlays.slot(pane)?.page != nil {
            return ControlResponse(ok: false, error: OverlayHtmlError.noResult)
        }
        if let slot = remoteOverlays.slot(pane), !slot.ended {
            return ControlResponse(ok: false, error: OverlayResultError.stillRunning)
        }
        if htmlCovers(pane) {
            return ControlResponse(ok: false, error: OverlayHtmlError.noResult)
        }
        let (running, exitCode) = pane.map { (paneOverlay($0) != nil, paneOverlayExitCode($0)) }
            ?? (programOverlayActive, overlayExitCode)
        if running {
            return ControlResponse(ok: false, error: OverlayResultError.stillRunning)
        }
        if exitCode == nil, let failure = remoteOverlays.failure(pane) {
            return ControlResponse(ok: false, error: OverlayResultError.ended(failure))
        }
        // a HUD opened after a program clears its result, so one recorded here is a remote job's that
        // ended under a HUD; the painter itself never reports a status
        if exitCode == nil, pane == nil, hudActive {
            return ControlResponse(ok: false, error: OverlayHudError.noResult)
        }
        guard let code = exitCode else {
            return ControlResponse(ok: false, error: OverlayResultError.noResult)
        }
        return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, exitCode: code))
    }
}
