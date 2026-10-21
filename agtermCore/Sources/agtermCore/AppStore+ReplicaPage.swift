import Foundation

// MARK: - Pages an origin handed to this Mac, on the viewer

extension AppStore {
    /// presentReplicaPage shows a page `id`'s origin handed over, in the mapped pane or the session-wide slot,
    /// under a page id of this Mac's own. Nil when shown, otherwise the reason it was not, which the caller
    /// reports to the origin as a refusal.
    public func presentReplicaPage(_ page: PresentationPage, forSession id: UUID) -> String? {
        guard let session = session(withID: id), session.remotePresentation != nil else { return "no such session" }
        guard let origin = UUID(uuidString: page.page) else { return "invalid page id" }
        let source: HtmlSource
        switch page.source {
        case .file(let path, _): source = .replica(path: path)
        case .url(let text):
            guard let url = HtmlSource.webURL(text) else { return "invalid url" }
            source = .url(url)
        }
        var pane: OverlayPane?
        if page.pane != nil {
            guard let role = localPane(page.pane, in: session), session.rendersPane(role) else {
                return PaneOverlayError.paneNotVisible
            }
            pane = role
        }
        let overlay = HtmlOverlay(source: source, navigation: page.navigation, javascript: page.javascript,
                                  chromeless: page.chromeless, persistent: page.persistent, browse: page.browse,
                                  replicaOf: origin)
        if let failure = openHtmlOverlay(id, pane: pane, overlay: overlay, sizePercent: page.sizePercent,
                                         backgroundColor: page.backgroundColor) {
            return failure.message(pane: pane)
        }
        if page.follow { selectSession(id) }
        return nil
    }

    /// replicaPage finds the page shown here for origin page `origin`, with the slot it sits in.
    public func replicaPage(_ origin: String, forSession id: UUID) -> (pane: OverlayPane?, page: HtmlOverlay)? {
        guard let session = session(withID: id), let origin = UUID(uuidString: origin) else { return nil }
        return session.replicaPages.first { $0.page.replicaOf == origin }
    }

    /// closeReplicaPage takes down the page shown for `origin`, once its origin closed it.
    public func closeReplicaPage(_ origin: String, forSession id: UUID) {
        guard let slot = replicaPage(origin, forSession: id) else { return }
        if let pane = slot.pane {
            closePaneOverlay(id, pane: pane)
        } else {
            closeOverlay(id)
        }
    }

    /// setReplicaPageHidden hides or shows only the slot holding the page for `origin`, never its neighbours.
    public func setReplicaPageHidden(_ origin: String, forSession id: UUID, hidden: Bool) {
        guard let session = session(withID: id), let slot = replicaPage(origin, forSession: id),
              session.overlayHidden(slot.pane) != hidden else { return }
        session.setOverlayHidden(hidden, slot: slot.pane)
        scheduleTreeChanged()
        onReplicaPageChanged?(slot.page.id)
    }

    /// resizeReplicaPage applies the origin's size to a session-wide page; a pane page is always full-pane.
    public func resizeReplicaPage(_ origin: String, forSession id: UUID, sizePercent: Int?) {
        guard let slot = replicaPage(origin, forSession: id), slot.pane == nil else { return }
        resizeOverlay(id, sizePercent: sizePercent)
    }

    /// replicaPageState is what the page `localID` shows now, as the origin reads it back, nil once it is gone.
    public func replicaPageState(_ localID: UUID, appliedSeq: Int) -> PresentationPageState? {
        guard let slot = htmlOverlaySlot(localID), let page = slot.pane.map({ slot.session.paneOverlay($0)?.html })
                ?? slot.session.htmlOverlay, let origin = page.replicaOf else { return nil }
        return PresentationPageState(page: origin.uuidString, title: page.current?.title, address: page.current?.page,
                                     load: page.loadState, error: page.loadError,
                                     canGoBack: page.current?.canGoBack ?? false,
                                     canGoForward: page.current?.canGoForward ?? false,
                                     hidden: slot.session.overlayHidden(slot.pane),
                                     appliedSeq: appliedSeq)
    }

    /// closeReplicaPages takes down every page `session` shows for its origin: with the stream gone the origin
    /// has ended them, and nothing could reach it from them.
    func closeReplicaPages(of session: Session) {
        for slot in session.replicaPages {
            if let pane = slot.pane {
                closePaneOverlay(session.id, pane: pane)
            } else {
                closeOverlay(session.id)
            }
        }
    }
}

extension Session {
    /// replicaPages are the pages in this session's slots shown for its origin, session-wide first.
    var replicaPages: [(pane: OverlayPane?, page: HtmlOverlay)] {
        let local: OverlayPane? = nil
        let slots = [(local, htmlOverlayActive ? htmlOverlay : nil)] + OverlayPane.allCases.map { ($0, paneOverlay($0)?.html) }
        return slots.compactMap { pane, page in page.flatMap { $0.replicaOf == nil ? nil : (pane, $0) } }
    }
}
