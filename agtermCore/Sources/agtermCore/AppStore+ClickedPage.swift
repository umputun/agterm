import Foundation

extension AppStore {
    /// releaseHiddenClickedPage closes the session-wide page a terminal click opened while it is hidden by hand
    /// (`overlayHidden`), so the next click page can take the slot. Any other occupant, a shown page, one only out
    /// of sight under a newer pane overlay, and a slot the placement rule hands to the presenting Mac are left
    /// alone, and the answer is false.
    @discardableResult
    public func releaseHiddenClickedPage(_ sessionID: UUID) -> Bool {
        guard let session = session(withID: sessionID), session.overlayHidden, session.htmlOverlay?.clicked == true,
              !pageBelongsRemote(session, pane: nil) else { return false }
        return closeOverlay(sessionID)
    }
}
