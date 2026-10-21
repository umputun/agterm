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
    /// loopback: a URL on this Mac's loopback names a server the presenter cannot reach.
    case loopback
    /// tooLarge: the request would not fit one presentation frame.
    case tooLarge
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
}

/// RemotePageClaim is a page channel the claim admitted: the session and slot the page sits in, and the page.
public struct RemotePageClaim: Equatable, Sendable {
    public let sessionID: UUID
    public let pane: OverlayPane?
    public let overlay: HtmlOverlay
}

// MARK: - Pages handed to the viewer presenting a session, on the origin

extension AppStore {
    /// pageClaimWindow bounds how long a handed-over file page waits for its channel to be claimed.
    public static let pageClaimWindow: TimeInterval = 30

    /// openRemotePage hands a page to the viewer presenting `sessionID` under the program overlay placement rule:
    /// it reserves the slot, registers the page's outcome as pending and asks the presenter to show it. Nothing
    /// is mounted here.
    public func openRemotePage(_ sessionID: UUID, overlay: HtmlOverlay, options: ControlSessionOverlayOpenOptions,
                               now: Date = Date()) -> RemotePageOpen {
        let pane = options.pane
        guard let hub = presentationHub, hub.hasPresenter(session: sessionID), let session = session(withID: sessionID),
              let source = Self.presentationSource(overlay.source) else { return .local }
        guard session.remoteOverlays.slot(pane) == nil, !localOverlayHolds(pane, in: session) else { return .slotTaken }
        let identity = pane.map { $0 == .right ? session.splitPaneIdentity : session.paneIdentity }
        if case .some(nil) = identity { return .paneMissing }
        guard session.followsRemotely(paneIdentity: identity.flatMap { $0 }) else { return .local }
        guard PresentationHub.pageKinds.allSatisfy({ hub.presenterSupports($0, session: sessionID) }) else { return .unsupported }
        if case .url(let url) = overlay.source, HtmlSource.isLoopback(url.absoluteString) { return .loopback }
        let token = UUID().uuidString
        let size = pane == nil ? options.sizePercent.map { min(100, max(1, $0)) } : nil
        let request = PresentationPage(
            page: overlay.id.uuidString, token: token, source: source, identity: overlay.identity,
            chromeless: overlay.chromeless, javascript: overlay.javascript, navigation: overlay.navigation,
            browse: overlay.browse, persistent: overlay.persistent, backgroundColor: options.backgroundColor,
            pane: identity.flatMap { $0 }.map { .identity($0) }, sizePercent: size, follow: options.follow)
        // a frame over the cap fails the offer, and the hub then drops the presenter with every page it shows
        guard (try? PresentationCodec.encode(PresentationFrame(gen: .max, rev: .max, body: .pageRequest(request)))) != nil
        else { return .tooLarge }
        if pane == nil, session.hudActive { closeHud(sessionID) }
        let page = RemotePage(overlay: overlay, token: token, claimDeadline: now.addingTimeInterval(Self.pageClaimWindow))
        session.remoteOverlays.reserve(RemoteOverlaySlot(job: overlay.id.uuidString, pane: pane,
                                                         owner: hub.presenterGeneration(session: sessionID),
                                                         sizePercent: size, page: page))
        clearOverlayExitCode(pane, in: session)
        HtmlPageOutcomes.shared.register(overlay.id)
        scheduleTreeChanged()
        hub.sendToPresenter(.pageRequest(request), session: sessionID)
        return .opened
    }

    /// receiveRemotePageFrame applies what the presenter of `sessionID` reported about one of its pages.
    public func receiveRemotePageFrame(_ body: PresentationFrame.Body, forSession sessionID: UUID) {
        guard let session = session(withID: sessionID) else { return }
        switch body {
        case .pageState(let state):
            var changed = false
            session.remoteOverlays.updatePage(state.page) { changed = $0.apply(state) }
            if changed { scheduleTreeChanged() }
        case .pageRejected(let change), .pageClosed(let change):
            endRemotePage(change.page, in: session)
        default:
            break
        }
    }

