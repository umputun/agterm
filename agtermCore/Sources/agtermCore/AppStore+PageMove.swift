import Foundation

// MARK: - Pages moving between this Mac and the viewers presenting a session, on the origin

extension AppStore {
    /// offerPageCandidate offers page `page` of session `id`, shown here or by another viewer, to viewer `owner` it
    /// moves to. The page stays where it is shown until that viewer confirms the offer. False when that viewer cannot
    /// show it, the page is a page row's own, or it is already offered there.
    @discardableResult
    public func offerPageCandidate(_ page: UUID, forSession id: UUID, to owner: Int, now: Date = Date()) -> Bool {
        let job = page.uuidString
        guard let hub = presentationHub, let session = session(withID: id), session.content != .page, takesHeldWork(owner),
              session.remoteOverlays.candidate(job: job)?.owner != owner,
              let offered = candidateOffer(job, in: session, to: owner, now: now),
              offered.request.markdownLinks == nil || hub.supports(PresentationHub.pageLinksKind, owner: owner),
              (try? PresentationCodec.encode(PresentationFrame(gen: .max, rev: .max, body: .pageRequest(offered.request)))) != nil
        else { return false }
        var candidate = offered.candidate, request = offered.request
        let merged = offered.merged
        dropPageCandidate(job, in: session)
        request.offer = candidate.offer
        var commands: [PresentationPageCommand] = []
        if !merged.isEmpty {
            let seq = nextCandidateSeq(&candidate, job: job, in: session)
            commands.append(PresentationPageCommand(page: job, seq: seq, action: .resize, sizePercent: request.sizePercent,
                                                    points: presentablePoints(merged, owner: owner), merge: true))
        }
        if offered.hidden { commands.append(PresentationPageCommand(page: job, seq: nextCandidateSeq(&candidate, job: job, in: session), action: .hide)) }
        session.remoteOverlays.setCandidate(candidate, job: job)
        hub.send(.pageRequest(request), toOwner: owner)
        for command in commands { hub.send(.pageCommand(command), toOwner: owner) }
        return true
    }

    /// candidateOffer builds the offer of page `job` to viewer `owner` from where it is shown now: a viewer's slot, or a
    /// slot here, which the offer carries as the slot the page takes once the move is confirmed.
    private func candidateOffer(_ job: String, in session: Session, to owner: Int, now: Date) -> CandidateOffer? {
        guard let hub = presentationHub else { return nil }
        let token = UUID().uuidString
        let deadline = now.addingTimeInterval(Self.pageClaimWindow)
        if let slot = session.remoteOverlays.slot(job: job), let held = slot.page, var request = held.request {
            guard slot.owner != owner, presenterShows(request.source, log: request.textLog != nil, owner: owner) else { return nil }
            let merged = reoffer(&request, from: slot, token: token, owner: owner)
            let candidate = PageCandidate(owner: owner, token: token, offer: hub.newOffer(toOwner: owner), claimDeadline: deadline)
            return CandidateOffer(candidate: candidate, request: request, merged: merged, hidden: held.effectiveHidden)
        }
        guard let local = localPage(job, in: session), let source = Self.handedSource(local.overlay, imagePixels: local.overlay.imagePixels),
              presenterShows(source, log: local.overlay.textLog != nil, owner: owner) else { return nil }
        let identity = local.pane.map { $0 == .right ? session.splitPaneIdentity : session.paneIdentity } ?? nil
        var request = Self.pageRequest(local.overlay, source: source, token: token, backgroundColor: local.backgroundColor,
                                       pane: identity, sizePercent: local.sizePercent,
                                       points: presentablePoints(local.points, owner: owner))
        request.textSeed = Self.textState(local.overlay)
        var page = RemotePage(overlay: local.overlay, token: token, claimDeadline: deadline)
        page.request = request
        page.hidden = local.hidden
        var arriving = RemoteOverlaySlot(job: job, pane: local.pane, owner: owner, sizePercent: local.sizePercent, page: page)
        arriving.points = local.points
        let offer = hub.newOffer(toOwner: owner)
        arriving.page?.offer = offer
        return CandidateOffer(candidate: PageCandidate(owner: owner, token: token, offer: offer, claimDeadline: deadline, arriving: arriving),
                              request: request, merged: OverlayPointSize(), hidden: local.hidden)
    }

