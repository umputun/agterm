import Foundation
import agtermCore

extension ControlServer {
    /// textFileRefusal reads and validates the file on the calling thread, nil when the page can open.
    func textFileRefusal(_ path: String) -> ControlResponse? {
        guard case .failure(let failure) = TextProbe.check(path: path) else { return nil }
        return ControlResponse(ok: false, error: "session.overlay.open: \(failure)")
    }

    /// openTextLink reads and validates the file off the main actor, then rechecks eligibility, since the session
    /// may have changed meanwhile.
    func openTextLink(_ link: LinkPolicy.TextLink, completion: @escaping @MainActor (Bool) -> Void) {
        let id = link.session
        guard canShowLinkOverlay(session: id) else { return completion(false) }
        let path = link.url.path(percentEncoded: false)
        Task { @MainActor [weak self] in
            let checked = await TextProbe.checkDetached(path: path)
            guard let self, case .success = checked, canShowLinkOverlay(session: id),
                  let store = library.store(forSession: id) else { return completion(false) }
            releaseHiddenClickedPage(session: id, persistent: false)
            guard store.session(withID: id)?.overlayHidden(nil) != true else { return completion(false) }
            let page = HtmlSource.text(path: path, line: link.line)
            let options = ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: link.sizePercent,
                                                           backgroundColor: nil, page: page, clicked: true)
            completion(openHtmlOverlay(in: store, sessionID: id, page: page, options: options).ok)
        }
    }

    /// setSessionOverlayFollow applies `mode` to the log page in the addressed slot; `result.text` is `following` or
    /// `paused`.
    func setSessionOverlayFollow(_ target: String?, window: String?, pane: OverlayPane?,
                                 mode: ControlToggleMode) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            switch store.setTextLogFollowing(id, pane: pane, mode: mode) {
            case .failure(let failure):
                return ControlResponse(ok: false, error: failure.message)
            case .success(let following):
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, text: following ? "following" : "paused"))
            }
        }
    }
}
