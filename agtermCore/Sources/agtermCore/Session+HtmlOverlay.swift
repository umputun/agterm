import Foundation

extension Session {
    /// htmlOverlayActive means a page covers the session: it owns input like a program but has no terminal
    /// surface, zoom target or exit status, so it never counts as `programOverlayActive`.
    public var htmlOverlayActive: Bool { overlayActive && htmlOverlay != nil }

    /// coverOverlayActive is the input-exclusion question; terminal-surface questions ask
    /// `programOverlayActive` instead.
    public var coverOverlayActive: Bool { programOverlayActive || htmlOverlayActive }

    public func paneOverlayIsHtml(_ pane: OverlayPane) -> Bool { paneOverlay(pane)?.html != nil }

    /// htmlCovers checks the slot a `--pane` command addresses, the session-wide one for nil.
    public func htmlCovers(_ pane: OverlayPane?) -> Bool {
        guard let pane else { return htmlOverlayActive }
        return paneOverlayIsHtml(pane)
    }

    /// teardownOverlaySlot discards the session-wide occupant where the whole session goes away; a page has
    /// no surface, so tearing down `overlaySurface` alone would leave it running.
    public func teardownOverlaySlot() {
        overlaySurface?.teardown()
        HtmlOverlayReleases.shared.release(htmlOverlay)
        htmlOverlay = nil
    }

    // false when no slot of this session holds page `id`
    func updateHtmlOverlay(_ id: UUID, _ change: (inout HtmlOverlay) -> Void) -> Bool {
        if var page = htmlOverlay, page.id == id {
            change(&page)
            htmlOverlay = page
            return true
        }
        for pane in OverlayPane.allCases {
            guard var overlay = paneOverlay(pane), var page = overlay.html, page.id == id else { continue }
            change(&page)
            overlay.html = page
            setPaneOverlay(overlay, pane: pane)
            return true
        }
        return false
    }
}
