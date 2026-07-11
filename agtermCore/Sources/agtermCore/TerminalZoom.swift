import Foundation
import Observation

public enum TerminalZoomSurface: String, CaseIterable, Codable, Equatable, Sendable {
    case primary = "left"
    case split = "right"
    case scratch
    case overlay

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
            return session.overlayActive
        }
    }

    @MainActor public func isActive(in session: Session) -> Bool {
        switch self {
        case .primary:
            return !session.overlayActive && !session.scratchActive && !session.splitFocused
        case .split:
            return !session.overlayActive && !session.scratchActive && session.splitFocused
        case .scratch:
            return !session.overlayActive && session.scratchActive
        case .overlay:
            return session.overlayActive
        }
    }

    @MainActor public func isVisible(in session: Session) -> Bool {
        switch self {
        case .primary:
            return !session.overlayActive && !session.scratchActive && (!session.splitFocused || session.isSplit)
        case .split:
            return !session.overlayActive && !session.scratchActive && (session.isSplit || session.splitFocused)
        case .scratch:
            return !session.overlayActive && session.scratchActive
        case .overlay:
            return session.overlayActive
        }
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
}
