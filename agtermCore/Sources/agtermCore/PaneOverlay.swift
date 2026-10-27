import Foundation

/// Which pane a pane-scoped overlay covers. Two cases rather than `StatusPane` so a scratch overlay is
/// not representable and no call site needs a scratch guard.
public enum OverlayPane: String, CaseIterable, Codable, Sendable {
    case left
    case right

    /// Accepts the same pane spellings as `TerminalZoomSurface`, minus `scratch`: a pane overlay covers a
    /// split pane only. Role and axis names are accepted as aliases, so the rejection message naming only
    /// `left or right` is guidance, not the full accepted set.
    public init?(controlName: String) {
        switch controlName {
        case "left", "top", "primary":
            self = .left
        case "right", "bottom", "split":
            self = .right
        default:
            return nil
        }
    }

    /// The three `Session` slots this pane owns, plus its zoom surface — the ONE place the
    /// `left`↔`leftOverlay*` mapping is written. Every reader and writer goes through these key paths, so a
    /// transposed ternary can no longer drive the wrong pane from any of the call sites.
    @MainActor public var overlaySlot: ReferenceWritableKeyPath<Session, PaneOverlay?> {
        self == .left ? \.leftOverlay : \.rightOverlay
    }

    @MainActor public var surfaceSlot: ReferenceWritableKeyPath<Session, (any TerminalSurface)?> {
        self == .left ? \.leftOverlaySurface : \.rightOverlaySurface
    }

    @MainActor public var exitCodeSlot: ReferenceWritableKeyPath<Session, Int?> {
        self == .left ? \.leftOverlayExitCode : \.rightOverlayExitCode
    }

    /// The zoom surface addressing this pane's overlay (`surface:<id>:overlay-left|overlay-right`).
    public var zoomSurface: TerminalZoomSurface {
        self == .left ? .overlayLeft : .overlayRight
    }

    /// The pane itself as a zoom surface, the slot this overlay covers.
    public var paneZoomSurface: TerminalZoomSurface {
        self == .left ? .primary : .split
    }
}

/// One pane's ephemeral overlay — the session-scoped overlay's fields minus the size percent, which a
/// pane overlay never has (it is always full-pane). The surface lives beside this in
/// `leftOverlaySurface`/`rightOverlaySurface`, not inside, because `TerminalView` writes that slot back
/// during view update and an observed write there would loop.
public struct PaneOverlay: Equatable, Sendable {
    /// The command the overlay runs as its process, read by the overlay factory at creation.
    public var command: String
    /// The overlay's working directory, or nil to inherit `effectiveCwd`.
    public var cwd: String?
    /// The overlay's own solid background as `#rrggbb`, nil for the theme default. Per-surface, so two
    /// pane overlays open at once may carry different colors.
    public var backgroundColor: String?
    /// Whether the overlay holds its surface after the command exits (libghostty's "press any key to
    /// close"), instead of closing.
    public var wait: Bool
    /// Set on a viewer when the overlay shows a job running on its origin.
    public var replica: OverlayReplica?
    /// html is the page this overlay shows instead of running `command`, which is then empty and never read.
    public var html: HtmlOverlay?
    /// hidden keeps the overlay running while it covers nothing; a new occupant starts shown.
    public var hidden = false
    /// holdsSessionCover: this overlay opened while the session slot held a program or page, so it draws above
    /// that cover while shown. See `Session.sessionSlotShown`.
    public var holdsSessionCover = false

    public init(command: String, cwd: String? = nil, backgroundColor: String? = nil, wait: Bool = false) {
        self.command = command
        self.cwd = cwd
        self.backgroundColor = backgroundColor
        self.wait = wait
    }

    public init(html: HtmlOverlay, backgroundColor: String? = nil) {
        self.init(command: "", backgroundColor: backgroundColor)
        self.html = html
    }
}
