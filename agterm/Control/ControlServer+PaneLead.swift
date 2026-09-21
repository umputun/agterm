import agtermCore
import Foundation

/// Reads and scripted typing for a pane that does not lead its zmx daemon. Its own surface holds output
/// laid out for another client's grid, so screen text and the cursor come from the daemon's terminal
/// instead, and typing goes through the daemon's acknowledged path, which a follower's keystrokes cannot
/// use: the daemon drops them. This is what keeps pane-to-pane automation working on the Mac a session
/// runs on while another Mac leads it.
extension ControlServer {
    enum CoveredPane {
        /// The pane leads, or its zmx never reported a role: its own surface is the truth.
        case notCovered
        case daemon(name: String, client: ZmxClient)
        case refused(String)
    }

    func coveredPane(_ surface: GhosttySurfaceView) -> CoveredPane {
        guard surface.leadCovered else { return .notCovered }
        guard let name = surface.zmxSessionName, let client = zmxClient else {
            // an attached pane's daemon is on another Mac, out of reach of a synchronous read
            return .refused("pane is in use on the Mac it runs on; take the lead to drive it from here")
        }
        return .daemon(name: name, client: client)
    }

    /// `session.lead`: what a key press on the pane's cover does. A pane that already leads answers ok, so
    /// a caller can ask without reading `lead` first; one whose zmx never reported a role has no lead to
    /// take and says so rather than answering ok for nothing.
    func takeSessionLead(_ target: String?, window: String?, pane: StatusPane?) -> ControlResponse {
        guard pane != .scratch else { return ControlResponse(ok: false, error: "the scratch terminal has no lead") }
        return resolver.resolveSession(target, window: window) { store, id in
            let session = store.session(withID: id)
            if pane == .right, session?.splitSurface == nil {
                return ControlResponse(ok: false, error: "session has no split pane")
            }
            guard let surface = (pane == .right ? session?.splitSurface : session?.surface) as? GhosttySurfaceView,
                  let identity = UUID(uuidString: surface.paneToken) else {
                return ControlResponse(ok: false, error: "session not realized")
            }
            guard ZmxLeadBook.shared.role(pane: identity) != nil || surface.leadCovered else {
                return ControlResponse(ok: false, error: "pane has no lead to take")
            }
            if surface.leadCovered, !ZmxLeadBook.shared.reattaching(pane: identity) { PaneLead.reattach?(surface, true) }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// `session.text` for a covered pane, nil when the pane is not covered.
    func coveredText(_ surface: GhosttySurfaceView, all: Bool, lines: Int?) -> ControlResponse? {
        switch coveredPane(surface) {
        case .notCovered: return nil
        case .refused(let reason): return ControlResponse(ok: false, error: reason)
        case .daemon(let name, let client):
            guard let screen = client.screen(name: name, all: all || lines != nil) else {
                return ControlResponse(ok: false, error: "failed to read surface buffer")
            }
            return ControlResponse(ok: true, result: ControlResult(text: lines.map(screen.lastLines) ?? screen.text))
        }
    }

    /// `surface.cursor` for a covered pane, nil when the pane is not covered.
    func coveredCursor(_ surface: GhosttySurfaceView, controlID: String) -> ControlResponse? {
        switch coveredPane(surface) {
        case .notCovered: return nil
        case .refused(let reason): return ControlResponse(ok: false, error: reason)
        case .daemon(let name, let client):
            guard let screen = client.screen(name: name, all: false) else {
                return ControlResponse(ok: false, error: "failed to read cursor position")
            }
            return ControlResponse(ok: true, result: ControlResult(id: controlID,
                                                                   cursor: ControlCursor(column: screen.cursorColumn)))
        }
    }

    /// `session.type` into a covered pane, nil when the pane is not covered.
    func coveredType(_ text: String, into surface: GhosttySurfaceView, session: UUID) -> ControlResponse? {
        switch coveredPane(surface) {
        case .notCovered: return nil
        case .refused(let reason): return ControlResponse(ok: false, error: reason)
        case .daemon(let name, let client):
            let bytes = KeystrokeSegments.ptyBytes(text)
            guard bytes.isEmpty || client.type(name: name, bytes: bytes) else {
                return ControlResponse(ok: false, error: "the pane's zmx daemon did not accept the input")
            }
            // the pane-scoped status clear `injectAsUserInput` fires: the input a blocked agent waited for
            if !text.isEmpty { surface.onUserInputClearsStatus?(InterruptKeystroke.classify(text: text)) }
            return ControlResponse(ok: true, result: ControlResult(id: session.uuidString))
        }
    }
}
