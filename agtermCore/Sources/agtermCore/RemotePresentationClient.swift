import Foundation

/// One running bridge to an origin. Lines sent carry their newline.
@MainActor
public protocol RemotePresentationLink: AnyObject {
    func send(_ line: Data)
    func stop()
}

/// Launches the bridge process. `onLine` takes one line without its newline; `onClose` takes why it ended.
@MainActor
public protocol RemotePresentationTransport: AnyObject {
    func open(_ argv: [String], onLine: @escaping @MainActor (Data) -> Void,
              onClose: @escaping @MainActor (String) -> Void) -> RemotePresentationLink
}

/// What a client does with what arrives. The app supplies these, since showing a HUD or a notification
/// needs AppKit.
public struct RemotePresentationEffects {
    public var status: @MainActor (PresentationStatus?) -> Void
    /// The status a snapshot carries. Separate from `status` because it is no change on the origin: one
    /// arrives with every reconnect.
    public var snapshotStatus: @MainActor (PresentationStatus?) -> Void
    public var hud: @MainActor (PresentationHud?) -> Void
    public var notify: @MainActor (PresentationNotify) -> Void
    public var sound: @MainActor (PresentationSound) -> Void
    public var connection: @MainActor (RemotePresentationConnection) -> Void
    public var context: @MainActor (String?) -> Void
    /// info carries the origin's sidebar info line, nil for none; a snapshot sends it too.
    public var info: @MainActor (PresentationInfo?) -> Void
    public var layout: @MainActor (PresentationLayout) -> Void
    public var mode: @MainActor (PresentationMode) -> Void
    /// Shows an ask the origin handed over; false when it cannot, which the client reports as a refusal.
    public var askRequest: @MainActor (PresentationAsk) -> Bool
    public var askDismiss: @MainActor (PresentationAskRef) -> Void
    /// Shows a session-bound pick the origin handed over; false when it cannot, which the client reports as a refusal.
    public var pickRequest: @MainActor (PresentationPick) -> Bool
    public var pickDismiss: @MainActor (PresentationPickRef) -> Void
    /// Shows an overlay the origin handed over; false when it cannot, which the client reports as a refusal.
    public var overlayRequest: @MainActor (PresentationOverlay) -> Bool
    public var overlayClose: @MainActor (PresentationOverlayChange) -> Void
    public var overlayResize: @MainActor (PresentationOverlayChange) -> Void
    /// pageRequest shows a page the origin handed over; nil when shown, otherwise the reason sent as a refusal.
    public var pageRequest: @MainActor (PresentationPage) -> String?
    public var pageClose: @MainActor (PresentationPageChange) -> Void
    public var pageCommand: @MainActor (PresentationPageCommand) -> Void
    /// respawns reports the origin's respawn counts; true for a snapshot, which a first attach takes as its baseline.
    public var respawns: @MainActor (PresentationRespawns, Bool) -> Void
    /// linkRefused reports the origin refused a click this Mac forwarded.
    public var linkRefused: @MainActor (RemoteLinkRefusal) -> Void
    /// linkClickRefused names the forwarded click a refusal answers, when that click carried an id; `linkRefused` still
    /// reports the refusal itself.
    public var linkClickRefused: @MainActor (UUID) -> Void
    /// linkSnapshot reports the origin offering a forwarded click's file for an `open` rule here.
    public var linkSnapshot: @MainActor (PresentationLinkSnapshot) -> Void
    /// message reports mail queued on the origin for one of the session's panes, to every viewer alike.
    public var message: @MainActor (PresentationMessage) -> Void
    /// mail replaces the origin's unacked counts per origin pane; nil from a snapshot of an origin that sends none.
    public var mail: @MainActor (PresentationMail?) -> Void
    /// companions is the origin's companion membership of the session; nil from a snapshot that carries none.
    public var companions: @MainActor (PresentationCompanions?) -> Void
    /// leads is the set of the origin's panes this Mac leads, read whenever the client checks for a change.
    public var leads: @MainActor () -> Set<UUID>
    /// ended reports the origin removed the session for good, or, for an observer, that the origin's hello left out the
    /// companions kind; either way the client has stopped and never reconnects.
    public var ended: @MainActor () -> Void
    /// acked reports the origin's answer to `RemotePresentationClient.ping`.
    public var acked: @MainActor () -> Void
    public var warn: @MainActor (String) -> Void

