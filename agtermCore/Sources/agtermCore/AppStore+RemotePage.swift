import Foundation

/// RemotePageOpen is what `openRemotePage` did with a page.
public enum RemotePageOpen: Equatable, Sendable {
    /// local: no presenter, or the placement rule keeps the page on this Mac.
    case local
    /// slotTaken: the slot holds an overlay, local or remote.
    case slotTaken
    /// paneMissing: the origin has no pane in the requested role.
    case paneMissing
    /// unsupported: the presenter cannot show pages, so the page is refused.
    case unsupported
    /// loopback: a URL on the origin's loopback names a server the connected presenter cannot forward to.
    case loopback
    /// tooLarge: the request would not fit one presentation frame.
    case tooLarge
    /// pointsUnsupported is never returned; it stays for agterm-linux, whose switches still name it.
    case pointsUnsupported
    case opened
}

/// RemotePageCommand is how a page command addressed to a slot ended: the slot holds no page shown on the
/// presenting Mac, the command was queued for that Mac (not proof it applied it), or it was refused.
public enum RemotePageCommand: Equatable, Sendable {
    case local
    case sent
    case refused(String)
}

/// RemotePageEnds carries the one signal the app's page channels need from the model: a page handed to the
/// presenting Mac ended, by close, rejection, presenter loss or session removal.
@MainActor
public final class RemotePageEnds {
    public static let shared = RemotePageEnds()
    public var onEnd: ((UUID) -> Void)?
    /// onWithdrawn retires the channel of a page a headless origin took back for the next presenter.
    public var onWithdrawn: ((UUID) -> Void)?
}

/// RemotePageClaim is a page channel the claim admitted: the session and slot the page sits in, and the page.
public struct RemotePageClaim: Equatable, Sendable {
    public let sessionID: UUID
    public let pane: OverlayPane?
    public let overlay: HtmlOverlay
}

// MARK: - Pages handed to the viewer presenting a session, on the origin

extension AppStore {
    /// pageClaimWindow bounds how long a handed-over page that fetches over a channel waits for it to be claimed.
    public static let pageClaimWindow: TimeInterval = 30

    /// openRemotePage hands a page to the viewer leading its pane under the program overlay placement rule, or for a
    /// forwarded click to the viewer that clicked: it reserves the slot, registers the page's outcome as pending and
    /// asks that viewer to show it. Nothing is mounted here.
    public func openRemotePage(_ sessionID: UUID, overlay: HtmlOverlay, options: ControlSessionOverlayOpenOptions,
                               now: Date = Date()) -> RemotePageOpen {
        let pane = options.pane
        // a headless origin holds the page for a viewer to come; a Mac shows it here
        guard let hub = presentationHub, hub.subscriberCount(session: sessionID) > 0 || headless,
              let session = session(withID: sessionID),
              let source = Self.handedSource(overlay, imagePixels: overlay.imagePixels ?? options.imagePixels)
        else { return .local }
        let replaces = options.forwarded && holdsHiddenClickedRemotePage(pane, in: session)
        guard session.remoteOverlays.slot(pane) == nil || replaces, !localOverlayHolds(pane, in: session) else { return .slotTaken }
        let identity = pane.map { $0 == .right ? session.splitPaneIdentity : session.paneIdentity }
        if case .some(nil) = identity { return .paneMissing }
        guard presentsRemotely(session, paneIdentity: identity.flatMap { $0 }) else { return .local }
        let recipient = options.forwardedTo ?? remoteRecipient(session, paneIdentity: identity.flatMap { $0 })
        if recipient == nil, !headless { return .local }
        let shows = recipient.map { presenterShows(source, log: overlay.textLog != nil, owner: $0) } ?? false
        if case .forwarded = source, recipient != nil, !shows { return .loopback }
        if !shows, !headless { return .unsupported }
        let token = UUID().uuidString
        let size = pane == nil ? options.sizePercent.map { min(100, max(1, $0)) } : nil
        let points = size == nil ? OverlayPointSize() : options.points
        let request = Self.pageRequest(overlay, source: source, token: token, backgroundColor: options.backgroundColor,
                                       pane: identity.flatMap { $0 }, sizePercent: size,
                                       points: recipient.map { presentablePoints(points, owner: $0) } ?? OverlayPointSize(),
                                       follow: options.follow)
        // a frame over the cap fails the offer, and the hub then drops the presenter with every page it shows
        guard (try? PresentationCodec.encode(PresentationFrame(gen: .max, rev: .max, body: .pageRequest(request)))) != nil
        else { return .tooLarge }
        // last, so a refused open never costs the page it would replace
        if replaces { closeRemoteOverlay(sessionID, pane: pane) }
        if pane == nil, session.hudActive { closeHud(sessionID) }
        let page = RemotePage(overlay: overlay, token: token, claimDeadline: now.addingTimeInterval(Self.pageClaimWindow))
        // the presenter sizes an unsized picture itself as a floating panel at the base percent, so the slot records
        // that percent: the tree then reads it floating and a point resize has a percent to keep
        var reserved = size
        if case .image = source, pane == nil, size == nil { reserved = ImagePage.basePercent }
        var held = page
        held.request = request
        let owner = shows ? recipient : nil
        var slot = RemoteOverlaySlot(job: overlay.id.uuidString, pane: pane, owner: owner, sizePercent: reserved, page: held)
        slot.points = points
        slot.presenterSized = reserved != size
        session.remoteOverlays.reserve(slot)
        clearOverlayExitCode(pane, in: session)
        HtmlPageOutcomes.shared.register(overlay.id)
        scheduleTreeChanged()
        if let owner { sendPageRequest(request, job: slot.job, owner: owner, in: session) }
        return .opened
    }

