import Foundation

private let pageLog = CoreLog(category: "PageServe")

/// PageServeHost serves the pages it handed to a presenter: the Mac's control server and agterm-server. Claiming,
/// adoption and the channel itself are shared through this protocol's extension. An attachment is one more viewer of
/// a page that is not handed over (the Mac's page companion); a host without them keeps the defaults.
@MainActor
public protocol PageServeHost: AnyObject, SendableMetatype {
    /// pageServeStreams are the channels presenters opened for pages handed over, by page id.
    var pageServeStreams: [UUID: PageServeStream] { get set }
    /// pendingPageClaims are claims answered ok whose connection is not adopted yet, by the token that claimed.
    var pendingPageClaims: [String: PendingPageClaim] { get set }
    /// claimRemotePage admits `token` once: the page it names and what that page serves, nil for no such claim.
    func claimRemotePage(token: String) -> (page: UUID, served: PageServeClaim)?
    /// remotePagePlace finds where page `page` is reserved now, nil once it ended or its presenter changed.
    func remotePagePlace(_ page: UUID) -> (session: UUID, pane: OverlayPane?, window: UUID?)?
    /// endRemotePage ends page `page` wherever its reservation sits, which also tells the presenter.
    func endRemotePage(_ page: UUID)
    /// pageChannelLost handles page `page`'s registered channel ending without a close: a Mac ends the page, a headless
    /// origin keeps it for the next presenter.
    func pageChannelLost(_ page: UUID)
    /// isCurrentPageClaim is whether `token` is still the claim page `page` is offered under.
    func isCurrentPageClaim(_ page: UUID, token: String) -> Bool
    /// dispatchPageBridge runs one bridge request as a local page's would run; nil when control is unavailable.
    func dispatchPageBridge(_ request: ControlRequest) async -> ControlResponse?
    /// pageMimeType names a served file's type, read off the main actor.
    nonisolated static func pageMimeType(_ path: String) -> String

    func claimPageAttachment(_ token: String) -> ControlResponse?
    func adoptPageAttachment(descriptor: Int32, claim: UUID) -> Bool
    func dropPageAttachmentClaim(_ claim: UUID) -> Bool
    func pageAttachmentPlace(_ attachment: PageServeStream.Attachment, page: UUID) -> (session: UUID, pane: OverlayPane?, window: UUID?)?
    func pageAttachmentClosed(_ attachment: PageServeStream.Attachment)
}

/// PendingPageClaim is a page channel claim answered ok, waiting for its connection.
public struct PendingPageClaim: Sendable {
    public let page: UUID
    public let served: PageServeClaim
}

extension PageServeHost {
    public func pageChannelLost(_ page: UUID) { endRemotePage(page) }
    public func isCurrentPageClaim(_: UUID, token _: String) -> Bool { true }
    public func claimPageAttachment(_ token: String) -> ControlResponse? { nil }
    public func adoptPageAttachment(descriptor: Int32, claim: UUID) -> Bool { false }
    public func dropPageAttachmentClaim(_ claim: UUID) -> Bool { false }
    public func pageAttachmentPlace(_ attachment: PageServeStream.Attachment, page: UUID) -> (session: UUID, pane: OverlayPane?, window: UUID?)? {
        nil
    }
    public func pageAttachmentClosed(_ attachment: PageServeStream.Attachment) {}
}

/// PageServeAdmission counts one kind of request a page channel has taken in and not finished. It never
/// blocks: a request past the limit is refused, so the reader keeps reading cancels and EOF behind it.
public final class PageServeAdmission: Sendable {
    private let limit: Int
    private let taken = Locked(0)

    public init(limit: Int) { self.limit = limit }

    /// tryAcquire takes a slot, false when all are taken.
    public func tryAcquire() -> Bool {
        taken.withLock { count in
            guard count < limit else { return false }
            count += 1
            return true
        }
    }

    public func release() {
        taken.withLock { $0 -= 1 }
    }
}

/// PageServeStream is the channel a presenter's helper opened for one page this host handed over. It serves a file
/// page's files from inside its grant and runs its bridge requests here, as a local page's would run, and serves an
/// image, markdown or text page the files its kind may read, with no bridge.
/// The helper's connection closing, or sending what a helper never sends, ends the page; the presenter
/// subscription is not touched.
@MainActor
public final class PageServeStream {
    public static let limits = ControlStreamOwner.Limits(maxLineBytes: PageServeCodec.maxFrameBytes,
                                                         maxPendingLines: 8, writeTimeoutSeconds: 5)
    public static let resourceLimit = 8
    public static let bridgeLimit = 8

