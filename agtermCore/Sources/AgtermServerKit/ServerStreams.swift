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
    var pendingPageClaims: [String: PendingPageClaim] = [:]
    /// originEpoch names this server run in respawn counts, so a viewer never reads a restarted counter as older.
    let originEpoch = UUID().uuidString
    private var respawnGenerations: [UUID: [String: Int]] = [:]
    /// now is the clock pending deadlines are checked against at an offer or an answer.
    var now: @MainActor () -> Date = Date.init
    /// checkPage reads a file page's file before it is handed over; a click runs it off the main actor.
    var checkPage: @Sendable (HtmlSource, ControlSessionOverlayOpenOptions)
        -> Result<ControlSessionOverlayOpenOptions, ServerActions.PageCheckFailure> = ServerActions.checkedPage
    /// dispatch runs a page's bridge request through the server's own dispatcher.
    var dispatch: ((ControlRequest) async -> ControlResponse)?
    var catalogStreams: [CatalogStream] = []
    var catalogHeartbeat: Task<Void, Never>?
    /// catalogWorkspaces projects the store's workspaces into the catalog.
    var catalogWorkspaces: @MainActor () -> [CatalogWorkspace] = { [] }
    var catalogVersions = CatalogVersions(server: "", protocolVersion: PresentationCodec.version, catalog: CatalogCodec.version)
    /// catalogHub numbers the catalog in this run's epoch, the same one respawn counts carry.
    lazy var catalogHub = CatalogHub(epoch: originEpoch, staleTimeout: 30) { [unowned self] in
        CatalogSnapshot(epoch: "", rev: 0, catalogID: catalogID, versions: catalogVersions, workspaces: catalogWorkspaces())
    }

    init(store: AppStore, catalogID: UUID) {
        self.store = store
        self.catalogID = catalogID
        store.presentationHub = presentationHub
        store.overlayJobs = overlayJobs
        presentationHub.onPresenterLost = { [weak self] session in self?.presenterLost(session) }
        presentationHub.onPresenterGranted = { [weak self] session in self?.presenterGranted(session) }
        presentationHub.onPresenterFrame = { [weak self] session, body in self?.receivePresenterFrame(body, forSession: session) }
        RemotePageEnds.shared.onEnd = { [weak self] page in self?.pageServeStreams[page]?.shutdown() }
        RemotePageEnds.shared.onWithdrawn = { [weak self] page in
            self?.pendingPageClaims = self?.pendingPageClaims.filter { $0.value.page != page } ?? [:]
            self?.pageServeStreams.removeValue(forKey: page)?.shutdown()
        }
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

    // a headless origin has nowhere to draw what its presenter dropped: an ask, pick, page or unclaimed job waits for
    // the next presenter, and a claimed or running job keeps its slot until its helper reports
    private func presenterLost(_ session: UUID) {
        store.returnAskToPending(forSession: session)
        SessionPickBook.shared.returnToPending(session: session)
        store.remoteOverlayPresenterLost(forSession: session)
    }

    // pending work goes only to a presenter that takes it and its job tokens; an older one sees only what opens
    // while it holds the session
    private func presenterGranted(_ session: UUID) {
        guard presentationHub.presenterSupports(PresentationHub.pendingSnapshotKind, session: session),
              presentationHub.presenterSupports(PresentationHub.jobTokenKind, session: session) else { return }
        presentationHub.batchToPresenter(session: session) { store.offerPendingInteractions(forSession: session, now: now()) }
        scheduleOverlayJobExpiry(after: OverlayJobs.launchWindow)
        schedulePageClaimExpiry(after: AppStore.pageClaimWindow)
    }

    func receivePresenterFrame(_ body: PresentationFrame.Body, forSession sessionID: UUID) {
        switch body {
        case .askResolve(let answer):
            // an answer past the deadline ends the ask instead, whether or not its expiry ran yet
            guard !store.expireInteraction(answer.id, now: now()) else { return }
            store.resolveRemoteAsk(answer, forSession: sessionID)
        case .askRejected(let ref) where store.isPresentingRemotely(ref, forSession: sessionID):
            store.returnAskToPending(forSession: sessionID)
        case .pickResolve(let answer):
            guard !store.expireInteraction(answer.id, now: now()) else { return }
            SessionPickBook.shared.resolveRemote(answer, session: sessionID)
        case .pickRejected(let ref):
            SessionPickBook.shared.returnToPending(session: sessionID, refused: ref)
        case .overlayRejected(let change):
            store.rejectRemoteOverlay(change.job, forSession: sessionID)
        case .overlayClosed(let change):
            store.remoteOverlaySurfaceClosed(change.job, forSession: sessionID)
        case .pageState, .pageClosed, .pageRejected:
            store.receiveRemotePageFrame(body, forSession: sessionID)
        case .linkClick(let click):
            receiveLinkClick(click, forSession: sessionID)
        default:
            break
        }
    }

    // MARK: pages

    /// handOver gives a checked page to the Mac presenting `session`, or holds it for the next one.
    func handOver(_ overlay: HtmlOverlay, in session: Session, options: ControlSessionOverlayOpenOptions) -> RemotePageOpen {
        let result = store.openRemotePage(session.id, overlay: overlay, options: options)
        if result == .opened, overlay.source.kind != .url { schedulePageClaimExpiry(after: AppStore.pageClaimWindow) }
        return result
    }

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

    func pageChannelLost(_ page: UUID) { store.withdrawRemotePage(page) }

    func isCurrentPageClaim(_ page: UUID, token: String) -> Bool { store.remotePageClaimToken(page) == token }

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
        case .catalogSubscribe:
            guard written, response.ok else { return false }
            adoptCatalogStream(descriptor: conn)
        case .sessionOverlayJobRun:
            guard response.ok, let job = response.result?.id else { return false }
            guard written else {
                overlayJobs.helperGone(job)
                return false
            }
            adoptOverlayJobStream(descriptor: conn, job: job)
        case .sessionOverlayPageServe:
            guard response.ok, let page = response.result?.id.flatMap(UUID.init(uuidString:)), let token = request.target else {
                return false
            }
            guard written else {
                pageClaimUnanswered(page, token: token)
                return false
            }
            adoptPageServeStream(descriptor: conn, page: page, token: token)
        default:
            return false
        }
        return true
    }

    func shutdown() {
        shutdownPresentationStreams()
        shutdownCatalogStreams()
        for stream in overlayJobStreams.values { stream.shutdown() }
        for stream in pageServeStreams.values { stream.shutdown() }
    }
}

