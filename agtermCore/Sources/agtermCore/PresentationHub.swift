import Foundation

/// PresentationSink is where the hub hands a subscriber's frames. The bounded queue and the socket live behind
/// it, off the main actor; the hub only learns whether a frame was taken.
@MainActor
public protocol PresentationSink: AnyObject {
    /// Returns false when the consumer's queue is full, which the hub treats as a stalled subscriber.
    func offer(_ frame: PresentationFrame) -> Bool
    func close(_ reason: PresentationHub.CloseReason)
}

/// PresentationHub fans a session's presentation state out to the viewers subscribed to it.
@MainActor
public final class PresentationHub {
    public enum CloseReason: Equatable, Sendable {
        case stalled
        case stale
    }

    public enum SubscribeError: Error, Equatable {
        case unsupportedVersion(Int)
    }

    public struct SubscriberID: Hashable, Sendable {
        let generation: Int
    }

    private final class Subscriber {
        let session: UUID
        let generation: Int
        let sink: PresentationSink
        var revision = 0
        var lastAck: Date
        /// Deltas published while the snapshot is being taken, held so they land after it.
        var held: [PresentationFrame.Body]? = []

        init(session: UUID, generation: Int, sink: PresentationSink, now: Date) {
            self.session = session
            self.generation = generation
            self.sink = sink
            lastAck = now
        }
    }

    /// The frame kinds this origin can produce.
    public static let supportedKinds = ["status", "hud", "notify"]

    private let staleTimeout: TimeInterval
    private let now: () -> Date
    private var subscribers: [SubscriberID: Subscriber] = [:]
    private var lastGeneration = 0

    public init(staleTimeout: TimeInterval, now: @escaping () -> Date = Date.init) {
        self.staleTimeout = staleTimeout
        self.now = now
    }

    /// Registers a viewer and sends it hello, then the snapshot, then whatever was published meanwhile.
    ///
    /// The subscriber is registered BEFORE `snapshot` runs, so a change made while the snapshot is taken is
    /// held and delivered after it and nothing falls between the two.
    @discardableResult
    public func subscribe(session: UUID, hello: PresentationHello, sink: PresentationSink,
                          snapshot: () -> PresentationSnapshot) throws -> SubscriberID {
        guard let version = PresentationCodec.negotiatedVersion(ours: PresentationCodec.version,
                                                                theirs: hello.version) else {
            throw SubscribeError.unsupportedVersion(hello.version)
        }
        lastGeneration += 1
        let id = SubscriberID(generation: lastGeneration)
        let subscriber = Subscriber(session: session, generation: lastGeneration, sink: sink, now: now())
        subscribers[id] = subscriber

        let state = snapshot()
        let held = subscriber.held ?? []
        subscriber.held = nil
        let kinds = Self.supportedKinds.filter(hello.kinds.contains)
        let answer = PresentationHello(version: version, kinds: kinds, mode: .mirror)
        for body in [.hello(answer), .snapshot(state)] + held {
            guard send(body, to: id) else { break }
        }
        return id
    }

    public func unsubscribe(_ id: SubscriberID) {
        subscribers[id] = nil
    }

    public func publish(_ body: PresentationFrame.Body, session: UUID) {
        for (id, subscriber) in subscribers where subscriber.session == session {
            if subscriber.held != nil {
                subscriber.held?.append(body)
                continue
            }
            send(body, to: id)
        }
    }

    /// Handles a frame a viewer sent. One from another generation is left over from an earlier connection.
    public func receive(_ frame: PresentationFrame, from id: SubscriberID) {
        guard let subscriber = subscribers[id], frame.gen == subscriber.generation else { return }
        switch frame.body {
        case .ack: subscriber.lastAck = now()
        case .ping: send(.ack, to: id)
        default: break
        }
    }

    /// Closes every subscriber whose last ack is older than the stale timeout and pings the rest. The owner of
    /// the streams calls this on its own timer.
    public func heartbeat() {
        let current = now()
        for (id, subscriber) in subscribers {
            if current.timeIntervalSince(subscriber.lastAck) > staleTimeout {
                drop(id, reason: .stale)
                continue
            }
            send(.ping, to: id)
        }
    }

    public func subscriberCount(session: UUID) -> Int {
        subscribers.values.count { $0.session == session }
    }

    @discardableResult
    private func send(_ body: PresentationFrame.Body, to id: SubscriberID) -> Bool {
        guard let subscriber = subscribers[id] else { return false }
        let frame = PresentationFrame(gen: subscriber.generation, rev: subscriber.revision, body: body)
        guard subscriber.sink.offer(frame) else {
            drop(id, reason: .stalled)
            return false
        }
        subscriber.revision += 1
        return true
    }

    private func drop(_ id: SubscriberID, reason: CloseReason) {
        guard let subscriber = subscribers.removeValue(forKey: id) else { return }
        subscriber.sink.close(reason)
    }
}
