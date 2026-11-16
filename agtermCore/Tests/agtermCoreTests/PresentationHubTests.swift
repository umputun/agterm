import Foundation
import Testing
@testable import agtermCore

@MainActor
struct PresentationHubTests {
    final class Sink: PresentationSink {
        var frames: [PresentationFrame] = []
        var closed: PresentationHub.CloseReason?
        var capacity = Int.max

        func offer(_ frame: PresentationFrame) -> Bool {
            guard frames.count < capacity else { return false }
            frames.append(frame)
            return true
        }

        func close(_ reason: PresentationHub.CloseReason) { closed = reason }

        var bodies: [PresentationFrame.Body] { frames.map(\.body) }
    }

    final class Clock {
        var now = Date(timeIntervalSince1970: 1_789_000_000)
    }

    static let hello = PresentationHello(version: 1, kinds: ["status", "hud", "notify"], mode: .mirror)
    static let session = UUID()
    static let blocked = PresentationStatus(status: .blocked, blink: false, color: nil, shape: nil, pane: nil,
                                            changedAt: nil)
    static let empty = PresentationSnapshot(status: nil, hud: nil)

    let clock = Clock()

    func makeHub() -> PresentationHub {
        let clock = clock
        return PresentationHub(staleTimeout: 30, now: { clock.now })
    }

    @Test func subscribeAnswersHelloThenTheSnapshotBeforeAnyDelta() throws {
        let hub = makeHub()
        let sink = Sink()
        let snapshot = PresentationSnapshot(status: Self.blocked, hud: nil)

        try hub.subscribe(session: Self.session, hello: Self.hello, sink: sink) { snapshot }
        hub.publish(.status(nil), session: Self.session)

        #expect(sink.bodies == [.hello(Self.hello), .snapshot(snapshot), .status(nil)])
    }

    @Test func aChangeMadeWhileTheSnapshotIsTakenLandsAfterIt() throws {
        let hub = makeHub()
        let sink = Sink()

        try hub.subscribe(session: Self.session, hello: Self.hello, sink: sink) {
            hub.publish(.status(Self.blocked), session: Self.session)
            return Self.empty
        }

        #expect(sink.bodies == [.hello(Self.hello), .snapshot(Self.empty), .status(Self.blocked)])
    }

    @Test func revisionsAreMonotonicWithinOneGeneration() throws {
        let hub = makeHub()
        let sink = Sink()

        try hub.subscribe(session: Self.session, hello: Self.hello, sink: sink) { Self.empty }
        hub.publish(.status(Self.blocked), session: Self.session)
        hub.publish(.hud(nil), session: Self.session)

        #expect(Set(sink.frames.map(\.gen)).count == 1)
        #expect(sink.frames.map(\.rev) == [0, 1, 2, 3])
    }

    @Test func aSecondSubscriberToOneSessionGetsItsOwnGeneration() throws {
        let hub = makeHub()
        let first = Sink()
        let second = Sink()

        try hub.subscribe(session: Self.session, hello: Self.hello, sink: first) { Self.empty }
        try hub.subscribe(session: Self.session, hello: Self.hello, sink: second) { Self.empty }
        hub.publish(.status(Self.blocked), session: Self.session)

        #expect(first.frames[0].gen != second.frames[0].gen)
        #expect(first.bodies.last == .status(Self.blocked))
        #expect(second.bodies.last == .status(Self.blocked))
        #expect(hub.subscriberCount(session: Self.session) == 2)
    }

    @Test func aPublishForAnotherSessionReachesNobody() throws {
        let hub = makeHub()
        let sink = Sink()

        try hub.subscribe(session: Self.session, hello: Self.hello, sink: sink) { Self.empty }
        hub.publish(.status(Self.blocked), session: UUID())

        #expect(sink.frames.count == 2)
    }

    @Test func aFullQueueDisconnectsThatSubscriberOnly() throws {
        let hub = makeHub()
        let stalled = Sink()
        let healthy = Sink()
        stalled.capacity = 2

        try hub.subscribe(session: Self.session, hello: Self.hello, sink: stalled) { Self.empty }
        try hub.subscribe(session: Self.session, hello: Self.hello, sink: healthy) { Self.empty }
        hub.publish(.status(Self.blocked), session: Self.session)

        #expect(stalled.closed == .stalled)
        #expect(healthy.closed == nil)
        #expect(healthy.bodies.last == .status(Self.blocked))
        #expect(hub.subscriberCount(session: Self.session) == 1)
    }

    @Test func unsubscribeReleasesTheSubscriber() throws {
        let hub = makeHub()
        let sink = Sink()

        let id = try hub.subscribe(session: Self.session, hello: Self.hello, sink: sink) { Self.empty }
        hub.unsubscribe(id)
        hub.publish(.status(Self.blocked), session: Self.session)

        #expect(sink.frames.count == 2)
        #expect(sink.closed == nil)
        #expect(hub.subscriberCount(session: Self.session) == 0)
    }

