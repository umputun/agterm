import Foundation
import Observation

public enum TerminalZoomSurface: String, CaseIterable, Codable, Equatable, Sendable {
    case primary = "left"
    case split = "right"
    case scratch
    case overlay
    case overlayLeft = "overlay-left"
    case overlayRight = "overlay-right"

    public init?(controlName: String) {
        switch controlName {
        case "left", "primary":
            self = .primary
        case "right", "split":
            self = .split
        case "scratch":
            self = .scratch
        case "overlay":
            self = .overlay
        case "overlay-left":
            self = .overlayLeft
        case "overlay-right":
            self = .overlayRight
        default:
            return nil
        }
    }

    @MainActor public func isAvailable(in session: Session) -> Bool {
        switch self {
        case .primary:
            if session.surface == nil, session.splitSurface != nil, session.splitFocused {
                return false
            }
            return true
        case .split:
            return session.hasSplit || session.splitSurface != nil
        case .scratch:
            return session.scratchActive || session.scratchSurface != nil
        case .overlay:
            // a HUD is NOT addressable: it takes no input, so there is nothing to zoom into, and `tree`
            // already reports the slot as `overlay: false` while one is up — advertising
            // `surface:<id>:overlay` would contradict the same response. `surface.zoom` on it answers
            // "surface not available" through `isTargetValid`.
            return session.programOverlayActive
        case .overlayLeft:
            return session.paneOverlay(.left) != nil
        case .overlayRight:
            return session.paneOverlay(.right) != nil
        }
    }

    /// MUTUALLY EXCLUSIVE across cases and TOTAL, which `resolveTarget` relies on: it takes the FIRST active
    /// case as the zoom target. Exclusivity rests on two shared terms rather than hand-repeated conjunctions —
    /// `uncovered` (no session-wide cover) separates the four pane cases from `.overlay`/`.scratch`, and
    /// `session.focusedPane` picks exactly one side — leaving each pane separated from its OWN overlay by
    /// that pane's slot alone. Widening either one without narrowing the other silently picks the wrong target.
    /// A HUD holds the overlay slot but covers nothing — the session stays focusable under it — so every term
    /// reads `programOverlayActive`. Narrowing `.overlay` alone would leave NO case active with a HUD up and
    /// fall through to the `?? .primary` fallback `resolveTarget` documents as unreachable.
    @MainActor public func isActive(in session: Session) -> Bool {
        let uncovered = !session.programOverlayActive && !session.scratchActive
        switch self {
        case .primary:
            return uncovered && session.focusedPane == .left && session.leftOverlay == nil
        case .split:
            return uncovered && session.focusedPane == .right && session.rightOverlay == nil
        case .scratch:
            return !session.programOverlayActive && session.scratchActive
        case .overlay:
            return session.programOverlayActive
        case .overlayLeft:
            return uncovered && session.focusedPane == .left && session.leftOverlay != nil
        case .overlayRight:
            return uncovered && session.focusedPane == .right && session.rightOverlay != nil
        }
    }

    @MainActor public func isVisible(in session: Session) -> Bool {
        switch self {
        case .primary:
            // a pane renders at opacity 0 under its OWN overlay, so the overlay case takes the visibility.
            return Self.paneVisible(.left, in: session) && session.leftOverlay == nil
        case .split:
            return Self.paneVisible(.right, in: session) && session.rightOverlay == nil
        case .scratch:
            return !session.programOverlayActive && session.scratchActive
        case .overlay:
            return session.programOverlayActive
        case .overlayLeft:
            return Self.paneVisible(.left, in: session) && session.leftOverlay != nil
        case .overlayRight:
            return Self.paneVisible(.right, in: session) && session.rightOverlay != nil
        }
    }

    /// Whether the detail pane shows that pane at all, ignoring any pane overlay covering it: the layout
    /// question `Session.rendersPane` owns, minus the session-wide covers that hide both panes. A HUD is not
    /// one: the deck leaves the panes lit and clickable around the panel.
    @MainActor private static func paneVisible(_ pane: OverlayPane, in session: Session) -> Bool {
        guard !session.programOverlayActive, !session.scratchActive else { return false }
        return session.rendersPane(pane)
    }
}

