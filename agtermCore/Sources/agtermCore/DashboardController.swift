import Foundation
import Observation

/// How the dashboard overlay sizes its member surfaces' font: `.untouched` leaves each at its own
/// `session.fontSize`, `.fixed` applies one absolute size to every cell, `.auto` derives a per-grid size
/// from `DashboardLayout.dashboardFontSize` so a denser grid shrinks to stay readable. The app-side wiring
/// translates the mode into a transient surface override.
public enum DashboardFontMode: Equatable, Sendable {
    case untouched
    case fixed(Double)
    case auto

    /// appliedFontSize resolves the absolute font size (points) the wiring applies to every member surface
    /// over `memberCount` cells: nil for `.untouched` (each surface keeps its own `session.fontSize`),
    /// `.fixed`'s own value, or a grid-derived one via `DashboardLayout` for `.auto`. Shared by the app-side
    /// font wiring and `ControlServer.setDashboard`, so the controller's `appliedFontSize` (the
    /// `dashboardFontSize` tree read-back) is authoritative at command return, not a runloop turn later.
    public func appliedFontSize(memberCount: Int, base: Double) -> Double? {
        switch self {
        case .untouched:
            return nil
        case let .fixed(value):
            return value
        case .auto:
            let (cols, rows) = DashboardLayout.grid(count: memberCount)
            return DashboardLayout.dashboardFontSize(cols: cols, rows: rows, base: base)
        }
    }
}

/// One dashboard cell's identity: a session plus which of its panes it hosts. A non-split session yields one
/// `.primary` member, a split session both `.primary` and `.split`, so each pane gets its own cell. `surface`
/// is always `.primary` or `.split` here — `TerminalZoomSurface`'s `.scratch`/`.overlay` are never members.
public struct DashboardMember: Equatable, Hashable, Sendable {
    public let session: UUID
    public let surface: TerminalZoomSurface

    public init(session: UUID, surface: TerminalZoomSurface) {
        self.session = session
        self.surface = surface
    }

    /// The `tree` read-back reference for this cell — `<uuid>:left` (primary) / `<uuid>:right` (split),
    /// using the surface's raw value. The read side of `dashboardMembers`/`dashboardHighlighted`.
    public var controlRef: String {
        "\(session.uuidString):\(surface.rawValue)"
    }
}

/// Per-window dashboard state — the picked pane cells, the keyboard highlight, the font mode. Host-free
/// (`agtermCore`, Foundation + Observation only) and `@MainActor`, mirroring `TerminalZoomController`: the
/// app target owns one per window and drives it, `ControlServer` reaches a specific window's through
/// `DashboardControllerRegistry`. `members` are `DashboardMember` pane cells resolved app-side to their live
/// surfaces; `isOpen` derives from a non-empty member set, so `close()` is the open/closed source of truth.
@Observable
@MainActor
public final class DashboardController {
    /// The picked pane cells, in grid order (row-major). Empty when the dashboard is closed.
    public private(set) var members: [DashboardMember] = []

    /// The cell under the keyboard highlight, or nil when closed. Always one of `members` while open.
    public private(set) var highlighted: DashboardMember?

    /// How the overlay sizes member fonts. Reset to `.untouched` on close.
    public private(set) var fontMode: DashboardFontMode = .untouched

    /// The absolute font size (points) the wiring last applied, for tree read-back; nil when `.untouched`
    /// or closed. Set app-side via `setAppliedFontSize(_:)` when the override is applied; reset on close.
    public private(set) var appliedFontSize: Double?

    /// Changes when an overlay above the dashboard releases keyboard ownership, prompting its AppKit
    /// key catcher to reclaim first responder without changing dashboard content.
    public private(set) var focusRevision = 0

    public init() {}

    /// Whether the dashboard is open.
    public var isOpen: Bool { !members.isEmpty }

    /// open shows the dashboard over `members`. The highlight starts on `highlighted` when it is one of
    /// `members`, otherwise on the first member. `fontMode` picks how member fonts are sized.
    public func open(members: [DashboardMember], highlighted: DashboardMember? = nil,
                     fontMode: DashboardFontMode = .untouched) {
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

    /// highlight moves the highlight to `member`, only when it is a current member (a stray one changes
    /// nothing); a no-op when closed. A mouse click uses it to flash the active frame on the clicked cell
    /// before entering it; the keyboard walks the highlight with `move`.
    public func highlight(_ member: DashboardMember) {
        guard members.contains(member) else { return }
        highlighted = member
    }

    /// move walks the keyboard highlight one step in `direction`, clamped by `DashboardLayout` (no wrap,
    /// stays put at an edge or an empty slot of a ragged last row). No-op when closed or with no highlight.
    public func move(_ direction: DashboardLayout.Direction) {
        guard let highlighted, let from = members.firstIndex(of: highlighted) else { return }
        let (cols, _) = DashboardLayout.grid(count: members.count)
        let to = DashboardLayout.move(from: from, direction: direction, cols: cols, count: members.count)
        self.highlighted = members[to]
    }

    /// setAppliedFontSize records the size the app-side wiring applied to the member surfaces, for the
    /// `dashboardFontSize` tree read-back. `private(set)` keeps this the only writer; the wiring calls it on
    /// every font (re)apply.
    public func setAppliedFontSize(_ size: Double?) {
        appliedFontSize = size
    }

    /// requestFocus bumps `focusRevision` so the dashboard's AppKit key catcher reclaims first responder once
    /// an overlay above it (a control picker) resolves. Called by `restoreFocusAfterPick`; only the change
    /// carries meaning, never the value.
    public func requestFocus() {
        focusRevision &+= 1
    }

    /// promoteSplitMember follows a promoted split survivor: `AppStore.closePrimaryPane` moves the split's
    /// shell into the primary slot, so a `.split` cell for that session now points at a pane that no longer
    /// exists even though its shell is alive. Rewriting it to `.primary` keeps a grid built from
    /// `<id>:right` watching the same shell; without this, reconcile prunes the cell and the watched
    /// program silently leaves the dashboard.
    ///
    /// Must run BEFORE reconcile: `closeSplit` (the split's own shell exiting) and `closePrimaryPane` both
    /// end with `hasSplit == false`, so the valid-member set looks identical and only the caller knows a
    /// promotion happened. Collapses into an existing `.primary` cell rather than duplicating it — a bare
    /// id contributes both — and carries the highlight across. No-op without a `.split` member.
    public func promoteSplitMember(session: UUID) {
        let promoted = DashboardMember(session: session, surface: .split)
        let destination = DashboardMember(session: session, surface: .primary)
        guard let index = members.firstIndex(of: promoted) else { return }
        if members.contains(destination) {
            members.remove(at: index)
        } else {
            members[index] = destination
        }
        if highlighted == promoted { highlighted = destination }
    }

    /// reconcile drops any member pane absent from `existing` (a member session or split pane closed while
    /// the dashboard is open — e.g. over the control socket), preserving order. Closes the dashboard when no
    /// member survives, and moves the highlight to the first survivor when the highlighted one vanished. A
    /// no-op when nothing was removed, so it is cheap to call on every session/split add/remove.
    public func reconcile(existing: Set<DashboardMember>) {
        let survivors = members.filter { existing.contains($0) }
        guard survivors.count != members.count else { return }
        guard !survivors.isEmpty else {
            close()
            return
        }
        members = survivors
        if let highlighted, !survivors.contains(highlighted) {
            self.highlighted = survivors.first
        }
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
