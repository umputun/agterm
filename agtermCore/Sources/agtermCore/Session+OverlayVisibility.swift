import Foundation

/// OverlayVisibilityMode is what `session.overlay.hide|show|toggle` asks of the scoped overlays.
public enum OverlayVisibilityMode: String, Sendable {
    case hide, show, toggle
}

/// VisibleCover names what owns a session's keyboard instead of its terminal: a session-wide program or page,
/// or one over the focused pane.
public enum VisibleCover: Equatable, Sendable {
    case session, focusedPane
}

/// OverlayVisibilityFailure is why a hide, show or toggle of a session's overlays refused.
public enum OverlayVisibilityFailure: Equatable, Sendable {
    case unknownSession, noOverlay, remote

    /// message is the control error for this refusal.
    public var message: String {
        switch self {
        case .unknownSession: return "no such session"
        case .noOverlay: return OverlayVisibilityError.noOverlay
        case .remote: return OverlayResultError.shownElsewhere
        }
    }
}

extension Session {
    /// coverOverlayVisible is `coverOverlayActive` minus a hidden occupant: the input-exclusion question.
    public var coverOverlayVisible: Bool { coverOverlayActive && !overlayHidden }

    /// programOverlayVisible is `programOverlayActive` minus a hidden occupant.
    public var programOverlayVisible: Bool { programOverlayActive && !overlayHidden }

    /// htmlOverlayVisible is `htmlOverlayActive` minus a hidden occupant.
    public var htmlOverlayVisible: Bool { htmlOverlayActive && !overlayHidden }

    /// fullOverlayVisible is `fullOverlayActive` minus a hidden occupant: whether the panes are hidden.
    public var fullOverlayVisible: Bool { fullOverlayActive && !overlayHidden }

    /// visibleCover is the cover owning the keyboard now, nil for the terminal itself. It changes only when what
    /// the user types into changes: a hidden overlay closing or the other pane's overlay toggling leaves it alone,
    /// and so does a pane overlay under the scratch, which keeps the keyboard.
    public var visibleCover: VisibleCover? {
        if coverOverlayVisible { return .session }
        if scratchActive { return nil }
        return focusedOverlayPane == nil ? nil : .focusedPane
    }

    /// paneOverlayVisible says whether `pane` holds an overlay that covers it now.
    public func paneOverlayVisible(_ pane: OverlayPane) -> Bool { paneOverlay(pane).map { !$0.hidden } ?? false }

    /// overlayHidden reports the hidden bit of the slot `pane` addresses, the session-wide one for nil.
    public func overlayHidden(_ pane: OverlayPane?) -> Bool {
        guard let pane else { return overlayHidden }
        return paneOverlay(pane)?.hidden ?? false
    }

    /// hideableOverlaySlots lists the slots `pane` scopes that hold a program or page, nil standing for the
    /// session-wide slot; every slot of the session for a nil `pane`. A HUD, an ask and an origin-only
    /// remote reservation hold nothing that can be hidden.
    public func hideableOverlaySlots(_ pane: OverlayPane?) -> [OverlayPane?] {
        if let pane { return paneOverlay(pane) == nil ? [] : [pane] }
        return (coverOverlayActive ? [nil] : []) + OverlayPane.allCases.filter { paneOverlay($0) != nil }
    }

    /// anyOverlayShown says a slot `pane` scopes holds a program or page that is not hidden: what a toggle hides.
    /// A page shown on the presenting Mac counts by its pending request, else by what that Mac last reported.
    public func anyOverlayShown(_ pane: OverlayPane?) -> Bool {
        hideableOverlaySlots(pane).contains { !overlayHidden($0) }
            || remotePageSlots(pane).contains { $0.page?.effectiveHidden == false }
    }

    /// remotePageSlots lists the reserved slots `pane` scopes that hold a page shown on the presenting Mac; every
    /// such slot for a nil `pane`.
    func remotePageSlots(_ pane: OverlayPane?) -> [RemoteOverlaySlot] {
        remoteOverlays.slots.filter { $0.page != nil && (pane == nil || $0.pane == pane) }
    }

    /// hiddenOverlayNames is the tree's `hiddenOverlays`: the hidden slots as `session`, `left`, `right`, a remote
    /// page counted as its presenter reports it.
    public var hiddenOverlayNames: [String] {
        let remote = remotePageSlots(nil).filter { $0.page?.hidden == true }.map(\.pane)
        let hidden = hideableOverlaySlots(nil).filter { overlayHidden($0) } + remote
        return ([nil] + OverlayPane.allCases).filter(hidden.contains).map { $0?.rawValue ?? "session" }
    }

    func setOverlayHidden(_ hidden: Bool, slot pane: OverlayPane?) {
        guard let pane else {
            overlayHidden = hidden
            return
        }
        var overlay = paneOverlay(pane)
        overlay?.hidden = hidden
        setPaneOverlay(overlay, pane: pane)
    }

    /// overlayVisibilityRefusal names why `pane`'s scope holds nothing to hide: a remote reservation there
    /// is shown on another Mac, which alone can hide it.
    func overlayVisibilityRefusal(_ pane: OverlayPane?) -> OverlayVisibilityFailure {
        let reserved = pane.map { remoteOverlays.slot($0) != nil } ?? !remoteOverlays.slots.isEmpty
        return reserved ? .remote : .noOverlay
    }
}
