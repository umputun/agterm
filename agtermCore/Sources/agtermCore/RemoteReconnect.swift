import Foundation

/// The retry schedule every remote link shares. A laptop asleep for the night should not be retried every
/// thirty seconds, and should never be given up on either.
enum RemoteRetryBackoff {
    static let firstCap: TimeInterval = 30
    static let lateCap: TimeInterval = 300
    /// Failures in a row before the cap grows.
    static let failuresBeforeLateCap = 8

    /// The wait after the `failures`th failure in a row, counted from one.
    static func delay(afterFailures failures: Int) -> TimeInterval {
        let cap = failures > failuresBeforeLateCap ? lateCap : firstCap
        return min(pow(2, Double(min(failures - 1, 30))), cap)
    }
}

/// The attach wrapper's word that ssh lost the connection, a title under a reserved prefix like
/// `ZmxLeadNotice`. It carries the pane's lead nonce, so only the pane's current attachment is believed.
public struct RemoteLinkNotice: Equatable, Sendable {
    static let prefix = "agterm-remote;"
    static let suffix = ":lost"

    public let nonce: String

    public init?(title: String) {
        guard title.hasPrefix(Self.prefix), title.hasSuffix(Self.suffix) else { return nil }
        nonce = String(title.dropFirst(Self.prefix.count).dropLast(Self.suffix.count))
    }

    static func title(nonce: String) -> String { prefix + nonce + suffix }
}

/// Panes whose ssh lost the connection and wait to be attached again, keyed by pane identity like
/// `ZmxLeadBook`. No clock of its own: the owner asks what is `due` on its tick and reports every probe,
/// which keeps the schedule deterministic to test.
@Observable
@MainActor
public final class RemoteReconnectBook {
    public static let shared = RemoteReconnectBook()
    /// A pane that loses the link again this soon after attaching keeps its backoff, so a host that answers
    /// the probe but fails the attach is not retried every second.
    static let settle: TimeInterval = 60

    public struct Entry: Equatable, Sendable {
        public let session: UUID
        public let host: String
        /// The origin reported lead roles, so the fresh attach will too and may be covered until it does.
        public let cover: Bool
        fileprivate(set) var failures = 0
        /// reason is what the last failed probe's ssh said, nil when it said nothing. It describes that
        /// probe only, never the attach that follows a probe that answered.
        fileprivate(set) var reason: String?
        fileprivate(set) var retryAt: Date
        fileprivate(set) var probing = false
    }

    public private(set) var entries: [UUID: Entry] = [:]
    @ObservationIgnored private var resumed: [UUID: (at: Date, failures: Int)] = [:]
    static let reasonLimit = 200

    init() {}

    public var isEmpty: Bool { entries.isEmpty }

    public func waiting(pane: UUID?) -> Bool { pane.flatMap { entries[$0] } != nil }

    /// Registers a pane to be reconnected, unless it is already waiting.
    public func wait(pane: UUID, session: UUID, host: String, cover: Bool, now: Date) {
        guard entries[pane] == nil else { return }
        var entry = Entry(session: session, host: host, cover: cover, retryAt: now)
        if let last = resumed.removeValue(forKey: pane), now.timeIntervalSince(last.at) < Self.settle {
            entry.failures = last.failures + 1
            entry.retryAt = now.addingTimeInterval(RemoteRetryBackoff.delay(afterFailures: entry.failures))
        }
        entries[pane] = entry
    }

    /// The panes to probe now, marked so a slow probe is not started twice.
    public func due(now: Date) -> [UUID] {
        resumed = resumed.filter { now.timeIntervalSince($0.value.at) < Self.settle }
        let panes = entries.filter { !$0.value.probing && $0.value.retryAt <= now }.map(\.key)
        for pane in panes { entries[pane]?.probing = true }
        return panes
    }

    /// A failed probe schedules the next one. One that answered ends the wait and returns the entry to
    /// attach again; a result for a pane cancelled meanwhile returns nil.
    public func finished(pane: UUID, ok: Bool, stderr: String = "", now: Date) -> Entry? {
        guard var entry = entries[pane], entry.probing else { return nil }
        guard ok else {
            entry.probing = false
            entry.failures += 1
            entry.reason = Self.reason(fromStderr: stderr)
            entry.retryAt = now.addingTimeInterval(RemoteRetryBackoff.delay(afterFailures: entry.failures))
            entries[pane] = entry
            return nil
        }
        entries[pane] = nil
        resumed[pane] = (now, entry.failures)
        return entry
    }

    /// reason takes ssh's last non-empty line, with control characters removed and its length capped.
    static func reason(fromStderr stderr: String) -> String? {
        let lines = stderr.split(whereSeparator: \.isNewline).map { TerminalText.sanitized(String($0)) }
        guard let last = lines.last(where: { !$0.allSatisfy(\.isWhitespace) }) else { return nil }
        return String(last.trimmingCharacters(in: .whitespaces).prefix(reasonLimit))
    }

    /// readback is the tree's view of a waiting pane, nil for one that is not waiting.
    public func readback(pane: UUID?) -> ControlReconnect? {
        guard let entry = pane.flatMap({ entries[$0] }) else { return nil }
        return ControlReconnect(failures: entry.failures, reason: entry.reason)
    }

    /// Due now with the backoff over; a probe already running is not started twice.
    public func retryNow(pane: UUID, now: Date) {
        guard entries[pane] != nil else { return }
        entries[pane]?.failures = 0
        guard entries[pane]?.probing == false else { return }
        entries[pane]?.retryAt = now
    }

    public func retryAllNow(now: Date) {
        for pane in entries.keys { retryNow(pane: pane, now: now) }
    }

    public func cancel(pane: UUID) {
        entries[pane] = nil
        resumed[pane] = nil
    }
}