    /// nextCandidateSeq numbers a command sent with an offer in the sequence the page keeps once it moves.
    private func nextCandidateSeq(_ candidate: inout PageCandidate, job: String, in session: Session) -> Int {
        if candidate.arriving != nil { return candidate.arriving?.page?.nextSeq() ?? 0 }
        var seq = 0
        session.remoteOverlays.updatePage(job) { seq = $0.nextSeq() }
        return seq
    }

    /// pageCandidateClaimed is whether `token` is the claimed offer of page `page` to a viewer still connected.
    public func pageCandidateClaimed(_ page: UUID, token: String) -> Bool {
        guard let (_, candidate) = candidateHolder(page) else { return false }
        return candidate.token == token && candidate.claimed && presentationHub?.isConnected(owner: candidate.owner) == true
    }

    /// commitPageCandidate confirms the offer of page `page` claimed under `token`: the viewer it was offered to now
    /// holds it. It sends nothing; `finishPageMove` tells the previous holder once the new channel is in place.
    public func commitPageCandidate(_ page: UUID, token: String) -> PageMove? {
        guard let (session, candidate) = candidateHolder(page), candidate.token == token else { return nil }
        return commit(candidate, job: page.uuidString, in: session, claimed: true)
    }

    /// finishPageMove tells the viewer that showed a moved page before to take its copy down; tagged, so its reply is not
    /// read as a dismissal.
    public func finishPageMove(_ move: PageMove) {
        guard let previous = move.previous, session(withID: move.session) != nil else { return }
        presentationHub?.send(.pageClose(PresentationPageChange(page: move.page.uuidString, reason: PresentationPageChange.channelLost)),
                              toOwner: previous)
    }

    /// failPageCandidate drops the offer of page `page` made under `token`, whose claim reply never reached its viewer;
    /// false when `token` names no offer, and the page's own claim is then the caller's.
    public func failPageCandidate(_ page: UUID, token: String) -> Bool {
        guard let (session, candidate) = candidateHolder(page), candidate.token == token else { return false }
        dropPageCandidate(page.uuidString, in: session)
        return true
    }

    /// discardPageCandidate drops the offer of page `page` to the viewer it was moving to, whose copy is taken down; the
    /// page stays where it is shown.
    public func discardPageCandidate(_ page: UUID) {
        guard let (session, _) = candidateHolder(page) else { return }
        dropPageCandidate(page.uuidString, in: session)
    }

    func dropPageCandidate(_ job: String, in session: Session) {
        guard let candidate = session.remoteOverlays.candidate(job: job) else { return }
        session.remoteOverlays.setCandidate(nil, job: job)
        guard presentationHub?.isConnected(owner: candidate.owner) == true else { return }
        presentationHub?.send(.pageClose(PresentationPageChange(page: job, reason: PresentationPageChange.channelLost)),
                              toOwner: candidate.owner)
    }

    /// receiveCandidateFrame applies what the viewer a page is offered to reported about that offer, true when the frame
    /// was about it: its first report confirms a URL page, and its refusal or close drops the offer.
    func receiveCandidateFrame(_ body: PresentationFrame.Body, in session: Session, from sender: Int) -> Bool {
        switch body {
        case .pageState(let state):
            guard let candidate = session.remoteOverlays.candidate(job: state.page), candidate.owner == sender,
                  candidate.offer == state.offer else { return false }
            guard pageSourceKind(state.page, in: session) == .url,
                  let move = commit(candidate, job: state.page, in: session, claimed: false) else { return true }
            finishPageMove(move)
            return false
        case .pageRejected(let change), .pageClosed(let change):
            guard let candidate = session.remoteOverlays.candidate(job: change.page), candidate.owner == sender,
                  candidate.offer == change.offer else { return false }
            session.remoteOverlays.setCandidate(nil, job: change.page)
            return true
        default:
            return false
        }
    }

