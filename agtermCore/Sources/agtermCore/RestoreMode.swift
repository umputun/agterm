import Foundation

/// How session processes are restored after an app restart.
public enum RestoreMode: String, Codable, CaseIterable, Sendable {
    case none
    case rerun
    case live

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RestoreMode(rawValue: raw) ?? .none
    }

    public var displayName: String {
        switch self {
        case .none: "Fresh shells"
        case .rerun: "Re-run commands"
        case .live: "Live sessions"
        }
    }

    public func launchDecision(liveUnavailableReason: String?) -> RestoreLaunchDecision {
        let active: RestoreMode = self == .live && liveUnavailableReason != nil ? .none : self
        return RestoreLaunchDecision(requested: self, active: active,
                                     liveUnavailableReason: liveUnavailableReason)
    }
}

public struct RestoreLaunchDecision: Equatable, Sendable {
    public let requested: RestoreMode
    public let active: RestoreMode
    public let liveUnavailableReason: String?
}