    /// handedSource is how `overlay` travels to another Mac: a loopback URL is reached through that Mac's own forward to
    /// this host. Nil for a page that cannot be handed over.
    static func handedSource(_ overlay: HtmlOverlay, imagePixels: ImagePixels?) -> PresentationPageSource? {
        if case .url(let url) = overlay.source, HtmlSource.isLoopback(url.absoluteString) { return .forwarded(url.absoluteString) }
        return presentationSource(overlay.source, imagePixels: imagePixels)
    }

    static func pageRequest(_ overlay: HtmlOverlay, source: PresentationPageSource, token: String, backgroundColor: String? = nil,
                            pane: UUID? = nil, sizePercent: Int? = nil, points: OverlayPointSize = OverlayPointSize(),
                            follow: Bool = false) -> PresentationPage {
        PresentationPage(page: overlay.id.uuidString, token: token, source: source, identity: overlay.identity,
                         chromeless: overlay.chromeless, javascript: overlay.javascript, navigation: overlay.navigation,
                         browse: overlay.browse, persistent: overlay.persistent, backgroundColor: backgroundColor,
                         pane: pane.map { .identity($0) }, sizePercent: sizePercent, points: points, follow: follow,
                         markdownLinks: overlay.markdownLinks, textLog: overlay.textLog)
    }

    /// presenterShows is whether viewer `owner` speaks the page frames and, for a content page, its sources; a log page
    /// also needs live text pages, which an older viewer would show as a static page.
    func presenterShows(_ source: PresentationPageSource, log: Bool, owner: Int) -> Bool {
        guard let hub = presentationHub, PresentationHub.pageKinds.allSatisfy({ hub.supports($0, owner: owner) }) else { return false }
        if log, !hub.supports(PresentationHub.pageTextKind, owner: owner) { return false }
        if source.isContent, !hub.supports(PresentationHub.pageContentKind, owner: owner) { return false }
        if case .document = source { return hub.supports(PresentationHub.pageDocumentKind, owner: owner) }
        if case .forwarded = source { return hub.supports(PresentationHub.pageForwardKind, owner: owner) }
        return true
    }

    /// sendPageRequest offers `request` to viewer `owner` as that viewer can show it: one that predates links gets the
    /// page without its grant, and the record the claim serves from is set to match, so an older viewer is served as
    /// before links while the held request keeps the grant for the next offer.
    private func sendPageRequest(_ request: PresentationPage, job: String, owner: Int, in session: Session) {
        guard let hub = presentationHub else { return }
        var sent = request
        sent.offer = hub.newOffer(toOwner: owner)
        session.remoteOverlays.updatePage(job) { page in
            page.offer = sent.offer
            page.overlay.markdownLinks = request.markdownLinks
            page.overlay.navigation = request.navigation
            guard request.markdownLinks != nil, !hub.supports(PresentationHub.pageLinksKind, owner: owner) else { return }
            page.overlay = page.overlay.withoutLinks()
            sent.markdownLinks = nil
            sent.navigation = page.overlay.navigation
        }
        hub.send(.pageRequest(sent), toOwner: owner)
    }

