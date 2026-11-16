import Foundation

/// OpenWorkLocal is what the host knows about showing a session's work here: the window modal slot of the window
/// holding the session, and whether a GUI ask anchored to the session could be seen in it now. A pick needs only the
/// slot, since the picker draws over a dashboard, a zoom and an unselected row.
public struct OpenWorkLocal {
    public let modal: @MainActor (Session) -> (controller: PickController, window: WindowInfo.ID)?
    public let showsGuiAsk: @MainActor (Session) -> Bool

    public init(modal: @escaping @MainActor (Session) -> (controller: PickController, window: WindowInfo.ID)?,
                showsGuiAsk: @escaping @MainActor (Session) -> Bool) {
        self.modal = modal
        self.showsGuiAsk = showsGuiAsk
    }
}

/// OpenWorkMoves is what a placement pass did that its host follows up.
public struct OpenWorkMoves: Equatable, Sendable {
    /// offered is whether a page or job was offered, whose claim expiry the host then schedules.
    public var offered = false

    public init(offered: Bool = false) { self.offered = offered }
}

/// Where a piece of open work belongs while its holder is connected.
private enum WorkPlace: Equatable {
    case viewer(Int)
    case origin
}

// MARK: - Open work following the pane lead, on the origin

extension AppStore {
    /// reconcileOpenWork moves `id`'s open ask, pick and pages to where they belong now: the viewer newest leading the
    /// pane they are for, or this Mac when its own pane leads. Work whose viewer was lost goes where new work would,
    /// and on a Mac with no viewer to take it, here. `local` is the host's window for work coming here; nil headless.
    @discardableResult
    public func reconcileOpenWork(forSession id: UUID, now: Date = Date(), local: OpenWorkLocal? = nil) -> OpenWorkMoves {
        var moves = OpenWorkMoves()
        guard presentationHub != nil, let session = session(withID: id) else { return moves }
        placeSessionAsk(session, local: local)
        placeWindowAsk(session, local: local)
        placePick(session, local: local)
        moves.offered = placePages(session, now: now)
        if headless { moves.offered = offerPendingInteractions(forSession: id, now: now) || moves.offered }
        return moves
    }

    /// remotePageLost handles page `page` whose connection to the viewer showing it broke with nobody closing it. When
    /// that viewer reported it loaded under its current offer, the page is withdrawn and the place it belongs takes it
    /// again, the same viewer included; that evidence is spent, so a retried page that breaks again before it reports
    /// loaded ends. False when neither applies, a viewer without offers included, and the host's own handling stands.
    @discardableResult
    public func remotePageLost(_ page: UUID) -> Bool {
        let job = page.uuidString
        guard let session = workspaces.flatMap(\.sessions).first(where: { $0.remoteOverlays.slot(job: job)?.page != nil }),
              let held = session.remoteOverlays.slot(job: job)?.page, let offer = held.offer else { return false }
        guard held.loadedOffer == offer else {
            guard held.retried else { return false }
            endRemotePage(job, in: session)
            return true
        }
        session.remoteOverlays.updatePage(job) { page in
            page.loadedOffer = nil
            page.retried = true
        }
        withdrawRemotePage(page)
        presentationHub?.scheduleOpenWork(session.id)
        return true
    }

    private func place(_ session: Session, pane: UUID?) -> WorkPlace? {
        guard let hub = presentationHub else { return nil }
        let pane = pane ?? session.paneIdentity
        if !headless {
            switch ZmxLeadBook.shared.role(pane: pane) {
            case .leader?: return .origin
            case .follower?: break
            default: return nil
            }
        }
        guard let claimant = hub.leadClaimant(session: session.id, pane: pane), takesHeldWork(claimant) else { return nil }
        return .viewer(claimant)
    }

    private func connected(_ owner: Int) -> Bool { presentationHub?.isConnected(owner: owner) == true }

    // a Mac origin moves a shown GUI ask or pick only to a viewer that holds what it cannot show yet: an older one refuses,
    // and the refused piece can end cancelled. A headless origin keeps moving to any viewer, whose refusal returns it to pending
    private func takesWorkFromHolder(_ owner: Int) -> Bool {
        headless || presentationHub?.supports(PresentationHub.offerIdentityKind, owner: owner) == true
    }

    // MARK: asks

    private func placeSessionAsk(_ session: Session, local: OpenWorkLocal?) {
        guard let ask = session.askPending, !session.askReplica else { return }
        let pane = session.askPaneIdentity
        guard let owner = session.askRemoteOwner else {
            if !headless, case .viewer(let next)? = place(session, pane: pane) { offerAsk(forSession: session.id, to: next) }
            return
        }
        if connected(owner) {
            switch place(session, pane: pane) {
            case .viewer(let next)? where next != owner && (ask.style != .gui || takesWorkFromHolder(next)):
                moveRemoteAsk(forSession: session.id, to: next)
            case .origin?: bringAskHome(session, gui: ask.style == .gui, local: local)
            default: break
            }
            return
        }
        // a headless origin returned it to pending when the viewer was lost
        guard !headless else { return }
        if let next = pendingRecipient(session, paneIdentity: pane), moveRemoteAsk(forSession: session.id, to: next) { return }
        takeLostAskHome(session, owner: owner, local: local)
    }

