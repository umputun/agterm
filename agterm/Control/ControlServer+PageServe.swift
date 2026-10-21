import Foundation
import UniformTypeIdentifiers
import os
import agtermCore

private let pageLogger = Logger(subsystem: "com.umputun.agterm", category: "PageServe")

/// PageServeAdmission counts one kind of request a page channel has taken in and not finished. It never
/// blocks: a request past the limit is refused, so the reader keeps reading cancels and EOF behind it.
final class PageServeAdmission: Sendable {
    private let limit: Int
    private let taken = OSAllocatedUnfairLock(initialState: 0)

    init(limit: Int) { self.limit = limit }

    /// tryAcquire takes a slot, false when all are taken.
    func tryAcquire() -> Bool {
        taken.withLock { count in
            guard count < limit else { return false }
            count += 1
            return true
        }
    }

    func release() {
        taken.withLock { $0 -= 1 }
    }
}

/// PageServeStream is the channel a presenter's helper opened for one page this Mac handed over. It serves the
/// page's files from inside its grant and runs the page's bridge requests here, as a local page's would run.
/// The helper's connection closing, or sending what a helper never sends, ends the page; the presenter
/// subscription is not touched.
@MainActor
final class PageServeStream {
    private struct Transfers {
        var active: Set<Int> = []
        var cancelled: Set<Int> = []
    }

    let page: UUID
    let resourceSlots = PageServeAdmission(limit: ControlServer.pageServeResourceLimit)
    let bridgeSlots = PageServeAdmission(limit: ControlServer.pageServeBridgeLimit)
    private let source: HtmlSource
    private let owner: ControlStreamOwner
    private weak var server: ControlServer?
    // bridge calls have their own slots and queue, so they wait behind at most the chunks already queued for
    // the writer, never behind a whole file
    private let files = DispatchQueue(label: "com.umputun.agterm.pageserve.files")
    private let replies = DispatchQueue(label: "com.umputun.agterm.pageserve.replies")
    private let transfers = OSAllocatedUnfairLock(initialState: Transfers())
    private var ending = false

    init(page: UUID, source: HtmlSource, owner: ControlStreamOwner, server: ControlServer) {
        self.page = page
        self.source = source
        self.owner = owner
        self.server = server
    }

