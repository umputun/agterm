import Foundation

/// The app-side terminal surface (a libghostty-backed NSView) seen by the
/// host-free model. Kept minimal so `agtermCore` stays free of GhosttyKit/AppKit:
/// the concrete `GhosttySurfaceView` in the app target conforms to it.
///
/// `@MainActor`-isolated: the only owner is the `@MainActor` `Session`, and the
/// concrete conformer is a `@MainActor` `NSView`, so isolation lines up without
/// crossing actor boundaries.
@MainActor
public protocol TerminalSurface: AnyObject {
    /// Frees the underlying libghostty surface and shell. Called when the
    /// owning session is closed.
    func teardown()

    /// Reassigns this surface from the split (right) pane role to the primary pane, so its live
    /// pwd/title reports flow to the session's main fields (`currentCwd`/`oscTitle`) instead of the
    /// split fields (`splitCwd`/`splitTitle`). Called by `closePrimaryPane` when the primary pane's
    /// shell exits and the surviving split pane is promoted to the session's sole pane.
    func promoteToPrimaryPane()
}

public extension TerminalSurface {
    /// Default no-op so adding this requirement stays source-compatible for conformers that route
    /// pwd/title reports role-agnostically and have nothing to reassign. `GhosttySurfaceView` overrides
    /// it (dynamically dispatched via the witness table) to clear its split-role flag.
    func promoteToPrimaryPane() {}
}

/// The direction the search selection steps, in agterm's natural convention:
/// `next` = forward = visually DOWN the screen (toward newer output), `previous` = back = visually UP
/// (toward older scrollback). Host-free so the inversion to libghostty's own `navigate_search` strings is
/// unit-testable without GhosttyKit.
public enum SearchDirection: String, Sendable {
    case next
    case previous

    /// The libghostty `navigate_search:<dir>` argument for this direction. libghostty's own `next` walks
    /// matches newest→oldest (visually UP) and its `previous` walks oldest→newest (visually DOWN), the
    /// OPPOSITE of agterm's convention — so agterm's `.next` (down) maps to `previous` and `.previous`
    /// (up) maps to `next`. Centralizing the inversion here keeps the DOWN chevron / Enter / `--next`
    /// moving visually down and the UP chevron / Shift-Enter / `--prev` moving visually up.
    public var ghosttyAction: String {
        switch self {
        case .next: return "navigate_search:previous"
        case .previous: return "navigate_search:next"
        }
    }
}