    @Test(arguments: [false, true])
    func aNewSubscriberReceivesAReturnToThePreviousLayout(staleHeartbeat: Bool) throws {
        let hub = makeHub()
        let first = Sink()
        let primary = UUID()
        let initial = PresentationLayout(panes: [primary], primary: primary, shown: false)
        let changed = PresentationLayout(panes: [primary, UUID()], primary: primary, axis: "vertical", shown: true)
        let id = try hub.subscribe(session: Self.session, hello: Self.hello, sink: first) {
            PresentationSnapshot(status: nil, hud: nil, layout: initial)
        }
        if staleHeartbeat {
            hub.heartbeat()
            clock.now += 31
            hub.heartbeat()
            #expect(first.closed == .stale)
        } else {
            hub.unsubscribe(id)
        }
        #expect(hub.subscriberCount(session: Self.session) == 0)
        hub.publishLayout(changed, session: Self.session)
        let next = Sink()
        let snapshot = PresentationSnapshot(status: nil, hud: nil, layout: changed)
        try hub.subscribe(session: Self.session, hello: Self.hello, sink: next) { snapshot }
        #expect(next.bodies.last == .snapshot(snapshot))

        hub.publishLayout(initial, session: Self.session)

        #expect(next.bodies.last == .layout(initial))
        #expect(next.frames.count == 3)
    }

    static let shapesHello = PresentationHello(version: 1, kinds: hello.kinds + [PresentationHub.statusShapesKind],
                                               mode: .mirror)
    static let checkmarkHello = PresentationHello(version: 1, kinds: shapesHello.kinds + [PresentationHub.statusCheckmarkKind],
                                                  mode: .mirror)

    static func status(shape: StatusShape?) -> PresentationStatus {
        PresentationStatus(status: .blocked, blink: true, color: "#ff8800", shape: shape, pane: .scratch, changedAt: 42)
    }

