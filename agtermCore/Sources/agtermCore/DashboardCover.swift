import Foundation

/// DashboardCover names what hides a pane's terminal in the session's own view, so a dashboard cell hosting
/// that terminal can say so instead of showing a shell the session does not show.
public enum DashboardCover: Equatable, Sendable {
    /// identity is the app-derived source (`HtmlOverlay.identity`); title is the page's own text.
    case page(identity: String, title: String?)
    /// command is nil for a replica, whose stored command is the ssh helper line, not the remote program.
    case program(command: String?)
}

extension Session {
    /// dashboardCover returns the cover over `pane`: a full session-wide program or page first, then the
    /// pane's own overlay. A HUD and a floating overlay leave the panes lit in the deck, so they cover nothing.
    public func dashboardCover(for pane: OverlayPane) -> DashboardCover? {
        if fullOverlayActive {
            if let page = htmlOverlay { return .page(identity: page.identity, title: page.current?.title) }
            return .program(command: overlayReplica == nil ? overlayCommand : nil)
        }
        guard let overlay = paneOverlay(pane) else { return nil }
        if let page = overlay.html { return .page(identity: page.identity, title: page.current?.title) }
        return .program(command: overlay.replica == nil ? overlay.command : nil)
    }
}
