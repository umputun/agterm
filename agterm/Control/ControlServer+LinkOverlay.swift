import Foundation
import agtermCore

extension ControlServer {
    /// openLinkOverlay shows a clicked link as a browsing page over its session, at `sizePercent` or full size
    /// when nil, and says whether it did.
    /// A HUD on the session and a zoomed terminal in its window both refuse it up front: the store would
    /// accept the page, closing the HUD for good in one case and showing nothing in the other.
    func openLinkOverlay(_ url: URL, session id: UUID, sizePercent: Int?) -> Bool {
        guard canShowLinkOverlay(session: id) else { return false }
        releaseHiddenClickedPage(session: id, persistent: true)
        let options = ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: sizePercent,
                                                       backgroundColor: nil, page: .url(url), navigation: true,
                                                       javascript: true, persistent: true, browse: true, clicked: true)
        return openSessionOverlay(id.uuidString, window: nil, options: options).ok
    }

    /// canShowLinkOverlay is the up-front HUD and zoom refusal `openLinkOverlay` describes. A click forwarded from the
    /// presenting Mac skips the zoom check: this Mac's zoom is not what that Mac shows.
    func canShowLinkOverlay(session id: UUID, forwarded: Bool = false) -> Bool {
        guard let session = library.store(forSession: id)?.session(withID: id), !session.hudActive else { return false }
        if !forwarded, let windowID = library.windowID(forSession: id),
           TerminalZoomRegistry.shared.controller(for: windowID)?.target != nil { return false }
        return true
    }
}
