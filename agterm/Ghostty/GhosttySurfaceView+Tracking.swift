import AppKit
import GhosttyKit

extension GhosttySurfaceView {
    /// Only the on-screen deck pane tracks the pointer. Every session's surface is eagerly realized, and
    /// AppKit tracking areas ignore SwiftUI's `.opacity(0)` and sibling overlap exactly like the
    /// drag-destination resolution (`deckVisible`) — a hidden surface's `visibleRect` is NOT clipped by an
    /// overlapping sibling, so with `.mouseMoved`/`.cursorUpdate` still armed it receives the SAME move as the
    /// visible pane and races to set the one process-global `NSCursor`. A hidden session cached at a different
    /// mouse shape (a mouse-reporting TUI, or an OSC 22 pointer shape) then flickers over the visible terminal
    /// (issue #225). `setupTrackingArea` installs the area only while `deckVisible`, so a hidden surface's
    /// `mouseMoved`/`cursorUpdate` never fire — which also silences `applyMouseShape`'s `.set()` (guarded on
    /// `pointerInside`, only set from `mouseEntered`). On going off-screen, clear the hover/pointer state a
    /// now-untracked surface would otherwise keep (like `mouseExited`).
    func updatePointerTracking() {
        setupTrackingArea()
        guard !deckVisible else { return }
        pointerInside = false
        if let surface { ghostty_surface_mouse_pos(surface, -1, -1, GHOSTTY_MODS_NONE) }
        lastReportedMousePoint = NSPoint(x: -1, y: -1)
    }

    func setupTrackingArea() {
        if let existing = currentTrackingArea { removeTrackingArea(existing); currentTrackingArea = nil }
        // only the on-screen pane owns the pointer (see `updatePointerTracking`): a hidden deck surface
        // installs NO tracking area, so its `mouseMoved`/`cursorUpdate` never fire and it can't race to set
        // the one process-global cursor — the multi-surface flicker of issue #225.
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
}
