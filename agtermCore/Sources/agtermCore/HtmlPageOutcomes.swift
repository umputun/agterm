import Foundation

/// ControlHtmlPageOutcomeState is where a page stands as a selector: still open, answered, or closed without one.
public enum ControlHtmlPageOutcomeState: String, Codable, Sendable, CaseIterable {
    case pending
    case submitted
    case dismissed
}

/// ControlHtmlPageOutcome is the wire payload of `session.overlay.result --page`; `value` is set only when
/// the page submitted, and may be empty.
public struct ControlHtmlPageOutcome: Codable, Sendable, Equatable {
    public let pageID: String
    public let outcome: ControlHtmlPageOutcomeState
    public let value: String?

    public init(pageID: String, outcome: ControlHtmlPageOutcomeState, value: String? = nil) {
        self.pageID = pageID
        self.outcome = outcome
        self.value = value
    }
}

/// HtmlPageOutcomes records how each HTML page ended, keyed by page id rather than by slot, so a caller
/// blocked on a page reads the answer after the page, its session or its window are gone. Open pages bound
/// the pending set; finished outcomes keep the most recent `retainedLimit`.
@MainActor
public final class HtmlPageOutcomes {
    public static let shared = HtmlPageOutcomes()
    static let retainedLimit = 32

    private var pending: Set<UUID> = []
    private var finished: [(id: UUID, outcome: ControlHtmlPageOutcome)] = []

    init() {}

    func register(_ id: UUID) {
        pending.insert(id)
    }

    /// submit answers a pending page; false when it is not waiting, so the first answer stands.
    @discardableResult func submit(_ id: UUID, value: String) -> Bool {
        finish(id, ControlHtmlPageOutcome(pageID: id.uuidString, outcome: .submitted, value: value))
    }

    func dismiss(_ id: UUID) {
        finish(id, ControlHtmlPageOutcome(pageID: id.uuidString, outcome: .dismissed))
    }

    public func outcome(for id: UUID) -> ControlHtmlPageOutcome? {
        if pending.contains(id) { return ControlHtmlPageOutcome(pageID: id.uuidString, outcome: .pending) }
        return finished.last { $0.id == id }?.outcome
    }

    /// response is the `session.overlay.result --page` reply for page `id`.
    func response(for id: UUID) -> ControlResponse {
        guard let outcome = outcome(for: id) else { return ControlResponse(ok: false, error: OverlayHtmlError.unknownPage) }
        return ControlResponse(ok: true, result: ControlResult(pageOutcome: outcome))
    }

    private func finish(_ id: UUID, _ outcome: ControlHtmlPageOutcome) -> Bool {
        guard pending.remove(id) != nil else { return false }
        finished.append((id, outcome))
        if finished.count > Self.retainedLimit { finished.removeFirst(finished.count - Self.retainedLimit) }
        return true
    }
}
