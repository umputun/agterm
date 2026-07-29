import Foundation

/// One caller-provided choice displayed by the native picker.
public struct ControlPickItem: Codable, Sendable, Equatable {
    public static let maxItems = 1_000

    public let id: String
    public let label: String
    public let subtitle: String?

    public init(id: String, label: String, subtitle: String? = nil) {
        self.id = id
        self.label = label
        self.subtitle = subtitle
    }
}

/// The state or terminal outcome returned by `pick.result`.
public enum ControlPickOutcome: String, Codable, Sendable, CaseIterable {
    case pending
    case picked
    case custom
    case cancelled
}

/// The nested wire payload returned by `pick.result`.
public struct ControlPickResult: Codable, Sendable, Equatable {
    public let result: ControlPickOutcome
    public let id: String?
    public let label: String?
    public let index: Int?
    public let query: String?

    public init(result: ControlPickOutcome, id: String? = nil, label: String? = nil,
                index: Int? = nil, query: String? = nil) {
        self.result = result
        self.id = id
        self.label = label
        self.index = index
        self.query = query
    }
}

/// A completed picker result paired with the picker id that produced it. `sequence` orders results
/// across windows so the app-wide retention evicts the oldest ANSWER rather than the oldest transfer;
/// it is internal bookkeeping and never crosses the wire.
public struct ResolvedPick: Codable, Sendable, Equatable {
    public let id: String
    public let result: ControlPickResult
    public let sequence: Int

    public init(id: String, result: ControlPickResult, sequence: Int = 0) {
        self.id = id
        self.result = result
        self.sequence = sequence
    }
}