    /// Attachment is one viewer's channel to a page that stays with its host; ending it ends nothing but itself.
    public struct Attachment: Sendable, Equatable {
        public let claim: UUID
        public let session: UUID

        public init(claim: UUID, session: UUID) {
            self.claim = claim
            self.session = session
        }
    }

    private struct Transfers {
        var active: Set<Int> = []
        var cancelled: Set<Int> = []
    }

    public let page: UUID
    public let attachment: Attachment?
    public let resourceSlots = PageServeAdmission(limit: PageServeStream.resourceLimit)
    public let bridgeSlots = PageServeAdmission(limit: PageServeStream.bridgeLimit)
    private let source: HtmlSource
    private let links: MarkdownLinkGrant?
    private let log: TextLog?
    private let owner: ControlStreamOwner
    private weak var host: (any PageServeHost)?
    private let mimeType: @Sendable (String) -> String
    // bridge calls have their own slots and queue, so they wait behind at most the chunks already queued for
    // the writer, never behind a whole file
    private let files = DispatchQueue(label: "com.umputun.agterm.pageserve.files")
    private let replies = DispatchQueue(label: "com.umputun.agterm.pageserve.replies")
    private let transfers = Locked(Transfers())
    private var ending = false

    init(page: UUID, source: HtmlSource, links: MarkdownLinkGrant? = nil, log: TextLog? = nil, owner: ControlStreamOwner,
         host: any PageServeHost, mimeType: @escaping @Sendable (String) -> String, attachment: Attachment?) {
        self.page = page
        self.attachment = attachment
        self.source = source
        self.links = links
        self.log = log
        self.owner = owner
        self.host = host
        self.mimeType = mimeType
    }

    /// adopt starts the channel for page `page` on `descriptor`, or closes the descriptor when `source` is nil: a
    /// page that ended between its claim and this adoption gets no channel.
    public static func adopt(descriptor: Int32, page: UUID, source: HtmlSource?, links: MarkdownLinkGrant? = nil,
                             log: TextLog? = nil, attachment: Attachment?, host: some PageServeHost) -> PageServeStream? {
        let owner = ControlStreamOwner(descriptor: descriptor, limits: limits)
        guard let source else {
            owner.start(onLine: { _ in }, onClose: {})
            owner.shutdown()
            return nil
        }
        let hostType = type(of: host)
        let stream = PageServeStream(page: page, source: source, links: links, log: log, owner: owner, host: host,
                                     mimeType: { hostType.pageMimeType($0) }, attachment: attachment)
        owner.start(
            onLine: { [weak stream] line in stream?.take(Data(line)) },
            onClose: { [weak stream] in
                DispatchQueue.main.async { MainActor.assumeIsolated { stream?.closed() } }
            }
        )
        return stream
    }