    /// offerPendingPage hands the page a headless origin holds in `slot` to the viewer its pane routes to under a new
    /// token, restarting its claim window; false when nothing there waits or that viewer cannot show it.
    @discardableResult
    func offerPendingPage(_ slot: RemoteOverlaySlot, in session: Session, now: Date) -> Bool {
        guard slot.owner == nil, var request = slot.page?.request,
              let owner = pendingRecipient(session, paneIdentity: request.pane?.identity), mayHandOver(slot.job, to: owner),
              presenterShows(request.source, log: request.textLog != nil, owner: owner) else { return false }
        let merged = reoffer(&request, from: slot, token: UUID().uuidString, owner: owner)
        let hidden = slot.page?.effectiveHidden == true
        session.remoteOverlays.update(job: slot.job) { $0.owner = owner }
        session.remoteOverlays.updatePage(slot.job) { page in
            page.token = request.token
            page.claimDeadline = now.addingTimeInterval(Self.pageClaimWindow)
            page.claimed = false
            page.withdrawnFrom = nil
        }
        scheduleTreeChanged()
        sendPageRequest(request, job: slot.job, owner: owner, in: session)
        if !merged.isEmpty {
            sendRemotePageCommand(session.id, pane: slot.pane, action: .resize, sizePercent: slot.sizePercent,
                                  points: presentablePoints(merged, owner: owner), merge: true)
        }
        if hidden { sendRemotePageCommand(session.id, pane: slot.pane, action: .hide) }
        return true
    }

    /// reoffer readies `request` for viewer `owner` under `token` at what `slot` shows now: its size and points and a text
    /// page's state. It returns the point overrides a picture the presenter sizes takes as a merge resize after it.
    func reoffer(_ request: inout PresentationPage, from slot: RemoteOverlaySlot, token: String, owner: Int) -> OverlayPointSize {
        request.token = token
        request.textSeed = slot.page.flatMap { Self.textState($0.overlay) }
        // a picture the presenter sizes goes unsized, its point overrides following as the merge resize they were made by
        if !slot.presenterSized { request.sizePercent = slot.sizePercent }
        request.points = slot.presenterSized ? OverlayPointSize() : presentablePoints(slot.points, owner: owner)
        return slot.presenterSized ? slot.points : OverlayPointSize()
    }

    /// receiveRemotePageFrame applies what viewer `sender` reported about a page of `sessionID`; a report about a page
    /// it was not handed changes nothing.
    public func receiveRemotePageFrame(_ body: PresentationFrame.Body, forSession sessionID: UUID, from sender: Int) {
        guard let session = session(withID: sessionID), !receiveCandidateFrame(body, in: session, from: sender) else { return }
        switch body {
        case .pageState(let state):
            guard let slot = session.remoteOverlays.slot(job: state.page), slot.owner == sender, slot.page?.offer == state.offer
            else { return }
            var changed = false
            session.remoteOverlays.updatePage(state.page) { changed = $0.apply(state) }
            if changed { scheduleTreeChanged() }
        case .pageResult(let result):
            receiveRemoteTextResult(result, in: session, from: sender)
        case .pageRejected(let change), .pageClosed(let change):
            // only the offer holding the page reports its end; a copy this origin already withdrew says nothing, except
            // a dismissal its viewer sent before seeing the withdrawal, which the channel's end overtook
            guard let slot = session.remoteOverlays.slot(job: change.page), slot.page?.offer == change.offer,
                  slot.owner == sender || (slot.owner == nil && slot.page?.withdrawnFrom == sender
                      && change.reason != PresentationPageChange.channelLost) else { return }
            let lost = change.reason == PresentationPageChange.channelLost
            if lost, let page = UUID(uuidString: change.page), remotePageLost(page) { return }
            if headless, lost, let page = UUID(uuidString: change.page) {
                withdrawRemotePage(page)
            } else {
                endRemotePage(change.page, in: session)
            }
        default:
            break
        }
    }

