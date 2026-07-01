import agtermCore
import GhosttyKit
import SwiftUI

/// Bridges one session's libghostty surface (a `GhosttySurfaceView`) into SwiftUI.
///
/// The surface is owned by the `Session` (`session.surface`), not the
/// representable. `makeNSView` returns the session's cached surface view,
/// creating it through the app-supplied `makeSurface` factory on first display;
/// `dismantleNSView` is a no-op so the surface (and its shell) survives view
/// churn when switching sessions. Only an explicit `teardown()` frees it.
///
/// The detail pane keeps every session's `TerminalView` mounted (a deck) and toggles visibility +
/// `isActive` on selection rather than swapping by `.id`, so switching sessions does NOT dismantle/
/// re-host the surface NSView (a re-host invalidates the Metal drawable and flickers). Surfaces stay
/// alive regardless.
struct TerminalView: NSViewRepresentable {
    let session: Session
    /// Which surface slot this view binds to: the primary `\.surface` or the split
    /// `\.splitSurface`. Lets one representable host either pane.
    let surfaceKeyPath: ReferenceWritableKeyPath<Session, (any TerminalSurface)?>
    /// Lazily creates a `GhosttySurfaceView` for the session and stores it in the slot.
    /// Supplied by the app target (a primary or split factory).
    let makeSurface: (Session) -> GhosttySurfaceView
    /// Whether this is the active (visible) pane in the deck. Every session's surface stays mounted, so
    /// a view only auto-grabs focus when active — otherwise every mounted pane would fight for it.
    var isActive = true
    /// Whether this pane is on-screen (its session is selected and not hidden by a full overlay/scratch).
    /// UNLIKE `isActive` this is NOT split-focus-gated: both panes of a visible split are `deckVisible`.
    /// Drives `GhosttySurfaceView`'s drag-type (un)registration so a file drop can't land on an invisible
    /// background surface.
    var deckVisible = true

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context _: Context) -> GhosttySurfaceView {
        let view = (session[keyPath: surfaceKeyPath] as? GhosttySurfaceView) ?? makeSurface(session)
        session[keyPath: surfaceKeyPath] = view
        // before the view attaches: gate the overlay/scratch auto-focus to the active slot so a background
        // session's overlay can't grab first responder during its initial createSurface.
        view.deckActive = isActive
        view.deckVisible = deckVisible
        return view
    }

    func updateNSView(_ nsView: GhosttySurfaceView, context: Context) {
        // keep the auto-focus gate in sync with selection, set BEFORE createSurface (which fires the overlay
        // auto-focus) so a background slot never starts the focus-grab retry.
        nsView.deckActive = isActive
        nsView.deckVisible = deckVisible
        // makeNSView may have run before the view had a sized window; createSurface is idempotent
        // (guards surface == nil and a non-zero backing size), so calling it here is safe. Synchronous
        // on purpose: a deferred next-tick create races the layout and gives the surface a stale size.
        nsView.createSurface()
        guard isActive else {
            // hidden deck pane: drop the focus latch so it re-grabs when it next becomes active, and
            // never keep first responder while hidden — the active pane needs it, and a background pane
            // that still looks "focused" wrongly suppresses its own OSC 9 desktop notification.
            context.coordinator.didFocus = false
            if let window = nsView.window, window.firstResponder === nsView { window.makeFirstResponder(nil) }
            return
        }
        focusIfNeeded(nsView, coordinator: context.coordinator)
    }

    /// Grabs first responder for this session's surface only when it is the
    /// natural focus target, so unrelated detail-pane re-renders (window resize,
    /// observable invalidations) don't steal focus.
    ///
    /// Focus is taken once, when this representable first attaches to a window
    /// (each `TerminalView(session).id(session.id)` is a fresh representable, so
    /// this fires when a session becomes active). On later updates focus is left
    /// alone unless the surface already holds it — and never grabbed while a text
    /// field editor is first responder, so editing a sidebar rename survives a
    /// re-render. Mouse clicks (`mouseDown`) cover focus for the rest.
    private func focusIfNeeded(_ nsView: GhosttySurfaceView, coordinator: Coordinator) {
        guard let window = nsView.window else { return }
        if window.firstResponder === nsView { return }
        // don't steal focus from an active text field editor (e.g. a sidebar
        // rename TextField); its field editor is an NSText serving the window.
        if window.firstResponder is NSText { return }
        guard !coordinator.didFocus else { return }
        coordinator.didFocus = true
        window.makeFirstResponder(nsView)
    }

    static func dismantleNSView(_: GhosttySurfaceView, coordinator _: Coordinator) {
        // No-op: the surface outlives the representable and is owned by the
        // session. Only an explicit teardown() may free it.
    }

    /// Tracks whether this representable has already claimed first responder, so
    /// focus is grabbed only on first attach, not on every `updateNSView`.
    final class Coordinator {
        var didFocus = false
    }
}