    /// take handles one line on the reader thread: a cancel applies at once, a request takes a slot of its
    /// kind and runs on the main actor or is refused at once by id, and anything else ends the page. Nothing
    /// here waits, so cancels and EOF behind a request are always read.
    nonisolated func take(_ line: Data) {
        guard let frame = try? PageServeCodec.decode(line) else { return failOnMain("a malformed frame") }
        switch frame {
        case .cancel(let id):
            transfers.withLock { if $0.active.contains(id) { $0.cancelled.insert(id) } }
        case .resource(let id, _), .logTail(let id, _):
            guard resourceSlots.tryAcquire() else { return refuse(id) }
            transfers.withLock { _ = $0.active.insert(id) }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.receive(frame) } }
        case .bridge(let id, _):
            guard bridgeSlots.tryAcquire() else { return refuse(id) }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.receive(frame) } }
        case .head, .chunk, .end, .failure, .reply, .logHead, .logUnchanged:
            failOnMain("a frame only this host sends")
        }
    }

    /// receive runs one admitted request; its slot is released once its last frame is queued for the writer.
    func receive(_ frame: PageServeFrame) {
        switch frame {
        case .resource(let id, let path): serve(id: id, path: path)
        case .logTail(let id, let stamp): serveLog(id: id, stamp: stamp)
        case .bridge(let id, let request): relay(id: id, request: request)
        case .cancel, .head, .chunk, .end, .failure, .reply, .logHead, .logUnchanged: break
        }
    }

    /// shutdown closes the channel without ending the page, which the caller already did or is doing.
    public func shutdown() {
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
        if let attachment {
            host?.pageAttachmentClosed(attachment)
            return
        }
        // a channel replaced by a later claim, or retired, closes without ending the page the new one serves
        let registered = host?.pageServeStreams[page] === self
        if registered { host?.pageServeStreams[page] = nil }
        guard !ending, registered else { return }
        host?.pageChannelLost(page)
    }

    private nonisolated func failOnMain(_ reason: String) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.fail(reason) } }
    }

    private func fail(_ reason: String) {
        guard !ending else { return }
        pageLog.error("ending a page whose channel sent \(reason)")
        ending = true
        if attachment == nil, host?.pageServeStreams[page] === self { host?.endRemotePage(page) }
        shutdown()
    }

    private func serve(id: Int, path: String) {
        let owner = owner, source = source, links = links, transfers = transfers, slots = resourceSlots, mimeType = mimeType
        files.async {
            Self.transfer(Request(id: id, path: path, source: source, links: links), owner: owner, transfers: transfers,
                          mimeType: mimeType)
            transfers.withLock {
                $0.active.remove(id)
                $0.cancelled.remove(id)
            }
            slots.release()
        }
    }

    private func serveLog(id: Int, stamp: BoundedFile.FileStamp?) {
        var path: String?
        if case .text(let file, _) = source, log != nil { path = file }
        let owner = owner, transfers = transfers, slots = resourceSlots
        files.async { [path] in
            Self.transferLog(id: id, stamp: stamp, path: path, owner: owner, transfers: transfers)
            transfers.withLock {
                $0.active.remove(id)
                $0.cancelled.remove(id)
            }
            slots.release()
        }
    }

    // a log tail is read only from the claimed log page's own file, within the tail cap whatever the file's size; the
    // viewer builds the snapshot from the raw bytes, so rotation, truncation and binary ends read as they do locally
    nonisolated private static func transferLog(id: Int, stamp: BoundedFile.FileStamp?, path: String?,
                                                owner: ControlStreamOwner, transfers: Locked<Transfers>) {
        let cancelled = { transfers.withLock { $0.cancelled.contains(id) } }
        guard let path else {
            _ = sendWaiting(.failure(id: id, error: "not a log page"), owner)
            return
        }
        guard !cancelled() else {
            _ = sendWaiting(.failure(id: id, error: PageServeFrame.cancelled), owner)
            return
        }
        let read: BoundedFile.TailRead
        switch BoundedFile.readTail(path: path, maxBytes: TextPage.maxTailBytes, unchangedFrom: stamp) {
        case .failure:
            _ = sendWaiting(.failure(id: id, error: "file cannot be read"), owner)
            return
        case .success(nil):
            _ = sendWaiting(.logUnchanged(id: id), owner)
            return
        case .success(let fresh?): read = fresh
        }
        guard sendWaiting(.logHead(id: id, stamp: read.stamp, offset: read.offset), owner) else { return }
        for start in stride(from: 0, to: read.data.count, by: PageServeCodec.maxChunkBytes) {
            guard !cancelled() else {
                _ = sendWaiting(.failure(id: id, error: PageServeFrame.cancelled), owner)
                return
            }
            let end = min(start + PageServeCodec.maxChunkBytes, read.data.count)
            guard sendWaiting(.chunk(id: id, data: read.data.subdata(in: start..<end)), owner) else { return }
        }
        _ = sendWaiting(.end(id: id), owner)
    }

    // every admitted transfer ends in exactly one terminal frame, a cancelled one too, so the viewer frees its
    // request slot only when this side has
    nonisolated private static func transfer(_ request: Request, owner: ControlStreamOwner, transfers: Locked<Transfers>,
                                             mimeType: (String) -> String) {
        let id = request.id, path = request.path, source = request.source
        let cancelled = { transfers.withLock { $0.cancelled.contains(id) } }
        let stop = { _ = sendWaiting(.failure(id: id, error: PageServeFrame.cancelled), owner) }
        guard !cancelled() else { return stop() }
        if let resource = RemotePageResources.content(path, source: source, links: request.links) {
            switch contentBody(resource) {
            case .failure(let refusal):
                _ = sendWaiting(.failure(id: id, error: refusal.message), owner)
            case .success(let body):
                guard sendWaiting(.head(id: id, mimeType: body.mimeType), owner) else { return }
                for start in stride(from: 0, to: body.data.count, by: PageServeCodec.maxChunkBytes) {
                    guard !cancelled() else { return stop() }
                    let end = min(start + PageServeCodec.maxChunkBytes, body.data.count)
                    guard sendWaiting(.chunk(id: id, data: body.data.subdata(in: start..<end)), owner) else { return }
                }
                _ = sendWaiting(.end(id: id), owner)
            }
            return
        }
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
        if attachment != nil, case .url = source { return .failure(id: id, error: "a URL page has no bridge") }
        if [.image, .markdown, .text, .document, .unreadable].contains(source.kind) {
            return .failure(id: id, error: "this page has no bridge")
        }
        guard let host, let place = attachment.map({ host.pageAttachmentPlace($0, page: page) }) ?? host.remotePagePlace(page) else {
            return .failure(id: id, error: "page closed")
        }
        let origin = HtmlBridgePage(window: place.window?.uuidString, session: place.session, pane: place.pane)
        let built: ControlRequest
        switch HtmlBridge.request(from: Data(request.utf8), page: origin) {
        case .success(let value): built = value
        case .failure(let refusal): return .failure(id: id, error: refusal.message)
        }
        guard let response = await host.dispatchPageBridge(built) else {
            return .failure(id: id, error: "control is unavailable")
        }
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

    /// Request is one resource the viewer asked for under the page's source.
    private struct Request: Sendable {
        let id: Int
        let path: String
        let source: HtmlSource
        let links: MarkdownLinkGrant?
    }

    private struct ContentRefusal: Error {
        let message: String
    }

    // a content page's file is read whole under its kind's cap through one checked descriptor, and a picture is
    // sent only when its bytes carry a picture signature, so a markdown page sends text only for its own file or
    // the documents its link grant admits
    nonisolated private static func contentBody(
        _ resource: RemotePageResources.ContentResource
    ) -> Result<(mimeType: String, data: Data), ContentRefusal> {
        let data: Data
        switch BoundedFile.read(path: resource.path, maxBytes: resource.maxBytes) {
        case .success(let read): data = read
        case .failure(.tooLarge): return .failure(ContentRefusal(message: "file is too large for the page"))
        case .failure(.unreadable): return .failure(ContentRefusal(message: "file cannot be read"))
        }
        guard resource.picture else { return .success(("text/plain; charset=utf-8", data)) }
        guard let mimeType = ImagePage.mimeType(sniffing: data) else {
            return .failure(ContentRefusal(message: "not a png, jpg, gif or webp image"))
        }
        return .success((mimeType, data))
    }
}

