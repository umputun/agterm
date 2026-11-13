import Foundation
import agtermCore

private let catalogLog = CoreLog(category: "ServerCatalog")

/// CatalogStream is one viewer's catalog stream: the hub's sink on one side, a `ControlStreamOwner` on the other.
/// The viewer speaks first; its hello subscribes it.
@MainActor
final class CatalogStream: CatalogSink {
    static let limits = ControlStreamOwner.Limits(maxLineBytes: CatalogCodec.maxFrameBytes,
                                                  maxPendingLines: PresentationCodec.maxPendingFrames, writeTimeoutSeconds: 5)
    static let heartbeatSeconds: UInt64 = 10

    private let owner: ControlStreamOwner
    private weak var streams: ServerStreams?
    private(set) var subscriber: CatalogHub.SubscriberID?

    init(owner: ControlStreamOwner, streams: ServerStreams) {
        self.owner = owner
        self.streams = streams
    }

    func offer(_ frame: CatalogFrame) -> Bool {
        do {
            return owner.send(try CatalogCodec.encode(frame))
        } catch {
            catalogLog.error("closing a catalog stream on an unsendable frame: \(error)")
            return false
        }
    }

    func close(_ reason: CatalogHub.CloseReason) {
        catalogLog.notice("closing a catalog stream: \(reason)")
        owner.shutdown()
    }

    func shutdown() { owner.shutdown() }

    func receive(_ line: Data) {
        guard let streams else { return }
        let frame: CatalogFrame
        do {
            frame = try CatalogCodec.decode(line)
        } catch {
            catalogLog.error("closing a catalog stream on a bad frame: \(error)")
            owner.shutdown()
            return
        }
        if let subscriber {
            streams.catalogHub.receive(frame, from: subscriber)
            return
        }
        guard case .hello(let hello) = frame else {
            catalogLog.error("closing a catalog stream that did not open with hello")
            owner.shutdown()
            return
        }
        do {
            subscriber = try streams.catalogHub.subscribe(hello: hello, sink: self, versions: streams.catalogVersions)
        } catch {
            catalogLog.error("refusing a catalog stream: \(error)")
            owner.shutdown()
        }
    }

    func closed() {
        if let subscriber { streams?.catalogHub.unsubscribe(subscriber) }
        subscriber = nil
        streams?.catalogStreams.removeAll { $0 === self }
    }
}

extension ServerStreams {
    /// adoptCatalogStream takes over a connection whose `catalog.subscribe` was just answered ok.
    func adoptCatalogStream(descriptor: Int32) {
        let owner = ControlStreamOwner(descriptor: descriptor, limits: CatalogStream.limits)
        let stream = CatalogStream(owner: owner, streams: self)
        catalogStreams.append(stream)
        startCatalogHeartbeat()
        let deadline = presentationHelloDeadline
        Task { @MainActor [weak stream] in
            try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
            guard let stream, stream.subscriber == nil else { return }
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
                self.catalogHub.heartbeat()
            }
        }
    }

    func shutdownCatalogStreams() {
        for stream in catalogStreams { stream.shutdown() }
        catalogHeartbeat?.cancel()
        catalogHeartbeat = nil
    }
}

extension ServerActions {
    public func catalogSubscribe() -> ControlResponse { ControlResponse(ok: true) }

    /// catalogVersions is what this server advertises on `version` and in every catalog snapshot.
    var catalogVersions: CatalogVersions {
        CatalogVersions(server: identity.version, protocolVersion: PresentationCodec.version, catalog: CatalogCodec.version)
    }

    /// catalogWorkspaces is the headless store as the catalog: workspaces and sessions in order, each live session
    /// with its left pane and, while it has a split, its right one. An ended session and a page row list no pane.
    func catalogWorkspaces() -> [CatalogWorkspace] {
        let endpoint = ControlZmxEndpoint(executable: panes.configuration.zmxPath,
                                          socketDirectory: panes.configuration.zmxSocketDirectory)
        return store.workspaces.map { workspace in
            CatalogWorkspace(id: workspace.id, name: workspace.name, sessions: workspace.sessions.map { session in
                var identities = [session.paneIdentity]
                if session.hasSplit, let split = session.splitPaneIdentity { identities.append(split) }
                let panes = session.ended || session.content == .page ? [] : identities.map {
                    CatalogPane(identity: $0, daemon: ZmxSupport.daemonName(for: $0), endpoint: endpoint)
                }
                let scratch = session.scratchDaemon.map {
                    CatalogScratch(pane: CatalogPane(identity: $0.identity, daemon: ZmxSupport.scratchDaemonName(for: $0.identity),
                                                     endpoint: endpoint), shown: $0.shown)
                }
                let page = session.content == .page ? session.htmlOverlay.map { overlay in
                    CatalogPage(kind: { if case .url = overlay.source { "url" } else { "file" } }(), identity: overlay.identity,
                                endpoint: endpoint)
                } : nil
                let fields = CatalogSessionFields(id: session.id, name: session.displayName, parent: session.parentID,
                                                  cwd: session.effectiveCwd, primary: page == nil ? session.paneIdentity : session.id,
                                                  axis: session.hasSplit ? session.splitAxis.rawValue : nil,
                                                  shown: session.hasSplit && session.isSplit,
                                                  lifecycle: session.ended ? .ended : .live, scratch: scratch, page: page,
                                                  customName: session.customName ?? "")
                return CatalogSession(fields: fields, panes: panes)
            })
        }
    }
}
