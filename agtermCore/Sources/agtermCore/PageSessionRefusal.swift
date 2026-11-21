/// PageSessionRefusal is the one guard every host runs before dispatch for a command a page session cannot take, so a
/// socket client and a page's bridge meet one refusal.
public enum PageSessionRefusal {
    // a page session's page is the row: these act on a terminal, or would cover or float the page
    private static let refused: Set<Command> = [
        .sessionType, .sessionText, .sessionCopy, .sessionPaste, .sessionSelectAll, .sessionSearch, .sessionBackground,
        .sessionLead, .sessionSwap, .sessionFocus, .sessionResize, .sessionSplit, .sessionSplitClose, .sessionScratch,
        .sessionRestart, .sessionRestore, .sessionOverlayOpen, .sessionHudOpen,
    ]

    /// refusal answers `request` when it addresses a page session, nil otherwise. `isPageSession` resolves a session
    /// target and window as the command would. `surface.zoom` and `surface.cursor` are judged only for an explicit
    /// target, since their `active` means the window's zoom target, and a zoom hide stays idempotent.
    public static func refusal(_ request: ControlRequest,
                               isPageSession: (_ target: String?, _ window: String?) -> Bool) -> ControlResponse? {
        let floats = request.cmd == .sessionOverlayResize && request.args?.full != true
        let terminalAsk = request.cmd == .askOpen && request.args?.style != "gui"
        let namedSurface = (request.cmd == .surfaceCursor || (request.cmd == .surfaceZoom && request.args?.mode != "hide"))
            && request.target.map { $0 != "active" } == true
        guard refused.contains(request.cmd) || floats || terminalAsk || namedSurface,
              isPageSession(request.target.map(sessionPart(ofSurface:)), request.args?.window) else { return nil }
        return ControlResponse(ok: false, error: "\(request.cmd.rawValue): not available on a page session")
    }

    // a `surface:<session>:<slot>` address names its session in the middle
    private static func sessionPart(ofSurface target: String) -> String {
        let parts = target.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0] == "surface" ? String(parts[1]) : target
    }
}