    /// claimRemotePage admits the page channel `token` names: unclaimed, inside its deadline, and still held by
    /// the presenter it was handed to. A token claims once.
    public func claimRemotePage(token: String, now: Date = Date()) -> RemotePageClaim? {
        for session in workspaces.flatMap(\.sessions) {
            guard let slot = session.remoteOverlays.slots.first(where: { $0.page?.token == token }),
                  let page = slot.page, !page.claimed, now <= page.claimDeadline,
                  presentationHub?.hasPresenter(session: session.id) == true,
                  presentationHub?.presenterGeneration(session: session.id) == slot.owner else { continue }
            session.remoteOverlays.updatePage(slot.job) { $0.claimed = true }
            return RemotePageClaim(sessionID: session.id, pane: slot.pane, overlay: page.overlay)
        }
        return nil
    }

    /// expireRemotePageClaims ends every file page whose channel was not claimed in time; a URL page loads on
    /// the presenter with no channel and never expires.
    public func expireRemotePageClaims(now: Date = Date()) {
        for session in workspaces.flatMap(\.sessions) {
            for slot in session.remoteOverlays.slots {
                guard let page = slot.page, !page.claimed, now > page.claimDeadline,
                      case .file = page.overlay.source else { continue }
                closeRemoteOverlay(session.id, pane: slot.pane)
            }
        }
    }

    /// sendRemotePageCommand asks the presenter to act on the page in `pane`'s slot; false when no remote page
    /// sits there or the stream it was handed to is gone.
    @discardableResult
    public func sendRemotePageCommand(_ sessionID: UUID, pane: OverlayPane?, action: PresentationPageAction,
                                      sizePercent: Int? = nil) -> Bool {
        guard let session = session(withID: sessionID), let slot = session.remoteOverlays.slot(pane), slot.page != nil,
              let hub = presentationHub, hub.presenterGeneration(session: sessionID) == slot.owner else { return false }
        var seq = 0
        session.remoteOverlays.updatePage(slot.job) { page in
            switch action {
            case .hide: seq = page.request(hidden: true)
            case .show: seq = page.request(hidden: false)
            default: seq = page.nextSeq()
            }
        }
        return hub.sendToPresenter(.pageCommand(PresentationPageCommand(page: slot.job, seq: seq, action: action,
                                                                        sizePercent: sizePercent)), session: sessionID)
    }

    /// navigateRemotePage runs a toolbar navigation on the page in `pane`'s slot when the presenting Mac shows it.
    public func navigateRemotePage(_ sessionID: UUID, pane: OverlayPane?, navigation: HtmlNavigation) -> RemotePageCommand {
        guard let page = session(withID: sessionID)?.remoteOverlays.slot(pane)?.page else { return .local }
        let file: Bool
        if case .file = page.overlay.source { file = true } else { file = false }
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

    /// pageBelongsRemote says the placement rule hands a page in `pane`'s slot to the presenting Mac: a presenter
    /// exists and the target pane, or every pane for the session-wide slot, follows on this Mac.
    func pageBelongsRemote(_ session: Session, pane: OverlayPane?) -> Bool {
        guard presentationHub?.hasPresenter(session: session.id) == true else { return false }
        let identity = pane.map { $0 == .right ? session.splitPaneIdentity : session.paneIdentity }
        if case .some(nil) = identity { return false }
        return session.followsRemotely(paneIdentity: identity.flatMap { $0 })
    }

    /// endRemotePage drops the page's reservation and records it dismissed unless it was already answered.
    func endRemotePage(_ job: String, in session: Session) {
        guard let slot = session.remoteOverlays.slot(job: job), let page = slot.page else { return }
        session.remoteOverlays.remove(job: job)
        HtmlPageOutcomes.shared.dismiss(page.overlay.id)
        scheduleTreeChanged()
        RemotePageEnds.shared.onEnd?(page.overlay.id)
    }

    /// remotePageNodes pairs each remote page of `session` with its slot, nil standing for the session-wide one.
    func remotePageNodes(_ session: Session) -> [(pane: OverlayPane?, page: RemotePage)] {
        session.remoteOverlays.slots.compactMap { slot in slot.page.map { (slot.pane, $0) } }
    }

    private static func presentationSource(_ source: HtmlSource) -> PresentationPageSource? {
        switch source {
        case .file(let path, let grantRoot): return .file(path: path, grantRoot: grantRoot)
        case .url(let url): return .url(url.absoluteString)
        case .replica: return nil
        }
    }
}
