import Foundation
import agtermCore

extension ControlServer {
    /// receiveForwardedClick opens the page a path clicked on viewer `sender` names, on that viewer, the way a click
    /// in that pane here would, and never on this Mac: it reveals nothing, opens no browser and releases no hidden page
    /// here, since only `openRemotePage` replaces one, once every check passed. A click asking for a snapshot whose
    /// file one of its selectors takes is answered with a claim on that file instead, and one that forbids a page gets
    /// nothing else. Every click it cannot open is answered with one refusal to that viewer, naming the click when it
    /// carried an id; a click whose viewer left meanwhile is dropped.
    func receiveForwardedClick(_ click: PresentationLinkClick, forSession id: UUID, from sender: Int) {
        let clickID = click.click
        guard let target = library.store(forSession: id)?.forwardedClickPane(id, pane: click.pane) else {
            return refuseForwardedClick(.paneNotAttached, to: sender, click: clickID)
        }
        let origin = LinkPolicy.ClickOrigin.pane(id)
        let candidates = LinkPolicy.locations(for: click.raw, origin: origin, cwd: target.cwd)
        let exists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
        let selectors = presentationHub.snapshotSelectors(click, from: sender)
        Task { @MainActor [weak self] in
            let (route, present, snapshot) = await Task.detached(priority: .userInitiated) {
                let route = LinkPolicy.resolvedRoute(for: click.raw, candidates: candidates, mode: click.mode,
                                                     origin: origin, exists: exists)
                let present = route.localFile.map { exists($0.path(percentEncoded: false)) } ?? false
                return (route, present, present ? SnapshotCandidate.find(route, selectors: selectors) : nil)
            }.value
            guard let self, forwardIsCurrent(sender) else { return }
            // a location nobody found routes as typed, and a relative one then has nothing to open
            if route == .ignore, !candidates.isEmpty { return refuseForwardedClick(.notFound, to: sender, click: clickID) }
            switch route {
            case .image, .markdown, .text, .document, .reveal:
                guard present else { return refuseForwardedClick(.notFound, to: sender, click: clickID) }
            default:
                break
            }
            if let snapshot, let clickID, library.store(forSession: id)?.session(withID: id) != nil {
                return presentationHub.offerSnapshot(snapshot, click: clickID, book: snapshotBook, to: sender)
            }
            if click.snapshotOnly == true { return refuseForwardedClick(.hidden, to: sender, click: clickID) }
            openForwardedRoute(route, session: id, sender: sender, click: clickID)
        }
    }

    /// forwardIsCurrent says whether the viewer `sender` a forwarded click came from is still connected; always true
    /// for a click made on this Mac, which carries no sender.
    func forwardIsCurrent(_ sender: Int?) -> Bool {
        sender.map { presentationHub.isConnected(owner: $0) } ?? true
    }

    private func openForwardedRoute(_ route: LinkPolicy.Route, session id: UUID, sender: Int, click: UUID?) {
        let done: @MainActor (Bool) -> Void = { [weak self] shown in
            if !shown { self?.refuseForwardedClick(.notOpened, to: sender, click: click) }
        }
        switch route {
        case .image(let url, _): openImageLink(url, session: id, forward: sender, completion: done)
        case .markdown(let url, _, let percent): openMarkdownLink(url, session: id, sizePercent: percent, forward: sender,
                                                                  completion: done)
        case .text(let link): openTextLink(link, forward: sender, completion: done)
        case .document(let url, _, let percent): openDocumentLink(url, session: id, sizePercent: percent, forward: sender,
                                                                  completion: done)
        case .reveal, .ignore, .browser, .overlay, .forwardRemote, .selectSession:
            refuseForwardedClick(.notAPage, to: sender, click: click)
        }
    }

    private func refuseForwardedClick(_ reason: RemoteLinkRefusal, to sender: Int, click: UUID?) {
        presentationHub.send(.linkRefused(PresentationLinkRefusal(reason: reason, click: click)), toOwner: sender)
    }
}