    @Test(arguments: StatusShape.allCases)
    func oneStatusReachesEachViewerWithOnlyAShapeItDecodes(shape: StatusShape) throws {
        let hub = makeHub()
        let legacy = Sink()
        let shapes = Sink()
        let current = Sink()

        try hub.subscribe(session: Self.session, hello: Self.hello, sink: legacy) { Self.empty }
        try hub.subscribe(session: Self.session, hello: Self.shapesHello, sink: shapes) { Self.empty }
        try hub.subscribe(session: Self.session, hello: Self.checkmarkHello, sink: current) { Self.empty }
        hub.publish(.status(Self.status(shape: shape)), session: Self.session)

        #expect(current.bodies.last == .status(Self.status(shape: shape)))
        #expect(shapes.bodies.last == .status(Self.status(shape: StatusShape.expanded.contains(shape) ? shape : nil)))
        #expect(legacy.bodies.last == .status(Self.status(shape: StatusShape.original.contains(shape) ? shape : nil)))
        let line = String(decoding: try PresentationCodec.encode(try #require(legacy.frames.last)), as: UTF8.self)
        #expect(line.contains("\"\(shape.rawValue)\"") == StatusShape.original.contains(shape))
    }

    @Test func aViewerWithoutTheCheckmarkKindGetsTheSnapshotAndAHeldDeltaWithoutTheCheckmark() throws {
        let hub = makeHub()
        let sink = Sink()
        let snapshot = PresentationSnapshot(status: Self.status(shape: .checkmark), hud: nil, context: "build")

        try hub.subscribe(session: Self.session, hello: Self.shapesHello, sink: sink) {
            hub.publish(.status(Self.status(shape: .bolt)), session: Self.session)
            return snapshot
        }

        let expected = PresentationSnapshot(status: Self.status(shape: nil), hud: nil, context: "build")
        #expect(sink.bodies == [.hello(Self.shapesHello), .snapshot(expected), .status(Self.status(shape: .bolt))])
    }

    @Test func aViewerWithoutTheShapesKindGetsTheSnapshotAndAHeldDeltaWithoutANewShape() throws {
        let hub = makeHub()
        let sink = Sink()
        let snapshot = PresentationSnapshot(status: Self.status(shape: .bolt), hud: nil, context: "build")

        try hub.subscribe(session: Self.session, hello: Self.hello, sink: sink) {
            hub.publish(.status(Self.status(shape: .seal)), session: Self.session)
            return snapshot
        }

        let expected = PresentationSnapshot(status: Self.status(shape: nil), hud: nil, context: "build")
        #expect(sink.bodies == [.hello(Self.hello), .snapshot(expected), .status(Self.status(shape: nil))])
    }

    @Test func aViewerAdvertisingTheShapesKindGetsTheSnapshotUnchanged() throws {
        let hub = makeHub()
        let sink = Sink()
        let snapshot = PresentationSnapshot(status: Self.status(shape: .triangleDown), hud: nil)

        try hub.subscribe(session: Self.session, hello: Self.shapesHello, sink: sink) { snapshot }

        #expect(sink.bodies == [.hello(Self.shapesHello), .snapshot(snapshot)])
        #expect(PresentationHub.supportedKinds.contains(PresentationHub.statusShapesKind))
    }

    @Test func aViewerAdvertisingTheCheckmarkKindGetsTheSnapshotUnchanged() throws {
        let hub = makeHub()
        let sink = Sink()
        let snapshot = PresentationSnapshot(status: Self.status(shape: .checkmark), hud: nil)

        try hub.subscribe(session: Self.session, hello: Self.checkmarkHello, sink: sink) { snapshot }

        #expect(sink.bodies == [.hello(Self.checkmarkHello), .snapshot(snapshot)])
        #expect(PresentationHub.supportedKinds.contains(PresentationHub.statusCheckmarkKind))
    }

    @Test func theAnswerAdvertisesOnlyKindsBothSidesSpeak() throws {
        let hub = makeHub()
        let sink = Sink()
        let hello = PresentationHello(version: 1, kinds: ["notify", "overlay.request", "status"], mode: .presenter)

        try hub.subscribe(session: Self.session, hello: hello, sink: sink) { Self.empty }

        #expect(sink.bodies.first == .hello(PresentationHello(version: 1, kinds: ["status", "notify"],
                                                              mode: .presenter)))
    }

    @Test(arguments: [true, false])
    func aNegotiatedKindReachesOnlyAPresenterThatAdvertisedIt(advertised: Bool) throws {
        let hub = makeHub()
        let sink = Sink()
        let kinds = advertised ? ["status", "sound"] : ["status"]
        let id = try hub.subscribe(session: Self.session, hello: PresentationHello(version: 1, kinds: kinds, mode: .presenter),
                                   sink: sink) { Self.empty }
        hub.receive(PresentationFrame(gen: sink.frames[0].gen, rev: 0, body: .presenterAcquire), from: id)
        let sound = PresentationFrame.Body.sound(PresentationSound(name: "Glass"))
        let ask = PresentationFrame.Body.askRequest(PresentationAsk(
            PendingAsk(id: "a1", title: "deploy?", buttons: [ControlAskButton(id: "y", label: "Yes")]), pane: nil, owner: 1))

        #expect(hub.send(sound, toOwner: sink.frames[0].gen) == advertised)
        #expect(hub.send(ask, toOwner: sink.frames[0].gen))

        #expect(sink.bodies.contains(sound) == advertised)
        #expect(sink.bodies.last == ask)
    }

    @Test func onlyThePresentersLinkClickReachesTheHost() throws {
        let hub = makeHub()
        var received: [PresentationFrame.Body] = []
        hub.onPresenterFrame = { _, _, body in received.append(body) }
        let hello = PresentationHello(version: 1, kinds: [PresentationHub.linkClickKind], mode: .presenter)
        let presenterSink = Sink()
        let presenter = try hub.subscribe(session: Self.session, hello: hello, sink: presenterSink) { Self.empty }
        hub.receive(PresentationFrame(gen: presenterSink.frames[0].gen, rev: 0, body: .presenterAcquire), from: presenter)
        let mirrorSink = Sink()
        let mirror = try hub.subscribe(session: Self.session, hello: hello, sink: mirrorSink) { Self.empty }
        let click = PresentationFrame.Body.linkClick(PresentationLinkClick(raw: "/a.md", pane: UUID(), mode: .overlay))

        hub.receive(PresentationFrame(gen: mirrorSink.frames[0].gen, rev: 1, body: click), from: mirror)
        hub.receive(PresentationFrame(gen: presenterSink.frames[0].gen, rev: 1, body: click), from: presenter)

        #expect(received == [click])
        #expect(presenterSink.bodies.first == .hello(hello))
    }

    @Test func aPageResultReachesTheHostWithItsSender() throws {
        let hub = makeHub()
        var received: [Int] = []
        hub.onPresenterFrame = { _, sender, _ in received.append(sender) }
        let hello = PresentationHello(version: 1, kinds: [PresentationHub.pageTextKind], mode: .presenter)
        let presenterSink = Sink()
        let presenter = try hub.subscribe(session: Self.session, hello: hello, sink: presenterSink) { Self.empty }
        hub.receive(PresentationFrame(gen: presenterSink.frames[0].gen, rev: 0, body: .presenterAcquire), from: presenter)
        let mirrorSink = Sink()
        let mirror = try hub.subscribe(session: Self.session, hello: hello, sink: mirrorSink) { Self.empty }
        let result = PresentationFrame.Body.pageResult(PresentationPageResult(page: "p1", seq: 1, ok: true, text: "following"))

        hub.receive(PresentationFrame(gen: mirrorSink.frames[0].gen, rev: 1, body: result), from: mirror)
        hub.receive(PresentationFrame(gen: presenterSink.frames[0].gen, rev: 1, body: result), from: presenter)

        #expect(received == [mirrorSink.frames[0].gen, presenterSink.frames[0].gen])
        #expect(PresentationHub.supportedKinds.contains(PresentationHub.pageTextKind))
    }

    @Test(arguments: [true, false])
    func supportReflectsTheViewersOwnHello(advertised: Bool) throws {
        let hub = makeHub()
        let sink = Sink()
        let other = Sink()
        let kinds = advertised ? ["status", PresentationHub.askFormKind] : ["status"]
        try hub.subscribe(session: Self.session, hello: PresentationHello(version: 1, kinds: kinds, mode: .presenter),
                          sink: sink) { Self.empty }
        try hub.subscribe(session: Self.session, hello: PresentationHello(version: 1, kinds: ["status", PresentationHub.askFormKind],
                                                                          mode: .presenter), sink: other) { Self.empty }

        #expect(hub.supports(PresentationHub.askFormKind, owner: sink.frames[0].gen) == advertised)
        #expect(hub.supports(PresentationHub.askFormKind, owner: other.frames[0].gen))
        #expect(sink.bodies.first == .hello(PresentationHello(version: 1, kinds: kinds, mode: .presenter)))
    }

    @Test func aBatchGoesAsChunksOfOneArrayWithEveryEntryBehindTheCommit() throws {
        let hub = makeHub()
        let sink = Sink()
        let id = try hub.subscribe(session: Self.session, hello: PresentationHello(version: 1, kinds: ["notify"], mode: .presenter),
                                   sink: sink) { Self.empty }
        hub.receive(PresentationFrame(gen: sink.frames[0].gen, rev: 0, body: .presenterAcquire), from: id)
        let small = (0..<40).map { PresentationNotify(title: "t", body: String(repeating: "x", count: 5000) + "\($0)", pane: nil, source: "osc") }
        let big = PresentationNotify(title: "t", body: String(repeating: "y", count: 150 * 1024), pane: nil, source: "osc")
        let before = sink.frames.count

        hub.batch(session: Self.session) {
            for notify in small { hub.send(.notify(notify), toOwner: sink.frames[0].gen) }
            hub.send(.notify(big), toOwner: sink.frames[0].gen)
        }

        let sent = sink.bodies.dropFirst(before)
        let chunks = sent.compactMap { if case .pendingChunk(let chunk) = $0 { chunk } else { nil } }
        #expect(chunks.count > 1)
        #expect(chunks.map(\.index) == Array(chunks.indices))
        #expect(Array(sent.dropLast()).allSatisfy { if case .pendingChunk = $0 { true } else { false } })
        #expect(sent.last == .pendingCommit)
        var batch = PresentationPendingBatch()
        for chunk in chunks { batch.add(chunk) }
        #expect(try batch.commit() == small.map { .notify($0) } + [.notify(big)])
    }

    @Test func aPeerWithNoUsableVersionIsRefused() {
        let hub = makeHub()
        let sink = Sink()
        let hello = PresentationHello(version: 0, kinds: [], mode: .mirror)

        #expect(throws: PresentationHub.SubscribeError.unsupportedVersion(0)) {
            try hub.subscribe(session: Self.session, hello: hello, sink: sink) { Self.empty }
        }
        #expect(sink.frames.isEmpty)
    }

    @Test func aHeartbeatPingsAndAnAckKeepsTheSubscriberAlive() throws {
        let hub = makeHub()
        let sink = Sink()
        let id = try hub.subscribe(session: Self.session, hello: Self.hello, sink: sink) { Self.empty }

        clock.now += 20
        hub.heartbeat()
        hub.receive(PresentationFrame(gen: sink.frames[0].gen, rev: 0, body: .ack), from: id)
        clock.now += 20
        hub.heartbeat()

        #expect(sink.bodies.filter { $0 == .ping }.count == 2)
        #expect(sink.closed == nil)
    }

    @Test func aMissedAckPastTheStaleTimeoutClosesTheSubscriber() throws {
        let hub = makeHub()
        let sink = Sink()
        try hub.subscribe(session: Self.session, hello: Self.hello, sink: sink) { Self.empty }

        clock.now += 20
        hub.heartbeat()
        clock.now += 20
        hub.heartbeat()
        #expect(sink.closed == nil)
        clock.now += 11
        hub.heartbeat()

        #expect(sink.closed == .stale)
        #expect(hub.subscriberCount(session: Self.session) == 0)
    }

    // regression: a heartbeat late past the stale timeout dropped viewers it had never given a ping to answer
    @Test func aLongGapBetweenHeartbeatsLeavesTheViewerAPingToAnswer() throws {
        let hub = makeHub()
        let sink = Sink()
        let id = try hub.subscribe(session: Self.session, hello: Self.hello, sink: sink) { Self.empty }

        clock.now += 60
        hub.heartbeat()
        #expect(sink.closed == nil)
        hub.receive(PresentationFrame(gen: sink.frames[0].gen, rev: 0, body: .ack), from: id)
        clock.now += 60
        hub.heartbeat()

        #expect(sink.closed == nil)
        #expect(sink.bodies.filter { $0 == .ping }.count == 2)
    }

    @Test func aPingFromTheViewerIsAnswered() throws {
        let hub = makeHub()
        let sink = Sink()
        let id = try hub.subscribe(session: Self.session, hello: Self.hello, sink: sink) { Self.empty }

        hub.receive(PresentationFrame(gen: sink.frames[0].gen, rev: 0, body: .ping), from: id)

        #expect(sink.bodies.last == .ack)
    }

    @Test func aFrameFromAnotherGenerationIsIgnored() throws {
        let hub = makeHub()
        let sink = Sink()
        let id = try hub.subscribe(session: Self.session, hello: Self.hello, sink: sink) { Self.empty }

        hub.receive(PresentationFrame(gen: sink.frames[0].gen + 1, rev: 0, body: .ping), from: id)

        #expect(sink.frames.count == 2)
    }

    @Test func onlyThePresentersStatusClearAndSeenReachTheHost() throws {
        let hub = makeHub()
        var received: [PresentationFrame.Body] = []
        hub.onPresenterFrame = { _, _, body in received.append(body) }
        let hello = PresentationHello(version: 1, kinds: [PresentationHub.statusClearKind], mode: .presenter)
        let presenterSink = Sink()
        let presenter = try hub.subscribe(session: Self.session, hello: hello, sink: presenterSink) { Self.empty }
        hub.receive(PresentationFrame(gen: presenterSink.frames[0].gen, rev: 0, body: .presenterAcquire), from: presenter)
        let mirrorSink = Sink()
        let mirror = try hub.subscribe(session: Self.session, hello: hello, sink: mirrorSink) { Self.empty }
        let clear = PresentationFrame.Body.statusClear(PresentationStatusClear(reason: .manual))
        let seen = PresentationFrame.Body.statusSeen(PresentationSeen(reason: .viewed))

        hub.receive(PresentationFrame(gen: mirrorSink.frames[0].gen, rev: 1, body: clear), from: mirror)
        hub.receive(PresentationFrame(gen: presenterSink.frames[0].gen, rev: 1, body: clear), from: presenter)
        hub.receive(PresentationFrame(gen: presenterSink.frames[0].gen, rev: 2, body: seen), from: presenter)

        #expect(received == [clear, seen])
        #expect(presenterSink.bodies.first == .hello(hello))
    }

    static let pane = UUID().uuidString

    static func mail(_ count: Int?) -> PresentationMail { PresentationMail(panes: count.map { [pane: $0] } ?? [:]) }

    static func mailSnapshot(_ count: Int?) -> PresentationSnapshot {
        PresentationSnapshot(status: nil, hud: nil, mail: mail(count))
    }

    func lastMail(_ sink: Sink) -> PresentationMail? {
        sink.bodies.reduce(nil) { last, body in
            switch body {
            case .snapshot(let snapshot): return snapshot.mail
            case .mail(let mail): return mail
            default: return last
            }
        }
    }

    // regression: a count acked while nobody watched must not hide the next identical count from a new viewer
    @Test func aViewerArrivingAfterMailWasAckedUnwatchedGetsTheNextCount() throws {
        let hub = makeHub()
        let first = Sink()
        let id = try hub.subscribe(session: Self.session, hello: Self.hello, sink: first) { Self.mailSnapshot(nil) }
        hub.publishMail(Self.mail(1), session: Self.session)
        hub.unsubscribe(id)

        let next = Sink()
        try hub.subscribe(session: Self.session, hello: Self.hello, sink: next) { Self.mailSnapshot(nil) }
        hub.publishMail(Self.mail(1), session: Self.session)

        #expect(lastMail(next) == Self.mail(1))
    }

    // regression: a viewer subscribing between an ack and a new send ends at the current count, as does the one before it
    @Test func everyViewerConvergesWhenOneSubscribesBetweenAnAckAndANewSend() throws {
        let hub = makeHub()
        let first = Sink()
        try hub.subscribe(session: Self.session, hello: Self.hello, sink: first) { Self.mailSnapshot(nil) }
        hub.publishMail(Self.mail(1), session: Self.session)

        let second = Sink()
        try hub.subscribe(session: Self.session, hello: Self.hello, sink: second) { Self.mailSnapshot(nil) }
        hub.publishMail(Self.mail(1), session: Self.session)

        #expect(lastMail(first) == Self.mail(1))
        #expect(lastMail(second) == Self.mail(1))
    }

    @Test func anUnchangedMailMapSendsNothing() throws {
        let hub = makeHub()
        let sink = Sink()
        try hub.subscribe(session: Self.session, hello: Self.hello, sink: sink) { Self.mailSnapshot(2) }
        let sent = sink.frames.count

        hub.publishMail(Self.mail(2), session: Self.session)

        #expect(sink.frames.count == sent)
    }

    @Test func mailPublishedWhileTheSnapshotIsTakenLandsAfterIt() throws {
        let hub = makeHub()
        let sink = Sink()
        try hub.subscribe(session: Self.session, hello: Self.hello, sink: sink) {
            hub.publishMail(Self.mail(1), session: Self.session)
            return Self.mailSnapshot(1)
        }
        hub.publishMail(Self.mail(1), session: Self.session)

        #expect(sink.bodies == [.hello(Self.hello), .snapshot(Self.mailSnapshot(1)), .mail(Self.mail(1))])
    }

    @Test func subscribedSessionsListsEverySessionWithAViewer() throws {
        let hub = makeHub()
        let other = UUID()
        try hub.subscribe(session: Self.session, hello: Self.hello, sink: Sink()) { Self.empty }
        let id = try hub.subscribe(session: other, hello: Self.hello, sink: Sink()) { Self.empty }
        hub.unsubscribe(id)

        #expect(hub.subscribedSessions == [Self.session])
    }

    static let leadHello = PresentationHello(version: 1, kinds: ["status", "sound", PresentationHub.leadReportKind], mode: .presenter)
    static let left = UUID()
    static let right = UUID()
    static let split = PresentationSnapshot(status: nil, hud: nil,
                                            layout: PresentationLayout(panes: [left, right], primary: left, axis: "horizontal", shown: true))

    func viewer(_ hub: PresentationHub, hello: PresentationHello = Self.leadHello,
                sink: Sink = Sink()) throws -> (id: PresentationHub.SubscriberID, gen: Int) {
        let id = try hub.subscribe(session: Self.session, hello: hello, sink: sink) { Self.split }
        return (id, sink.frames[0].gen)
    }

    func report(_ hub: PresentationHub, _ viewer: (id: PresentationHub.SubscriberID, gen: Int), _ leaders: [UUID]) {
        hub.receive(PresentationFrame(gen: viewer.gen, rev: 0, body: .leadReport(PresentationLeadReport(leaders: leaders))), from: viewer.id)
    }

    @Test func aPaneRoutesToTheViewerLeadingIt() throws {
        let hub = makeHub()
        let first = try viewer(hub)
        let second = try viewer(hub)

        report(hub, first, [Self.left])
        report(hub, second, [Self.right])

        #expect(hub.route(session: Self.session, pane: Self.left) == first.gen)
        #expect(hub.route(session: Self.session, pane: Self.right) == second.gen)
    }

    @Test func sessionWideWorkRoutesToThePrimaryPanesLeader() throws {
        let hub = makeHub()
        let first = try viewer(hub)
        let second = try viewer(hub)

        report(hub, second, [Self.left])
        report(hub, first, [Self.right])

        #expect(hub.route(session: Self.session, pane: nil) == second.gen)
    }

    @Test func anUnclaimedPaneFallsToTheGrantHolder() throws {
        let hub = makeHub()
        let holder = try viewer(hub)
        let leader = try viewer(hub)
        hub.receive(PresentationFrame(gen: holder.gen, rev: 0, body: .presenterAcquire), from: holder.id)

        report(hub, leader, [Self.right])

        #expect(hub.route(session: Self.session, pane: Self.left) == holder.gen)
        #expect(hub.route(session: Self.session, pane: nil) == holder.gen)
        #expect(hub.route(session: Self.session, pane: Self.right) == leader.gen)
    }

    @Test func nothingRoutesWithoutAClaimOrAGrant() throws {
        let hub = makeHub()
        _ = try viewer(hub)

        #expect(hub.route(session: Self.session, pane: Self.left) == nil)
        #expect(hub.route(session: Self.session, pane: nil) == nil)
    }

    @Test func aReportFromAViewerThatDidNotNegotiateTheKindIsIgnored() throws {
        let hub = makeHub()
        let older = try viewer(hub, hello: Self.hello)

        report(hub, older, [Self.left])

        #expect(hub.route(session: Self.session, pane: Self.left) == nil)
    }

    @Test func anEmptyReportClearsTheViewersClaims() throws {
        let hub = makeHub()
        let first = try viewer(hub)
        report(hub, first, [Self.left, Self.right])

        report(hub, first, [])

        #expect(hub.route(session: Self.session, pane: Self.left) == nil)
        #expect(hub.route(session: Self.session, pane: Self.right) == nil)
    }

    @Test func aDroppedViewersClaimsVanish() throws {
        let hub = makeHub()
        let first = try viewer(hub)
        report(hub, first, [Self.left])

        hub.unsubscribe(first.id)

        #expect(hub.route(session: Self.session, pane: Self.left) == nil)
    }

    @Test func aWithdrawnClaimLeavesThePaneWithTheOlderClaimant() throws {
        let hub = makeHub()
        let first = try viewer(hub)
        let second = try viewer(hub)

        report(hub, second, [Self.left])
        report(hub, first, [Self.left])
        #expect(hub.route(session: Self.session, pane: Self.left) == first.gen)
        report(hub, first, [])

        #expect(hub.route(session: Self.session, pane: Self.left) == second.gen)
    }

    @Test func claimsStayWithinTheirSession() throws {
        let hub = makeHub()
        let other = UUID()
        let sink = Sink()
        let id = try hub.subscribe(session: other, hello: Self.leadHello, sink: sink) { Self.split }
        hub.receive(PresentationFrame(gen: sink.frames[0].gen, rev: 0, body: .leadReport(PresentationLeadReport(leaders: [Self.left]))), from: id)

        #expect(hub.route(session: Self.session, pane: Self.left) == nil)
        #expect(hub.route(session: other, pane: Self.left) == sink.frames[0].gen)
    }

    @Test func aSendToAnOwnerReachesThatViewerAlone() throws {
        let hub = makeHub()
        let firstSink = Sink()
        let secondSink = Sink()
        let first = try viewer(hub, sink: firstSink)
        _ = try viewer(hub, sink: secondSink)

        #expect(hub.send(.sound(PresentationSound(name: nil)), toOwner: first.gen))

        #expect(firstSink.bodies.last == .sound(PresentationSound(name: nil)))
        #expect(!secondSink.bodies.contains(.sound(PresentationSound(name: nil))))
    }

    @Test func aSendToAGoneOwnerOrOfAnUnlistedKindIsRefused() throws {
        let hub = makeHub()
        let gone = try viewer(hub)
        let older = try viewer(hub, hello: Self.hello)
        hub.unsubscribe(gone.id)

        #expect(!hub.send(.sound(PresentationSound(name: nil)), toOwner: gone.gen))
        #expect(!hub.send(.sound(PresentationSound(name: nil)), toOwner: older.gen))
        #expect(!hub.isConnected(owner: gone.gen))
        #expect(hub.isConnected(owner: older.gen))
        #expect(hub.supports("status", owner: older.gen))
        #expect(!hub.supports("sound", owner: older.gen))
    }

    @Test func anAnswerEchoingAnotherViewersOwnerIsDropped() throws {
        let hub = makeHub()
        let owner = try viewer(hub)
        let other = try viewer(hub)
        var received: [(Int, PresentationFrame.Body)] = []
        hub.onPresenterFrame = { _, sender, body in received.append((sender, body)) }
        let answer = PresentationFrame.Body.askResolve(PresentationAskAnswer(id: "a1", owner: owner.gen, button: "y"))

        hub.receive(PresentationFrame(gen: other.gen, rev: 0, body: answer), from: other.id)
        hub.receive(PresentationFrame(gen: owner.gen, rev: 0, body: answer), from: owner.id)

        #expect(received.map(\.0) == [owner.gen])
        #expect(received.map(\.1) == [answer])
    }

    @Test func anOverlayOrPageAnswerArrivesWithItsSender() throws {
        let hub = makeHub()
        _ = try viewer(hub)
        let other = try viewer(hub)
        var senders: [Int] = []
        hub.onPresenterFrame = { _, sender, _ in senders.append(sender) }

        hub.receive(PresentationFrame(gen: other.gen, rev: 0, body: .overlayClosed(PresentationOverlayChange(job: "j1"))), from: other.id)
        hub.receive(PresentationFrame(gen: other.gen, rev: 0, body: .pageClosed(PresentationPageChange(page: "p1"))), from: other.id)

        #expect(senders == [other.gen, other.gen])
    }

    @Test func clearsSeenAndClicksComeFromTheHolderOrALeader() throws {
        let hub = makeHub()
        let holder = try viewer(hub)
        let leader = try viewer(hub)
        let bystander = try viewer(hub)
        hub.receive(PresentationFrame(gen: holder.gen, rev: 0, body: .presenterAcquire), from: holder.id)
        report(hub, leader, [Self.right])
        var senders: [Int] = []
        hub.onPresenterFrame = { _, sender, _ in senders.append(sender) }
        let bodies: [PresentationFrame.Body] = [
            .statusSeen(PresentationSeen(reason: .viewed)), .statusClear(PresentationStatusClear(reason: .manual)),
            .linkClick(PresentationLinkClick(raw: "a.md", pane: Self.right, mode: .overlay)),
        ]

        for body in bodies {
            for viewer in [holder, leader, bystander] {
                hub.receive(PresentationFrame(gen: viewer.gen, rev: 0, body: body), from: viewer.id)
            }
        }

        #expect(senders == [holder.gen, leader.gen, holder.gen, leader.gen, holder.gen, leader.gen])
    }

    @Test func everyDroppedViewerReportsTheLossOfItsOwnWork() throws {
        let hub = makeHub()
        let holder = try viewer(hub)
        let other = try viewer(hub)
        hub.receive(PresentationFrame(gen: holder.gen, rev: 0, body: .presenterAcquire), from: holder.id)
        var lost: [Int] = []
        hub.onOwnerLost = { session, owner in
            #expect(session == Self.session)
            lost.append(owner)
        }

        hub.unsubscribe(other.id)
        hub.unsubscribe(holder.id)

        #expect(lost == [other.gen, holder.gen])
    }

    @Test func aSessionBatchCommitsEachViewersShareOnItsOwn() throws {
        let hub = makeHub()
        let firstSink = Sink(), secondSink = Sink(), idleSink = Sink(), elsewhereSink = Sink()
        let first = try viewer(hub, sink: firstSink)
        let second = try viewer(hub, sink: secondSink)
        _ = try viewer(hub, sink: idleSink)
        let elsewhere = try hub.subscribe(session: UUID(), hello: Self.leadHello, sink: elsewhereSink) { Self.split }
        let sound = PresentationFrame.Body.sound(PresentationSound(name: nil))
        let idleBefore = idleSink.frames.count

        hub.batch(session: Self.session) {
            hub.send(sound, toOwner: first.gen)
            hub.send(.sound(PresentationSound(name: "Glass")), toOwner: second.gen)
            hub.send(sound, toOwner: elsewhere.generation)
            #expect(!firstSink.bodies.contains(sound))
        }

        #expect(try committed(firstSink) == [sound])
        #expect(try committed(secondSink) == [.sound(PresentationSound(name: "Glass"))])
        #expect(idleSink.frames.count == idleBefore)
        #expect(elsewhereSink.bodies.last == sound)
    }

    final class Passes {
        var sessions: [UUID] = []
    }

    private func passes(of hub: PresentationHub, after events: () -> Void) async -> (during: [UUID], later: [UUID]) {
        let seen = Passes(), sentinel = UUID()
        hub.onOpenWork = { seen.sessions.append($0) }
        events()
        let during = seen.sessions
        hub.scheduleOpenWork(sentinel)
        for _ in 0..<400 where !seen.sessions.contains(sentinel) { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(seen.sessions.last == sentinel)
        return (during, seen.sessions.filter { $0 != sentinel })
    }

    @Test(arguments: ["lead", "grant", "layout"])
    func anEventThatChangesWhereWorkBelongsRunsOnePassOnALaterTurn(event: String) async throws {
        let hub = makeHub()
        let first = try viewer(hub)

        let ran = await passes(of: hub) {
            switch event {
            case "lead": report(hub, first, [Self.left])
            case "grant": hub.receive(PresentationFrame(gen: first.gen, rev: 0, body: .presenterAcquire), from: first.id)
            default: hub.publishLayout(PresentationLayout(panes: [Self.left, Self.right], primary: Self.right, axis: "horizontal",
                                                          shown: true), session: Self.session)
            }
        }

        #expect(ran.during.isEmpty)
        #expect(ran.later == [Self.session])
    }

    @Test func eventsInOneTurnRunOnePassPerSession() async throws {
        let hub = makeHub()
        let first = try viewer(hub)
        let second = try viewer(hub)

        let ran = await passes(of: hub) {
            hub.receive(PresentationFrame(gen: first.gen, rev: 0, body: .presenterAcquire), from: first.id)
            report(hub, first, [Self.left])
            report(hub, second, [Self.right])
            hub.unsubscribe(second.id)
        }

        #expect(ran.later == [Self.session])
    }

    @Test func aRepeatedAcquireAndAnUnchangedLayoutRunNoPass() async throws {
        let hub = makeHub()
        let first = try viewer(hub)
        hub.receive(PresentationFrame(gen: first.gen, rev: 0, body: .presenterAcquire), from: first.id)
        _ = await passes(of: hub) {}

        let ran = await passes(of: hub) {
            hub.receive(PresentationFrame(gen: first.gen, rev: 0, body: .presenterAcquire), from: first.id)
            hub.publishLayout(Self.split.layout!, session: Self.session)
        }

        #expect(ran.later.isEmpty)
    }

    private func committed(_ sink: Sink) throws -> [PresentationFrame.Body] {
        #expect(sink.bodies.last == .pendingCommit)
        var batch = PresentationPendingBatch()
        for case .pendingChunk(let chunk) in sink.bodies { batch.add(chunk) }
        return try batch.commit()
    }
}
