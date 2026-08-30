/// The app-side terminal surface (a libghostty-backed NSView) seen by the host-free model. Kept minimal so
/// `agtermCore` stays free of GhosttyKit/AppKit; the app target's `GhosttySurfaceView` conforms to it.
///
/// `@MainActor`-isolated: the only owner is the `@MainActor` `Session` and the concrete conformer is a
/// `@MainActor` `NSView`, so isolation lines up without crossing actor boundaries.
@MainActor
public protocol TerminalSurface: AnyObject {
    /// Frees the underlying libghostty surface and shell. Called when the owning session is closed.
    func teardown()

    /// Reassigns this surface from the split (right) pane role to the primary, so its live pwd/title reports
    /// flow to the session's main fields (`currentCwd`/`oscTitle`) not the split ones
    /// (`splitCwd`/`splitTitle`). Called by `closePrimaryPane` when the primary pane's shell exits and the
    /// surviving split pane becomes the session's sole pane. A hard requirement (no default) like
    /// `teardown()`: a conformer routing pwd/title by role MUST reassign here, so a future surface fails to
    /// compile rather than silently mis-reporting.
    func promoteToPrimaryPane()

    /// Whether the terminal itself EXISTS — the underlying libghostty surface created and its program
    /// spawned — as opposed to this object merely occupying a session's surface slot. The two differ:
    /// `TerminalView.makeNSView` parks the view in the slot BEFORE `createSurface()` runs, and creation
    /// defers until the view gets a nonzero backing size, so an occupied slot proves nothing about a running
    /// program. `dropUnrealizedPaneOverlays` keys on this to tell a stranded pane overlay from a live one. A
    /// hard requirement (no default) like `teardown()`, because either default silently misbehaves: `true`
    /// strands a slot that never started a program, `false` retires an overlay whose program is running.
    var isRealized: Bool { get }

    /// A stable per-surface identity assigned at spawn, distinct from the pane ROLE (`left|right|scratch`),
    /// which is NOT stable: a promoted split survivor keeps its baked `right` role while moving into the main
    /// slot. Baked into the shell env as `AGTERM_PANE_ID` and forwarded by the agent-status hook as
    /// `session.status --pane-id`, it lets `Session.paneRole(forToken:)` resolve the CURRENT slot instead of
    /// the stale baked role — the fix for a status set from a promoted-then-re-split pane (#199). Empty for a
    /// surface spawned with no pane identity (overlay / quick terminal, or a test stub), which
    /// `paneRole(forToken:)` never matches.
    var paneToken: String { get }
}

/// A live terminal surface's current role in a two-pane session.
public enum SwappablePaneRole: Equatable, Sendable {
    case primary
    case split
}

/// Optional capability for surfaces whose live callback routing can follow a pane-role exchange.
@MainActor
public protocol PaneRoleMutableSurface: TerminalSurface {
    /// Updates callback routing in place without recreating the terminal or changing its stable token.
    func setPaneRole(_ role: SwappablePaneRole)
}

/// The direction the search selection steps, in agterm's natural convention: `next` = forward = visually DOWN
/// the screen (toward newer output), `previous` = back = visually UP (toward older scrollback). Host-free so
/// the inversion to libghostty's own `navigate_search` strings is unit-testable without GhosttyKit.
public enum SearchDirection: String, Sendable {
    case next
    case previous

    /// The libghostty `navigate_search:<dir>` argument for this direction. libghostty's `next` walks matches
    /// newest→oldest (visually UP) and its `previous` oldest→newest (visually DOWN), the OPPOSITE of agterm's
    /// convention, so `.next` (down) maps to `previous` and `.previous` (up) to `next`. Centralizing the
    /// inversion keeps the DOWN chevron / Enter / `--next` moving down and the UP chevron / Shift-Enter /
    /// `--prev` moving up.
    public var ghosttyAction: String {
        switch self {
        case .next: return "navigate_search:previous"
        case .previous: return "navigate_search:next"
        }
    }
}
