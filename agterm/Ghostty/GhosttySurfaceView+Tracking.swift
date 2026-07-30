import AppKit
import GhosttyKit

extension GhosttySurfaceView {
    /// Only the on-screen deck pane tracks the pointer. Every session's surface is eagerly realized, and
    /// AppKit tracking areas ignore SwiftUI's `.opacity(0)` and sibling overlap exactly like drag-destination
    /// resolution (`deckVisible`) — a hidden surface's `visibleRect` is NOT clipped by the sibling over it,
    /// so with `.mouseMoved`/`.cursorUpdate` armed it gets the SAME move as the visible pane and races it for
    /// the one process-global `NSCursor`; a hidden session cached at another mouse shape (a mouse-reporting
    /// TUI, an OSC 22 pointer shape) then flickers over the visible terminal (issue #225). `setupTrackingArea`
    /// installs the area only while `deckVisible`, so a hidden surface never fires `mouseMoved`/`cursorUpdate`
    /// — which also silences `applyMouseShape`'s `.set()` (guarded on `pointerInside`, only set from
    /// `mouseEntered`). Going off-screen clears the state it would otherwise keep (like `mouseExited`).
    func updatePointerTracking() {
        setupTrackingArea()
        guard !deckVisible else { return }
        pointerInside = false
        if let surface { ghostty_surface_mouse_pos(surface, -1, -1, GHOSTTY_MODS_NONE) }
        lastReportedMousePoint = NSPoint(x: -1, y: -1)
    }

    func setupTrackingArea() {
        if let existing = currentTrackingArea { removeTrackingArea(existing); currentTrackingArea = nil }
        // only the on-screen pane owns the pointer — see `updatePointerTracking` (issue #225).
        guard deckVisible else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        currentTrackingArea = area
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        setupTrackingArea()
    }

    /// Whether this pane owns the pixel under `point` (window coordinates) — no sibling chrome is drawn over
    /// it there. `deckVisible` answers "am I the on-screen pane?", which is a different question: tracking
    /// areas ignore sibling overlap (see `updatePointerTracking`), so a pane keeps receiving `mouseMoved`
    /// under the sidebar's grab handle, an `NSSplitView` divider, or a floating overlay's margin, and
    /// re-asserts its shape into the process-global `NSCursor` on every move — beating chrome that sets the
    /// cursor once on hover entry (issue #324). Hit-testing resolves ownership the same way the drag that
    /// starts in that band already does, so no per-divider width has to be guessed and later chrome is
    /// covered without touching this file.
    ///
    /// Declines for chrome ONLY: a hit landing on any surface — this one, a descendant, or a sibling pane
    /// stacked at the same frame in the eager deck — keeps the pre-#324 behavior, so a hit test that cannot
    /// see through the deck can never silence the visible terminal.
    func ownsPointer(at point: NSPoint) -> Bool {
        guard let hit = window?.contentView?.hitTest(point) else { return true }
        if hit === self || hit.isDescendant(of: self) { return true }
        return hit is GhosttySurfaceView
    }

    /// `ownsPointer(at:)` for the callers with no event in hand (`applyMouseShape`, activation), reading the
    /// pointer live rather than from possibly-stale state.
    func ownsPointer() -> Bool {
        guard let window else { return true }
        return ownsPointer(at: window.mouseLocationOutsideOfEventStream)
    }
}
