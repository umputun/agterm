import Foundation
import agtermCore

extension ControlServer {
    /// markdownFileRefusal checks the file's descriptor on the calling thread, nil when the page can open.
    func markdownFileRefusal(_ path: String) -> ControlResponse? {
        guard case .failure(let failure) = MarkdownProbe.check(path: path) else { return nil }
        return ControlResponse(ok: false, error: "session.overlay.open: \(failure)")
    }

    /// openMarkdownLink rechecks eligibility after the off-main file check, since the session may have changed meanwhile.
    func openMarkdownLink(_ url: URL, session id: UUID, sizePercent: Int?, forward: Int? = nil,
                          completion: @escaping @MainActor (Bool) -> Void) {
        guard canShowLinkOverlay(session: id, forwarded: forward != nil) else { return completion(false) }
        let path = url.path(percentEncoded: false)
        Task { @MainActor [weak self] in
            let checked = await MarkdownProbe.checkDetached(path: path)
            let links = await Task.detached(priority: .userInitiated) { MarkdownPage.linkGrant(for: path) }.value
            guard let self, case .success = checked, canShowLinkOverlay(session: id, forwarded: forward != nil),
                  forwardIsCurrent(forward, session: id), let store = library.store(forSession: id) else { return completion(false) }
            if forward == nil { releaseHiddenClickedPage(session: id, persistent: false) }
            guard store.session(withID: id)?.overlayHidden(nil) != true else { return completion(false) }
            let options = ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: sizePercent,
                                                           backgroundColor: nil, page: .markdown(path: path), navigation: true,
                                                           clicked: true, forwarded: forward != nil, markdownLinks: links)
            completion(openHtmlOverlay(in: store, sessionID: id, page: .markdown(path: path), options: options).ok)
        }
    }
}