    public init(status: @escaping @MainActor (PresentationStatus?) -> Void,
                snapshotStatus: @escaping @MainActor (PresentationStatus?) -> Void,
                hud: @escaping @MainActor (PresentationHud?) -> Void,
                notify: @escaping @MainActor (PresentationNotify) -> Void,
                connection: @escaping @MainActor (RemotePresentationConnection) -> Void,
                context: @escaping @MainActor (String?) -> Void = { _ in },
                info: @escaping @MainActor (PresentationInfo?) -> Void = { _ in },
                mode: @escaping @MainActor (PresentationMode) -> Void = { _ in },
                askRequest: @escaping @MainActor (PresentationAsk) -> Bool = { _ in false },
                askDismiss: @escaping @MainActor (PresentationAskRef) -> Void = { _ in },
                pickRequest: @escaping @MainActor (PresentationPick) -> Bool = { _ in false },
                pickDismiss: @escaping @MainActor (PresentationPickRef) -> Void = { _ in },
                overlayRequest: @escaping @MainActor (PresentationOverlay) -> Bool = { _ in false },
                overlayClose: @escaping @MainActor (PresentationOverlayChange) -> Void = { _ in },
                overlayResize: @escaping @MainActor (PresentationOverlayChange) -> Void = { _ in },
                sound: @escaping @MainActor (PresentationSound) -> Void = { _ in },
                layout: @escaping @MainActor (PresentationLayout) -> Void = { _ in },
                pageRequest: @escaping @MainActor (PresentationPage) -> String? = { _ in RemotePresentationClient.pagesUnsupported },
                pageClose: @escaping @MainActor (PresentationPageChange) -> Void = { _ in },
                pageCommand: @escaping @MainActor (PresentationPageCommand) -> Void = { _ in },
                respawns: @escaping @MainActor (PresentationRespawns, Bool) -> Void = { _, _ in },
                linkRefused: @escaping @MainActor (RemoteLinkRefusal) -> Void = { _ in },
                linkClickRefused: @escaping @MainActor (UUID) -> Void = { _ in },
                linkSnapshot: @escaping @MainActor (PresentationLinkSnapshot) -> Void = { _ in },
                message: @escaping @MainActor (PresentationMessage) -> Void = { _ in },
                mail: @escaping @MainActor (PresentationMail?) -> Void = { _ in },
                companions: @escaping @MainActor (PresentationCompanions?) -> Void = { _ in },
                leads: @escaping @MainActor () -> Set<UUID> = { [] },
                ended: @escaping @MainActor () -> Void = {},
                acked: @escaping @MainActor () -> Void = {},
                warn: @escaping @MainActor (String) -> Void) {
        self.status = status
        self.snapshotStatus = snapshotStatus
        self.hud = hud
        self.notify = notify
        self.sound = sound
        self.connection = connection
        self.context = context
        self.info = info
        self.layout = layout
        self.mode = mode
        self.askRequest = askRequest
        self.askDismiss = askDismiss
        self.pickRequest = pickRequest
        self.pickDismiss = pickDismiss
        self.overlayRequest = overlayRequest
        self.overlayClose = overlayClose
        self.overlayResize = overlayResize
        self.pageRequest = pageRequest
        self.pageClose = pageClose
        self.pageCommand = pageCommand
        self.respawns = respawns
        self.linkRefused = linkRefused
        self.linkClickRefused = linkClickRefused
        self.linkSnapshot = linkSnapshot
        self.message = message
        self.mail = mail
        self.companions = companions
        self.leads = leads
        self.ended = ended
        self.acked = acked
        self.warn = warn
    }
}

