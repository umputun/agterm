import Foundation
import os
import agtermCore

private let presentationLogger = Logger(subsystem: "com.umputun.agterm", category: "ControlPresentation")

/// One viewer's presentation stream: the hub's sink on one side, a `ControlStreamOwner` on the other.
///
/// The viewer speaks first. Its hello subscribes it, and everything after goes to the hub as that
/// subscriber's frames. Main-actor only; the owner's thread callbacks hop here before touching it.
@MainActor
final class PresentationStream: PresentationSink {
    let session: UUID
    private let owner: ControlStreamOwner
    private weak var server: ControlServer?
    private var subscriber: PresentationHub.SubscriberID?

    init(session: UUID, owner: ControlStreamOwner, server: ControlServer) {
        self.session = session
        self.owner = owner
        self.server = server
    }

    /// False for a frame that cannot be encoded, too: reporting it taken would advance the revision over
    /// an event the viewer never got, on a stream that still looks healthy.
    func offer(_ frame: PresentationFrame) -> Bool {
        do {
            return owner.send(try PresentationCodec.encode(frame))
        } catch {
            presentationLogger.error("closing a presentation stream on an unsendable frame: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    var subscribed: Bool { subscriber != nil }

    func close(_ reason: PresentationHub.CloseReason) {
        presentationLogger.notice("closing a presentation stream: \(String(describing: reason), privacy: .public)")
        owner.shutdown()
    }

    func shutdown() { owner.shutdown() }

    func receive(_ line: Data) {
        guard let server else { return }
        let frame: PresentationFrame
        do {
            frame = try PresentationCodec.decode(line)
        } catch {
            presentationLogger.error("closing a presentation stream on a bad frame: \(String(describing: error), privacy: .public)")
            owner.shutdown()
            return
        }
        if let subscriber {
            server.presentationHub.receive(frame, from: subscriber)
            return
        }
        guard case .hello(let hello) = frame.body else {
            presentationLogger.error("closing a presentation stream that did not open with hello")
            owner.shutdown()
            return
        }
        guard server.presentationSourceExists(session) else {
            presentationLogger.notice("closing a presentation stream whose session is gone")
            owner.shutdown()
            return
        }
        do {
            subscriber = try server.subscribePresentation(self, hello: hello)
        } catch {
            presentationLogger.error("refusing a presentation stream: \(String(describing: error), privacy: .public)")
            owner.shutdown()
        }
    }

    func closed() {
        if let subscriber { server?.presentationHub.unsubscribe(subscriber) }
        subscriber = nil
        server?.presentationStreams.removeAll { $0 === self }
    }
}

extension ControlServer {
    static let presentationLimits = ControlStreamOwner.Limits(maxLineBytes: PresentationCodec.maxFrameBytes,
                                                              maxPendingLines: PresentationCodec.maxPendingFrames,
                                                              writeTimeoutSeconds: 5)
    static let presentationHeartbeatSeconds: UInt64 = 10
    /// Lines a viewer may have waiting for the main actor. The reader thread stops reading past this, so a
    /// fast or faulty peer backs up into its own socket instead of into this app's memory.
    static let presentationInboundLimit = 64

    /// Answers `zmx.present`. The stream itself starts only after this reply is on the wire.
    func openPresentation(session target: String) -> ControlResponse {
        resolver.resolveSession(target, window: nil) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session")
            }
            guard session.allPanesBackedByZmx else {
                return ControlResponse(ok: false, error: "session is not live-backed, so nothing can be attached to it")
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Takes over a connection whose `zmx.present` was just answered ok. Returns at once; the owner's
    /// threads do the I/O from here.
    func adoptPresentationStream(descriptor: Int32, session: UUID) {
        let owner = ControlStreamOwner(descriptor: descriptor, limits: Self.presentationLimits)
        let stream = PresentationStream(session: session, owner: owner, server: self)
        presentationStreams.append(stream)
        attachPresentationHub()
        startPresentationHeartbeat()
        // reads carry no idle timeout, and the hub's heartbeat only knows subscribers, so a peer that takes
        // the reply and then says nothing would otherwise hold two threads and a descriptor for good
        let deadline = presentationHelloDeadline
        Task { @MainActor [weak stream] in
            try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
            guard let stream, !stream.subscribed else { return }
            presentationLogger.notice("closing a presentation stream that sent no hello")
            stream.shutdown()
        }
        let inbound = DispatchSemaphore(value: Self.presentationInboundLimit)
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

    func subscribePresentation(_ stream: PresentationStream, hello: PresentationHello) throws
        -> PresentationHub.SubscriberID {
        let id = stream.session
        let library = library
        let clock = hudClock
        return try presentationHub.subscribe(session: id, hello: hello, sink: stream) {
            library.store(forSession: id)?.presentationSnapshot(forSession: id, now: clock())
                ?? PresentationSnapshot(status: nil, hud: nil)
        }
    }

    /// Points every open store at the hub. Stores are created by the window library, which this file cannot
    /// reach into, so the server assigns wherever it already walks the open windows.
    func attachPresentationHub() {
        for entry in library.windows {
            library.store(for: entry.id)?.presentationHub = presentationHub
        }
        dropOrphanedPresentationStreams()
    }

    func presentationSourceExists(_ session: UUID) -> Bool {
        library.store(forSession: session)?.session(withID: session) != nil
    }

    /// Ends the streams of sessions that are no longer in any open window. A viewer would otherwise keep
    /// the last mirrored state for good, on a stream that still answers pings.
    func dropOrphanedPresentationStreams() {
        for stream in presentationStreams where !presentationSourceExists(stream.session) {
            presentationLogger.notice("closing a presentation stream whose session is gone")
            stream.shutdown()
        }
    }

    func shutdownPresentationStreams() {
        for stream in presentationStreams { stream.shutdown() }
        presentationHeartbeat?.cancel()
        presentationHeartbeat = nil
    }

    private func startPresentationHeartbeat() {
        guard presentationHeartbeat == nil else { return }
        presentationHeartbeat = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.presentationHeartbeatSeconds * 1_000_000_000)
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