    private func bringAskHome(_ session: Session, gui: Bool, local: OpenWorkLocal?) {
        guard gui else {
            takeTerminalAskHome(forSession: session.id)
            return
        }
        guard let local, local.showsGuiAsk(session), let target = local.modal(session) else { return }
        _ = moveGuiAskHome(forSession: session.id, into: target.controller, window: target.window)
    }

    // the ask of a lost viewer nobody else can take: a terminal ask is drawn here, a GUI ask opens in its window when
    // it can be seen there, and otherwise ends rather than wait where nothing draws it
    private func takeLostAskHome(_ session: Session, owner: Int, local: OpenWorkLocal?) {
        guard let ask = takeBackRemoteAsk(forSession: session.id, owner: owner) else { return }
        let anchor = AskAnchor(sessionID: session.id, pane: session.askTargetPane, paneIdentity: session.askPaneIdentity)
        guard let local, local.showsGuiAsk(session), let target = local.modal(session),
              target.controller.openAsk(ask.anchored(at: anchor)) else { return failHandback(forSession: session.id) }
        session.releaseAsk()
        askRegistry.reassign(id: ask.id, to: .window(target.window))
    }

    // a GUI ask shown in the session's window here, anchored to it, follows once the session's own ask slot is free
    private func placeWindowAsk(_ session: Session, local: OpenWorkLocal?) {
        guard !headless, session.askPending == nil, let target = local?.modal(session),
              let shown = target.controller.pendingAsk, shown.anchor?.sessionID == session.id,
              case .viewer(let next)? = place(session, pane: shown.anchor?.paneIdentity), takesWorkFromHolder(next) else { return }
        _ = handGuiAskToViewer(target.controller, window: target.window, forSession: session.id, to: next)
    }

    // MARK: picks

    private func placePick(_ session: Session, local: OpenWorkLocal?) {
        let book = SessionPickBook.shared
        switch book.placement(forSession: session.id) {
        case .presenter(let owner)? where connected(owner):
            switch place(session, pane: nil) {
            case .viewer(let next)? where next != owner && takesWorkFromHolder(next): movePick(forSession: session.id, to: next)
            case .origin?:
                guard let target = local?.modal(session), let id = book.pickID(forSession: session.id) else { return }
                if book.moveHome(session: session.id, owner: owner, to: target.controller, window: target.window) { noteGivenUp(id, by: owner) }
            default: break
            }
        case .presenter(let owner)?:
            // a headless origin returned it to pending when the viewer was lost
            guard !headless else { return }
            if let next = pendingRecipient(session, paneIdentity: nil), movePick(forSession: session.id, to: next) { return }
            let target = local?.modal(session)
            book.handBack(session: session.id, owner: owner, to: target?.controller, window: target?.window)
        case .local?:
            if case .viewer(let next)? = place(session, pane: nil), takesWorkFromHolder(next) { movePick(forSession: session.id, to: next) }
        case .unpresented?, nil:
            break
        }
    }

    // MARK: pages

    private func placePages(_ session: Session, now: Date) -> Bool {
        var offered = false
        for slot in session.remoteOverlays.slots {
            guard let page = slot.page else { continue }
            let id = page.overlay.id
            guard let owner = slot.owner else {
                // headless, a page nobody holds waits for the pending offer
                guard !headless else { continue }
                if offerPendingPage(slot, in: session, now: now) {
                    session.remoteOverlays.updatePage(slot.job) { $0.recovered = true }
                    offered = true
                } else if !mountRemotePageHere(id, forSession: session.id) {
                    endRemotePage(slot.job, in: session)
                }
                continue
            }
            guard connected(owner) else { continue }
            let wanted = place(session, pane: page.request?.pane?.identity)
            keepCandidate(id, in: session, onlyFor: wanted, holder: owner)
            switch wanted {
            case .viewer(let next)? where next != owner:
                offered = offerPageCandidate(id, forSession: session.id, to: next, now: now) || offered
            case .origin?:
                mountRemotePageHere(id, forSession: session.id)
            default:
                break
            }
        }
        guard !headless, session.content != .page else { return offered }
        for (pane, overlay) in localPages(session) {
            let identity = pane.map { $0 == .right ? session.splitPaneIdentity : session.paneIdentity } ?? session.paneIdentity
            let wanted = place(session, pane: identity)
            keepCandidate(overlay.id, in: session, onlyFor: wanted, holder: nil)
            guard case .viewer(let next)? = wanted else { continue }
            offered = offerPageCandidate(overlay.id, forSession: session.id, to: next, now: now) || offered
        }
        return offered
    }

    // a pending move to a viewer that is no longer where the page belongs is dropped before any new offer is tried,
    // so a refused new offer cannot leave the old one free to confirm
    private func keepCandidate(_ page: UUID, in session: Session, onlyFor wanted: WorkPlace?, holder: Int?) {
        guard let candidate = session.remoteOverlays.candidate(job: page.uuidString) else { return }
        if case .viewer(let next)? = wanted, next == candidate.owner, next != holder { return }
        discardPageCandidate(page)
    }

    private func localPages(_ session: Session) -> [(OverlayPane?, HtmlOverlay)] {
        var pages: [(OverlayPane?, HtmlOverlay)] = []
        if session.htmlOverlayActive, let overlay = session.htmlOverlay, overlay.replicaOf == nil { pages.append((nil, overlay)) }
        for pane in OverlayPane.allCases {
            if let overlay = session.paneOverlay(pane)?.html, overlay.replicaOf == nil { pages.append((pane, overlay)) }
        }
        return pages
    }
}
