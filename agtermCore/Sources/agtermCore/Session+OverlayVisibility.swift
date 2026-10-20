import Foundation

/// OverlayVisibilityFailure is why a hide, show or toggle of a session's overlays refused.
public enum OverlayVisibilityFailure: Equatable, Sendable {
    case unknownSession, noOverlay, remote
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

    /// hiddenOverlayNames is the tree's `hiddenOverlays`: the hidden slots as `session`, `left`, `right`.
    var hiddenOverlayNames: [String] {
        hideableOverlaySlots(nil).filter { overlayHidden($0) }.map { $0?.rawValue ?? "session" }
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
