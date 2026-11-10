import Foundation
import agtermCore

/// CompanionPageToken is one attachment of a page companion handed to another Mac and not claimed yet.
struct CompanionPageToken {
    let session: UUID
    let page: UUID
    let deadline: Date
}

/// CompanionPageServing is the page companion one claimed attachment serves; `claim` keys its channel.
struct CompanionPageServing {
    let claim: UUID
    let session: UUID
    let page: UUID
}

/// Serves this Mac's page companions to the Macs viewing their parents. Each attachment has its own single-use
/// token and channel, and ending one ends nothing else: the page belongs to this Mac until it closes here, which
/// ends every channel serving it.
extension ControlServer {
    /// attachCompanionPage answers `session.companion.page.attach`: a token for one `page-serve` claim, and the page.
    func attachCompanionPage(_ target: String?, window: String?) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id), session.content == .page, let overlay = session.htmlOverlay else {
                return ControlResponse(ok: false, error: "not a page session")
            }
            if case .unreadable = overlay.source {
                return ControlResponse(ok: false, error: "an unreadable saved page cannot be shown on another Mac")
            }
            guard let source = AppStore.presentationSource(overlay.source) else {
                return ControlResponse(ok: false, error: "not a page session")
            }
            if source.isContent {
                return ControlResponse(ok: false, error: "a markdown, text or document page cannot be shown on another Mac")
            }
            // a loopback address names this Mac's own server, which the other Mac would never reach
            if case .url(let url) = overlay.source, HtmlSource.isLoopback(url.absoluteString) {
                return ControlResponse(ok: false, error: "a page on this Mac's loopback cannot be shown on another Mac")
            }
            HtmlOverlayReleases.shared.onServedRelease = { [weak self] page in self?.endCompanionPageServing(page) }
            let now = hudClock()
            companionPageTokens = companionPageTokens.filter { $0.value.deadline >= now }
            let token = UUID().uuidString
            companionPageTokens[token] = CompanionPageToken(session: id, page: overlay.id,
                                                            deadline: now.addingTimeInterval(AppStore.pageClaimWindow))
            let page = PresentationPage(
                page: overlay.id.uuidString, token: token, source: source, identity: overlay.identity,
                chromeless: overlay.chromeless, javascript: overlay.javascript, navigation: overlay.navigation,
                browse: overlay.browse, persistent: overlay.persistent, backgroundColor: session.overlayBackgroundColor,
                pane: nil, sizePercent: nil, follow: false)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, parent: session.parentID?.uuidString,
                                                                   companionPage: page))
        }
    }

    /// claimCompanionPage admits a page companion's token once, nil for a token that is not one.
    func claimCompanionPage(_ token: String) -> ControlResponse? {
        guard let entry = companionPageTokens.removeValue(forKey: token) else { return nil }
        guard hudClock() <= entry.deadline, servedPage(session: entry.session, page: entry.page) != nil else {
            return ControlResponse(ok: false, error: "page not claimable")
        }
        let claim = UUID()
        pendingCompanionClaims[claim] = CompanionPageServing(claim: claim, session: entry.session, page: entry.page)
        return ControlResponse(ok: true, result: ControlResult(id: claim.uuidString))
    }

    /// adoptCompanionPageStream takes over a claimed attachment's connection; a page that closed meanwhile gets none.
    func adoptCompanionPageStream(descriptor: Int32, serving: CompanionPageServing) {
        let source = servedPage(session: serving.session, page: serving.page)?.source
        let attachment = PageServeStream.Attachment(claim: serving.claim, session: serving.session)
        guard let stream = PageServeStream.adopt(descriptor: descriptor, page: serving.page, source: source,
                                                 attachment: attachment, host: self) else { return }
        companionPageStreams[serving.claim] = stream
    }

    func claimPageAttachment(_ token: String) -> ControlResponse? { claimCompanionPage(token) }

    func adoptPageAttachment(descriptor: Int32, claim: UUID) -> Bool {
        guard let serving = pendingCompanionClaims.removeValue(forKey: claim) else { return false }
        adoptCompanionPageStream(descriptor: descriptor, serving: serving)
        return true
    }

    func dropPageAttachmentClaim(_ claim: UUID) -> Bool { pendingCompanionClaims.removeValue(forKey: claim) != nil }

    func pageAttachmentClosed(_ attachment: PageServeStream.Attachment) { companionPageStreams[attachment.claim] = nil }

    /// pageAttachmentPlace is where a served page companion sits now, nil once it is gone. A soft-closed page still
    /// serves: undo brings it back with its viewers attached.
    func pageAttachmentPlace(_ attachment: PageServeStream.Attachment, page: UUID) -> (session: UUID, pane: OverlayPane?, window: UUID?)? {
        guard servedPage(session: attachment.session, page: page) != nil else { return nil }
        // the holding store, pending close included, so a soft-closed page still answers for its own window
        return (attachment.session, nil, library.store(holdingSession: attachment.session).flatMap(library.windowID(for:)))
    }

    /// endCompanionPageServing ends every attachment of `page`, which left its slot here.
    func endCompanionPageServing(_ page: UUID) {
        companionPageTokens = companionPageTokens.filter { $0.value.page != page }
        pendingCompanionClaims = pendingCompanionClaims.filter { $0.value.page != page }
        for stream in companionPageStreams.values where stream.page == page { stream.shutdown() }
    }

    private func servedPage(session: UUID, page: UUID) -> HtmlOverlay? {
        guard let row = heldSession(session), row.content == .page, let overlay = row.htmlOverlay, overlay.id == page else {
            return nil
        }
        return overlay
    }
}