    /// take handles one line on the reader thread: a cancel applies at once, a request takes a slot of its
    /// kind and runs on the main actor or is refused at once by id, and anything else ends the page. Nothing
    /// here waits, so cancels and EOF behind a request are always read.
    nonisolated func take(_ line: Data) {
        guard let frame = try? PageServeCodec.decode(line) else { return failOnMain("a malformed frame") }
        switch frame {
        case .cancel(let id):
            transfers.withLock { if $0.active.contains(id) { $0.cancelled.insert(id) } }
        case .resource(let id, _):
            guard resourceSlots.tryAcquire() else { return refuse(id) }
            transfers.withLock { _ = $0.active.insert(id) }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.receive(frame) } }
        case .bridge(let id, _):
            guard bridgeSlots.tryAcquire() else { return refuse(id) }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.receive(frame) } }
        case .head, .chunk, .end, .failure, .reply:
            failOnMain("a frame only this Mac sends")
        }
    }

    /// receive runs one admitted request; its slot is released once its last frame is queued for the writer.
    func receive(_ frame: PageServeFrame) {
        switch frame {
        case .resource(let id, let path): serve(id: id, path: path)
        case .bridge(let id, let request): relay(id: id, request: request)
        case .cancel, .head, .chunk, .end, .failure, .reply: break
        }
    }

    /// shutdown closes the channel without ending the page, which the caller already did or is doing.
    func shutdown() {
        ending = true
        owner.shutdown()
    }

    // a peer past the limit while the writer queue is full is not reading what it asked for, so the page ends
    // rather than the reader waiting or the refusals queueing without bound
    private nonisolated func refuse(_ id: Int) {
        guard let line = try? PageServeCodec.encode(.failure(id: id, error: PageServeFrame.busy)), owner.send(line) else {
            return failOnMain("more requests than it reads answers to")
        }
    }

    func closed() {
        if server?.pageServeStreams[page] === self { server?.pageServeStreams[page] = nil }
        guard !ending else { return }
        server?.endRemotePage(page)
    }

    private nonisolated func failOnMain(_ reason: String) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.fail(reason) } }
    }

    private func fail(_ reason: String) {
        guard !ending else { return }
        pageLogger.error("ending a page whose channel sent \(reason, privacy: .public)")
        ending = true
        server?.endRemotePage(page)
        shutdown()
    }

    private func serve(id: Int, path: String) {
        let owner = owner, source = source, transfers = transfers, slots = resourceSlots
        files.async {
            Self.transfer(id: id, path: path, source: source, owner: owner, transfers: transfers)
            transfers.withLock {
                $0.active.remove(id)
                $0.cancelled.remove(id)
            }
            slots.release()
        }
    }

    // every admitted transfer ends in exactly one terminal frame, a cancelled one too, so the viewer frees its
    // request slot only when this side has
    nonisolated private static func transfer(id: Int, path: String, source: HtmlSource, owner: ControlStreamOwner,
                                             transfers: OSAllocatedUnfairLock<Transfers>) {
        let cancelled = { transfers.withLock { $0.cancelled.contains(id) } }
        let stop = { _ = sendWaiting(.failure(id: id, error: PageServeFrame.cancelled), owner) }
        guard !cancelled() else { return stop() }
        guard let file = RemotePageResources.resolve(path, source: source) else {
            _ = sendWaiting(.failure(id: id, error: "file is outside the page's folder"), owner)
            return
        }
        guard let handle = FileHandle(forReadingAtPath: file) else {
            _ = sendWaiting(.failure(id: id, error: "file cannot be read"), owner)
            return
        }
        defer { try? handle.close() }
        guard sendWaiting(.head(id: id, mimeType: mimeType(file)), owner) else { return }
        while !cancelled() {
            let data: Data?
            do {
                data = try handle.read(upToCount: PageServeCodec.maxChunkBytes)
            } catch {
                _ = sendWaiting(.failure(id: id, error: "file cannot be read"), owner)
                return
            }
            guard let data, !data.isEmpty else {
                _ = sendWaiting(.end(id: id), owner)
                return
            }
            guard sendWaiting(.chunk(id: id, data: data), owner) else { return }
        }
        stop()
    }

    private func relay(id: Int, request: String) {
        Task {
            let frame = await answer(id: id, request: request)
            let owner = owner, slots = bridgeSlots
            replies.async {
                _ = Self.sendWaiting(frame, owner)
                slots.release()
            }
        }
    }

    /// answer resolves the page where it sits now and dispatches in the same main-actor turn, so a request
    /// queued before its page closed or moved never runs against the old place.
    private func answer(id: Int, request: String) async -> PageServeFrame {
        guard let server, let place = server.remotePagePlace(page) else { return .failure(id: id, error: "page closed") }
        let origin = HtmlBridgePage(window: place.window?.uuidString, session: place.session, pane: place.pane)
        let built: ControlRequest
        switch HtmlBridge.request(from: Data(request.utf8), page: origin) {
        case .success(let value): built = value
        case .failure(let refusal): return .failure(id: id, error: refusal.message)
        }
        guard let dispatch = HtmlOverlayRegistry.shared.dispatch else {
            return .failure(id: id, error: "control is unavailable")
        }
        let response = await dispatch(built)
        guard let encoded = try? JSONEncoder().encode(response) else {
            return .failure(id: id, error: "reply could not be encoded")
        }
        return .reply(id: id, response: String(decoding: encoded, as: UTF8.self))
    }

    nonisolated private static func sendWaiting(_ frame: PageServeFrame, _ owner: ControlStreamOwner) -> Bool {
        do {
            return owner.sendWaiting(try PageServeCodec.encode(frame))
        } catch {
            // a reply too large for one line goes back as a failure, so the page learns why and the channel stays
            guard let line = try? PageServeCodec.encode(.failure(id: frame.id, error: "answer too large for the channel"))
            else { return false }
            return owner.sendWaiting(line)
        }
    }

    nonisolated private static func mimeType(_ path: String) -> String {
        UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}

