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

    static func status(shape: StatusShape?) -> PresentationStatus {
        PresentationStatus(status: .blocked, blink: true, color: "#ff8800", shape: shape, pane: .scratch, changedAt: 42)
    }

    @Test(arguments: StatusShape.allCases)
    func oneStatusReachesAViewerWithoutTheShapesKindWithOnlyAShapeItDecodes(shape: StatusShape) throws {
        let hub = makeHub()
        let legacy = Sink()
        let capable = Sink()

        try hub.subscribe(session: Self.session, hello: Self.hello, sink: legacy) { Self.empty }
        try hub.subscribe(session: Self.session, hello: Self.shapesHello, sink: capable) { Self.empty }
        hub.publish(.status(Self.status(shape: shape)), session: Self.session)

        let legacyShape = StatusShape.original.contains(shape) ? shape : nil
        #expect(capable.bodies.last == .status(Self.status(shape: shape)))
        #expect(legacy.bodies.last == .status(Self.status(shape: legacyShape)))
        let line = String(decoding: try PresentationCodec.encode(try #require(legacy.frames.last)), as: UTF8.self)
        #expect(line.contains("\"\(shape.rawValue)\"") == StatusShape.original.contains(shape))
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

        #expect(hub.sendToPresenter(sound, session: Self.session) == advertised)
        #expect(hub.sendToPresenter(ask, session: Self.session))

        #expect(sink.bodies.contains(sound) == advertised)
        #expect(sink.bodies.last == ask)
    }

    @Test func onlyThePresentersLinkClickReachesTheHost() throws {
        let hub = makeHub()
        var received: [PresentationFrame.Body] = []
        hub.onPresenterFrame = { _, body in received.append(body) }
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

    @Test(arguments: [true, false])
    func presenterSupportReflectsTheHelloOfTheCurrentPresenterOnly(advertised: Bool) throws {
        let hub = makeHub()
        let sink = Sink()
        let kinds = advertised ? ["status", PresentationHub.askFormKind] : ["status"]
        let id = try hub.subscribe(session: Self.session, hello: PresentationHello(version: 1, kinds: kinds, mode: .presenter),
                                   sink: sink) { Self.empty }
        #expect(!hub.presenterSupports(PresentationHub.askFormKind, session: Self.session))

        hub.receive(PresentationFrame(gen: sink.frames[0].gen, rev: 0, body: .presenterAcquire), from: id)

        #expect(hub.presenterSupports(PresentationHub.askFormKind, session: Self.session) == advertised)
        #expect(sink.bodies.first == .hello(PresentationHello(version: 1, kinds: kinds, mode: .presenter)))
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

        #expect(sink.closed == .stale)
        #expect(hub.subscriberCount(session: Self.session) == 0)
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
}