/// RemotePresentationClient keeps one attached session's presentation stream up: it opens the bridge, applies
/// the snapshot and the deltas behind it, and reconnects when the link ends or goes quiet.
///
/// Event-driven, with no timer of its own: the owner calls `tick` on its clock, which is what makes the
/// backoff and the stale check deterministic to test.
@MainActor
public final class RemotePresentationClient {
    /// The origin pings every 10 seconds, so three missed is a dead link and not a quiet one.
    static let staleAfter: TimeInterval = 30
    /// pagesUnsupported is the refusal a host that shows no handed-over pages answers with.
    public static let pagesUnsupported = "pages are not shown on this Mac"

    private let argv: [String]
    private let presentationVersion: Int?
    private let transport: RemotePresentationTransport
    private let effects: RemotePresentationEffects
    private let now: () -> Date

    private var link: RemotePresentationLink?
    /// Counts launches. A transport callback carries the count it was made under, and one from an earlier
    /// launch is dropped. An object reference cannot do this: the earlier link is gone by then.
    private var launchCount = 0
    private var running = false
    private var generation: Int?
    private var revision = -1
    private var pendingBatch = PresentationPendingBatch()
    private var lastFrameAt = Date.distantPast
    private var retryAt: Date?
    private var failures = 0
    private var warnedReason: String?
    private var connection: RemotePresentationConnection?
    /// Nil until reported, so a new client's first report reaches the row whatever an earlier client of
    /// the same row left on it.
    private var mode: PresentationMode?
    /// The kinds the origin's hello answer agreed for the current link, empty with no link.
    private var originKinds: Set<String> = []
    /// sentLeads is the lead set last reported on the current link, nil until the first report.
    private var sentLeads: Set<UUID>?

    /// observerKinds are all an observer asks for: an origin's companion membership and the session's end.
    public static let observerKinds = [PresentationHub.companionsKind, PresentationHub.endedKind]

    /// observer is a client that only follows the origin's companion membership, for a row the origin shows its asks
    /// and pages to itself: it never asks for the presenter role and answers nothing but pings.
    public let observer: Bool

    public init(argv: [String], presentationVersion: Int?, transport: RemotePresentationTransport,
                effects: RemotePresentationEffects, now: @escaping () -> Date = Date.init, observer: Bool = false) {
        self.argv = argv
        self.presentationVersion = presentationVersion
        self.transport = transport
        self.effects = effects
        self.now = now
        self.observer = observer
    }

    /// Opens the stream. An origin that predates the protocol is never launched at all.
    public func start() {
        guard !running else { return }
        guard presentationVersion != nil else {
            report(.unsupported)
            return
        }
        running = true
        report(.mirror)
        launch()
    }

    /// Ends the stream for good, until `start` is called again. Reports nothing: the row is leaving.
    public func stop() {
        running = false
        retryAt = nil
        dropLink()
    }

    /// A pending retry is due now with the backoff over; a launch still connecting is not started twice.
    public func retryNow() {
        failures = 0
        guard retryAt != nil else { return }
        retryAt = now()
    }

    /// originSupports says whether the origin agreed `kind` on the current link.
    public func originSupports(_ kind: String) -> Bool { link != nil && originKinds.contains(kind) }

    /// claimsLead says the origin knows this Mac leads one of its panes, which lets a mirror send clicks and
    /// status clears as the presenter does.
    public var claimsLead: Bool { originSupports(PresentationHub.leadReportKind) && sentLeads?.isEmpty == false }

    /// refreshLeads reports the panes this Mac leads to an origin that takes lead reports, when they differ from
    /// what the current link last reported.
    public func refreshLeads() {
        guard !observer, let link, originKinds.contains(PresentationHub.leadReportKind) else { return }
        let leads = effects.leads()
        guard leads != sentLeads else { return }
        sentLeads = leads
        send(.leadReport(PresentationLeadReport(leaders: leads.sorted { $0.uuidString < $1.uuidString })), on: link)
    }

    /// Sends what this Mac answered about work the origin handed over. Dropped with no link: the origin
    /// takes that work back when the stream goes.
    public func answer(_ body: PresentationFrame.Body) {
        guard !observer, let link else { return }
        send(body, on: link)
    }

