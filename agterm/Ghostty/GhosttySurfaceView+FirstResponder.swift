import AppKit
import GhosttyKit

/// Who may take keyboard focus on a surface, which clicks reach the terminal at all, and how a responder
/// transition is reported to libghostty and to the session model.
extension GhosttySurfaceView {
    override var acceptsFirstResponder: Bool { !viewOnly }

    /// In view-only mode refuse hit-testing, so a click passes THROUGH to the SwiftUI cell overlay instead of
    /// reaching `mouseDown` — AppKit routes clicks here regardless of `.allowsHitTesting(false)`.
    ///
    /// `deckVisible` deliberately does NOT gate this. Refusing while off-screen only promotes the hidden deck
    /// entry's own container — its `NSSplitView` or pane view — to answer in its place, and that is not a
    /// `GhosttySurfaceView`, so `ownsPointer` then declines across the whole visible terminal and it loses
    /// every cursor shape it paints.
    override func hitTest(_ point: NSPoint) -> NSView? {
        viewOnly ? nil : super.hitTest(point)
    }

    /// Deliver the LEFT click that reactivates a background window straight to the surface (a "first mouse")
    /// instead of letting AppKit swallow it to raise the window: otherwise clicking a pane of a two-pane split
    /// from another window raises it but never runs `mouseDown`, leaving `splitFocused` on the previous pane.
    /// The click then behaves like any in-window one — selects the pane AND is reported to the program — as in
    /// Terminal.app/iTerm2/Ghostty. Gated to `.leftMouseDown`: a first-mouse right/middle click reaches
    /// `rightMouseDown`/`otherMouseDown`, which forward to libghostty, where the default
    /// `right-click-action = paste` would paste into a window you only meant to raise.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        // with auto-hide-inactive-sidebars on, activating an inactive window expands its hidden sidebar and
        // resizes THIS surface, so an activating click on the terminal would drag the still-held press into a
        // phantom selection. in that mode the click only raises; a follow-up click selects once key.
        if GhosttyApp.shared.autoHideSidebarInactiveWindows { return false }
        return event?.type == .leftMouseDown
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let surface {
            // report focused, gated on the window being key (a background window's surface stays hollow). push
            // directly: `window.firstResponder` is not yet self inside this call, so `liveFocus` reads stale.
            // onFocusChange (split-pane tracking) is independent of key state.
            ghostty_surface_set_focus(surface, window?.isKeyWindow ?? false)
            if !suppressFocusChange { onFocusChange?(true) }
        }
        // AX hears the move from here, NOT from `updateGhosttyFocus` (which this path deliberately skips):
        // the post is deferred a run-loop turn precisely because `window.firstResponder` reads stale here.
        postAccessibilityFocusChange()
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result, let surface {
            ghostty_surface_set_focus(surface, false)
            if !suppressFocusChange { onFocusChange?(false) }
        }
        postAccessibilityFocusChange() // see becomeFirstResponder; the deferred post coalesces the pair
        return result
    }
}
