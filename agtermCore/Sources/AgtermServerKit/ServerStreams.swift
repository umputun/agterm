import Foundation
import agtermCore

/// ServerStreams is agterm-server's side of the streams a presenting Mac opens: its presentation subscriptions,
/// overlay job helpers and page channels, through the engines the Mac's control server shares.
@MainActor
final class ServerStreams: PresentationStreamHost, OverlayJobStreamHost, PageServeHost {
    let store: AppStore
    let catalogID: UUID
    let presentationHub = PresentationHub(staleTimeout: 30)
    let overlayJobs = OverlayJobs()
    var presentationStreams: [PresentationStream] = []
    var presentationHeartbeat: Task<Void, Never>?
    var presentationHelloDeadline: TimeInterval = 10
    var overlayJobStreams: [String: OverlayJobStream] = [:]
    var pendingJobCancels: Set<String> = []
    var pageServeStreams: [UUID: PageServeStream] = [:]
    var pendingPageClaims: [UUID: PageServeClaim] = [:]
    /// originEpoch names this server run in respawn counts, so a viewer never reads a restarted counter as older.
    let originEpoch = UUID().uuidString
    private var respawnGenerations: [UUID: [String: Int]] = [:]
    /// dispatch runs a page's bridge request through the server's own dispatcher.
    var dispatch: ((ControlRequest) async -> ControlResponse)?

    init(store: AppStore, catalogID: UUID) {
        self.store = store
        self.catalogID = catalogID
        store.presentationHub = presentationHub
        store.overlayJobs = overlayJobs
        presentationHub.onPresenterLost = { [weak self] session in self?.presenterLost(session) }
        presentationHub.onPresenterFrame = { [weak self] session, body in self?.receivePresenterFrame(body, forSession: session) }
        RemotePageEnds.shared.onEnd = { [weak self] page in self?.pageServeStreams[page]?.shutdown() }
        overlayJobs.onFinished = { [weak self] job in
            self?.pendingJobCancels.remove(job.id)
            self?.store.finishRemoteOverlay(job)
        }
    }

    // MARK: presentation

    func presentationSourceExists(_ session: UUID) -> Bool { store.session(withID: session) != nil }

    func presentationSnapshot(forSession id: UUID) -> PresentationSnapshot {
        var snapshot = store.presentationSnapshot(forSession: id, now: Date())
        snapshot.respawns = PresentationRespawns(epoch: originEpoch, generations: respawnGenerations[id] ?? [:])
        return snapshot
    }

    func prepareForPresentationStream() {}

    /// noteRespawn publishes that `daemon` runs a fresh shell for `session`, which carries its viewers across.
    func noteRespawn(session: UUID, daemon: String) {
        var counts = respawnGenerations[session] ?? [:]
        let generation = (counts[daemon] ?? 0) + 1
        counts[daemon] = generation
        respawnGenerations[session] = counts
        presentationHub.publish(.respawn(PresentationRespawns(epoch: originEpoch, generations: [daemon: generation])),
                                session: session)
    }

    // a headless origin has nowhere to draw what its presenter dropped: an ask or pick ends cancelled, and the
    // overlays it held end as they do on the Mac
    private func presenterLost(_ session: UUID) {
        if store.session(withID: session)?.askPresentedRemotely == true { store.failHandback(forSession: session) }
        SessionPickBook.shared.handBack(session: session, refused: nil, to: nil, window: catalogID)
        store.remoteOverlayPresenterLost(forSession: session)
    }

    func receivePresenterFrame(_ body: PresentationFrame.Body, forSession sessionID: UUID) {
        switch body {
        case .askResolve(let answer):
            store.resolveRemoteAsk(answer, forSession: sessionID)
        case .askRejected(let ref) where store.isPresentingRemotely(ref, forSession: sessionID):
            store.failHandback(forSession: sessionID)
        case .pickResolve(let answer):
            SessionPickBook.shared.resolveRemote(answer, session: sessionID)
        case .pickRejected(let ref):
            SessionPickBook.shared.handBack(session: sessionID, refused: ref, to: nil, window: catalogID)
        case .overlayRejected(let change):
            store.rejectRemoteOverlay(change.job, forSession: sessionID)
        case .overlayClosed(let change):
            store.remoteOverlaySurfaceClosed(change.job, forSession: sessionID)
        case .pageState, .pageClosed, .pageRejected:
            store.receiveRemotePageFrame(body, forSession: sessionID)
        default:
            break
        }
    }