    /// claimRemotePage admits the page channel `token` names: unclaimed, inside its deadline, and still held by
    /// the connected viewer it was handed to. A token claims once.
    public func claimRemotePage(token: String, now: Date = Date()) -> RemotePageClaim? {
        for session in workspaces.flatMap(\.sessions) {
            if let claim = claimPageCandidate(token: token, in: session, now: now) { return claim }
            guard let slot = session.remoteOverlays.slots.first(where: { $0.page?.token == token }),
                  let page = slot.page, !page.claimed, now <= page.claimDeadline,
                  let owner = slot.owner, presentationHub?.isConnected(owner: owner) == true else { continue }
            session.remoteOverlays.updatePage(slot.job) { $0.claimed = true }
            return RemotePageClaim(sessionID: session.id, pane: slot.pane, overlay: page.overlay)
        }
        return nil
    }

    /// expireRemotePageClaims ends every channel page whose channel was not claimed in time; a URL page loads on
    /// the presenter with no channel and never expires.
    public func expireRemotePageClaims(now: Date = Date()) {
        for session in workspaces.flatMap(\.sessions) {
            expirePageCandidates(in: session, now: now)
            for slot in session.remoteOverlays.slots {
                guard slot.owner != nil, let page = slot.page, !page.claimed, now > page.claimDeadline,
                      page.overlay.source.kind != .url else { continue }
                closeRemoteOverlay(session.id, pane: slot.pane)
            }
        }
    }

    /// sendRemotePageCommand asks the viewer showing the page in `pane`'s slot to act on it; false when no remote page
    /// sits there or the stream it was handed to is gone.
    @discardableResult
    public func sendRemotePageCommand(_ sessionID: UUID, pane: OverlayPane?, action: PresentationPageAction,
                                      sizePercent: Int? = nil, points: OverlayPointSize = OverlayPointSize(),
                                      merge: Bool? = nil) -> Bool {
        guard let session = session(withID: sessionID), let slot = session.remoteOverlays.slot(pane), slot.page != nil,
              let owner = slot.owner, let hub = presentationHub, hub.isConnected(owner: owner) else { return false }
        var seq = 0
        session.remoteOverlays.updatePage(slot.job) { page in
            switch action {
            case .hide: seq = page.request(hidden: true)
            case .show: seq = page.request(hidden: false)
            default: seq = page.nextSeq()
            }
        }
        return hub.send(.pageCommand(PresentationPageCommand(page: slot.job, seq: seq, action: action,
                                                             sizePercent: sizePercent, points: points, merge: merge)),
                        toOwner: owner)
    }

    /// navigateRemotePage runs a toolbar navigation on the page in `pane`'s slot when the presenting Mac shows it.
    public func navigateRemotePage(_ sessionID: UUID, pane: OverlayPane?, navigation: HtmlNavigation) -> RemotePageCommand {
        guard let page = session(withID: sessionID)?.remoteOverlays.slot(pane)?.page else { return .local }
        let file = page.overlay.source.kind != .url
        switch navigation {
        case .back: return deliverRemotePageCommand(sessionID, pane: pane, action: .back)
        case .forward: return deliverRemotePageCommand(sessionID, pane: pane, action: .forward)
        case .browser:
            return file ? .refused(OverlayHtmlError.remotePage) : deliverRemotePageCommand(sessionID, pane: pane, action: .browser)
        case .finder: return .refused(file ? OverlayHtmlError.remotePage : OverlayHtmlError.finderRequiresFile)
        }
    }

    /// reloadRemotePage asks the presenting Mac to reload the page in `pane`'s slot, its original source or what
    /// it shows now.
    public func reloadRemotePage(_ sessionID: UUID, pane: OverlayPane?, current: Bool) -> RemotePageCommand {
        guard session(withID: sessionID)?.remoteOverlays.slot(pane)?.page != nil else { return .local }
        return deliverRemotePageCommand(sessionID, pane: pane, action: current ? .reloadCurrent : .reloadOriginal)
    }

    private func deliverRemotePageCommand(_ sessionID: UUID, pane: OverlayPane?, action: PresentationPageAction) -> RemotePageCommand {
        sendRemotePageCommand(sessionID, pane: pane, action: action) ? .sent : .refused(OverlayResultError.viewerGone)
    }

    /// pageBelongsRemote says the placement rule hands a page in `pane`'s slot to an attached Mac: the target pane, or
    /// the primary pane for the session-wide slot, follows on this Mac and a viewer takes its work.
    func pageBelongsRemote(_ session: Session, pane: OverlayPane?) -> Bool {
        pageRecipient(session, pane: pane) != nil
    }