    /// expirePageCandidates drops every offer of a channel page whose channel was not claimed in time.
    func expirePageCandidates(in session: Session, now: Date) {
        for (job, candidate) in session.remoteOverlays.candidates where !candidate.claimed && now > candidate.claimDeadline {
            guard pageSourceKind(job, in: session) != .url else { continue }
            dropPageCandidate(job, in: session)
        }
    }

    /// forgetPageCandidates drops the offers made to viewer `owner`, which is gone.
    func forgetPageCandidates(of owner: Int, in session: Session) {
        for (job, candidate) in session.remoteOverlays.candidates where candidate.owner == owner {
            session.remoteOverlays.setCandidate(nil, job: job)
        }
    }

    /// claimPageCandidate admits the offer `token` names: unclaimed, inside its deadline and offered to a viewer still
    /// connected. The page's current presentation is left as it is.
    func claimPageCandidate(token: String, in session: Session, now: Date) -> RemotePageClaim? {
        guard let (job, candidate) = session.remoteOverlays.candidates.first(where: { $0.value.token == token }),
              !candidate.claimed, now <= candidate.claimDeadline, presentationHub?.isConnected(owner: candidate.owner) == true,
              let place = candidate.arriving.map({ ($0.pane, $0.page?.overlay) }) ?? session.remoteOverlays.slot(job: job).map({ ($0.pane, $0.page?.overlay) }),
              let overlay = place.1 else { return nil }
        var claimed = candidate
        claimed.claimed = true
        session.remoteOverlays.setCandidate(claimed, job: job)
        return RemotePageClaim(sessionID: session.id, pane: place.0, overlay: overlay)
    }

    // MARK: - Pages coming back to this Mac

    /// mountRemotePageHere moves page `page` of session `id` from the viewer showing it into its slot here, its outcome
    /// still open, and the viewer takes its copy down. False on a headless origin, or when the slot here is taken or its
    /// pane is not shown, and the page stays with the viewer.
    @discardableResult
    public func mountRemotePageHere(_ page: UUID, forSession id: UUID) -> Bool {
        let job = page.uuidString
        guard !headless, let session = session(withID: id), let slot = session.remoteOverlays.slot(job: job), var held = slot.page,
              let previous = slot.owner, localSlotFree(slot.pane, in: session) else { return false }
        dropPageCandidate(job, in: session)
        session.remoteOverlays.remove(job: job)
        settleRemoteTextWaits(job: job)
        RemotePageEnds.shared.onWithdrawn?(page)
        held.overlay.loadState = .loading
        held.overlay.loadError = nil
        held.overlay.current = nil
        // a picture the viewer fitted itself floats here at the base percent its slot records, keeping its point overrides
        guard placeHtmlOverlay(held.overlay, in: session, pane: slot.pane, sizePercent: slot.sizePercent, points: slot.points,
                               backgroundColor: held.request?.backgroundColor) == nil else { return false }
        if held.effectiveHidden { session.setOverlayHidden(true, slot: slot.pane) }
        presentationHub?.send(.pageClose(PresentationPageChange(page: job, reason: PresentationPageChange.channelLost)), toOwner: previous)
        return true
    }

    private func localSlotFree(_ pane: OverlayPane?, in session: Session) -> Bool {
        guard let pane else { return !session.overlayActive || session.hudActive }
        return session.paneOverlay(pane) == nil && session.rendersPane(pane)
    }

    // MARK: - Shared

