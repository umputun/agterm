import Foundation
import agtermCore

extension ControlServer {
    /// receiveForwardedClick opens the page a path clicked on viewer `sender` names, on that viewer, the way a click
    /// in that pane here would, and never on this Mac: it reveals nothing, opens no browser and releases no hidden page
    /// here, since only `openRemotePage` replaces one, once every check passed. Every click it cannot open is answered
    /// with one refusal to that viewer; a click whose viewer left meanwhile is dropped.
    func receiveForwardedClick(_ click: PresentationLinkClick, forSession id: UUID, from sender: Int) {
        guard let target = library.store(forSession: id)?.forwardedClickPane(id, pane: click.pane) else {
            return refuseForwardedClick(.paneNotAttached, to: sender)
        }
        let origin = LinkPolicy.ClickOrigin.pane(id)
        let candidates = LinkPolicy.locations(for: click.raw, origin: origin, cwd: target.cwd)
        let exists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
        Task { @MainActor [weak self] in
            let (route, present) = await Task.detached(priority: .userInitiated) {
                let route = LinkPolicy.resolvedRoute(for: click.raw, candidates: candidates, mode: click.mode,
                                                     origin: origin, exists: exists)
                return (route, route.localFile.map { exists($0.path(percentEncoded: false)) } ?? false)
            }.value
            guard let self, forwardIsCurrent(sender) else { return }
            // a location nobody found routes as typed, and a relative one then has nothing to open
            if route == .ignore, !candidates.isEmpty { return refuseForwardedClick(.notFound, to: sender) }
            openForwardedRoute(route, present: present, session: id, sender: sender)
        }
    }

    /// forwardIsCurrent says whether the viewer `sender` a forwarded click came from is still connected; always true
    /// for a click made on this Mac, which carries no sender.
    func forwardIsCurrent(_ sender: Int?) -> Bool {
        sender.map { presentationHub.isConnected(owner: $0) } ?? true
    }

    private func openForwardedRoute(_ route: LinkPolicy.Route, present: Bool, session id: UUID, sender: Int) {
        let done: @MainActor (Bool) -> Void = { [weak self] shown in
            if !shown { self?.refuseForwardedClick(.notOpened, to: sender) }
        }
        switch route {
        case .image, .markdown, .text, .document, .reveal:
            guard present else { return refuseForwardedClick(.notFound, to: sender) }
        default:
            break
        }
        switch route {
        case .image(let url, _): openImageLink(url, session: id, forward: sender, completion: done)
        case .markdown(let url, _, let percent): openMarkdownLink(url, session: id, sizePercent: percent, forward: sender,
                                                                  completion: done)
        case .text(let link): openTextLink(link, forward: sender, completion: done)
        case .document(let url, _, let percent): openDocumentLink(url, session: id, sizePercent: percent, forward: sender,
                                                                  completion: done)
        case .reveal, .ignore, .browser, .overlay, .forwardRemote, .selectSession:
            refuseForwardedClick(.notAPage, to: sender)
        }
    }

    private func refuseForwardedClick(_ reason: RemoteLinkRefusal, to sender: Int) {
        presentationHub.send(.linkRefused(PresentationLinkRefusal(reason: reason)), toOwner: sender)
    }
}
