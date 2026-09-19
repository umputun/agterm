import Foundation
import Testing
@testable import agtermCore

@MainActor
struct RemotePresentationClientTests {
    final class Link: RemotePresentationLink {
        var sent: [PresentationFrame] = []
        var stopped = false
        func send(_ line: Data) {
            if let frame = try? PresentationCodec.decode(line.dropLast()) { sent.append(frame) }
        }
        func stop() { stopped = true }
    }

    final class Transport: RemotePresentationTransport {
        var links: [Link] = []
        var launches: [[String]] = []
        var lineCallbacks: [@MainActor (Data) -> Void] = []
        var closeCallbacks: [@MainActor (String) -> Void] = []
        func open(_ argv: [String], onLine: @escaping @MainActor (Data) -> Void,
                  onClose: @escaping @MainActor (String) -> Void) -> RemotePresentationLink {
            launches.append(argv)
            lineCallbacks.append(onLine)
            closeCallbacks.append(onClose)
            let link = Link()
            links.append(link)
            return link
        }

        func deliver(_ line: Data) { lineCallbacks.last?(line) }
        func close(_ reason: String) { closeCallbacks.last?(reason) }
    }

    final class Recorder {
        var statuses: [PresentationStatus?] = []
        var snapshotStatuses: [PresentationStatus?] = []
        var huds: [PresentationHud?] = []
        var notifies: [PresentationNotify] = []
        var connections: [RemotePresentationConnection] = []
        var modes: [PresentationMode] = []
        var asks: [PresentationAsk] = []
        var dismissals: [PresentationAskRef] = []
        var showsAsks = true
        var overlays: [PresentationOverlay] = []
        var showsOverlays = true
        var overlayCloses: [PresentationOverlayChange] = []
        var overlayResizes: [PresentationOverlayChange] = []
        var warnings: [String] = []
    }

    final class Clock { var now = Date(timeIntervalSince1970: 1_789_000_000) }

    let transport = Transport()
    let recorder = Recorder()
    let clock = Clock()

    static let blocked = PresentationStatus(status: .blocked, blink: false, color: nil, shape: nil, pane: nil,
                                            changedAt: nil)

    func makeClient(version: Int? = 1) -> RemotePresentationClient {
        let recorder = recorder
        let clock = clock
        let effects = RemotePresentationEffects(
            status: { recorder.statuses.append($0) },
            snapshotStatus: {
                recorder.statuses.append($0)
                recorder.snapshotStatuses.append($0)
            },
            hud: { recorder.huds.append($0) },
            notify: { recorder.notifies.append($0) },
            connection: { recorder.connections.append($0) },
            mode: { recorder.modes.append($0) },
            askRequest: {
                recorder.asks.append($0)
                return recorder.showsAsks
            },
            askDismiss: { recorder.dismissals.append($0) },
            overlayRequest: {
                recorder.overlays.append($0)
                return recorder.showsOverlays
            },
            overlayClose: { recorder.overlayCloses.append($0) },
            overlayResize: { recorder.overlayResizes.append($0) },
            warn: { recorder.warnings.append($0) })
        return RemotePresentationClient(argv: ["ssh", "buildbox", "present"], presentationVersion: version,
                                        transport: transport, effects: effects, now: { clock.now })
    }

    func line(_ body: PresentationFrame.Body, gen: Int = 7, rev: Int) -> Data {
        (try? PresentationCodec.encode(PresentationFrame(gen: gen, rev: rev, body: body)).dropLast()) ?? Data()
    }

    func connect(_ client: RemotePresentationClient, snapshot: PresentationSnapshot? = nil, gen: Int = 7,
                 mode: PresentationMode = .mirror) {
        let answer = PresentationHello(version: 1, kinds: ["status", "hud", "notify"], mode: mode)
        transport.deliver(line(.hello(answer), gen: gen, rev: 0))
        transport.deliver(line(.snapshot(snapshot ?? PresentationSnapshot(status: nil, hud: nil)), gen: gen, rev: 1))
    }

