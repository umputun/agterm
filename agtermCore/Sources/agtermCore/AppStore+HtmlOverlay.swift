import Foundation

/// HtmlOverlayOpenFailure is why `AppStore.openHtmlOverlay` refused.
public enum HtmlOverlayOpenFailure: Equatable, Sendable {
    case unknownSession, alreadyOpen, paneNotVisible, presenter
}

/// HtmlOverlayCommandFailure is why a command addressing a page (`reload`, `navigate`) refused.
public enum HtmlOverlayCommandFailure: Error, Equatable, Sendable {
    case unknownSession, noOverlay, notHtml
}

extension HtmlOverlayOpenFailure {
    /// message is the control error for this refusal; `pane` picks the pane-overlay wording.
    public func message(pane: OverlayPane?) -> String {
        switch self {
        case .unknownSession: return "no such session"
        case .alreadyOpen: return pane == nil ? "overlay already open" : PaneOverlayError.alreadyOpen
        case .paneNotVisible: return PaneOverlayError.paneNotVisible
        case .presenter: return OverlayHtmlError.presenter
        }
    }
}

extension HtmlOverlayCommandFailure {
    /// message is the control error for this refusal.
    public var message: String {
        switch self {
        case .unknownSession: return "no such session"
        case .noOverlay: return OverlayHtmlError.noOverlay
        case .notHtml: return OverlayHtmlError.notHtml
        }
    }
}

extension AppStore {
    /// openHtmlOverlay opens a page in the session-wide slot (`pane` nil) or one pane's slot, with the slot
    /// rules of `openOverlay`/`openPaneOverlay`. Refused while a presenter owns the session: the page renders
    /// on this Mac, where nobody is looking. NOT persisted.
    public func openHtmlOverlay(_ sessionID: UUID, pane: OverlayPane?, overlay: HtmlOverlay, sizePercent: Int?,
                                backgroundColor: String? = nil) -> HtmlOverlayOpenFailure? {
        guard let session = session(withID: sessionID) else { return .unknownSession }
        if presentationHub?.hasPresenter(session: sessionID) == true { return .presenter }
        if let pane {
            guard session.paneOverlay(pane) == nil else { return .alreadyOpen }
            guard session.rendersPane(pane) else { return .paneNotVisible }
            session.setPaneOverlayExitCode(nil, pane: pane)
            session.remoteOverlays.clearFailure(pane)
            session.setPaneOverlay(PaneOverlay(html: overlay, backgroundColor: backgroundColor), pane: pane)
            return nil
        }
        if session.hudActive { closeOverlay(sessionID) }
        guard !session.overlayActive else { return .alreadyOpen }
        session.overlaySlotGeneration += 1
        session.overlayExitCode = nil
        session.remoteOverlays.clearFailure(nil)
        session.overlaySizePercent = sizePercent.map { min(100, max(1, $0)) }
        session.overlayBackgroundColor = backgroundColor
        session.htmlOverlay = overlay
        session.overlayActive = true
        return nil
    }

    /// htmlOverlayCommandFailure is why the slot `pane` addresses cannot take a page command, nil when it
    /// holds a page.
    public func htmlOverlayCommandFailure(_ sessionID: UUID, pane: OverlayPane?) -> HtmlOverlayCommandFailure? {
        switch htmlOverlay(sessionID, pane: pane) {
        case .success: return nil
        case .failure(let failure): return failure
        }
    }

    /// reloadHtmlOverlay asks the app to reload the page, keeping the slot, its identity and the web view.
    public func reloadHtmlOverlay(_ sessionID: UUID, pane: OverlayPane?,
                                  target: HtmlReloadTarget = .original) -> HtmlOverlayCommandFailure? {
        let page: HtmlOverlay
        switch htmlOverlay(sessionID, pane: pane) {
        case .success(let found): page = found
        case .failure(let failure): return failure
        }
        updateHtmlOverlay(page.id) {
            $0.reloadRevision += 1
            $0.reloadTarget = target
            $0.loadState = .loading
            $0.loadError = nil
            if target == .original { $0.current = nil }
        }
        return nil
    }

    /// setHtmlLoadState records what the web view reported for page `id` wherever its slot now is, including
    /// a session hidden by an undoable close. No-op once the page has left its slot.
    public func setHtmlLoadState(_ id: UUID, state: HtmlLoadState, error: String?) {
        updateHtmlOverlay(id) {
            $0.loadState = state
            $0.loadError = error
        }
    }

    /// setHtmlPage records what the web view now shows, as `setHtmlLoadState` does.
    public func setHtmlPage(_ id: UUID, _ info: HtmlPageInfo?) {
        updateHtmlOverlay(id) { $0.current = info }
    }

    func htmlOverlayNodes(_ session: Session) -> [ControlHtmlOverlayNode]? {
        let slots: [(String?, HtmlOverlay?)] = [(nil, session.htmlOverlayActive ? session.htmlOverlay : nil)]
            + OverlayPane.allCases.map { ($0.rawValue, session.paneOverlay($0)?.html) }
        let nodes = slots.compactMap { pane, page in
            page.map {
                ControlHtmlOverlayNode(pane: pane, file: $0.file, cwd: $0.grantRoot, state: $0.loadState.rawValue,
                                       error: $0.loadError, page: $0.current?.page, title: $0.current?.title,
                                       canGoBack: $0.current?.canGoBack, canGoForward: $0.current?.canGoForward)
            }
        }
        return nodes.isEmpty ? nil : nodes
    }

    private func htmlOverlay(_ sessionID: UUID, pane: OverlayPane?) -> Result<HtmlOverlay, HtmlOverlayCommandFailure> {
        guard let session = session(withID: sessionID) else { return .failure(.unknownSession) }
        let occupied = pane.map { session.paneOverlay($0) != nil } ?? (session.overlayActive && !session.hudActive)
        guard occupied else { return .failure(.noOverlay) }
        let page = pane.map { session.paneOverlay($0)?.html } ?? session.htmlOverlay
        return page.map { .success($0) } ?? .failure(.notHtml)
    }

    private func updateHtmlOverlay(_ id: UUID, _ change: (inout HtmlOverlay) -> Void) {
        let sessions = workspaces.flatMap(\.sessions) + pendingCloseMembers().map(\.session)
        for session in sessions where session.updateHtmlOverlay(id, change) { return }
    }
}
