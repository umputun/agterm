import Foundation

/// Further main-actor observers of sequenced events beside `WindowLibrary.onControlEvent`'s
/// single hooks slot; the event stream hub subscribes through this.
@MainActor
public final class ControlEventTaps {
    private var taps: [UUID: (ControlEvent) -> Void] = [:]

    @discardableResult
    public func add(_ tap: @escaping (ControlEvent) -> Void) -> UUID {
        let id = UUID()
        taps[id] = tap
        return id
    }

    public func remove(_ id: UUID) {
        taps[id] = nil
    }

    public func notify(_ event: ControlEvent) {
        for tap in taps.values { tap(event) }
    }
}

/// Fans sequenced control events out to `events.stream` connections. Opening reserves a subscriber
/// slot BEFORE the anchor reply is computed, so no event in the open window can slip between the
/// anchor read and the stream start: frames arriving while the subscriber is pending are buffered
/// and, at commit, only those after the anchor cursor are flushed — the earlier ones are already in
/// the anchor batch. `fanout` encodes each event once on the main actor and queues the frame on
/// every matching subscriber's bounded `ControlStreamOwner` queue; a peer that stops reading is
/// dropped, never waited on — the same slow-peer policy as the other adopted streams.
@MainActor
public final class EventStreamHub {
    /// Concurrent stream cap; the connection past it is answered with an admission error.
    nonisolated public static let subscriberLimit = 32

    /// The admission error a connection past `subscriberLimit` receives. The CLI matches this
    /// constant to tell a capacity refusal from an older server without `events.stream`.
    nonisolated public static let capacityRefusal = "too many concurrent event streams (limit \(subscriberLimit))"

    /// A subscriber never sends after its request, and one event frame is tiny; the pending cap
    /// only bounds a burst queued to a peer that has stopped reading.
    public static let defaultLimits = ControlStreamOwner.Limits(
        maxLineBytes: 1 << 16, maxPendingLines: 1024, writeTimeoutSeconds: 5)

    private final class Subscriber {
        let kinds: Set<ControlEventKind>?
        var sent: UInt64
        var owner: ControlStreamOwner?
        /// Frames buffered while the reservation was pending, each with its sequence.
        var buffered: [(seq: UInt64, frame: Data)] = []

        init(kinds: Set<ControlEventKind>?, sent: UInt64) {
            self.kinds = kinds
            self.sent = sent
        }
    }

    private var subscribers: [UUID: Subscriber] = [:]
    private let limits: ControlStreamOwner.Limits

    public init(limits: ControlStreamOwner.Limits = EventStreamHub.defaultLimits) {
        self.limits = limits
    }

    public var hasCapacity: Bool { subscribers.count < Self.subscriberLimit }

    /// Reserve a subscriber slot, buffering frames until `commit`. Nil when the cap is reached.
    public func reserve(kinds: Set<ControlEventKind>?) -> UUID? {
        guard hasCapacity else { return nil }
        let id = UUID()
        subscribers[id] = Subscriber(kinds: kinds, sent: 0)
        return id
    }

    /// Drop a reservation that never became a stream — a refused admission or a reply that could
    /// not be written.
    public func release(_ id: UUID) {
        subscribers[id] = nil
    }

    /// Give the reserved slot its connection and start pushing. `cursor` is the sequence the anchor
    /// reply covered: buffered frames at or below it were in that batch and are discarded, the rest
    /// are flushed in order — after the anchor reply, which is already on the wire. False when the
    /// reservation was dropped while pending: the stream is not adopted and the caller keeps
    /// ownership of the descriptor.
    @discardableResult
    public func commit(_ id: UUID, descriptor: Int32, cursor: UInt64) -> Bool {
        guard let subscriber = subscribers[id] else { return false }
        subscriber.sent = cursor
        let owner = ControlStreamOwner(descriptor: descriptor, limits: limits)
        subscriber.owner = owner
        let buffered = subscriber.buffered
        subscriber.buffered = []
        // input after the request means nothing; EOF is the unsubscribe
        owner.start(onLine: { _ in }, onClose: { [weak self] in
            Task { @MainActor in self?.subscribers[id] = nil }
        })
        for pending in buffered where pending.seq > cursor {
            if !owner.send(pending.frame) { owner.shutdown() }
        }
        return true
    }

    /// Queue `event` on every matching subscriber, encoding the frame once. A committed subscriber
    /// only takes frames after its cursor; a pending one buffers everything for commit to sort out,
    /// under the same cap as a committed queue — a peer that lets even the short open window
    /// overflow is dropped, and its commit answers false so the caller closes the descriptor.
    public func fanout(_ event: ControlEvent) {
        guard !subscribers.isEmpty else { return }
        var frame: Data?
        for (id, subscriber) in subscribers {
            guard subscriber.kinds == nil || subscriber.kinds!.contains(event.kind) else { continue }
            if frame == nil {
                guard let encoded = try? JSONEncoder().encode(event) else { return }
                frame = encoded + Data([UInt8(ascii: "\n")])
            }
            if let owner = subscriber.owner {
                guard event.seq > subscriber.sent else { continue }
                if owner.send(frame!) {
                    subscriber.sent = event.seq
                } else {
                    // a stalled peer is dropped by shutdown; onClose removes it from the map
                    owner.shutdown()
                }
            } else if subscriber.buffered.count < limits.maxPendingLines {
                subscriber.buffered.append((event.seq, frame!))
            } else {
                subscribers[id] = nil
            }
        }
    }
}
