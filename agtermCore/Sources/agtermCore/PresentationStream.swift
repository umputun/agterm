import Foundation

private let presentationLog = CoreLog(category: "ControlPresentation")

/// PresentationStreamHost serves the presentation streams of the sessions it owns: the Mac's control server and
/// agterm-server. Adoption, subscription and the heartbeat are shared through this protocol's extension.
@MainActor
public protocol PresentationStreamHost: AnyObject {
    var presentationHub: PresentationHub { get }
    var presentationStreams: [PresentationStream] { get set }
    var presentationHeartbeat: Task<Void, Never>? { get set }
    /// presentationHelloDeadline is how long a stream may go without its hello before it is closed.
    var presentationHelloDeadline: TimeInterval { get }
    func presentationSourceExists(_ session: UUID) -> Bool
    /// presentationSnapshot is what a new subscriber of `session` starts from.
    func presentationSnapshot(forSession session: UUID) -> PresentationSnapshot
    /// prepareForPresentationStream runs before a stream is adopted, for a host that wires its stores lazily.
    func prepareForPresentationStream()
}

/// One viewer's presentation stream: the hub's sink on one side, a `ControlStreamOwner` on the other.
///
/// The viewer speaks first. Its hello subscribes it, and everything after goes to the hub as that
/// subscriber's frames. Main-actor only; the owner's thread callbacks hop here before touching it.
@MainActor
public final class PresentationStream: PresentationSink {
    public static let limits = ControlStreamOwner.Limits(maxLineBytes: PresentationCodec.maxFrameBytes,
                                                         maxPendingLines: PresentationCodec.maxPendingFrames,
                                                         writeTimeoutSeconds: 5)
    static let heartbeatSeconds: UInt64 = 10
    /// Lines a viewer may have waiting for the main actor. The reader thread stops reading past this, so a
    /// fast or faulty peer backs up into its own socket instead of into this process's memory.
    static let inboundLimit = 64

    public let session: UUID
    private let owner: ControlStreamOwner
    private weak var host: (any PresentationStreamHost)?
    private var subscriber: PresentationHub.SubscriberID?

    init(session: UUID, owner: ControlStreamOwner, host: any PresentationStreamHost) {
        self.session = session
        self.owner = owner
        self.host = host
    }

    /// False for a frame that cannot be encoded, too: reporting it taken would advance the revision over
    /// an event the viewer never got, on a stream that still looks healthy.
    public func offer(_ frame: PresentationFrame) -> Bool {
        do {
            return owner.send(try PresentationCodec.encode(frame))
        } catch {
            presentationLog.error("closing a presentation stream on an unsendable frame: \(error)")
            return false
        }
    }

    public var subscribed: Bool { subscriber != nil }

    public func close(_ reason: PresentationHub.CloseReason) {
        presentationLog.notice("closing a presentation stream: \(reason)")
        owner.shutdown()
    }

    public func shutdown() { owner.shutdown() }

    func receive(_ line: Data) {
        guard let host else { return }
        let frame: PresentationFrame
        do {
            frame = try PresentationCodec.decode(line)
        } catch {
            presentationLog.error("closing a presentation stream on a bad frame: \(error)")
            owner.shutdown()
            return
        }
        if let subscriber {
            host.presentationHub.receive(frame, from: subscriber)
            return
        }
        guard case .hello(let hello) = frame.body else {
            presentationLog.error("closing a presentation stream that did not open with hello")
            owner.shutdown()
            return
        }
        guard host.presentationSourceExists(session) else {
            presentationLog.notice("closing a presentation stream whose session is gone")
            owner.shutdown()
            return
        }
        do {
            subscriber = try host.subscribePresentation(self, hello: hello)
        } catch {
            presentationLog.error("refusing a presentation stream: \(error)")
            owner.shutdown()
        }
    }

    func closed() {
        if let subscriber { host?.presentationHub.unsubscribe(subscriber) }
        subscriber = nil
        host?.presentationStreams.removeAll { $0 === self }
    }
}

extension PresentationStreamHost {
    /// adoptPresentationStream takes over a connection whose `zmx.present` was just answered ok. It returns at once;
    /// the owner's threads do the I/O from here.
    public func adoptPresentationStream(descriptor: Int32, session: UUID) {
        let owner = ControlStreamOwner(descriptor: descriptor, limits: PresentationStream.limits)
        let stream = PresentationStream(session: session, owner: owner, host: self)
        presentationStreams.append(stream)
        prepareForPresentationStream()
        startPresentationHeartbeat()
        // reads carry no idle timeout, and the hub's heartbeat only knows subscribers, so a peer that takes
        // the reply and then says nothing would otherwise hold two threads and a descriptor for good
        let deadline = presentationHelloDeadline
        Task { @MainActor [weak stream] in
            try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
            guard let stream, !stream.subscribed else { return }
            presentationLog.notice("closing a presentation stream that sent no hello")
            stream.shutdown()
        }
        let inbound = DispatchSemaphore(value: PresentationStream.inboundLimit)
        owner.start(
            onLine: { [weak stream] line in
                let copy = Data(line)
                inbound.wait()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { stream?.receive(copy) }
                    inbound.signal()
                }
            },
            onClose: { [weak stream] in
                DispatchQueue.main.async { MainActor.assumeIsolated { stream?.closed() } }
            }
        )
    }

    public func subscribePresentation(_ stream: PresentationStream, hello: PresentationHello) throws
        -> PresentationHub.SubscriberID {
        let id = stream.session
        return try presentationHub.subscribe(session: id, hello: hello, sink: stream) { [weak self] in
            self?.presentationSnapshot(forSession: id) ?? PresentationSnapshot(status: nil, hud: nil)
        }
    }

    /// dropOrphanedPresentationStreams ends the streams of sessions that are gone. A viewer would otherwise keep
    /// the last mirrored state for good, on a stream that still answers pings.
    public func dropOrphanedPresentationStreams() {
        for stream in presentationStreams where !presentationSourceExists(stream.session) {
            presentationLog.notice("closing a presentation stream whose session is gone")
            stream.shutdown()
        }
    }

    public func shutdownPresentationStreams() {
        for stream in presentationStreams { stream.shutdown() }
        presentationHeartbeat?.cancel()
        presentationHeartbeat = nil
    }

    private func startPresentationHeartbeat() {
        guard presentationHeartbeat == nil else { return }
        presentationHeartbeat = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: PresentationStream.heartbeatSeconds * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard !self.presentationStreams.isEmpty else {
                    self.presentationHeartbeat = nil
                    return
                }
                self.dropOrphanedPresentationStreams()
                self.presentationHub.heartbeat()
            }
        }
    }
}