    /// ping asks the origin for an `ack`, which reaches `acked` behind every frame the origin queued before it.
    /// False with no link.
    @discardableResult
    public func ping() -> Bool {
        guard let link else { return false }
        send(.ping, on: link)
        return true
    }

    /// Reconnects when a retry is due and drops a link that has gone quiet.
    public func tick() {
        guard running else { return }
        if link != nil, now().timeIntervalSince(lastFrameAt) > Self.staleAfter {
            fail("no frames for \(Int(Self.staleAfter)) seconds")
            return
        }
        if link == nil, let retryAt, now() >= retryAt { launch() }
        // a binding the catalog or a restore rewrote changes the set with no event of its own
        refreshLeads()
    }

    /// Takes one line from the link opened by `launch`. One from an earlier launch is dropped.
    private func receive(_ line: Data, launch: Int) {
        guard running, let link, launch == launchCount else { return }
        guard let frame = try? PresentationCodec.decode(line) else {
            fail("bad frame")
            return
        }
        guard accept(frame) else { return }
        lastFrameAt = now()
        apply(frame, on: link)
    }

    /// The link opened by `launch` ended. One from an earlier launch says nothing about this one.
    private func linkClosed(reason: String, launch: Int) {
        guard running, link != nil, launch == launchCount else { return }
        fail(reason)
    }

    /// Whether `frame` is next in order. The first hello fixes the generation; everything else has to match
    /// it and advance the revision, which drops what an earlier connection left in flight.
    private func accept(_ frame: PresentationFrame) -> Bool {
        guard let generation else {
            guard case .hello = frame.body else { return false }
            self.generation = frame.gen
            revision = frame.rev
            return true
        }
        guard frame.gen == generation, frame.rev > revision else { return false }
        revision = frame.rev
        return true
    }

    private func apply(_ frame: PresentationFrame, on link: RemotePresentationLink) {
        apply(frame.body, on: link)
    }

    private func apply(_ body: PresentationFrame.Body, on link: RemotePresentationLink) {
        guard !observer else { return observe(body, on: link) }
        switch body {
        case .snapshot(let snapshot):
            failures = 0
            warnedReason = nil
            report(.connected)
            if let layout = snapshot.layout { applyLayout(layout) }
            effects.snapshotStatus(snapshot.status)
            effects.hud(snapshot.hud)
            effects.context(snapshot.context)
            effects.info(snapshot.info)
            effects.mail(snapshot.mail)
            effects.companions(snapshot.companions)
            if let respawns = snapshot.respawns { effects.respawns(respawns, true) }
        case .status(let status): effects.status(status)
        case .context(let context): effects.context(context)
        case .info(let info): effects.info(info)
        case .layout(let layout): applyLayout(layout)
        case .hud(let hud): effects.hud(hud)
        case .notify(let notify): effects.notify(notify)
        case .message(let message): effects.message(message)
        case .mail(let mail): effects.mail(mail)
        case .companions(let companions): effects.companions(companions)
        case .sound(let sound): effects.sound(sound)
        case .ping: send(.ack, on: link)
        // an origin that predates the role answers mirror, and nothing is asked of it
        case .hello(let answer):
            originKinds = Set(answer.kinds)
            if answer.mode == .presenter { send(.presenterAcquire, on: link) }
            refreshLeads()
        case .presenterGranted: report(.presenter)
        case .presenterRefused: report(.mirror)
        case .presenterVacant: if mode != .presenter { send(.presenterAcquire, on: link) }
        case .askRequest(let ask):
            if !effects.askRequest(ask) { send(.askRejected(PresentationAskRef(id: ask.id, owner: ask.owner, offer: ask.offer)), on: link) }
        case .askDismiss(let ref): effects.askDismiss(ref)
        case .pickRequest(let pick):
            if !effects.pickRequest(pick) { send(.pickRejected(PresentationPickRef(id: pick.id, owner: pick.owner, offer: pick.offer)), on: link) }
        case .pickDismiss(let ref): effects.pickDismiss(ref)
        case .overlayRequest(let overlay):
            if !effects.overlayRequest(overlay) { send(.overlayRejected(PresentationOverlayChange(job: overlay.job)), on: link) }
        case .overlayClose(let change): effects.overlayClose(change)
        case .overlayResize(let change): effects.overlayResize(change)
        case .pageRequest(let page):
            if let reason = effects.pageRequest(page) {
                send(.pageRejected(PresentationPageChange(page: page.page, reason: reason, offer: page.offer)), on: link)
            }
        case .pageClose(let change): effects.pageClose(change)
        case .pageCommand(let command): effects.pageCommand(command)
        case .respawn(let respawns): effects.respawns(respawns, false)
        case .linkRefused(let refusal):
            refusal.click.map(effects.linkClickRefused)
            effects.linkRefused(refusal.reason)
        case .linkSnapshot(let snapshot): effects.linkSnapshot(snapshot)
        case .ended: finish()
        case .pendingChunk(let chunk): pendingBatch.add(chunk)
        case .pendingCommit:
            guard let entries = try? pendingBatch.commit() else { return effects.warn("malformed pending batch") }
            for entry in entries {
                switch entry {
                case .pendingChunk, .pendingCommit: continue
                default: apply(entry, on: link)
                }
            }
        case .ack: effects.acked()
        case .presenterAcquire, .leadReport, .linkClick, .statusClear, .statusSeen, .askResolve, .askRejected, .pickResolve, .pickRejected, .overlayRejected,
             .overlayClosed, .unknown,
             .pageRejected, .pageClosed, .pageState, .pageResult:
            break
        }
    }

