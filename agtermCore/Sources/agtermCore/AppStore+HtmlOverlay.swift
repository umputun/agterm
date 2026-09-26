import Foundation

/// HtmlOverlayOpenFailure is why `AppStore.openHtmlOverlay` refused.
public enum HtmlOverlayOpenFailure: Equatable, Sendable {
    case unknownSession, alreadyOpen, paneNotVisible, presenter
}

/// HtmlOverlayReloadFailure is why `AppStore.reloadHtmlOverlay` refused.
public enum HtmlOverlayReloadFailure: Equatable, Sendable {
    case unknownSession, noOverlay, notHtml
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

    /// reloadHtmlOverlay asks the app to load the page's original file again, keeping the slot, its identity
    /// and the web view.
    public func reloadHtmlOverlay(_ sessionID: UUID, pane: OverlayPane?) -> HtmlOverlayReloadFailure? {
        guard let session = session(withID: sessionID) else { return .unknownSession }
        let occupied = pane.map { session.paneOverlay($0) != nil } ?? (session.overlayActive && !session.hudActive)
        guard occupied else { return .noOverlay }
        let page = pane.map { session.paneOverlay($0)?.html } ?? session.htmlOverlay
        guard let page else { return .notHtml }
        _ = session.updateHtmlOverlay(page.id) {
            $0.reloadRevision += 1
            $0.loadState = .loading
            $0.loadError = nil
        }
        return nil
    }

    /// setHtmlLoadState records what the web view reported for page `id` wherever its slot now is, including
    /// a session hidden by an undoable close. No-op once the page has left its slot.
    public func setHtmlLoadState(_ id: UUID, state: HtmlLoadState, error: String?) {
        let sessions = workspaces.flatMap(\.sessions) + pendingCloseMembers().map(\.session)
        for session in sessions where session.updateHtmlOverlay(id, {
            $0.loadState = state
            $0.loadError = error
        }) {
            return
        }
    }
}
