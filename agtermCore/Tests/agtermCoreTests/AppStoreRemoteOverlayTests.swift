import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreRemoteOverlayTests {
    final class Sink: PresentationSink {
        var frames: [PresentationFrame] = []

        func offer(_ frame: PresentationFrame) -> Bool {
            frames.append(frame)
            return true
        }

        func close(_: PresentationHub.CloseReason) {}

        var bodies: [PresentationFrame.Body] { frames.map(\.body) }
    }

    final class Clock {
        var now = Date(timeIntervalSince1970: 1_789_000_000)
    }

    static let context = OverlayLaunchContext(command: "revdiff", cwd: "/tmp", sessionEnvironment: [:])

    let store = makeStore()
    let hub = PresentationHub(staleTimeout: 30)
    let clock = Clock()
    let jobs: OverlayJobs
    let presenter = Sink()

    init() {
        let clock = clock
        jobs = OverlayJobs(now: { clock.now })
    }

    private func origin(presented: Bool = true, split: Bool = false) throws -> (Session, PresentationHub.SubscriberID?) {
        store.presentationHub = hub
        store.overlayJobs = jobs
        jobs.onFinished = { [store] in store.finishRemoteOverlay($0) }
        hub.onPresenterLost = { [store] in store.remoteOverlayPresenterLost(forSession: $0) }
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        if split { store.toggleSplit(session.id) }
        guard presented else { return (session, nil) }
        let hello = PresentationHello(version: 1, kinds: [], mode: .presenter)
        let id = try hub.subscribe(session: session.id, hello: hello, sink: presenter) { PresentationSnapshot(status: nil, hud: nil) }
        hub.receive(PresentationFrame(gen: presenter.frames[0].gen, rev: 0, body: .presenterAcquire), from: id)
        return (session, id)
    }

    private func open(_ session: Session, pane: OverlayPane? = nil, size: Int? = nil, wait: Bool = false) -> RemoteOverlayOpen {
        store.openRemoteOverlay(session.id, options: ControlSessionOverlayOpenOptions(
            command: "revdiff", cwd: nil, wait: wait, sizePercent: size, backgroundColor: "#102030", follow: true, pane: pane),
                                context: Self.context)
    }

    private func job(of result: RemoteOverlayOpen) throws -> String {
        guard case .opened(let job) = result else { throw OpenFailed() }
        return job
    }

    private struct OpenFailed: Error {}

    @Test func aSessionWithoutAPresenterOpensItsOverlayHere() throws {
        let (session, _) = try origin(presented: false)

        #expect(open(session) == .notPresented)
        #expect(session.remoteOverlays.slots.isEmpty)
    }

    @Test func anOpenReservesTheSlotAsksThePresenterAndCoversNothingHere() throws {
        let (session, _) = try origin()

        let job = try job(of: open(session, size: 60, wait: true))

        #expect(presenter.bodies.last == .overlayRequest(PresentationOverlay(
            job: job, pane: nil, sizePercent: 60, backgroundColor: "#102030", follow: true, wait: true)))
        #expect(session.remoteOverlays.slot(nil) == RemoteOverlaySlot(job: job, pane: nil, sizePercent: 60, wait: true))
        #expect(!session.overlayActive)
        #expect(!session.programOverlayActive)
        #expect(jobs.job(job)?.context == Self.context)
    }

    @Test func aPaneOverlayNamesTheOriginsPaneIdentity() throws {
        let (session, _) = try origin(split: true)

        let job = try job(of: open(session, pane: .right))

        let pane = try #require(session.splitPaneIdentity)
        #expect(presenter.bodies.last == .overlayRequest(PresentationOverlay(
            job: job, pane: .identity(pane), sizePercent: nil, backgroundColor: "#102030", follow: true, wait: false)))
    }

    @Test func aSecondOpenOnAReservedSlotIsRefused() throws {
        let (session, _) = try origin()
        _ = open(session)

        #expect(open(session) == .slotTaken)
    }

    @Test func aSlotHoldingALocalProgramOverlayIsRefused() throws {
        let (session, _) = try origin()
        store.openOverlay(session.id, command: "top")

        #expect(open(session) == .slotTaken)
    }

    @Test func anExitCodeLandsInTheSlotResultAndFreesTheSlot() throws {
        let (session, _) = try origin()
        let job = try job(of: open(session))
        _ = jobs.claim(job) {}
        jobs.started(job)

        jobs.finish(job, .exited(3))

        #expect(session.overlayExitCode == 3)
        #expect(session.remoteOverlays.slots.isEmpty)
    }

    @Test func aPaneJobsExitCodeLandsInThatPanesResult() throws {
        let (session, _) = try origin(split: true)
        let job = try job(of: open(session, pane: .right))

        jobs.finish(job, .exited(4))

        #expect(session.paneOverlayExitCode(.right) == 4)
        #expect(session.overlayExitCode == nil)
    }

    @Test(arguments: [(OverlayJobOutcome.canceled, "canceled"), (.launchFailed, "launch-failed"), (.unknown, "unknown")])
    func anOutcomeWithoutAnExitCodeIsRecordedAsTheSlotsFailure(_ outcome: OverlayJobOutcome, _ name: String) throws {
        let (session, _) = try origin()
        let job = try job(of: open(session))

        jobs.finish(job, outcome)

        #expect(session.remoteOverlays.failure(nil) == name)
        #expect(session.overlayExitCode == nil)
    }

    @Test func aLocalOpenClearsARemoteFailure() throws {
        let (session, _) = try origin()
        jobs.finish(try job(of: open(session)), .launchFailed)

        store.openOverlay(session.id, command: "top")

        #expect(session.remoteOverlays.failure(nil) == nil)
    }

    @Test func aRemoteOpenClearsTheSlotsPreviousExitCode() throws {
        let (session, _) = try origin()
        session.overlayExitCode = 9

        _ = open(session)

        #expect(session.overlayExitCode == nil)
    }

    @Test func aWaitJobThatEndsKeepsItsSlotHeldWithItsResultRecorded() throws {
        let (session, _) = try origin()
        let job = try job(of: open(session, wait: true))

        jobs.finish(job, .exited(3))

        #expect(session.remoteOverlays.slot(nil)?.ended == true)
        #expect(session.overlayExitCode == 3)
        #expect(open(session) == .slotTaken)
    }

    @Test func closingAHeldSurfaceFreesItsSlotAndKeepsTheResult() throws {
        let (session, _) = try origin()
        let job = try job(of: open(session, wait: true))
        jobs.finish(job, .exited(3))

        #expect(store.closeRemoteOverlay(session.id, pane: nil))

        #expect(presenter.bodies.last == .overlayClose(PresentationOverlayChange(job: job)))
        #expect(session.remoteOverlays.slots.isEmpty)
        #expect(session.overlayExitCode == 3)
    }

    @Test func theViewerClosingAHeldSurfaceFreesItsSlot() throws {
        let (session, _) = try origin()
        let job = try job(of: open(session, wait: true))
        jobs.finish(job, .exited(0))

        store.remoteOverlaySurfaceClosed(job, forSession: session.id)

        #expect(session.remoteOverlays.slots.isEmpty)
    }

    @Test func aSurfaceClosedBeforeItsWaitJobEndsFreesTheSlotAtTheEnd() throws {
        let (session, _) = try origin()
        let job = try job(of: open(session, wait: true))
        _ = jobs.claim(job) {}
        jobs.started(job)

        store.remoteOverlaySurfaceClosed(job, forSession: session.id)
        #expect(session.remoteOverlays.slot(nil)?.job == job)
        jobs.finish(job, .canceled)

        #expect(session.remoteOverlays.slots.isEmpty)
    }

    private func presentAgain(_ session: Session) throws -> Sink {
        let sink = Sink()
        let id = try hub.subscribe(session: session.id, hello: PresentationHello(version: 1, kinds: [], mode: .presenter),
                                   sink: sink) { PresentationSnapshot(status: nil, hud: nil) }
        hub.receive(PresentationFrame(gen: sink.frames[0].gen, rev: 0, body: .presenterAcquire), from: id)
        return sink
    }

    @Test func losingThePresenterCancelsAnUnclaimedJobAndALateClaimLaunchesNothing() throws {
        let (session, id) = try origin()
        let job = try job(of: open(session))

        hub.unsubscribe(try #require(id))

        #expect(jobs.job(job)?.state == .finished(.canceled))
        #expect(jobs.claim(job) {} == nil)
        #expect(session.remoteOverlays.slots.isEmpty)
    }

    @Test(arguments: [OverlayJobOutcome.exited(3), .unknown])
    func losingThePresenterFreesAHeldSurfacesSlotAndKeepsItsOutcome(_ outcome: OverlayJobOutcome) throws {
        let (session, id) = try origin()
        let job = try job(of: open(session, wait: true))
        jobs.finish(job, outcome)

        hub.unsubscribe(try #require(id))

        #expect(session.remoteOverlays.slots.isEmpty)
        #expect(jobs.job(job)?.state == .finished(outcome))
    }

    @Test func aRunningJobKeepsItsSlotAcrossAReconnectAndFreesItOnItsOutcome() throws {
        let (session, id) = try origin()
        let job = try job(of: open(session, wait: true))
        _ = jobs.claim(job) {}
        jobs.started(job)

        hub.unsubscribe(try #require(id))
        _ = try presentAgain(session)
        #expect(session.remoteOverlays.slot(nil)?.job == job)
        jobs.finish(job, .exited(0))

        #expect(session.remoteOverlays.slots.isEmpty)
        #expect(session.overlayExitCode == 0)
    }

    @Test func aCloseAfterTheStreamBrokeStillReachesTheRunningJob() throws {
        let (session, id) = try origin()
        let job = try job(of: open(session))
        var reached = 0
        _ = jobs.claim(job) { reached += 1 }
        jobs.started(job)
        hub.unsubscribe(try #require(id))

        #expect(store.closeRemoteOverlay(session.id, pane: nil))
        #expect(reached == 1)
        jobs.finish(job, .canceled)

        #expect(session.remoteOverlays.slots.isEmpty)
        #expect(session.remoteOverlays.failure(nil) == "canceled")
    }

    @Test func anOldJobEndingLeavesTheNewPresentersJobAlone() throws {
        let (session, id) = try origin(split: true)
        let old = try job(of: open(session, pane: .left))
        _ = jobs.claim(old) {}
        jobs.started(old)
        hub.unsubscribe(try #require(id))
        _ = try presentAgain(session)
        let newer = try job(of: open(session, pane: .right))

        jobs.finish(old, .exited(1))

        #expect(session.remoteOverlays.slots.map(\.job) == [newer])
        #expect(jobs.job(newer)?.state == .unclaimed(deadline: clock.now.addingTimeInterval(OverlayJobs.launchWindow)))
    }

    @Test(arguments: [false, true])
    func aClaimThatNeverStartsAfterTheLossEndsUnknownAndFreesTheSlot(_ reconnect: Bool) throws {
        let (session, id) = try origin()
        let job = try job(of: open(session))
        _ = jobs.claim(job) {}

        hub.unsubscribe(try #require(id))
        if reconnect { _ = try presentAgain(session) }
        clock.now = clock.now.addingTimeInterval(OverlayJobs.startWindow)
        jobs.expire()

        #expect(jobs.job(job)?.state == .finished(.unknown))
        #expect(session.remoteOverlays.slots.isEmpty)
        #expect(session.remoteOverlays.failure(nil) == "unknown")
    }

    @Test func aRefusalFromThePresenterFailsTheLaunch() throws {
        let (session, _) = try origin()
        let job = try job(of: open(session))

        store.rejectRemoteOverlay(job, forSession: session.id)

        #expect(jobs.job(job)?.state == .finished(.launchFailed))
        #expect(session.remoteOverlays.failure(nil) == "launch-failed")
    }

    @Test func closingAnUnclaimedJobCancelsItAndAsksThePresenterToTakeItDown() throws {
        let (session, _) = try origin()
        let job = try job(of: open(session))

        #expect(store.closeRemoteOverlay(session.id, pane: nil))

        #expect(presenter.bodies.last == .overlayClose(PresentationOverlayChange(job: job)))
        #expect(jobs.job(job)?.state == .finished(.canceled))
        #expect(session.remoteOverlays.slots.isEmpty)
    }

    @Test func closingARunningJobReachesItsHelperAndKeepsTheSlotUntilItReports() throws {
        let (session, _) = try origin()
        let job = try job(of: open(session))
        var reached = 0
        _ = jobs.claim(job) { reached += 1 }
        jobs.started(job)

        store.closeRemoteOverlay(session.id, pane: nil)

        #expect(reached == 1)
        #expect(session.remoteOverlays.slot(nil)?.job == job)
    }

    @Test func closingASlotNoViewerHoldsIsRefused() throws {
        let (session, _) = try origin()

        #expect(!store.closeRemoteOverlay(session.id, pane: nil))
    }

    @Test func aResizeIsRecordedAndSentWhileTheJobsStreamIsUp() throws {
        let (session, _) = try origin()
        let job = try job(of: open(session))

        #expect(store.resizeRemoteOverlay(session.id, sizePercent: 40) == true)

        #expect(session.remoteOverlays.slot(nil)?.sizePercent == 40)
        #expect(presenter.bodies.last == .overlayResize(PresentationOverlayChange(job: job, sizePercent: 40)))
    }

    @Test func aResizeFailsOnceTheJobsStreamIsGoneEvenWithANewerOne() throws {
        let (session, id) = try origin()
        let job = try job(of: open(session))
        _ = jobs.claim(job) {}
        jobs.started(job)
        hub.unsubscribe(try #require(id))
        let newer = Sink()
        let newerID = try hub.subscribe(session: session.id, hello: PresentationHello(version: 1, kinds: [], mode: .presenter),
                                        sink: newer) { PresentationSnapshot(status: nil, hud: nil) }
        hub.receive(PresentationFrame(gen: newer.frames[0].gen, rev: 0, body: .presenterAcquire), from: newerID)

        #expect(store.resizeRemoteOverlay(session.id, sizePercent: 40) == false)
    }

    @Test func aResizeWithNoRemoteOverlayIsNotTheRemotePaths() throws {
        let (session, _) = try origin()

        #expect(store.resizeRemoteOverlay(session.id, sizePercent: 40) == nil)
    }

    @Test func theTreeReportsTheReservedSlotAndNoLocalOverlay() throws {
        let (session, _) = try origin(split: true)
        _ = open(session, size: 50)
        _ = open(session, pane: .right)

        let node = try #require(store.controlTree().workspaces[0].sessions.first { $0.id == session.id.uuidString })

        #expect(node.remoteOverlays == [ControlRemoteOverlayNode(pane: nil, sizePercent: 50),
                                        ControlRemoteOverlayNode(pane: "right", sizePercent: nil)])
        #expect(!node.overlay)
        #expect(node.paneOverlays == nil)
    }

    @Test func theTreeOmitsRemoteOverlaysWhenNoneIsHeld() throws {
        let (session, _) = try origin()

        let node = try #require(store.controlTree().workspaces[0].sessions.first { $0.id == session.id.uuidString })

        #expect(node.remoteOverlays == nil)
    }

    // regression: a soft-closed source left the store before loss cleanup could find it, and undo brought the slots back
    @Test func softClosingTheSourceEndsItsJobsAndUndoRestoresNoReservation() throws {
        let (session, _) = try origin(split: true)
        let unclaimed = try job(of: open(session))
        let running = try job(of: open(session, pane: .right, wait: true))
        var reached = 0
        _ = jobs.claim(running) { reached += 1 }
        jobs.started(running)

        #expect(store.softCloseSession(session.id))

        #expect(presenter.bodies.contains(.overlayClose(PresentationOverlayChange(job: unclaimed))))
        #expect(presenter.bodies.contains(.overlayClose(PresentationOverlayChange(job: running))))
        #expect(jobs.claim(unclaimed) {} == nil)
        #expect(reached == 1)
        jobs.finish(running, .exited(0))
        #expect(store.undoPendingClose())
        #expect(session.remoteOverlays.slots.isEmpty)
        #expect(session.remoteOverlays.failure(nil) == nil)
        #expect(session.paneOverlayExitCode(.right) == nil)
    }

    @Test func closingTheSourceFreesAHeldSlot() throws {
        let (session, _) = try origin()
        let job = try job(of: open(session, wait: true))
        jobs.finish(job, .exited(3))

        store.closeSession(session.id)

        #expect(session.remoteOverlays.slots.isEmpty)
    }

    @Test func aPaneTheOriginDoesNotHaveIsRefusedWithoutAJob() throws {
        let (session, _) = try origin()

        #expect(open(session, pane: .right) == .paneMissing)

        #expect(session.remoteOverlays.slots.isEmpty)
        #expect(!presenter.bodies.contains { if case .overlayRequest = $0 { true } else { false } })
    }

    @Test func aRefusedWaitRequestRecordsItsFailureAndFreesTheSlot() throws {
        let (session, _) = try origin()
        let job = try job(of: open(session, wait: true))

        store.rejectRemoteOverlay(job, forSession: session.id)

        #expect(session.remoteOverlays.failure(nil) == "launch-failed")
        #expect(session.remoteOverlays.slots.isEmpty)
        _ = try self.job(of: open(session))
    }

    @Test func aRemoteOpenTakesTheSlotFromAnOriginHud() throws {
        let (session, _) = try origin()
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "working"), file: "/tmp/hud",
                      size: HudPanelSize(widthPercent: 30, heightPercent: 8))

        _ = try job(of: open(session))

        #expect(!session.hudActive)
        #expect(!session.overlayActive)
    }

    private func realizeSplit(_ session: Session) {
        session.surface = SpySurface(paneToken: "primary")
        session.splitSurface = SpySurface(paneToken: "split")
    }

    @Test func aPaneJobFollowsItsPaneAcrossASwap() throws {
        let (session, _) = try origin(split: true)
        realizeSplit(session)
        let job = try job(of: open(session, pane: .right))

        #expect(store.swapPanes(session.id) == nil)
        #expect(session.remoteOverlays.slot(.left)?.job == job)
        #expect(session.remoteOverlays.slot(.right) == nil)
        jobs.finish(job, .canceled)

        #expect(session.remoteOverlays.failure(.left) == "canceled")
        #expect(session.remoteOverlays.failure(.right) == nil)
    }

    @Test func aSwapMovesARecordedRemoteFailureWithItsPane() throws {
        let (session, _) = try origin(split: true)
        realizeSplit(session)
        jobs.finish(try job(of: open(session, pane: .right)), .launchFailed)

        #expect(store.swapPanes(session.id) == nil)

        #expect(session.remoteOverlays.failure(.left) == "launch-failed")
        #expect(session.remoteOverlays.failure(.right) == nil)
    }

    @Test func aPromotedSplitKeepsItsJobOnTheLeftAndThePrimarysJobEnds() throws {
        let (session, _) = try origin(split: true)
        realizeSplit(session)
        let left = try job(of: open(session, pane: .left))
        let right = try job(of: open(session, pane: .right))

        store.closePrimaryPane(session.id)

        #expect(jobs.job(left)?.state == .finished(.canceled))
        #expect(presenter.bodies.contains(.overlayClose(PresentationOverlayChange(job: left))))
        #expect(session.remoteOverlays.slots.map(\.job) == [right])
        #expect(session.remoteOverlays.slot(.left)?.job == right)
    }

    @Test func closingTheSplitEndsItsJobAndALateOutcomeRecordsNothing() throws {
        let (session, _) = try origin(split: true)
        realizeSplit(session)
        let job = try job(of: open(session, pane: .right))
        var reached = 0
        _ = jobs.claim(job) { reached += 1 }
        jobs.started(job)

        store.closeSplit(session.id)

        #expect(reached == 1)
        #expect(session.remoteOverlays.slots.isEmpty)
        jobs.finish(job, .exited(0))
        #expect(session.paneOverlayExitCode(.right) == nil)
    }
}