    @Test func startingLaunchesTheBridgeAndOpensWithHello() throws {
        let client = makeClient()

        client.start()

        #expect(transport.launches == [["ssh", "buildbox", "present"]])
        let hello = try #require(transport.links[0].sent.first)
        #expect(hello.body == .hello(PresentationHello(version: PresentationCodec.version,
                                                       kinds: PresentationHub.supportedKinds, mode: .presenter)))
        #expect(recorder.connections == [.connecting])
    }

    @Test func anOriginOfferingTheRoleIsAskedForIt() {
        let client = makeClient()
        client.start()

        connect(client, mode: .presenter)

        #expect(transport.links[0].sent.map(\.body).last == .presenterAcquire)
    }

    @Test func anOriginAnsweringMirrorIsNeverAskedForTheRole() {
        let client = makeClient()
        client.start()

        connect(client)

        #expect(!transport.links[0].sent.map(\.body).contains(.presenterAcquire))
        #expect(recorder.modes == [.mirror])
    }

    @Test func aGrantMakesThisMacThePresenter() {
        let client = makeClient()
        client.start()
        connect(client, mode: .presenter)

        transport.deliver(line(.presenterGranted, rev: 2))

        #expect(recorder.modes == [.mirror, .presenter])
    }

    @Test func aRefusalKeepsThisMacAMirror() {
        let client = makeClient()
        client.start()
        connect(client, mode: .presenter)

        transport.deliver(line(.presenterRefused, rev: 2))

        #expect(recorder.modes == [.mirror])
        #expect(recorder.connections.last == .connected)
    }

    // regression: a replacement client after soft close and undo left the row reading presenter when refused
    @Test func aReplacementClientRefusedTheRoleResetsTheRowToMirror() {
        let first = makeClient()
        first.start()
        connect(first, mode: .presenter)
        transport.deliver(line(.presenterGranted, rev: 2))
        first.stop()

        let replacement = makeClient()
        replacement.start()
        connect(replacement, gen: 8, mode: .presenter)
        transport.deliver(line(.presenterRefused, gen: 8, rev: 2))

        #expect(recorder.modes.last == .mirror)
    }

    static let handedOver = PresentationAsk(PendingAsk(id: "a1", title: "deploy?",
                                                       buttons: [ControlAskButton(id: "yes", label: "Yes")]),
                                            pane: nil, owner: 2)

    @Test func aHandedOverAskReachesTheAppAndNothingIsSentBack() {
        let client = makeClient()
        client.start()
        connect(client, mode: .presenter)

        transport.deliver(line(.askRequest(Self.handedOver), rev: 2))

        #expect(recorder.asks == [Self.handedOver])
        #expect(transport.links[0].sent.map(\.body).last == .presenterAcquire)
    }

    @Test func anAskTheAppCannotShowIsRefused() {
        let client = makeClient()
        client.start()
        connect(client, mode: .presenter)
        recorder.showsAsks = false

        transport.deliver(line(.askRequest(Self.handedOver), rev: 2))

        #expect(transport.links[0].sent.map(\.body).last == .askRejected(PresentationAskRef(id: "a1", owner: 2)))
    }

    @Test func theOriginsDismissalReachesTheApp() {
        let client = makeClient()
        client.start()
        connect(client, mode: .presenter)

        transport.deliver(line(.askDismiss(PresentationAskRef(id: "a1", owner: 2)), rev: 2))

        #expect(recorder.dismissals == [PresentationAskRef(id: "a1", owner: 2)])
    }

    static let overlay = PresentationOverlay(job: "j1", pane: nil, sizePercent: 60, backgroundColor: nil, follow: false,
                                             wait: true)

    @Test func aHandedOverOverlayReachesTheAppAndNothingIsSentBack() {
        let client = makeClient()
        client.start()
        connect(client, mode: .presenter)

        transport.deliver(line(.overlayRequest(Self.overlay), rev: 2))

        #expect(recorder.overlays == [Self.overlay])
        #expect(transport.links[0].sent.map(\.body).last == .presenterAcquire)
    }

    @Test func anOverlayTheAppCannotShowIsRefused() {
        let client = makeClient()
        client.start()
        connect(client, mode: .presenter)
        recorder.showsOverlays = false

        transport.deliver(line(.overlayRequest(Self.overlay), rev: 2))

        #expect(transport.links[0].sent.map(\.body).last == .overlayRejected(PresentationOverlayChange(job: "j1")))
    }

    @Test func theOriginsOverlayCloseAndResizeReachTheApp() {
        let client = makeClient()
        client.start()
        connect(client, mode: .presenter)

        transport.deliver(line(.overlayResize(PresentationOverlayChange(job: "j1", sizePercent: 40)), rev: 2))
        transport.deliver(line(.overlayClose(PresentationOverlayChange(job: "j1")), rev: 3))

        #expect(recorder.overlayResizes == [PresentationOverlayChange(job: "j1", sizePercent: 40)])
        #expect(recorder.overlayCloses == [PresentationOverlayChange(job: "j1")])
    }

    @Test func anAnswerGoesOutOnTheLink() {
        let client = makeClient()
        client.start()
        connect(client, mode: .presenter)
        let answer = PresentationFrame.Body.askResolve(PresentationAskAnswer(id: "a1", owner: 2, button: "yes"))

        client.answer(answer)

        #expect(transport.links[0].sent.map(\.body).last == answer)
    }

    @Test func anAnswerWithTheStreamDownIsDropped() {
        let client = makeClient()
        client.start()
        transport.close("exit 255")
        let sent = transport.links[0].sent.count

        client.answer(.askResolve(PresentationAskAnswer(id: "a1", owner: 2, button: "yes")))

        #expect(transport.links[0].sent.count == sent)
    }

    @Test func losingTheStreamDropsTheRoleAndAReconnectAsksAgain() {
        let client = makeClient()
        client.start()
        connect(client, mode: .presenter)
        transport.deliver(line(.presenterGranted, rev: 2))

        transport.close("exit 255")
        #expect(recorder.modes == [.mirror, .presenter, .mirror])

        clock.now = clock.now.addingTimeInterval(2)
        client.tick()
        connect(client, gen: 8, mode: .presenter)
        transport.deliver(line(.presenterGranted, gen: 8, rev: 2))

        #expect(transport.links[1].sent.map(\.body).last == .presenterAcquire)
        #expect(recorder.modes == [.mirror, .presenter, .mirror, .presenter])
    }

    @Test func theSnapshotIsAppliedAndMarksTheStreamConnected() {
        let client = makeClient()
        client.start()
        let hud = PresentationHud(spec: HudSpec(message: "deploying"), pane: nil, generation: 1, remaining: nil)

        connect(client, snapshot: PresentationSnapshot(status: Self.blocked, hud: hud))

        #expect(recorder.statuses == [Self.blocked])
        #expect(recorder.huds == [hud])
        #expect(recorder.connections == [.connecting, .connected])
    }

    @Test func aSnapshotsStatusIsReportedApartFromADelta() {
        let client = makeClient()
        client.start()

        connect(client, snapshot: PresentationSnapshot(status: Self.blocked, hud: nil))
        transport.deliver(line(.status(nil), rev: 2))

        #expect(recorder.snapshotStatuses == [Self.blocked])
        #expect(recorder.statuses == [Self.blocked, nil])
    }

    @Test func deltasAreAppliedInOrder() {
        let client = makeClient()
        client.start()
        connect(client)
        let notify = PresentationNotify(title: "build", body: "done", pane: nil, source: "control")

        transport.deliver(line(.status(Self.blocked), rev: 2))
        transport.deliver(line(.hud(nil), rev: 3))
        transport.deliver(line(.notify(notify), rev: 4))
        transport.deliver(line(.status(nil), rev: 5))

        #expect(recorder.statuses == [nil, Self.blocked, nil])
        #expect(recorder.huds == [nil, nil])
        #expect(recorder.notifies == [notify])
    }

    @Test func aFrameFromAnotherGenerationOrAnOldRevisionIsIgnored() {
        let client = makeClient()
        client.start()
        connect(client)
        transport.deliver(line(.status(Self.blocked), rev: 5))

        transport.deliver(line(.status(nil), gen: 6, rev: 9))
        transport.deliver(line(.status(nil), rev: 5))
        transport.deliver(line(.status(nil), rev: 3))

        #expect(recorder.statuses == [nil, Self.blocked])
    }

    @Test func anUnknownKindIsSkippedAndKeepsTheStreamUp() {
        let client = makeClient()
        client.start()
        connect(client)

        transport.deliver(line(.unknown("future.kind"), rev: 2))
        transport.deliver(line(.status(Self.blocked), rev: 3))

        #expect(recorder.statuses == [nil, Self.blocked])
        #expect(!transport.links[0].stopped)
    }

    @Test func aPingIsAcked() {
        let client = makeClient()
        client.start()
        connect(client)

        transport.deliver(line(.ping, rev: 2))

        #expect(transport.links[0].sent.last?.body == .ack)
        #expect(transport.links[0].sent.last?.gen == 7)
    }

    @Test func anUndecodableLineDropsTheLinkAndReconnects() {
        let client = makeClient()
        client.start()
        connect(client)

        transport.deliver(Data("not json".utf8))

        #expect(transport.links[0].stopped)
        #expect(recorder.connections.last == .failed("bad frame"))
    }

    @Test func aLinkThatEndsIsRetriedAfterABackoffThatDoublesToThirtySeconds() {
        let client = makeClient()
        client.start()
        var delays: [TimeInterval] = []

        for _ in 0..<7 {
            transport.close("exit 255")
            let launched = transport.launches.count
            var waited: TimeInterval = 0
            while transport.launches.count == launched, waited < 1000 {
                clock.now += 1
                waited += 1
                client.tick()
            }
            delays.append(waited)
        }

        #expect(delays == [1, 2, 4, 8, 16, 30, 30])
    }

    @Test func repeatedFailuresGrowTheCapToFiveMinutesAndItNeverStops() {
        let client = makeClient()
        client.start()
        var last: TimeInterval = 0

        for _ in 0..<40 {
            transport.close("exit 255")
            let launched = transport.launches.count
            last = 0
            while transport.launches.count == launched, last < 1000 {
                clock.now += 1
                last += 1
                client.tick()
            }
        }

        #expect(last == 300)
        #expect(transport.launches.count == 41)
    }

    @Test func aHealthyConnectionResetsTheBackoff() {
        let client = makeClient()
        client.start()
        for _ in 0..<4 {
            transport.close("exit 255")
            clock.now += 100
            client.tick()
        }
        connect(client)

        transport.close("exit 255")
        clock.now += 1
        client.tick()

        #expect(transport.launches.count == 6, "one second was enough again")
    }

    @Test func oneWarningPerFailureEpisodeOrChangedReason() {
        let client = makeClient()
        client.start()

        for reason in ["exit 255", "exit 255", "exit 1"] {
            transport.close(reason)
            clock.now += 400
            client.tick()
        }
        connect(client)
        transport.close("exit 255")

        #expect(recorder.warnings.count == 3)
    }

    @Test func aQuietStreamGoesStaleAndReconnects() {
        let client = makeClient()
        client.start()
        connect(client)

        clock.now += 29
        client.tick()
        #expect(!transport.links[0].stopped)
        clock.now += 2
        client.tick()

        #expect(transport.links[0].stopped)
        #expect(recorder.connections.last == .failed("no frames for 30 seconds"))
    }

    @Test func anyFrameKeepsTheStreamFresh() {
        let client = makeClient()
        client.start()
        connect(client)

        for rev in 2..<8 {
            clock.now += 20
            transport.deliver(line(.ping, rev: rev))
            client.tick()
        }

        #expect(!transport.links[0].stopped)
    }

    @Test func anOriginWithoutTheCapabilityIsNeverLaunched() {
        let client = makeClient(version: nil)

        client.start()
        clock.now += 1000
        client.tick()

        #expect(transport.launches.isEmpty)
        #expect(recorder.connections == [.unsupported])
    }

    @Test func stoppingEndsTheLinkAndNothingReconnects() {
        let client = makeClient()
        client.start()
        connect(client)

        client.stop()
        transport.close("exit 143")
        clock.now += 1000
        client.tick()

        #expect(transport.links[0].stopped)
        #expect(transport.launches.count == 1)
    }

    @Test func startingAgainAfterAStopOpensAFreshLinkAndAcceptsANewGeneration() {
        let client = makeClient()
        client.start()
        connect(client, gen: 7)
        client.stop()

        client.start()
        connect(client, snapshot: PresentationSnapshot(status: Self.blocked, hud: nil), gen: 9)

        #expect(transport.launches.count == 2)
        #expect(recorder.statuses.last == .some(Self.blocked))
    }

    @Test func aLateCloseFromAnEarlierLinkDoesNotTouchTheCurrentOne() {
        let client = makeClient()
        client.start()
        transport.close("exit 255")
        clock.now += 1
        client.tick()
        connect(client)

        transport.closeCallbacks[0]("exit 255")

        #expect(recorder.connections.last == .connected)
    }

    // a queued callback outlived its link and was taken for the current link's first frame
    @Test func aLateLineFromAnEarlierLinkThatIsGoneIsNotTakenForTheCurrentOne() {
        let client = makeClient()
        client.start()
        connect(client, gen: 7)
        transport.close("exit 255")
        clock.now += 1
        client.tick()
        transport.links.removeFirst()
        let answer = PresentationHello(version: 1, kinds: ["status"], mode: .mirror)

        transport.lineCallbacks[0](line(.hello(answer), gen: 7, rev: 0))
        connect(client, snapshot: PresentationSnapshot(status: Self.blocked, hud: nil), gen: 9)

        #expect(recorder.connections.last == .connected)
        #expect(recorder.statuses.last == .some(Self.blocked))
    }
}