public struct TerminalSurfaceID: Hashable, Codable, Sendable, RawRepresentable, CustomStringConvertible {
    public let sessionID: UUID
    public let surface: TerminalZoomSurface

    public var rawValue: String {
        "surface:\(sessionID.uuidString):\(surface.rawValue)"
    }

    public var description: String { rawValue }

    public init(sessionID: UUID, surface: TerminalZoomSurface) {
        self.sessionID = sessionID
        self.surface = surface
    }

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "surface",
              let sessionID = UUID(uuidString: String(parts[1])),
              let surface = TerminalZoomSurface(controlName: String(parts[2])) else {
            return nil
        }
        self.sessionID = sessionID
        self.surface = surface
    }
}

public enum TerminalZoomTarget: Equatable, Sendable {
    case session(UUID, TerminalZoomSurface)
    case quick

    public var controlID: String {
        switch self {
        case let .session(sessionID, surface):
            return TerminalSurfaceID(sessionID: sessionID, surface: surface).rawValue
        case .quick:
            return "quick"
        }
    }
}

@Observable
@MainActor
public final class TerminalZoomController {
    public private(set) var target: TerminalZoomTarget?

    @ObservationIgnored public var targetResolver: (() -> TerminalZoomTarget?)?

    public init() {}

    public func toggle() {
        if target != nil {
            target = nil
        } else {
            target = targetResolver?()
        }
    }

    public func set(_ mode: ControlToggleMode, target newTarget: TerminalZoomTarget?) {
        switch mode {
        case .on:
            if let newTarget {
                target = newTarget
            }
        case .off:
            if let newTarget {
                if target == newTarget {
                    target = nil
                }
            } else {
                target = nil
            }
        case .toggle:
            guard let newTarget else {
                target = nil
                return
            }
            target = target == newTarget ? nil : newTarget
        }
    }

    public func clear() {
        target = nil
    }

    public static func resolveTarget(store: AppStore, quickTerminalVisible: Bool) -> TerminalZoomTarget? {
        if quickTerminalVisible { return .quick }
        guard let session = store.activeSession else { return nil }
        // one source of truth for the active-surface precedence: `isActive(in:)` defines mutually
        // exclusive predicates per case, so the first (only) active one is the zoom target. The
        // `.primary` fallback is unreachable but keeps the derivation total.
        let surface = TerminalZoomSurface.allCases.first { $0.isActive(in: session) } ?? .primary
        return .session(session.id, surface)
    }

    public static func isTargetValid(_ target: TerminalZoomTarget, in store: AppStore, quickTerminalVisible: Bool) -> Bool {
        switch target {
        case .quick:
            return quickTerminalVisible
        case let .session(sessionID, surface):
            guard let session = store.session(withID: sessionID) else { return false }
            return surface.isAvailable(in: session)
        }
    }
}

@MainActor
public final class TerminalZoomRegistry {
    public static let shared = TerminalZoomRegistry()
    private var controllers: [WindowInfo.ID: TerminalZoomController] = [:]

    private init() {}

    public func register(_ id: WindowInfo.ID, controller: TerminalZoomController) {
        controllers[id] = controller
    }

    public func unregister(_ id: WindowInfo.ID) {
        controllers[id] = nil
    }

    public func controller(for id: WindowInfo.ID?) -> TerminalZoomController? {
        guard let id else { return nil }
        return controllers[id]
    }

    /// Whether SOME window's zoom currently targets this session surface — a CLAIM on the slot that stands
    /// from the moment the target is set, before SwiftUI mounts the zoom layer that hosts it. Scanned rather
    /// than looked up: a store carries no window id, and a session is open in exactly one window, so at most
    /// one controller can match. `Session.paneOverlayHosted` reads it, since the deck deliberately hands the
    /// zoomed slot over (`deckHostsSurface`) and is therefore not the whole answer to "who hosts this".
    public func targets(sessionID: UUID, surface: TerminalZoomSurface) -> Bool {
        controllers.values.contains { $0.target == .session(sessionID, surface) }
    }
}