    private func commit(_ candidate: PageCandidate, job: String, in session: Session, claimed: Bool) -> PageMove? {
        guard let page = UUID(uuidString: job) else { return nil }
        session.remoteOverlays.setCandidate(nil, job: job)
        if var arriving = candidate.arriving {
            guard takeLocalPage(job, in: session) else { return nil }
            arriving.page?.claimed = claimed
            session.remoteOverlays.reserve(arriving)
            scheduleTreeChanged()
            return PageMove(page: page, session: session.id, previous: nil)
        }
        guard let slot = session.remoteOverlays.slot(job: job), slot.page != nil else { return nil }
        session.remoteOverlays.update(job: job) { $0.owner = candidate.owner }
        session.remoteOverlays.updatePage(job) { held in
            held.token = candidate.token
            held.offer = candidate.offer
            held.claimDeadline = candidate.claimDeadline
            held.claimed = claimed
            held.withdrawnFrom = nil
        }
        settleRemoteTextWaits(job: job)
        scheduleTreeChanged()
        return PageMove(page: page, session: session.id, previous: slot.owner)
    }

    private func candidateHolder(_ page: UUID) -> (Session, PageCandidate)? {
        for session in workspaces.flatMap(\.sessions) {
            if let candidate = session.remoteOverlays.candidate(job: page.uuidString) { return (session, candidate) }
        }
        return nil
    }

    private func pageSourceKind(_ job: String, in session: Session) -> HtmlPageKind? {
        session.remoteOverlays.candidate(job: job)?.arriving?.page?.overlay.source.kind
            ?? session.remoteOverlays.slot(job: job)?.page?.overlay.source.kind
    }

    /// localPage is page `job` as a slot here shows it, with what the slot keeps beside it.
    private func localPage(_ job: String, in session: Session) -> LocalPage? {
        if session.htmlOverlayActive, let overlay = session.htmlOverlay, overlay.id.uuidString == job {
            return LocalPage(overlay: overlay, pane: nil, sizePercent: session.overlaySizePercent, points: session.overlayPoints,
                             backgroundColor: session.overlayBackgroundColor, hidden: session.overlayHidden)
        }
        guard let pane = OverlayPane.allCases.first(where: { session.paneOverlay($0)?.html?.id.uuidString == job }),
              let slot = session.paneOverlay(pane), let overlay = slot.html else { return nil }
        return LocalPage(overlay: overlay, pane: pane, sizePercent: nil, points: OverlayPointSize(), backgroundColor: slot.backgroundColor,
                         hidden: slot.hidden)
    }

    /// takeLocalPage empties the slot here that shows page `job` without recording an outcome, for a page moving to a
    /// viewer.
    private func takeLocalPage(_ job: String, in session: Session) -> Bool {
        if session.htmlOverlayActive, let overlay = session.htmlOverlay, overlay.id.uuidString == job {
            session.htmlOverlay = nil
            HtmlOverlayReleases.shared.moved(overlay)
            closeOverlay(session.id)
            return true
        }
        guard let pane = OverlayPane.allCases.first(where: { session.paneOverlay($0)?.html?.id.uuidString == job }),
              var slot = session.paneOverlay(pane), let overlay = slot.html else { return false }
        slot.html = nil
        session.setPaneOverlay(slot, pane: pane)
        HtmlOverlayReleases.shared.moved(overlay)
        closePaneOverlay(session.id, pane: pane)
        return true
    }
}

/// CandidateOffer is an offer of a page to a viewer before it is sent: the pending move, the request, the point size
/// merged into it, and whether the page arrives hidden.
private struct CandidateOffer {
    var candidate: PageCandidate
    var request: PresentationPage
    var merged: OverlayPointSize
    var hidden: Bool
}

/// LocalPage is a page a slot here shows, with what the slot keeps beside it.
private struct LocalPage {
    let overlay: HtmlOverlay
    let pane: OverlayPane?
    let sizePercent: Int?
    let points: OverlayPointSize
    let backgroundColor: String?
    let hidden: Bool
}