    private func observe(_ body: PresentationFrame.Body, on link: RemotePresentationLink) {
        switch body {
        case .hello(let answer):
            originKinds = Set(answer.kinds)
            if !originKinds.contains(PresentationHub.companionsKind) { finish() }
        case .snapshot(let snapshot):
            failures = 0
            warnedReason = nil
            report(.connected)
            effects.companions(snapshot.companions)
        case .companions(let companions): effects.companions(companions)
        case .ping: send(.ack, on: link)
        case .ended: finish()
        default: break
        }
    }

    private func finish() {
        stop()
        effects.ended()
    }

    private func applyLayout(_ layout: PresentationLayout) {
        guard layout.isValid else {
            effects.warn("invalid layout")
            return
        }
        effects.layout(layout)
        refreshLeads()
    }

    private func launch() {
        retryAt = nil
        generation = nil
        revision = -1
        pendingBatch = PresentationPendingBatch()
        lastFrameAt = now()
        report(.connecting)
        launchCount += 1
        let launch = launchCount
        let opened = transport.open(
            argv,
            onLine: { [weak self] line in self?.receive(line, launch: launch) },
            onClose: { [weak self] reason in self?.linkClosed(reason: reason, launch: launch) })
        link = opened
        let hello = PresentationHello(version: PresentationCodec.version, kinds: observer ? Self.observerKinds : PresentationHub.supportedKinds,
                                      mode: observer ? .mirror : .presenter)
        send(.hello(hello), on: opened)
    }

    private func fail(_ reason: String) {
        dropLink()
        failures += 1
        if warnedReason != reason {
            warnedReason = reason
            effects.warn(reason)
        }
        report(.failed(reason))
        // the role goes with the link it was granted to
        report(.mirror)
        retryAt = now().addingTimeInterval(RemoteRetryBackoff.delay(afterFailures: failures))
    }

    private func dropLink() {
        link?.stop()
        link = nil
        originKinds = []
        sentLeads = nil
    }

    private func send(_ body: PresentationFrame.Body, on link: RemotePresentationLink) {
        let frame = PresentationFrame(gen: generation ?? 0, rev: 0, body: body)
        if let line = try? PresentationCodec.encode(frame) { link.send(line) }
    }

    private func report(_ next: RemotePresentationConnection) {
        guard connection != next else { return }
        connection = next
        effects.connection(next)
    }

    private func report(_ next: PresentationMode) {
        guard mode != next else { return }
        mode = next
        effects.mode(next)
    }
}