    /// pageRecipient is the token of the viewer a page in `pane`'s slot goes to, nil when it opens on this Mac.
    public func pageRecipient(_ session: Session, pane: OverlayPane?) -> Int? {
        let identity = pane.map { $0 == .right ? session.splitPaneIdentity : session.paneIdentity }
        if case .some(nil) = identity { return nil }
        return remoteRecipient(session, paneIdentity: identity.flatMap { $0 })
    }

    /// holdsHiddenClickedRemotePage says whether `pane`'s slot holds a clicked page the presenting Mac hides, the one
    /// occupant a forwarded click replaces.
    func holdsHiddenClickedRemotePage(_ pane: OverlayPane?, in session: Session) -> Bool {
        guard let page = session.remoteOverlays.slot(pane)?.page else { return false }
        return page.overlay.clicked && page.effectiveHidden
    }

    /// endRemotePage drops the page's reservation and records it dismissed unless it was already answered.
    func endRemotePage(_ job: String, in session: Session) {
        guard let slot = session.remoteOverlays.slot(job: job), let page = slot.page else { return }
        dropPageCandidate(job, in: session)
        session.remoteOverlays.remove(job: job)
        OfferlessHolders.shared.forget(job)
        settleRemoteTextWaits(job: job)
        HtmlPageOutcomes.shared.dismiss(page.overlay.id)
        scheduleTreeChanged()
        RemotePageEnds.shared.onEnd?(page.overlay.id)
    }

    /// remotePageNodes pairs each remote page of `session` with its slot, nil standing for the session-wide one.
    func remotePageNodes(_ session: Session) -> [(pane: OverlayPane?, page: RemotePage)] {
        session.remoteOverlays.slots.compactMap { slot in slot.page.map { (slot.pane, $0) } }
    }

    /// presentationSource is how `source` travels to another Mac; nil for a page that is itself a replica or
    /// is unreadable, and for an image whose probed size is not given.
    public static func presentationSource(_ source: HtmlSource, imagePixels: ImagePixels? = nil) -> PresentationPageSource? {
        switch source {
        case .file(let path, let grantRoot): return .file(path: path, grantRoot: grantRoot)
        case .url(let url): return .url(url.absoluteString)
        case .image(let path): return imagePixels.map { .image(path: path, width: $0.width, height: $0.height) }
        case .markdown(let path): return .markdown(path: path)
        case .text(let path, let line): return .text(path: path, line: line)
        case .document(let path): return .document(path: path)
        case .replica, .unreadable: return nil
        }
    }

    /// remotePageClaimToken is the token page `page` is offered under now, nil when this store holds no such page.
    public func remotePageClaimToken(_ page: UUID) -> String? {
        workspaces.flatMap(\.sessions).lazy.compactMap { $0.remoteOverlays.slot(job: page.uuidString)?.page?.token }.first
    }

    /// withdrawRemotePage takes page `page` back from the viewer showing it, which takes its copy down, and drops any
    /// pending move of it; the page, its outcome still open, waits for the next place to take it.
    public func withdrawRemotePage(_ page: UUID) {
        guard let session = workspaces.flatMap(\.sessions).first(where: { $0.remoteOverlays.slot(job: page.uuidString)?.page != nil }),
              let slot = session.remoteOverlays.slot(job: page.uuidString), let owner = slot.owner else { return }
        dropPageCandidate(slot.job, in: session)
        // tagged, so the viewer's reply to this close is not read as a dismissal
        presentationHub?.send(.pageClose(PresentationPageChange(page: slot.job, reason: PresentationPageChange.channelLost)),
                              toOwner: owner)
        session.remoteOverlays.update(job: slot.job) { $0.owner = nil }
        session.remoteOverlays.updatePage(slot.job) { page in
            page.claimed = false
            page.withdrawnFrom = slot.owner
        }
        settleRemoteTextWaits(job: slot.job)
        RemotePageEnds.shared.onWithdrawn?(page)
        scheduleTreeChanged()
    }

    /// pageBelongsRemote says the placement rule hands a page in `pane`'s slot of session `sessionID` to the
    /// presenting Mac, false for an unknown session.
    public func pageBelongsRemote(_ sessionID: UUID, pane: OverlayPane?) -> Bool {
        guard let session = session(withID: sessionID) else { return false }
        return pageBelongsRemote(session, pane: pane)
    }
}
