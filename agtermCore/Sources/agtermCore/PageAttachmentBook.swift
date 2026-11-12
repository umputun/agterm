import Foundation

/// PageAttachmentBook serves a host's page rows to the Macs that attach them. Each attachment has its own single-use
/// token and channel, and ending one ends nothing else: the page belongs to the host until it leaves its slot there,
/// which ends every channel serving it.
@MainActor
public final class PageAttachmentBook {
    /// Offer is one attachment handed out and not claimed yet.
    public struct Offer: Sendable {
        public let session: UUID
        public let page: UUID
        public let deadline: Date
    }

    /// Serving is the page row one claimed attachment serves.
    public struct Serving: Sendable {
        public let session: UUID
        public let page: UUID
    }

    /// offers are attachments handed out and not claimed yet, by token.
    public private(set) var offers: [String: Offer] = [:]
    /// claims are claimed attachments whose channel is not adopted yet, by claim id.
    public private(set) var claims: [UUID: Serving] = [:]
    /// streams are the live channels of attachments, by claim id.
    public private(set) var streams: [UUID: PageServeStream] = [:]

    private let clock: () -> Date
    private let servedPage: (_ session: UUID, _ page: UUID) -> HtmlOverlay?

    /// init takes the host's clock and its lookup of a page row still holding page `page`, nil once it is gone.
    public init(clock: @escaping () -> Date, servedPage: @escaping (_ session: UUID, _ page: UUID) -> HtmlOverlay?) {
        self.clock = clock
        self.servedPage = servedPage
    }

    /// offer answers `session.companion.page.attach` for `session`: a token for one `page-serve` claim, and the page.
    public func offer(_ session: Session) -> ControlResponse {
        guard session.content == .page, let overlay = session.htmlOverlay else {
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
        // a loopback address names the host's own server, which the other Mac would never reach
        if case .url(let url) = overlay.source, HtmlSource.isLoopback(url.absoluteString) {
            return ControlResponse(ok: false, error: "a page on this Mac's loopback cannot be shown on another Mac")
        }
        HtmlOverlayReleases.shared.onServedRelease = { [weak self] page in self?.end(page) }
        let now = clock()
        offers = offers.filter { $0.value.deadline >= now }
        let token = UUID().uuidString
        offers[token] = Offer(session: session.id, page: overlay.id, deadline: now.addingTimeInterval(AppStore.pageClaimWindow))
        let page = PresentationPage(
            page: overlay.id.uuidString, token: token, source: source, identity: overlay.identity,
            chromeless: overlay.chromeless, javascript: overlay.javascript, navigation: overlay.navigation,
            browse: overlay.browse, persistent: overlay.persistent, backgroundColor: session.overlayBackgroundColor,
            pane: nil, sizePercent: nil, follow: false)
        return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString, parent: session.parentID?.uuidString,
                                                               companionPage: page))
    }

    /// claim admits an offered token once, nil for a token that is not one.
    public func claim(_ token: String) -> ControlResponse? {
        guard let offer = offers.removeValue(forKey: token) else { return nil }
        guard clock() <= offer.deadline, servedPage(offer.session, offer.page) != nil else {
            return ControlResponse(ok: false, error: "page not claimable")
        }
        let claim = UUID()
        claims[claim] = Serving(session: offer.session, page: offer.page)
        return ControlResponse(ok: true, result: ControlResult(id: claim.uuidString))
    }

    /// adopt takes over a claimed attachment's connection, false for a claim that is not one; a page that closed
    /// meanwhile gets no channel.
    public func adopt(descriptor: Int32, claim: UUID, host: some PageServeHost) -> Bool {
        guard let serving = claims.removeValue(forKey: claim) else { return false }
        let attachment = PageServeStream.Attachment(claim: claim, session: serving.session)
        if let stream = PageServeStream.adopt(descriptor: descriptor, page: serving.page,
                                              source: servedPage(serving.session, serving.page)?.source,
                                              attachment: attachment, host: host) {
            streams[claim] = stream
        }
        return true
    }

    /// dropClaim forgets a claim whose connection never arrived, false for a claim that is not one.
    public func dropClaim(_ claim: UUID) -> Bool { claims.removeValue(forKey: claim) != nil }

    /// closed forgets the channel of an attachment that ended.
    public func closed(_ attachment: PageServeStream.Attachment) { streams[attachment.claim] = nil }

    /// serves is whether `attachment`'s page row still holds page `page`.
    public func serves(_ attachment: PageServeStream.Attachment, page: UUID) -> Bool {
        servedPage(attachment.session, page) != nil
    }

    /// end ends every attachment of `page`, which left its slot.
    public func end(_ page: UUID) {
        offers = offers.filter { $0.value.page != page }
        claims = claims.filter { $0.value.page != page }
        for stream in streams.values where stream.page == page { stream.shutdown() }
    }

    /// shutdown ends every attachment, for a host that stops serving while its pages stay saved.
    public func shutdown() {
        offers = [:]
        claims = [:]
        for stream in streams.values { stream.shutdown() }
    }
}
