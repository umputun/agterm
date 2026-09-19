import Foundation
import Testing
@testable import agtermCore

@MainActor
struct PresenterGrantTests {
    final class Sink: PresentationSink {
        var frames: [PresentationFrame] = []
        var closed: PresentationHub.CloseReason?

        func offer(_ frame: PresentationFrame) -> Bool {
            frames.append(frame)
            return true
        }

        func close(_ reason: PresentationHub.CloseReason) { closed = reason }

        var bodies: [PresentationFrame.Body] { frames.map(\.body) }
    }

    final class Clock {
        var now = Date(timeIntervalSince1970: 1_789_000_000)
    }

    static let presenterHello = PresentationHello(version: 1, kinds: ["status", "hud", "notify"], mode: .presenter)
    static let mirrorHello = PresentationHello(version: 1, kinds: ["status", "hud", "notify"], mode: .mirror)
    static let session = UUID()
    static let empty = PresentationSnapshot(status: nil, hud: nil)

    let clock = Clock()

    func makeHub() -> PresentationHub {
        let clock = clock
        return PresentationHub(staleTimeout: 30, now: { clock.now })
    }

    func acquire(_ hub: PresentationHub, _ id: PresentationHub.SubscriberID, gen: Int) {
        hub.receive(PresentationFrame(gen: gen, rev: 0, body: .presenterAcquire), from: id)
    }

    @Test func theFirstAcquireIsGrantedAndASecondViewerIsRefused() throws {
        let hub = makeHub()
        let first = Sink()
        let second = Sink()
        let firstID = try hub.subscribe(session: Self.session, hello: Self.presenterHello, sink: first) { Self.empty }
        let secondID = try hub.subscribe(session: Self.session, hello: Self.presenterHello, sink: second) { Self.empty }

        acquire(hub, firstID, gen: first.frames[0].gen)
        acquire(hub, secondID, gen: second.frames[0].gen)

        #expect(first.bodies.last == .presenterGranted)
        #expect(second.bodies.last == .presenterRefused)
        #expect(hub.hasPresenter(session: Self.session))
    }

    @Test func aRefusedViewerKeepsMirroring() throws {
        let hub = makeHub()
        let first = Sink()
        let second = Sink()
        let firstID = try hub.subscribe(session: Self.session, hello: Self.presenterHello, sink: first) { Self.empty }
        let secondID = try hub.subscribe(session: Self.session, hello: Self.presenterHello, sink: second) { Self.empty }
        acquire(hub, firstID, gen: first.frames[0].gen)
        acquire(hub, secondID, gen: second.frames[0].gen)

        hub.publish(.status(nil), session: Self.session)

        #expect(second.bodies.last == .status(nil))
        #expect(second.closed == nil)
    }

    @Test func aSecondAcquireNeverPreemptsTheHolder() throws {
        let hub = makeHub()
        let first = Sink()
        let second = Sink()
        let firstID = try hub.subscribe(session: Self.session, hello: Self.presenterHello, sink: first) { Self.empty }
        let secondID = try hub.subscribe(session: Self.session, hello: Self.presenterHello, sink: second) { Self.empty }
        acquire(hub, firstID, gen: first.frames[0].gen)
        let generation = hub.presenterGeneration(session: Self.session)

        acquire(hub, secondID, gen: second.frames[0].gen)
        acquire(hub, firstID, gen: first.frames[0].gen)

        #expect(first.bodies.last == .presenterGranted)
        #expect(hub.presenterGeneration(session: Self.session) == generation)
    }

    @Test func aClosedStreamRevokesTheRoleAndBumpsTheGeneration() throws {
        let hub = makeHub()
        let first = Sink()
        let second = Sink()
        let firstID = try hub.subscribe(session: Self.session, hello: Self.presenterHello, sink: first) { Self.empty }
        let secondID = try hub.subscribe(session: Self.session, hello: Self.presenterHello, sink: second) { Self.empty }
        acquire(hub, firstID, gen: first.frames[0].gen)
        let generation = hub.presenterGeneration(session: Self.session)

        hub.unsubscribe(firstID)

        #expect(!hub.hasPresenter(session: Self.session))
        #expect(hub.presenterGeneration(session: Self.session) == generation + 1)
        acquire(hub, secondID, gen: second.frames[0].gen)
        #expect(second.bodies.last == .presenterGranted)
    }

    @Test func aMissedHeartbeatRevokesTheRole() throws {
        let hub = makeHub()
        let sink = Sink()
        let id = try hub.subscribe(session: Self.session, hello: Self.presenterHello, sink: sink) { Self.empty }
        acquire(hub, id, gen: sink.frames[0].gen)
        let generation = hub.presenterGeneration(session: Self.session)

        clock.now = clock.now.addingTimeInterval(31)
        hub.heartbeat()

        #expect(sink.closed == .stale)
        #expect(!hub.hasPresenter(session: Self.session))
        #expect(hub.presenterGeneration(session: Self.session) == generation + 1)
    }

    @Test func aSliceOneViewerIsAnsweredAsAMirror() throws {
        let hub = makeHub()
        let sink = Sink()

        try hub.subscribe(session: Self.session, hello: Self.mirrorHello, sink: sink) { Self.empty }

        #expect(sink.bodies.first == .hello(Self.mirrorHello))
        #expect(!hub.hasPresenter(session: Self.session))
    }

    @Test func aViewerAskingToPresentIsOfferedTheRole() throws {
        let hub = makeHub()
        let sink = Sink()

        try hub.subscribe(session: Self.session, hello: Self.presenterHello, sink: sink) { Self.empty }

        #expect(sink.bodies.first == .hello(Self.presenterHello))
    }

    @Test func eachSessionHasItsOwnPresenter() throws {
        let hub = makeHub()
        let other = UUID()
        let first = Sink()
        let second = Sink()
        let firstID = try hub.subscribe(session: Self.session, hello: Self.presenterHello, sink: first) { Self.empty }
        let secondID = try hub.subscribe(session: other, hello: Self.presenterHello, sink: second) { Self.empty }

        acquire(hub, firstID, gen: first.frames[0].gen)
        acquire(hub, secondID, gen: second.frames[0].gen)

        #expect(first.bodies.last == .presenterGranted)
        #expect(second.bodies.last == .presenterGranted)
    }
}
