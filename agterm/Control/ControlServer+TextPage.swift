import Foundation
import agtermCore

extension ControlServer {
    /// textFileRefusal reads and validates the file on the calling thread, nil when the page can open; a log page reads
    /// only the file's end, so its size is never refused.
    func textFileRefusal(_ path: String, log: Bool) -> ControlResponse? {
        guard case .failure(let failure) = log ? TextProbe.checkLog(path: path) : TextProbe.check(path: path) else { return nil }
        return ControlResponse(ok: false, error: "session.overlay.open: \(failure)")
    }

    /// textLogRefusal refuses a log page the placement rule hands to the presenting Mac, nil otherwise: that Mac would
    /// get the text page without its log state, so it is refused rather than changed.
    func textLogRefusal(in store: AppStore, sessionID id: UUID, options: ControlSessionOverlayOpenOptions) -> ControlResponse? {
        guard options.textLog != nil, store.pageBelongsRemote(id, pane: options.pane) else { return nil }
        return ControlResponse(ok: false, error: OverlayHtmlError.logRemote)
    }

    /// openTextLink reads and validates the file off the main actor, then rechecks eligibility, since the session
    /// may have changed meanwhile.
    func openTextLink(_ link: LinkPolicy.TextLink, completion: @escaping @MainActor (Bool) -> Void) {
        let id = link.session
        guard canShowLinkOverlay(session: id) else { return completion(false) }
        let path = link.url.path(percentEncoded: false)
        // a page the presenting Mac is handed stays the static text page it already shows there
        let log = link.opensAsLog && library.store(forSession: id)?.pageBelongsRemote(id, pane: nil) == false
        Task { @MainActor [weak self] in
            let checked = log ? await TextProbe.checkLogDetached(path: path) : await TextProbe.checkDetached(path: path)
            guard let self, case .success = checked, canShowLinkOverlay(session: id),
                  let store = library.store(forSession: id) else { return completion(false) }
            releaseHiddenClickedPage(session: id, persistent: false)
            guard store.session(withID: id)?.overlayHidden(nil) != true else { return completion(false) }
            let page = HtmlSource.text(path: path, line: link.line)
            let options = ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: link.sizePercent,
                                                           backgroundColor: nil, page: page, clicked: true,
                                                           textLog: log ? TextLog(tail: TextPage.defaultTail, follow: true) : nil)
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
