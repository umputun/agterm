import Foundation
import agtermCore

/// Serves this Mac's page rows to the Macs that attach them, through the shared `PageAttachmentBook`.
extension ControlServer {
    /// attachCompanionPage answers `session.companion.page.attach`: a token for one `page-serve` claim, and the page.
    func attachCompanionPage(_ target: String?, window: String?) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else { return ControlResponse(ok: false, error: "not a page session") }
            return pageAttachments.offer(session)
        }
    }

    func claimPageAttachment(_ token: String) -> ControlResponse? { pageAttachments.claim(token) }

    func adoptPageAttachment(descriptor: Int32, claim: UUID) -> Bool {
        pageAttachments.adopt(descriptor: descriptor, claim: claim, host: self)
    }

    func dropPageAttachmentClaim(_ claim: UUID) -> Bool { pageAttachments.dropClaim(claim) }

    func pageAttachmentClosed(_ attachment: PageServeStream.Attachment) { pageAttachments.closed(attachment) }

    /// pageAttachmentPlace is where a served page row sits now, nil once it is gone. A soft-closed page still serves:
    /// undo brings it back with its viewers attached.
    func pageAttachmentPlace(_ attachment: PageServeStream.Attachment, page: UUID) -> (session: UUID, pane: OverlayPane?, window: UUID?)? {
        guard pageAttachments.serves(attachment, page: page) else { return nil }
        // the holding store, pending close included, so a soft-closed page still answers for its own window
        return (attachment.session, nil, library.store(holdingSession: attachment.session).flatMap(library.windowID(for:)))
    }

    /// servedPage is the page a page row holds now, pending close included.
    func servedPage(session: UUID, page: UUID) -> HtmlOverlay? {
        guard let row = heldSession(session), row.content == .page, let overlay = row.htmlOverlay, overlay.id == page else {
            return nil
        }
        return overlay
    }
}