    // MARK: pages

    func claimRemotePage(token: String) -> (page: UUID, served: PageServeClaim)? {
        store.claimRemotePage(token: token).map { ($0.overlay.id, PageServeClaim(source: $0.overlay.source, links: $0.overlay.markdownLinks)) }
    }

    func remotePagePlace(_ page: UUID) -> (session: UUID, pane: OverlayPane?, window: UUID?)? {
        for session in store.workspaces.flatMap(\.sessions) {
            guard let slot = session.remoteOverlays.slot(job: page.uuidString), slot.page != nil,
                  presentationHub.presenterGeneration(session: session.id) == slot.owner,
                  presentationHub.hasPresenter(session: session.id) else { continue }
            return (session.id, slot.pane, catalogID)
        }
        return nil
    }

    func endRemotePage(_ page: UUID) {
        for session in store.workspaces.flatMap(\.sessions) {
            guard let slot = session.remoteOverlays.slot(job: page.uuidString) else { continue }
            store.closeRemoteOverlay(session.id, pane: slot.pane)
            return
        }
    }

    func dispatchPageBridge(_ request: ControlRequest) async -> ControlResponse? {
        await dispatch?(request)
    }

    nonisolated static func pageMimeType(_ path: String) -> String {
        mimeTypes[(path as NSString).pathExtension.lowercased()] ?? "application/octet-stream"
    }

    private nonisolated static let mimeTypes = [
        "html": "text/html", "htm": "text/html", "css": "text/css", "js": "text/javascript", "mjs": "text/javascript",
        "json": "application/json", "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg",
        "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp", "ico": "image/x-icon", "txt": "text/plain",
        "md": "text/markdown", "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf",
        "wasm": "application/wasm", "xml": "application/xml", "pdf": "application/pdf", "mp4": "video/mp4",
        "webm": "video/webm", "mp3": "audio/mpeg", "wav": "audio/wav",
    ]

    /// schedulePageClaimExpiry ends every channel page whose channel was not claimed in time, once `seconds` passed.
    func schedulePageClaimExpiry(after seconds: TimeInterval) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((seconds + 0.1) * 1_000_000_000))
            self?.store.expireRemotePageClaims()
        }
    }

    // MARK: adoption

    /// adopt takes a streaming command's connection once its reply is written; false leaves the descriptor to the
    /// socket to close. A job or page whose ok reply never reached its helper is given up here.
    func adopt(_ conn: Int32, request: ControlRequest, response: ControlResponse, written: Bool) -> Bool {
        switch request.cmd {
        case .zmxPresent:
            guard written, response.ok, let session = response.result?.id.flatMap(UUID.init(uuidString:)) else { return false }
            adoptPresentationStream(descriptor: conn, session: session)
        case .sessionOverlayJobRun:
            guard response.ok, let job = response.result?.id else { return false }
            guard written else {
                overlayJobs.helperGone(job)
                return false
            }
            adoptOverlayJobStream(descriptor: conn, job: job)
        case .sessionOverlayPageServe:
            guard response.ok, let page = response.result?.id.flatMap(UUID.init(uuidString:)) else { return false }
            guard written else {
                pageClaimUnanswered(page)
                return false
            }
            adoptPageServeStream(descriptor: conn, page: page)
        default:
            return false
        }
        return true
    }

    func shutdown() {
        shutdownPresentationStreams()
        for stream in overlayJobStreams.values { stream.shutdown() }
        for stream in pageServeStreams.values { stream.shutdown() }
    }
}