extension ControlServer {
    static let pageServeLimits = ControlStreamOwner.Limits(maxLineBytes: PageServeCodec.maxFrameBytes,
                                                           maxPendingLines: 8, writeTimeoutSeconds: 5)
    static let pageServeResourceLimit = 8
    static let pageServeBridgeLimit = 8

    private var openStores: [AppStore] { library.openIDs().compactMap { library.store(for: $0) } }

    /// claimPageServe answers `session.overlay.page.serve`: an ok answer is the token's one admitted claim, and the connection
    /// is then adopted as that page's channel.
    func claimPageServe(_ token: String) -> ControlResponse {
        for store in openStores {
            guard let claim = store.claimRemotePage(token: token) else { continue }
            pendingPageClaims[claim.overlay.id] = claim.overlay.source
            return ControlResponse(ok: true, result: ControlResult(id: claim.overlay.id.uuidString))
        }
        return ControlResponse(ok: false, error: "page not claimable")
    }

    /// adoptPageServeStream takes over the connection of a page whose claim was just answered ok.
    func adoptPageServeStream(descriptor: Int32, page: UUID) {
        let owner = ControlStreamOwner(descriptor: descriptor, limits: Self.pageServeLimits)
        // a page that ended between its claim and this adoption gets no channel
        guard let source = pendingPageClaims.removeValue(forKey: page), remotePagePlace(page) != nil else {
            owner.start(onLine: { _ in }, onClose: {})
            owner.shutdown()
            return
        }
        let stream = PageServeStream(page: page, source: source, owner: owner, server: self)
        pageServeStreams[page] = stream
        owner.start(
            onLine: { [weak stream] line in stream?.take(Data(line)) },
            onClose: { [weak stream] in
                DispatchQueue.main.async { MainActor.assumeIsolated { stream?.closed() } }
            }
        )
    }

    /// pageClaimUnanswered ends a page whose claim reply never reached the helper, which leaves nobody to load it.
    func pageClaimUnanswered(_ page: UUID) {
        pendingPageClaims[page] = nil
        endRemotePage(page)
    }

    /// endRemotePage ends page `page` wherever its reservation sits, which also tells the presenter.
    func endRemotePage(_ page: UUID) {
        for store in openStores {
            for session in store.workspaces.flatMap(\.sessions) {
                guard let slot = session.remoteOverlays.slot(job: page.uuidString) else { continue }
                store.closeRemoteOverlay(session.id, pane: slot.pane)
                return
            }
        }
    }

    /// remotePagePlace finds where page `page` is reserved now, nil once it ended or its presenter changed: a swap
    /// moves the slot, and a new presenter generation means the page belongs to a stream that is gone.
    func remotePagePlace(_ page: UUID) -> (session: UUID, pane: OverlayPane?, window: UUID?)? {
        for store in openStores {
            for session in store.workspaces.flatMap(\.sessions) {
                guard let slot = session.remoteOverlays.slot(job: page.uuidString), slot.page != nil,
                      presentationHub.presenterGeneration(session: session.id) == slot.owner,
                      presentationHub.hasPresenter(session: session.id) else { continue }
                return (session.id, slot.pane, library.windowID(for: store))
            }
        }
        return nil
    }

    /// receiveRemotePageFrame hands what a presenter reported about a page to its store, logging why a page was
    /// refused, since the open was already answered ok and the reason surfaces nowhere else.
    func receiveRemotePageFrame(_ body: PresentationFrame.Body, in store: AppStore, forSession sessionID: UUID) {
        if case .pageRejected(let change) = body {
            pageLogger.notice("presenter refused page \(change.page, privacy: .public): \(change.reason ?? "no reason", privacy: .public)")
        }
        store.receiveRemotePageFrame(body, forSession: sessionID)
    }

    /// schedulePageClaimExpiry ends every file page whose channel was not claimed in time, once `seconds` passed.
    func schedulePageClaimExpiry(after seconds: TimeInterval) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((seconds + 0.1) * 1_000_000_000))
            guard let self else { return }
            for store in openStores { store.expireRemotePageClaims() }
        }
    }
}
