import Foundation

private let catalogLog = CoreLog(category: "CatalogStream")

/// CatalogSubscription is a host's answer to a viewer's hello: the hub and versions serving it, or why not.
public enum CatalogSubscription {
    case serve(CatalogHub, CatalogVersions)
    /// refuse sends the reason as the stream's last frame; a final refusal stops the viewer's retries.
    case refuse(reason: String, final: Bool)
}

/// CatalogStreamHost serves catalog streams: agterm-server's one catalog, or a Mac's windows. Adoption,
/// subscription and the heartbeat are shared through this protocol's extension.
@MainActor
public protocol CatalogStreamHost: AnyObject {
    var catalogStreams: [CatalogStream] { get set }
    var catalogHeartbeat: Task<Void, Never>? { get set }
    /// catalogHelloDeadline is how long a stream may go without its hello before it is closed.
    var catalogHelloDeadline: TimeInterval { get }
    var catalogHubs: [CatalogHub] { get }
    func catalogSubscription(for hello: CatalogHello) -> CatalogSubscription
}

/// CatalogStream is one viewer's catalog stream: a hub's sink on one side, a `ControlStreamOwner` on the other.
/// The viewer speaks first; its hello subscribes it to the hub the host picks.
@MainActor
public final class CatalogStream: CatalogSink {
    static let limits = ControlStreamOwner.Limits(maxLineBytes: CatalogCodec.maxFrameBytes,
                                                  maxPendingLines: PresentationCodec.maxPendingFrames, writeTimeoutSeconds: 5)
    static let heartbeatSeconds: UInt64 = 10

    private let owner: ControlStreamOwner
    private weak var host: (any CatalogStreamHost)?
    private var hub: CatalogHub?
    private var subscriber: CatalogHub.SubscriberID?

    init(owner: ControlStreamOwner, host: any CatalogStreamHost) {
        self.owner = owner
        self.host = host
    }

    public var subscribed: Bool { subscriber != nil }

    public func offer(_ frame: CatalogFrame) -> Bool {
        do {
            return owner.send(try CatalogCodec.encode(frame))
        } catch {
            catalogLog.error("closing a catalog stream on an unsendable frame: \(error)")
            return false
        }
    }

    public func close(_ reason: CatalogHub.CloseReason) {
        catalogLog.notice("closing a catalog stream: \(reason)")
        owner.shutdown()
    }

    public func shutdown() { owner.shutdown() }

    func receive(_ line: Data) {
        guard let host else { return }
        let frame: CatalogFrame
        do {
            frame = try CatalogCodec.decode(line)
        } catch {
            catalogLog.error("closing a catalog stream on a bad frame: \(error)")
            owner.shutdown()
            return
        }
        if let hub, let subscriber {
            hub.receive(frame, from: subscriber)
            return
        }
        guard case .hello(let hello) = frame else {
            catalogLog.error("closing a catalog stream that did not open with hello")
            owner.shutdown()
            return
        }
        switch host.catalogSubscription(for: hello) {
        case .serve(let hub, let versions):
            do {
                subscriber = try hub.subscribe(hello: hello, sink: self, versions: versions)
                self.hub = hub
            } catch {
                catalogLog.error("refusing a catalog stream: \(error)")
                owner.shutdown()
            }
        case .refuse(let reason, let final):
            catalogLog.notice("refusing a catalog stream: \(reason)")
            guard let line = try? CatalogCodec.encode(.refused(reason: reason, final: final)), owner.sendFinal(line) else {
                owner.shutdown()
                return
            }
        }
    }

    func closed() {
        if let hub, let subscriber { hub.unsubscribe(subscriber) }
        subscriber = nil
        hub = nil
        host?.catalogStreams.removeAll { $0 === self }
    }
}

extension CatalogStreamHost {
    /// adoptCatalogStream takes over a connection whose `catalog.subscribe` was just answered ok.
    public func adoptCatalogStream(descriptor: Int32) {
        let owner = ControlStreamOwner(descriptor: descriptor, limits: CatalogStream.limits)
        let stream = CatalogStream(owner: owner, host: self)
        catalogStreams.append(stream)
        startCatalogHeartbeat()
        // reads carry no idle timeout, so a peer that takes the reply and says nothing would hold the connection
        let deadline = catalogHelloDeadline
        Task { @MainActor [weak stream] in
            try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
            guard let stream, !stream.subscribed else { return }
            catalogLog.notice("closing a catalog stream that sent no hello")
            stream.shutdown()
        }
        let inbound = DispatchSemaphore(value: 64)
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

    /// beatCatalogStreams drops each hub's stale subscribers and pings the rest.
    public func beatCatalogStreams() {
        for hub in catalogHubs { hub.heartbeat() }
    }

    public func shutdownCatalogStreams() {
        for stream in catalogStreams { stream.shutdown() }
        catalogHeartbeat?.cancel()
        catalogHeartbeat = nil
    }

    private func startCatalogHeartbeat() {
        guard catalogHeartbeat == nil else { return }
        catalogHeartbeat = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: CatalogStream.heartbeatSeconds * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard !self.catalogStreams.isEmpty else {
                    self.catalogHeartbeat = nil
                    return
                }
                self.beatCatalogStreams()
            }
        }
    }
}