// MARK: - forwarded clicks

extension ServerStreams {
    /// receiveLinkClick opens the page a path clicked on the presenting Mac names, the way a Mac origin does: the
    /// path resolves against the pane's directory here, and only page routes open. Every other click is answered
    /// with one refusal to the presenter that sent it; a click whose presenter changed meanwhile is dropped.
    func receiveLinkClick(_ click: PresentationLinkClick, forSession id: UUID) {
        let generation = presentationHub.presenterGeneration(session: id)
        guard let target = store.forwardedClickPane(id, pane: click.pane) else {
            return refuseLinkClick(.paneNotAttached, session: id, generation: generation)
        }
        let origin = LinkPolicy.ClickOrigin.pane(id)
        let candidates = LinkPolicy.locations(for: click.raw, origin: origin, cwd: target.cwd)
        let check = checkPage
        Task { @MainActor [weak self] in
            let (route, present, opening) = await Task.detached(priority: .userInitiated) {
                let exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
                let route = LinkPolicy.resolvedRoute(for: click.raw, candidates: candidates, mode: click.mode, origin: origin,
                                                     exists: exists)
                let present = route.localFile.map { exists($0.path(percentEncoded: false)) } ?? false
                let opening = present ? Self.clickedPage(route).map { ($0.source, check($0.source, $0.options)) } : nil
                return (route, present, opening)
            }.value
            guard let self, presentationHub.presenterGeneration(session: id) == generation else { return }
            // a location nobody found routes as typed, and a relative one then has nothing to open
            if route == .ignore, !candidates.isEmpty { return refuseLinkClick(.notFound, session: id, generation: generation) }
            switch route {
            case .image, .markdown, .text, .document, .reveal:
                guard present else { return refuseLinkClick(.notFound, session: id, generation: generation) }
            default:
                break
            }
            guard let (source, checked) = opening else { return refuseLinkClick(.notAPage, session: id, generation: generation) }
            guard case .success(let options) = checked, let session = store.session(withID: id), !session.hudActive,
                  !session.overlayHidden(nil),
                  handOver(ServerActions.pageOverlay(source, options: options), in: session, options: options) == .opened
            else { return refuseLinkClick(.notOpened, session: id, generation: generation) }
        }
    }

    /// clickedPage is the page a click's route opens, with the options a Mac origin gives a clicked page; nil for a
    /// route that opens none.
    nonisolated static func clickedPage(_ route: LinkPolicy.Route) -> (source: HtmlSource, options: ControlSessionOverlayOpenOptions)? {
        let source: HtmlSource, sizePercent: Int?
        switch route {
        case .image(let url, _): (source, sizePercent) = (.image(path: url.path(percentEncoded: false)), nil)
        case .markdown(let url, _, let percent): (source, sizePercent) = (.markdown(path: url.path(percentEncoded: false)), percent)
        case .text(let link): (source, sizePercent) = (.text(path: link.url.path(percentEncoded: false), line: link.line), link.sizePercent)
        case .document(let url, _, let percent): (source, sizePercent) = (.document(path: url.path(percentEncoded: false)), percent)
        case .reveal, .ignore, .browser, .overlay, .forwardRemote: return nil
        }
        let navigation = if case .markdown = source { true } else { false }
        return (source, ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: sizePercent,
                                                         backgroundColor: nil, page: source, navigation: navigation,
                                                         clicked: true, forwarded: true))
    }

    private func refuseLinkClick(_ reason: RemoteLinkRefusal, session id: UUID, generation: Int) {
        guard presentationHub.presenterGeneration(session: id) == generation else { return }
        presentationHub.sendToPresenter(.linkRefused(PresentationLinkRefusal(reason: reason)), session: id)
    }
}
