import Foundation

/// The retry schedule every remote link shares. A laptop asleep for the night should not be retried every
/// thirty seconds, and should never be given up on either.
public enum RemoteRetryBackoff {
    static let firstCap: TimeInterval = 30
    static let lateCap: TimeInterval = 300
    /// Failures in a row before the cap grows.
    static let failuresBeforeLateCap = 8

    /// The wait after the `failures`th failure in a row, counted from one.
    public static func delay(afterFailures failures: Int) -> TimeInterval {
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

    public static func title(nonce: String) -> String { prefix + nonce + suffix }
}

/// Panes whose ssh lost the connection and wait to be attached again, keyed by pane identity like
/// `ZmxLeadBook`. No clock of its own: the owner asks what is `due` on its tick and reports every probe,
/// which keeps the schedule deterministic to test.
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
        public fileprivate(set) var failures = 0
        public fileprivate(set) var retryAt: Date
        public fileprivate(set) var probing = false
    }

    public private(set) var entries: [UUID: Entry] = [:]
    private var resumed: [UUID: (at: Date, failures: Int)] = [:]

    public init() {}

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
    public func finished(pane: UUID, ok: Bool, now: Date) -> Entry? {
        guard var entry = entries[pane], entry.probing else { return nil }
        guard ok else {
            entry.probing = false
            entry.failures += 1
            entry.retryAt = now.addingTimeInterval(RemoteRetryBackoff.delay(afterFailures: entry.failures))
            entries[pane] = entry
            return nil
        }
        entries[pane] = nil
        resumed[pane] = (now, entry.failures)
        return entry
    }

    public func retryNow(pane: UUID, now: Date) {
        guard entries[pane]?.probing == false else { return }
        entries[pane]?.retryAt = now
    }

    public func cancel(pane: UUID) {
        entries[pane] = nil
        resumed[pane] = nil
    }
}
