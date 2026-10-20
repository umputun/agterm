import Foundation

extension AppStore {
    /// setOverlaysHidden hides or shows a session's overlays: one pane's, or every program and page of the
    /// session for a nil `pane`. A hidden overlay keeps running and stays addressable. nil on success,
    /// including when nothing changed; `tree.changed` fires only on a change.
    @discardableResult
    public func setOverlaysHidden(_ sessionID: UUID, pane: OverlayPane?, hidden: Bool) -> OverlayVisibilityFailure? {
        guard let session = session(withID: sessionID) else { return .unknownSession }
        let slots = session.hideableOverlaySlots(pane)
        guard !slots.isEmpty else { return session.overlayVisibilityRefusal(pane) }
        let changing = slots.filter { session.overlayHidden($0) != hidden }
        for slot in changing { session.setOverlayHidden(hidden, slot: slot) }
        if !changing.isEmpty { scheduleTreeChanged() }
        return nil
    }

    /// toggleOverlaysHidden hides the scoped overlays when any of them is shown, otherwise shows them all.
    @discardableResult
    public func toggleOverlaysHidden(_ sessionID: UUID, pane: OverlayPane?) -> OverlayVisibilityFailure? {
        guard let session = session(withID: sessionID) else { return .unknownSession }
        return setOverlaysHidden(sessionID, pane: pane, hidden: session.anyOverlayShown(pane))
    }

    /// applyOverlayVisibility runs a control `mode` against the scoped overlays.
    @discardableResult
    public func applyOverlayVisibility(_ sessionID: UUID, pane: OverlayPane?,
                                       mode: OverlayVisibilityMode) -> OverlayVisibilityFailure? {
        switch mode {
        case .hide: return setOverlaysHidden(sessionID, pane: pane, hidden: true)
        case .show: return setOverlaysHidden(sessionID, pane: pane, hidden: false)
        case .toggle: return toggleOverlaysHidden(sessionID, pane: pane)
        }
    }

    /// hideHtmlOverlay hides page `id` from its own strip with a page's scope: a pane page hides its pane,
    /// a session-wide page the session's overlays. False once the page left its slot.
    @discardableResult public func hideHtmlOverlay(_ id: UUID) -> Bool {
        guard let slot = htmlOverlaySlot(id) else { return false }
        return setOverlaysHidden(slot.session.id, pane: slot.pane, hidden: true) == nil
    }

    func hiddenOverlaysNode(_ session: Session) -> [String]? {
        let names = session.hiddenOverlayNames
        return names.isEmpty ? nil : names
    }
}