/// PageServeClaim is what a claimed page's channel serves: its source and, for a markdown page, its link grant; a log
/// page's request is what admits its tail reads.
public struct PageServeClaim: Sendable {
    public let source: HtmlSource
    public let links: MarkdownLinkGrant?
    public let log: TextLog?

    public init(source: HtmlSource, links: MarkdownLinkGrant? = nil, log: TextLog? = nil) {
        self.source = source
        self.links = links
        self.log = log
    }
}

extension PageServeHost {
    /// claimPageStream answers `session.overlay.page.serve`: an ok answer is the token's one admitted claim, and the
    /// connection is then adopted as that page's channel.
    public func claimPageStream(_ token: String) -> ControlResponse {
        if let attachment = claimPageAttachment(token) { return attachment }
        guard let claim = claimRemotePage(token: token) else { return ControlResponse(ok: false, error: "page not claimable") }
        pendingPageClaims[token] = PendingPageClaim(page: claim.page, served: claim.served)
        return ControlResponse(ok: true, result: ControlResult(id: claim.page.uuidString))
    }

    /// adoptPageServeStream takes over the connection of a page whose claim under `token` was just answered ok. A claim
    /// the page was re-offered past gets no channel.
    public func adoptPageServeStream(descriptor: Int32, page: UUID, token: String) {
        if adoptPageAttachment(descriptor: descriptor, claim: page) { return }
        let claim = pendingPageClaims.removeValue(forKey: token)
        let live = claim?.page == page && remotePagePlace(page) != nil && isCurrentPageClaim(page, token: token)
        guard let stream = PageServeStream.adopt(descriptor: descriptor, page: page, source: live ? claim?.served.source : nil,
                                                 links: claim?.served.links, log: claim?.served.log, attachment: nil,
                                                 host: self) else { return }
        pageServeStreams[page] = stream
    }

    /// pageClaimUnanswered handles a claim whose reply never reached its helper, which leaves nobody to load the page,
    /// unless the page was re-offered past that claim meanwhile.
    public func pageClaimUnanswered(_ page: UUID, token: String) {
        // an attachment that never connected leaves the page and its other viewers alone
        if dropPageAttachmentClaim(page) { return }
        pendingPageClaims[token] = nil
        guard isCurrentPageClaim(page, token: token) else { return }
        pageChannelLost(page)
    }
}
