import Foundation
import Observation

/// How the dashboard overlay sizes the font of its member surfaces.
/// `.untouched` leaves each surface at its own `session.fontSize`; `.fixed` applies one absolute size to
/// every cell; `.auto` derives a per-grid size from `DashboardLayout.dashboardFontSize` so a denser grid
/// shrinks to stay readable. The app-side wiring translates the mode into a transient surface override.
public enum DashboardFontMode: Equatable, Sendable {
    case untouched
    case fixed(Double)
    case auto
}

/// Per-window dashboard state — the picked member sessions, the keyboard highlight, and the font mode.
/// Host-free (`agtermCore`, Foundation + Observation only) and `@MainActor`, mirroring
/// `TerminalZoomController`: the app target owns one per window and drives it, and `ControlServer` reaches
/// a specific window's controller through `DashboardControllerRegistry`. `members` are session UUIDs
/// (resolved app-side to their live surfaces); `isOpen` derives from a non-empty member set, so `close()`
/// (which empties it) is the single source of truth for open/closed.
@Observable
@MainActor
public final class DashboardController {
    /// The picked member sessions, in grid order (row-major). Empty when the dashboard is closed.
    public private(set) var members: [UUID] = []

    /// The session under the keyboard highlight, or nil when closed. Always one of `members` while open.
    public private(set) var highlighted: UUID?

    /// How the overlay sizes member fonts. Reset to `.untouched` on close.
    public private(set) var fontMode: DashboardFontMode = .untouched

    /// The absolute font size (points) the wiring last applied, for tree read-back; nil when `.untouched`
    /// or closed. Set app-side when the override is applied; reset on close.
    public var appliedFontSize: Double?

    public init() {}

    /// Whether the dashboard is open, i.e. it holds at least one member.
    public var isOpen: Bool { !members.isEmpty }

    /// open shows the dashboard over `members`. The highlight starts on `highlighted` when it is one of
    /// `members`, otherwise on the first member. `fontMode` picks how member fonts are sized.
    public func open(members: [UUID], highlighted: UUID? = nil, fontMode: DashboardFontMode = .untouched) {
        self.members = members
        self.fontMode = fontMode
        if let highlighted, members.contains(highlighted) {
            self.highlighted = highlighted
        } else {
            self.highlighted = members.first
        }
    }

    /// close hides the dashboard and resets all state (members, highlight, font mode, applied size).
    public func close() {
        members = []
        highlighted = nil
        fontMode = .untouched
        appliedFontSize = nil
    }

    /// move walks the keyboard highlight one step in `direction`, clamped by `DashboardLayout` (no wrap,
    /// stays put at an edge or an empty slot of a ragged last row). No-op when closed or with no highlight.
    public func move(_ direction: DashboardLayout.Direction) {
        guard let highlighted, let from = members.firstIndex(of: highlighted) else { return }
        let (cols, _) = DashboardLayout.grid(count: members.count)
        let to = DashboardLayout.move(from: from, direction: direction, cols: cols, count: members.count)
        self.highlighted = members[to]
    }
}

/// Maps a `WindowInfo.ID` to its live `DashboardController`, mirroring `TerminalZoomRegistry`, so the
/// control channel can drive a specific window's dashboard without a cross-window reference.
@MainActor
public final class DashboardControllerRegistry {
    public static let shared = DashboardControllerRegistry()
    private var controllers: [WindowInfo.ID: DashboardController] = [:]

    private init() {}

    public func register(_ id: WindowInfo.ID, controller: DashboardController) {
        controllers[id] = controller
    }

    public func unregister(_ id: WindowInfo.ID) {
        controllers[id] = nil
    }

    public func controller(for id: WindowInfo.ID?) -> DashboardController? {
        guard let id else { return nil }
        return controllers[id]
    }
}
