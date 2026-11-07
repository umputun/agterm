import Foundation
import agtermCore

extension ControlServer {
    /// openDocumentLink shows a clicked HTML file once the off-main read accepts it, rechecking eligibility after it,
    /// since the session may have changed meanwhile.
    func openDocumentLink(_ url: URL, session id: UUID, sizePercent: Int?, completion: @escaping @MainActor (Bool) -> Void) {
        guard canShowLinkOverlay(session: id) else { return completion(false) }
        let path = url.path(percentEncoded: false)
        Task { @MainActor [weak self] in
            let checked = await DocumentProbe.loadDetached(path: path)
            guard let self, case .success = checked, canShowLinkOverlay(session: id),
                  let store = library.store(forSession: id) else { return completion(false) }
            releaseHiddenClickedPage(session: id, persistent: false)
            guard store.session(withID: id)?.overlayHidden(nil) != true else { return completion(false) }
            let options = ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: sizePercent,
                                                           backgroundColor: nil, page: .document(path: path), clicked: true)
            completion(openHtmlOverlay(in: store, sessionID: id, page: .document(path: path), options: options).ok)
        }
    }
}
