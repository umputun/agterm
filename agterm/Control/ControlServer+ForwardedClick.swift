import Foundation
import agtermCore

extension ControlServer {
    /// receiveForwardedClick opens the page a path clicked on the presenting Mac names, the way a click in that pane
    /// here would, and never on this Mac: it reveals nothing, opens no browser and releases no hidden page here, since
    /// only `openRemotePage` replaces one, once every check passed. Every click it cannot open is answered with one
    /// refusal to the presenter that sent it; a click whose presenter changed meanwhile is dropped.
    func receiveForwardedClick(_ click: PresentationLinkClick, forSession id: UUID) {
        let generation = presentationHub.presenterGeneration(session: id)
        guard let target = library.store(forSession: id)?.forwardedClickPane(id, pane: click.pane) else {
            return refuseForwardedClick(.paneNotAttached, session: id, generation: generation)
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
            guard let self, forwardIsCurrent(generation, session: id) else { return }
            // a location nobody found routes as typed, and a relative one then has nothing to open
            if route == .ignore, !candidates.isEmpty { return refuseForwardedClick(.notFound, session: id, generation: generation) }
            openForwardedRoute(route, present: present, session: id, generation: generation)
        }
    }

    /// forwardIsCurrent says whether the presenter a forwarded click came from still presents `id`; always true for
    /// a click made on this Mac, which carries no generation.
    func forwardIsCurrent(_ generation: Int?, session id: UUID) -> Bool {
        generation.map { presentationHub.presenterGeneration(session: id) == $0 } ?? true
    }

    private func openForwardedRoute(_ route: LinkPolicy.Route, present: Bool, session id: UUID, generation: Int) {
        let done: @MainActor (Bool) -> Void = { [weak self] shown in
            if !shown { self?.refuseForwardedClick(.notOpened, session: id, generation: generation) }
        }
        switch route {
        case .image, .markdown, .text, .document, .reveal:
            guard present else { return refuseForwardedClick(.notFound, session: id, generation: generation) }
        default:
            break
        }
        switch route {
        case .image(let url, _): openImageLink(url, session: id, forward: generation, completion: done)
        case .markdown(let url, _, let percent): openMarkdownLink(url, session: id, sizePercent: percent, forward: generation,
                                                                  completion: done)
        case .text(let link): openTextLink(link, forward: generation, completion: done)
        case .document(let url, _, let percent): openDocumentLink(url, session: id, sizePercent: percent, forward: generation,
                                                                  completion: done)
        case .reveal, .ignore, .browser, .overlay, .forwardRemote:
            refuseForwardedClick(.notAPage, session: id, generation: generation)
        }
    }

    private func refuseForwardedClick(_ reason: RemoteLinkRefusal, session id: UUID, generation: Int) {
        guard forwardIsCurrent(generation, session: id) else { return }
        presentationHub.sendToPresenter(.linkRefused(PresentationLinkRefusal(reason: reason)), session: id)
    }
}
