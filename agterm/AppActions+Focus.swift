import agtermCore
import AppKit
import SwiftUI

extension AppActions {
    /// Move first responder to the split (right) pane on open, or the primary on close.
    /// Re-asserts over a short window because the split surface materializes a beat after the
    /// toggle and the HSplitView collapse churns the primary view. While a full-coverage surface
    /// (scratch or overlay) is up, the requested pane is hidden beneath it, so keep first responder on
    /// the visible `topmostSurface` instead — the caller has already set `splitFocused`, so the correct
    /// pane shows once the cover is dismissed.
    func focusSplitPane(_ session: Session, wantSplit: Bool, attempt: Int = 0, generation: Int? = nil) {
        // each fresh call SUPERSEDES any in-flight retry loop. without this, two calls with opposite
        // targets (focus-left then focus-right) each run their own 12x30ms `makeFirstResponder` loop
        // concurrently and ping-pong first responder between the panes for ~400ms - both surfaces redraw
        // on every flip, which is the split-focus flicker. the surviving (newest) loop still re-asserts
        // through the split-materialize / reparent churn (a lone loop's re-asserts are no-ops once its
        // target is first responder), so the retry keeps its original purpose.
        let gen: Int
        if let generation {
            guard generation == focusGeneration else { return } // superseded by a newer focus op
            gen = generation
        } else {
            focusGeneration += 1
            gen = focusGeneration
        }
        // gate on the SESSION's window, not the frontmost one: this path is cross-window (the control
        // channel focuses sessions in background windows), where the frontmost window's zoom is irrelevant.
        if terminalZoomActive(for: session) { return }
        // the quick terminal is a window-level cover above the session; while it's up it owns focus, so
        // don't move first responder to a pane behind it (its own hide restores the session). The caller
        // has already set `splitFocused`, so the right pane shows once the quick terminal is dismissed.
        if frontmostQuickTerminal?.isVisible == true { return }
        let target: (any TerminalSurface)? = (session.overlayActive || session.scratchActive)
            ? session.topmostSurface
            : (wantSplit ? session.splitSurface : session.surface)
        if let view = target as? GhosttySurfaceView, let window = view.window {
            window.makeFirstResponder(view)
        }
        guard attempt < 12 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.focusSplitPane(session, wantSplit: wantSplit, attempt: attempt + 1, generation: gen)
        }
    }
}
