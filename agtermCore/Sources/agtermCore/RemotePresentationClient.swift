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
    public var hud: @MainActor (PresentationHud?) -> Void
    public var notify: @MainActor (PresentationNotify) -> Void
    public var connection: @MainActor (RemotePresentationConnection) -> Void
    public var warn: @MainActor (String) -> Void

    public init(status: @escaping @MainActor (PresentationStatus?) -> Void,
                hud: @escaping @MainActor (PresentationHud?) -> Void,
                notify: @escaping @MainActor (PresentationNotify) -> Void,
                connection: @escaping @MainActor (RemotePresentationConnection) -> Void,
                warn: @escaping @MainActor (String) -> Void) {
        self.status = status
        self.hud = hud
        self.notify = notify
        self.connection = connection
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
    static let firstCap: TimeInterval = 30
    static let lateCap: TimeInterval = 300
    /// Failures in a row before the cap grows. A laptop asleep for the night should not be retried every
    /// thirty seconds, and should never be given up on either.
    static let failuresBeforeLateCap = 8

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
    private var lastFrameAt = Date.distantPast
    private var retryAt: Date?
    private var failures = 0
    private var warnedReason: String?
    private var connection: RemotePresentationConnection?

    public init(argv: [String], presentationVersion: Int?, transport: RemotePresentationTransport,
                effects: RemotePresentationEffects, now: @escaping () -> Date = Date.init) {
        self.argv = argv
        self.presentationVersion = presentationVersion
        self.transport = transport
        self.effects = effects
        self.now = now
    }

    /// Opens the stream. An origin that predates the protocol is never launched at all.
    public func start() {
        guard !running else { return }
        guard presentationVersion != nil else {
            report(.unsupported)
            return
        }
        running = true
        launch()
    }

    /// Ends the stream for good, until `start` is called again. Reports nothing: the row is leaving.
    public func stop() {
        running = false
        retryAt = nil
        dropLink()
    }

    /// Reconnects when a retry is due and drops a link that has gone quiet.
    public func tick() {
        guard running else { return }
        if link != nil, now().timeIntervalSince(lastFrameAt) > Self.staleAfter {
            fail("no frames for \(Int(Self.staleAfter)) seconds")
            return
        }
        if link == nil, let retryAt, now() >= retryAt { launch() }
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
        switch frame.body {
        case .snapshot(let snapshot):
            failures = 0
            warnedReason = nil
            report(.connected)
            effects.status(snapshot.status)
            effects.hud(snapshot.hud)
        case .status(let status): effects.status(status)
        case .hud(let hud): effects.hud(hud)
        case .notify(let notify): effects.notify(notify)
        case .ping: send(.ack, on: link)
        case .hello, .ack, .unknown: break
        }
    }

    private func launch() {
        retryAt = nil
        generation = nil
        revision = -1
        lastFrameAt = now()
        report(.connecting)
        launchCount += 1
        let launch = launchCount
        let opened = transport.open(
            argv,
            onLine: { [weak self] line in self?.receive(line, launch: launch) },
            onClose: { [weak self] reason in self?.linkClosed(reason: reason, launch: launch) })
        link = opened
        let hello = PresentationHello(version: PresentationCodec.version, kinds: PresentationHub.supportedKinds,
                                      mode: .mirror)
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
        let cap = failures > Self.failuresBeforeLateCap ? Self.lateCap : Self.firstCap
        let delay = min(pow(2, Double(min(failures - 1, 30))), cap)
        retryAt = now().addingTimeInterval(delay)
    }

    private func dropLink() {
        link?.stop()
        link = nil
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
}
