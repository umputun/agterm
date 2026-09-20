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
    public static let supportedKinds = ["status", "hud", "notify", "context"]

    private let staleTimeout: TimeInterval
    private let now: () -> Date
    private var subscribers: [SubscriberID: Subscriber] = [:]
    private var lastGeneration = 0
    private var grant = PresenterGrant()

    /// Called with a session whose presenter went away, after the role is released.
    public var onPresenterLost: (@MainActor (UUID) -> Void)?
    /// Called with what a session's current presenter sent about work it was handed. Frames of this kind
    /// from any other viewer are dropped before this is reached.
    public var onPresenterFrame: (@MainActor (UUID, PresentationFrame.Body) -> Void)?

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
        // presenter is offered only to a viewer that asked for it, so a slice-1 viewer stays a mirror
        let answer = PresentationHello(version: version, kinds: kinds, mode: hello.mode)
        for body in [.hello(answer), .snapshot(state)] + held {
            guard send(body, to: id) else { break }
        }
        return id
    }

    public func unsubscribe(_ id: SubscriberID) {
        subscribers[id] = nil
        release(id)
    }

    /// Sends `body` to `session`'s presenter alone. False when there is none, or it stalled and was dropped.
    @discardableResult
    public func sendToPresenter(_ body: PresentationFrame.Body, session: UUID) -> Bool {
        guard let holder = grant.holder(of: session) else { return false }
        return send(body, to: holder)
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
        case .presenterAcquire:
            let granted = grant.acquire(session: subscriber.session, by: id)
            send(granted ? .presenterGranted : .presenterRefused, to: id)
        case .askResolve, .askRejected, .overlayRejected, .overlayClosed:
            guard grant.holder(of: subscriber.session) == id else { return }
            onPresenterFrame?(subscriber.session, frame.body)
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

    /// Whether a viewer holds `session`'s presenter role.
    public func hasPresenter(session: UUID) -> Bool { grant.holder(of: session) != nil }

    /// Counts changes of `session`'s presenter, a grant and a loss alike.
    public func presenterGeneration(session: UUID) -> Int { grant.generation(of: session) }

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
        release(id)
    }

    private func release(_ id: SubscriberID) {
        for session in grant.release(id) { onPresenterLost?(session) }
    }
}
