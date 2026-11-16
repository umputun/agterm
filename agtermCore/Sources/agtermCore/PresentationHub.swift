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
        var kinds: Set<String> = []
        var revision = 0
        // the first ping still unanswered; a late heartbeat sends a ping before it can call the viewer stale
        var pingedAt: Date?
        /// Deltas published while the snapshot is being taken, held so they land after it.
        var held: [PresentationFrame.Body]? = []
        /// mail is the counts this viewer last accepted, from its snapshot or a mail frame.
        var mail: PresentationMail?
        /// leads are the origin panes this viewer last reported leading; leadsAt orders its report among all viewers'.
        var leads: Set<UUID> = []
        var leadsAt = 0

        init(session: UUID, generation: Int, sink: PresentationSink) {
            self.session = session
            self.generation = generation
            self.sink = sink
        }

        @MainActor func decodable(_ body: PresentationFrame.Body) -> PresentationFrame.Body {
            let accepted = PresentationHub.acceptedShapes(kinds)
            guard accepted.count < StatusShape.allCases.count else { return body }
            switch body {
            case .status(let status):
                return .status(status.map { Self.withShape(in: accepted, $0) })
            case .snapshot(var snapshot):
                snapshot.status = snapshot.status.map { Self.withShape(in: accepted, $0) }
                return .snapshot(snapshot)
            default:
                return body
            }
        }

        private static func withShape(in accepted: Set<StatusShape>, _ status: PresentationStatus) -> PresentationStatus {
            guard let shape = status.shape, !accepted.contains(shape) else { return status }
            var status = status
            status.shape = nil
            return status
        }
    }

    /// The frame kinds this origin can produce.
    public static let supportedKinds = ["status", "hud", "notify", "message", "mail", "context", "info", "layout", "sound", askFormKind, askOtherKind,
                                        overlayPointsKind, pageContentKind, pageDocumentKind, pageLinksKind, statusShapesKind,
                                        statusCheckmarkKind, linkClickKind, pendingSnapshotKind, jobTokenKind, pageForwardKind,
                                        pageTextKind, pageFilesKind, statusClearKind, restartRespawnKind, presenterVacantKind,
                                        leadReportKind, offerIdentityKind]
                                        + pageKinds + pickKinds
    /// pageKinds are the presentation kinds a presenter must speak to be handed a page.
    public static let pageKinds = ["page.request", "page.rejected", "page.close", "page.closed", "page.command",
                                   "page.state"]
    /// pickKinds are the presentation kinds a presenter must speak to be handed a session-bound pick.
    public static let pickKinds = ["pick.request", "pick.resolve", "pick.rejected", "pick.dismiss"]
    /// restartRespawnKind is an origin's capability of publishing a restarted pane's respawn, which carries every viewer's
    /// attach across the restart.
    public static let restartRespawnKind = "restart.respawn"
    /// leadReportKind is a viewer's capability of reporting the panes it leads, so new work for them is routed to it.
    public static let leadReportKind = "lead.report"
    /// offerIdentityKind is the capability of echoing each hand-over's `offer` in every reply about it, so a reply to an
    /// earlier offer of the same work to the same viewer is told apart. A viewer holds what an origin listing it hands
    /// over and it cannot show yet, instead of refusing it.
    public static let offerIdentityKind = "offer.id"
    /// presenterVacantKind is a viewer's capability of asking for the role again when the origin reports it vacant.
    public static let presenterVacantKind = "presenter.vacant"
    /// statusClearKind is an origin's capability of taking `status.clear` and `status.seen` from its presenter.
    public static let statusClearKind = "status.clear"
    /// pendingSnapshotKind is a presenter's capability of taking a headless origin's pending interactions.
    public static let pendingSnapshotKind = "pending.snapshot"
    /// jobTokenKind is a presenter's capability of passing an overlay job's offer token to its helper.
    public static let jobTokenKind = "job.token"
    /// askFormKind is the capability of drawing an ask's text field, choice list and cancel role. It names no
    /// frame body: an ask needing it travels as an ordinary `ask.request`, sent only to a presenter listing it.
    public static let askFormKind = "ask.form"
    /// askOtherKind is the capability of drawing a choice list's free-form row; a presenter with only
    /// `ask.form` would drop the row, so such an ask needs both.
    public static let askOtherKind = "ask.other"
    /// overlayPointsKind advertises point sizing without adding a frame kind.
    public static let overlayPointsKind = "overlay.points"
    /// pageContentKind advertises the image, markdown and text page sources without adding a frame kind.
    public static let pageContentKind = "page.content"
    /// pageDocumentKind advertises the clicked-HTML document page source.
    public static let pageDocumentKind = "page.document"
    /// pageLinksKind advertises a markdown page that follows its links under `PresentationPage.markdownLinks`; an older
    /// presenter would fetch the original spelling and `.md` pictures, so it is handed the page without links.
    public static let pageLinksKind = "page.links"
    /// pageForwardKind is a presenter's capability of reaching an origin's loopback URL page through an ssh forward it
    /// opens.
    public static let pageForwardKind = "page.forward"
    /// pageTextKind advertises live text pages: log pages, the text page actions, their `pageResult` answers and the
    /// text state in `pageState`.
    public static let pageTextKind = "page.text"
    /// pageFilesKind advertises the diff page file jump, a page action an older `page.text` presenter cannot decode.
    public static let pageFilesKind = "page.files"
    /// statusShapesKind advertises the expanded status-shape set.
    public static let statusShapesKind = "status.shapes"
    /// statusCheckmarkKind advertises `StatusShape.checkmark`, added after `status.shapes` shipped.
    public static let statusCheckmarkKind = "status.checkmark"

    /// acceptedShapes is the shape set a viewer advertising `kinds` decodes; a shape outside it is cleared, and
    /// that viewer draws its own Settings shape instead.
    static func acceptedShapes(_ kinds: Set<String>) -> Set<StatusShape> {
        var shapes = kinds.contains(statusShapesKind) ? StatusShape.expanded : StatusShape.original
        if kinds.contains(statusCheckmarkKind) { shapes.insert(.checkmark) }
        return shapes
    }
    /// linkClickKind advertises forwarded clicks and the refusal frame that answers one.
    public static let linkClickKind = "link.click"

    private let staleTimeout: TimeInterval
    private let now: () -> Date
    private var subscribers: [SubscriberID: Subscriber] = [:]
    private var lastGeneration = 0
    private var lastLeadReport = 0
    private var sessionLeadReports: [UUID: Int] = [:]
    private var lastOffer = 0
    private var layouts: [UUID: PresentationLayout] = [:]
    private var grant = PresenterGrant()

    /// onOwnerLost runs with a session and the token of a viewer of it whose stream ended, after any role it held is
    /// released: the work that viewer owned has nobody left to answer it.
    public var onOwnerLost: (@MainActor (UUID, Int) -> Void)?
    private var batches: [Int: [PresentationFrame.Body]] = [:]
    /// onPresenterGranted runs once a viewer took `session`'s presenter role and was told so.
    public var onPresenterGranted: (@MainActor (UUID) -> Void)?
    /// onLeadReport runs once a viewer of `session` replaced the set of panes it leads.
    public var onLeadReport: (@MainActor (UUID) -> Void)?
    /// onOpenWork runs a placement pass for a session one main turn after `scheduleOpenWork` asked for it, once
    /// however often it was asked meanwhile, so a pass never runs inside the call that changed a place.
    public var onOpenWork: (@MainActor (UUID) -> Void)?
    private var openWorkDue: Set<UUID> = []
    /// onPresenterFrame runs with what a viewer sent about work, and that viewer's token. An answer echoing another
    /// viewer's owner, and a clear, seen or click from a viewer neither holding the role nor leading a pane, are dropped
    /// before this is reached; the receiver checks that the sender owns the page or overlay a frame names.
    public var onPresenterFrame: (@MainActor (UUID, Int, PresentationFrame.Body) -> Void)?

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
        let subscriber = Subscriber(session: session, generation: lastGeneration, sink: sink)
        subscribers[id] = subscriber

        let state = snapshot()
        if layouts[session] == nil { layouts[session] = state.layout }
        let held = subscriber.held ?? []
        subscriber.held = nil
        let kinds = Self.supportedKinds.filter(hello.kinds.contains)
        subscriber.kinds = Set(kinds)
        // presenter is offered only to a viewer that asked for it, so a slice-1 viewer stays a mirror
        let answer = PresentationHello(version: version, kinds: kinds, mode: hello.mode)
        for body in [.hello(answer), .snapshot(state)] + held {
            guard send(body, to: id) else { break }
        }
        return id
    }

    /// newOffer numbers a hand-over to viewer `owner`, nil when that viewer does not echo offers and its replies are
    /// matched by owner alone.
    public func newOffer(toOwner owner: Int) -> Int? {
        guard supports(Self.offerIdentityKind, owner: owner) else { return nil }
        lastOffer += 1
        return lastOffer
    }

    public func unsubscribe(_ id: SubscriberID) {
        guard let subscriber = subscribers.removeValue(forKey: id) else { return }
        if subscriberCount(session: subscriber.session) == 0 { layouts[subscriber.session] = nil }
        release(id, session: subscriber.session)
    }

    /// send hands `body` to the viewer `owner` names. False when it is gone, it stalled and was dropped, or `body` is a
    /// negotiated kind its hello did not list, which an older viewer would skip.
    @discardableResult
    public func send(_ body: PresentationFrame.Body, toOwner owner: Int) -> Bool {
        let id = SubscriberID(generation: owner)
        guard let subscriber = subscribers[id] else { return false }
        if Self.supportedKinds.contains(body.kind), !subscriber.kinds.contains(body.kind) { return false }
        if batches[owner] != nil {
            batches[owner]?.append(body)
            return true
        }
        return send(body, to: id)
    }

    /// batch sends what `fill` hands each viewer of `session` as pending chunks and one commit of its own, so each
    /// applies its share together or, when its stream ends first, none of it.
    public func batch(session: UUID, _ fill: () -> Void) {
        let owners = subscribers.values.filter { $0.session == session }.map(\.generation)
        for owner in owners { batches[owner] = [] }
        fill()
        for owner in owners {
            let bodies = batches.removeValue(forKey: owner) ?? []
            guard !bodies.isEmpty, let chunks = try? PresentationPendingBatch.chunks(bodies) else { continue }
            for chunk in chunks { send(.pendingChunk(chunk), toOwner: owner) }
            send(.pendingCommit, toOwner: owner)
        }
    }

    /// publishMail sends `session`'s mail counts to each viewer whose last accepted counts differ, so every viewer
    /// converges on the current map whatever it saw in between.
    public func publishMail(_ mail: PresentationMail, session: UUID) {
        for (id, subscriber) in subscribers where subscriber.session == session {
            if subscriber.held != nil {
                subscriber.held?.append(.mail(mail))
                continue
            }
            if subscriber.mail != mail { send(.mail(mail), to: id) }
        }
    }

    /// subscribedSessions are the sessions at least one viewer follows.
    public var subscribedSessions: Set<UUID> { Set(subscribers.values.map(\.session)) }

    func publishLayout(_ layout: PresentationLayout, session: UUID) {
        guard subscriberCount(session: session) > 0, layouts[session] != layout else { return }
        layouts[session] = layout
        publish(.layout(layout), session: session)
        scheduleOpenWork(session)
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
        case .ack: subscriber.pingedAt = nil
        case .ping: send(.ack, to: id)
        case .presenterAcquire:
            // a vacancy can cross a viewer's first acquire, so the holder may ask twice; pending work goes out once
            let repeated = grant.holder(of: subscriber.session) == id
            let granted = grant.acquire(session: subscriber.session, by: id)
            send(granted ? .presenterGranted : .presenterRefused, to: id)
            guard granted, !repeated else { return }
            onPresenterGranted?(subscriber.session)
            scheduleOpenWork(subscriber.session)
        case .leadReport(let report):
            guard subscriber.kinds.contains(Self.leadReportKind) else { return }
            lastLeadReport += 1
            subscriber.leads = Set(report.leaders)
            subscriber.leadsAt = lastLeadReport
            sessionLeadReports[subscriber.session, default: 0] += 1
            onLeadReport?(subscriber.session)
            scheduleOpenWork(subscriber.session)
        case .askResolve(let answer):
            if answer.owner == id.generation { onPresenterFrame?(subscriber.session, id.generation, frame.body) }
        case .askRejected(let ref):
            if ref.owner == id.generation { onPresenterFrame?(subscriber.session, id.generation, frame.body) }
        case .pickResolve(let answer):
            if answer.owner == id.generation { onPresenterFrame?(subscriber.session, id.generation, frame.body) }
        case .pickRejected(let ref):
            if ref.owner == id.generation { onPresenterFrame?(subscriber.session, id.generation, frame.body) }
        case .overlayRejected, .overlayClosed, .pageRejected, .pageClosed, .pageState, .pageResult:
            onPresenterFrame?(subscriber.session, id.generation, frame.body)
        case .linkClick, .statusClear, .statusSeen:
            guard grant.holder(of: subscriber.session) == id || !subscriber.leads.isEmpty else { return }
            onPresenterFrame?(subscriber.session, id.generation, frame.body)
        default: break
        }
    }

    /// heartbeat closes every subscriber that left a ping unanswered past the stale timeout and pings the rest.
    /// The owner of the streams calls this on its own timer.
    public func heartbeat() {
        let current = now()
        for (id, subscriber) in subscribers {
            if let pingedAt = subscriber.pingedAt, current.timeIntervalSince(pingedAt) > staleTimeout {
                drop(id, reason: .stale)
                continue
            }
            if subscriber.pingedAt == nil { subscriber.pingedAt = current }
            send(.ping, to: id)
        }
    }

    public func subscriberCount(session: UUID) -> Int {
        subscribers.values.count { $0.session == session }
    }

    /// route is the token of the viewer that takes new work for `pane` of `session`, or for the session as a whole when
    /// `pane` is nil: the viewer leading that pane (the primary one for session-wide work), else the grant holder.
    public func route(session: UUID, pane: UUID?) -> Int? {
        if let target = pane ?? layouts[session]?.primary, let claimant = claimant(session: session, pane: target) {
            return claimant.generation
        }
        return grant.holder(of: session)?.generation
    }

    // the newest report still naming the pane wins, so withdrawing a claim hands the pane back to an older claimant
    private func claimant(session: UUID, pane: UUID) -> Subscriber? {
        subscribers.values.filter { $0.session == session && $0.leads.contains(pane) }.max { $0.leadsAt < $1.leadsAt }
    }

    /// Whether a viewer holds `session`'s presenter role.
    public func hasPresenter(session: UUID) -> Bool { grant.holder(of: session) != nil }

    /// presenter is the token of the viewer holding `session`'s presenter role, nil when none does.
    public func presenter(of session: UUID) -> Int? { grant.holder(of: session)?.generation }

    /// supports is whether viewer `owner` is connected and listed `kind` in its hello.
    public func supports(_ kind: String, owner: Int) -> Bool {
        subscribers[SubscriberID(generation: owner)]?.kinds.contains(kind) == true
    }

    /// isConnected is whether the stream of viewer `owner` is still up, so work it owns can still be answered.
    public func isConnected(owner: Int) -> Bool { subscribers[SubscriberID(generation: owner)] != nil }

    /// leadReports counts the lead reports session `id`'s viewers sent.
    func leadReports(of id: UUID) -> Int { sessionLeadReports[id] ?? 0 }

    /// leadClaimant is the token of the viewer newest leading `pane` of `session`, nil when none does; unlike `route`
    /// it never falls back to the grant holder.
    public func leadClaimant(session: UUID, pane: UUID) -> Int? { claimant(session: session, pane: pane)?.generation }

    /// scheduleOpenWork asks for a placement pass over `session`'s open work (`onOpenWork`).
    public func scheduleOpenWork(_ session: UUID) {
        guard openWorkDue.insert(session).inserted else { return }
        Task { @MainActor [weak self] in
            guard let self, self.openWorkDue.remove(session) != nil else { return }
            self.onOpenWork?(session)
        }
    }

    @discardableResult
    private func send(_ body: PresentationFrame.Body, to id: SubscriberID) -> Bool {
        guard let subscriber = subscribers[id] else { return false }
        let frame = PresentationFrame(gen: subscriber.generation, rev: subscriber.revision, body: subscriber.decodable(body))
        guard subscriber.sink.offer(frame) else {
            drop(id, reason: .stalled)
            return false
        }
        subscriber.revision += 1
        switch body {
        case .snapshot(let snapshot): subscriber.mail = snapshot.mail
        case .mail(let mail): subscriber.mail = mail
        default: break
        }
        return true
    }

    private func drop(_ id: SubscriberID, reason: CloseReason) {
        guard let subscriber = subscribers.removeValue(forKey: id) else { return }
        if subscriberCount(session: subscriber.session) == 0 { layouts[subscriber.session] = nil }
        subscriber.sink.close(reason)
        release(id, session: subscriber.session)
    }

    private func release(_ id: SubscriberID, session: UUID) {
        let vacated = grant.release(id)
        onOwnerLost?(session, id.generation)
        scheduleOpenWork(session)
        for session in vacated { announceVacancy(session: session) }
    }

    // a refused mirror asks only once per stream, so without this the role stays empty until a viewer reconnects.
    // the mirrors ask through `presenterAcquire` after the drop that freed the role has fully unwound
    private func announceVacancy(session: UUID) {
        for (id, subscriber) in subscribers where subscriber.session == session && subscriber.kinds.contains(Self.presenterVacantKind) {
            send(.presenterVacant, to: id)
        }
    }
}
