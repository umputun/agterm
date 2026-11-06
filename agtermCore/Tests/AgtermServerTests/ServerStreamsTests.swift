import Foundation
import Testing
@testable import AgtermServerKit
import agtermCore

@MainActor
struct ServerStreamsTests {
    private let harness: ServerHarness

    init() throws { harness = try ServerHarness() }

    private var streams: ServerStreams { harness.actions.streams }

    private func newSession() throws -> Session {
        try harness.session(harness.actions.createSession(ControlSessionCreateOptions(
            window: nil, cwd: nil, workspace: nil, workspaceName: nil, createWorkspace: nil, command: nil, wait: nil,
            name: nil, after: nil, before: nil, noSelect: false)))
    }

    final class Viewer: @unchecked Sendable {
        let fd: Int32
        private(set) var gen = 0

        init(fd: Int32) {
            self.fd = fd
            var timeout = timeval(tv_sec: 60, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }

        func send(_ body: PresentationFrame.Body) throws {
            try sendNoSignal(fd, try PresentationCodec.encode(PresentationFrame(gen: gen, rev: 0, body: body)))
        }

        func next() -> PresentationFrame? {
            var bytes: [UInt8] = []
            var byte: UInt8 = 0
            while read(fd, &byte, 1) == 1 {
                guard byte == UInt8(ascii: "\n") else {
                    bytes.append(byte)
                    continue
                }
                let frame = try? PresentationCodec.decode(Data(bytes))
                bytes.removeAll()
                switch frame?.body {
                case .hello?: gen = frame?.gen ?? gen
                case .ping?: guard (try? send(.ack)) != nil else { return nil }
                default: break
                }
                return frame
            }
            return nil
        }

        func first(within seconds: TimeInterval = 60, where match: (PresentationFrame.Body) -> Bool) -> PresentationFrame.Body? {
            let deadline = Date().addingTimeInterval(seconds)
            while true {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { return nil }
                var timeout = timeval(tv_sec: Int(remaining), tv_usec: .init(remaining.truncatingRemainder(dividingBy: 1) * 1_000_000))
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                guard let frame = next() else { return nil }
                if match(frame.body) { return frame.body }
            }
        }
    }

    private func connect(_ session: Session, mode: PresentationMode = .mirror,
                         kinds: [String] = PresentationHub.supportedKinds) async throws -> Viewer {
        var fds: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, UnixSocket.streamType, 0, &fds) == 0)
        streams.adoptPresentationStream(descriptor: fds[0], session: session.id)
        let viewer = Viewer(fd: fds[1])
        try viewer.send(.hello(PresentationHello(version: PresentationCodec.version, kinds: kinds, mode: mode)))
        let snapshot = await offPool { viewer.first { if case .snapshot = $0 { true } else { false } } }
        #expect(snapshot != nil)
        return viewer
    }

    @Test func aViewerGetsTheSnapshotThenTheSessionsChanges() async throws {
        let session = try newSession()
        let viewer = try await connect(session)
        defer { close(viewer.fd) }

        _ = harness.store.setContext("build", forSession: session.id)

        let change = await offPool { viewer.first { if case .context = $0 { true } else { false } } }
        #expect(change == .context("build"))
    }

    @Test func aNotificationReachesTheSessionsViewers() async throws {
        let session = try newSession()
        let viewer = try await connect(session)
        defer { close(viewer.fd) }

        _ = harness.actions.sendNotification(session.id.uuidString, window: nil, title: "done", body: "build passed")

        let frame = await offPool { viewer.first { if case .notify = $0 { true } else { false } } }
        guard case .notify(let notify)? = frame else { Issue.record("no notify frame"); return }
        #expect(notify.title == "done")
        #expect(notify.body == "build passed")
    }

    @Test func aHudReachesTheSessionsViewersAndItsCloseWithdrawsIt() async throws {
        let session = try newSession()
        let viewer = try await connect(session)
        defer { close(viewer.fd) }

        _ = harness.actions.openHud(session.id.uuidString, window: nil, spec: HudSpec(message: "building"))
        let shown = await offPool { viewer.first { if case .hud(let hud) = $0 { hud != nil } else { false } } }
        _ = harness.actions.closeHud(session.id.uuidString, window: nil)
        let withdrawn = await offPool { viewer.first { $0 == .hud(nil) } }

        guard case .hud(let hud)? = shown else { Issue.record("no hud frame"); return }
        #expect(hud?.spec.message == "building")
        #expect(withdrawn == .hud(nil))
    }

    // regression: a viewer that absorbed pings never reached its deadline, so a missing frame hung the test
    @Test func aViewerWaitingThroughPingsStopsAtItsDeadlineAndAcksThem() async throws {
        let ping = try PresentationCodec.encode(PresentationFrame(gen: 0, rev: 0, body: .ping))
        var fds: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, UnixSocket.streamType, 0, &fds) == 0)
        let viewer = Viewer(fd: fds[1])
        let origin = Viewer(fd: fds[0])
        let stopping = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        Thread {
            for _ in 0..<40 {
                guard stopping.wait(timeout: .now() + 0.05) == .timedOut, (try? sendNoSignal(origin.fd, ping)) != nil else { break }
            }
            stopped.signal()
        }.start()

        let (found, waited, ack) = await offPool {
            let started = Date()
            let found = viewer.first(within: 0.5) { _ in false } != nil
            let waited = Date().timeIntervalSince(started)
            stopping.signal()
            stopped.wait()
            return (found, waited, origin.first(within: 5) { $0 == .ack })
        }
        close(fds[0])
        close(fds[1])

        #expect(!found)
        #expect(waited < 10)
        #expect(ack == .ack)
    }

    @Test func aStreamThatSendsNoHelloIsClosed() async throws {
        let session = try newSession()
        streams.presentationHelloDeadline = 0.2
        var fds: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, UnixSocket.streamType, 0, &fds) == 0)
        defer { close(fds[1]) }
        streams.adoptPresentationStream(descriptor: fds[0], session: session.id)
        let viewer = Viewer(fd: fds[1])

        let frame = await offPool { viewer.next() }

        #expect(frame == nil)
    }

    @Test func aRespawnReachesTheSessionsViewers() async throws {
        let session = try newSession()
        let viewer = try await connect(session)
        defer { close(viewer.fd) }
        let daemon = ZmxSupport.daemonName(for: session.paneIdentity)

        streams.noteRespawn(session: session.id, daemon: daemon)

        let frame = await offPool { viewer.first { if case .respawn = $0 { true } else { false } } }
        guard case .respawn(let respawns)? = frame else { Issue.record("no respawn frame"); return }
        #expect(respawns.epoch == streams.originEpoch)
        #expect(respawns.generations == [daemon: 1])
    }

    private func presenter(for session: Session, kinds: [String] = PresentationHub.supportedKinds) async throws -> Viewer {
        let viewer = try await connect(session, mode: .presenter, kinds: kinds)
        try viewer.send(.presenterAcquire)
        let granted = await offPool { viewer.first { $0 == .presenterGranted || $0 == .presenterRefused } }
        #expect(granted == .presenterGranted)
        return viewer
    }

    @Test func aPickThePresenterAnswersSettles() async throws {
        let session = try newSession()
        let viewer = try await presenter(for: session)
        defer { close(viewer.fd) }
        let pick = PendingPick(id: UUID().uuidString, items: [ControlPickItem(id: "a", label: "A")])

        #expect(harness.actions.openPick(pick, session: session.id.uuidString, window: nil, follow: false).ok)
        let request = await offPool { viewer.first { if case .pickRequest = $0 { true } else { false } } }
        guard case .pickRequest(let shown)? = request else { Issue.record("no pick request"); return }
        try viewer.send(.pickResolve(PresentationPickAnswer(id: shown.id, owner: shown.owner, item: "a")))

        let settled = await eventually { harness.actions.pickResult(pick.id, window: nil).result?.pick?.result == .picked }
        #expect(settled)
    }

    @Test func aPickWhosePresenterLeavesEndsCancelled() async throws {
        let session = try newSession()
        let viewer = try await presenter(for: session)
        let pick = PendingPick(id: UUID().uuidString, items: [ControlPickItem(id: "a", label: "A")])
        #expect(harness.actions.openPick(pick, session: session.id.uuidString, window: nil, follow: false).ok)

        close(viewer.fd)

        let cancelled = await eventually { harness.actions.pickResult(pick.id, window: nil).result?.pick?.result == .cancelled }
        #expect(cancelled)
    }

    private func openAsk(_ ask: PendingAsk, on session: Session) -> ControlResponse {
        harness.actions.openAsk(ask, target: session.id.uuidString, window: nil, placement: ControlAskPlacement(), follow: false)
    }

    private func askOutcome(_ id: String) -> ControlAskResult? { harness.actions.askResult(id, window: nil).result?.ask }

    private static func ask(form: AskForm? = nil) -> PendingAsk {
        PendingAsk(id: UUID().uuidString, title: "deploy?", buttons: [ControlAskButton(id: "yes", label: "Yes")], form: form)
    }

    @Test func anAskThePresenterAnswersSettles() async throws {
        let session = try newSession()
        let viewer = try await presenter(for: session)
        defer { close(viewer.fd) }
        let ask = Self.ask()

        #expect(openAsk(ask, on: session).ok)
        #expect(askOutcome(ask.id)?.result == .pending)
        let request = await offPool { viewer.first { if case .askRequest = $0 { true } else { false } } }
        guard case .askRequest(let shown)? = request else { Issue.record("no ask request"); return }
        try viewer.send(.askResolve(PresentationAskAnswer(id: shown.id, owner: shown.owner, button: "yes")))

        let settled = await eventually { askOutcome(ask.id)?.id == "yes" }
        #expect(settled)
        #expect(session.askPending == nil)
    }

    @Test func anAskWhosePresenterLeavesEndsCancelled() async throws {
        let session = try newSession()
        let viewer = try await presenter(for: session)
        let ask = Self.ask()
        #expect(openAsk(ask, on: session).ok)

        close(viewer.fd)

        let cancelled = await eventually { askOutcome(ask.id) == ControlAskResult(result: .cancelled, reason: ControlAskResult.presentationLost) }
        #expect(cancelled)
    }

    @Test func anAskThePresenterRefusesEndsCancelled() async throws {
        let session = try newSession()
        let viewer = try await presenter(for: session)
        defer { close(viewer.fd) }
        let ask = Self.ask()
        #expect(openAsk(ask, on: session).ok)
        let request = await offPool { viewer.first { if case .askRequest = $0 { true } else { false } } }
        guard case .askRequest(let shown)? = request else { Issue.record("no ask request"); return }

        try viewer.send(.askRejected(PresentationAskRef(id: shown.id, owner: shown.owner)))

        let cancelled = await eventually { askOutcome(ask.id)?.result == .cancelled }
        #expect(cancelled)
    }

    @Test func aCancelledAskIsWithdrawnFromThePresenter() async throws {
        let session = try newSession()
        let viewer = try await presenter(for: session)
        defer { close(viewer.fd) }
        let ask = Self.ask()
        #expect(openAsk(ask, on: session).ok)

        #expect(harness.actions.cancelAsk(ask.id, window: nil).ok)

        let dismiss = await offPool { viewer.first { if case .askDismiss = $0 { true } else { false } } }
        guard case .askDismiss(let ref)? = dismiss else { Issue.record("no ask dismiss"); return }
        #expect(ref.id == ask.id)
        #expect(askOutcome(ask.id)?.result == .cancelled)
    }

    @Test func aFormAskThePresenterCannotDrawIsRefused() async throws {
        let session = try newSession()
        let viewer = try await presenter(for: session, kinds: PresentationHub.supportedKinds.filter { $0 != PresentationHub.askFormKind })
        defer { close(viewer.fd) }

        let reply = openAsk(Self.ask(form: .input(AskInputForm(mode: .line))), on: session)

        #expect(reply == ControlResponse(ok: false, error: "the connected Mac cannot show a form ask"))
        #expect(session.askPending == nil)
    }

    private func openOverlay(on session: Session, page: HtmlSource? = nil) -> ControlResponse {
        harness.actions.openSessionOverlay(session.id.uuidString, window: nil, options: ControlSessionOverlayOpenOptions(
            command: "tput colors", cwd: "/tmp", wait: false, sizePercent: nil, backgroundColor: nil, page: page))
    }

    @Test func aProgramOverlayLaunchesWithTheServersIdentityAndTerminfo() async throws {
        let terminfo = harness.panes.configuration.resourcesDirectory + "/terminfo"
        try FileManager.default.createDirectory(atPath: terminfo + "/x", withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: terminfo + "/x/" + TerminfoInstall.entry))
        let session = try newSession()
        let viewer = try await presenter(for: session)
        defer { close(viewer.fd) }

        #expect(openOverlay(on: session).ok)

        let request = await offPool { viewer.first { if case .overlayRequest = $0 { true } else { false } } }
        guard case .overlayRequest(let shown)? = request else { Issue.record("no overlay request"); return }
        let context = try #require(streams.overlayJobs.job(shown.job)?.context)
        #expect(context.cwd == "/tmp")
        #expect(context.environment["TERMINFO"] == terminfo)
        #expect(context.environment["AGTERM_STATE_DIR"] == harness.panes.configuration.stateDirectory)
        #expect(context.environment["AGTERM_SESSION_ID"] == session.id.uuidString)
        #expect(context.environment["AGTERM_WINDOW_ID"] == harness.catalog.id.uuidString)
    }

    @Test func closingAnUnclaimedProgramEndsItCancelledAndWithdrawsItFromThePresenter() async throws {
        let session = try newSession()
        let viewer = try await presenter(for: session)
        defer { close(viewer.fd) }
        #expect(openOverlay(on: session).ok)

        #expect(harness.actions.closeSessionOverlay(session.id.uuidString, window: nil, pane: nil).ok)

        let closed = await offPool { viewer.first { if case .overlayClose = $0 { true } else { false } } }
        #expect(closed != nil)
        #expect(harness.actions.sessionOverlayResult(session.id.uuidString, window: nil, pane: nil)
            == ControlResponse(ok: false, error: OverlayResultError.ended("canceled")))
    }

    @Test func aPictureReachesThePresenterWithItsPixelSize() async throws {
        let session = try newSession()
        let viewer = try await presenter(for: session)
        defer { close(viewer.fd) }
        let path = harness.scratch.root + "/shot.png"
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52,
                            0, 0, 0x02, 0x80, 0, 0, 0x01, 0xE0, 8, 6, 0, 0, 0, 0, 0, 0, 0]
        try Data(png).write(to: URL(fileURLWithPath: path))

        let reply = openOverlay(on: session, page: .image(path: path))

        #expect(reply.ok)
        #expect(reply.result?.pageID != nil)
        let request = await offPool { viewer.first { if case .pageRequest = $0 { true } else { false } } }
        guard case .pageRequest(let page)? = request else { Issue.record("no page request"); return }
        #expect(page.source == .image(path: path, width: 640, height: 480))
    }

    @Test func aMarkdownPageReachesThePresenterAndItsReloadFollows() async throws {
        let session = try newSession()
        let viewer = try await presenter(for: session)
        defer { close(viewer.fd) }
        let path = harness.scratch.root + "/notes.md"
        try Data("# notes\n".utf8).write(to: URL(fileURLWithPath: path))

        #expect(openOverlay(on: session, page: .markdown(path: path)).ok)
        let request = await offPool { viewer.first { if case .pageRequest = $0 { true } else { false } } }
        guard case .pageRequest(let page)? = request else { Issue.record("no page request"); return }
        #expect(page.source == .markdown(path: path))

        #expect(harness.actions.reloadSessionOverlay(session.id.uuidString, window: nil, pane: nil, current: false).ok)
        let reload = await offPool { viewer.first { if case .pageCommand = $0 { true } else { false } } }
        #expect(reload != nil)
    }

    @Test func aHudIsRefusedWhileTheSessionsProgramIsShownOnThePresenter() async throws {
        let session = try newSession()
        let viewer = try await presenter(for: session)
        defer { close(viewer.fd) }
        #expect(openOverlay(on: session).ok)

        let reply = harness.actions.openHud(session.id.uuidString, window: nil, spec: HudSpec(message: "building"))

        #expect(reply == ControlResponse(ok: false, error: "overlay already open"))
        #expect(!session.hudActive)
    }

    @Test func aHudIsRefusedWhileTheSessionsPageIsShownOnThePresenter() async throws {
        let session = try newSession()
        let viewer = try await presenter(for: session)
        defer { close(viewer.fd) }
        let path = harness.scratch.root + "/notes.md"
        try Data("# notes\n".utf8).write(to: URL(fileURLWithPath: path))
        #expect(openOverlay(on: session, page: .markdown(path: path)).ok)

        let reply = harness.actions.openHud(session.id.uuidString, window: nil, spec: HudSpec(message: "building"))

        #expect(reply == ControlResponse(ok: false, error: "overlay already open"))
        #expect(!session.hudActive)
    }

    @Test func aProgramReplacesATimedHudAndItsTimer() async throws {
        let session = try newSession()
        let viewer = try await presenter(for: session)
        defer { close(viewer.fd) }
        #expect(harness.actions.openHud(session.id.uuidString, window: nil, spec: HudSpec(message: "done", hideAfter: 60)).ok)

        #expect(openOverlay(on: session).ok)

        #expect(!session.hudActive)
        #expect(harness.actions.hudAutoHide[session.id] == nil)
        #expect(session.remoteOverlays.slot(nil) != nil)
    }

    @Test func aHudOpenedAfterAFinishedProgramClearsItsResult() async throws {
        let session = try newSession()
        let viewer = try await presenter(for: session)
        defer { close(viewer.fd) }
        #expect(openOverlay(on: session).ok)
        let request = await offPool { viewer.first { if case .overlayRequest = $0 { true } else { false } } }
        guard case .overlayRequest(let shown)? = request else { Issue.record("no overlay request"); return }
        _ = streams.overlayJobs.claim(shown.job) {}
        streams.overlayJobs.started(shown.job)
        _ = streams.overlayJobs.finish(shown.job, .exited(7))
        let id = session.id.uuidString
        #expect(harness.actions.sessionOverlayResult(id, window: nil, pane: nil) == ControlResponse(ok: true, result: ControlResult(id: id, exitCode: 7)))

        #expect(harness.actions.openHud(id, window: nil, spec: HudSpec(message: "next")).ok)

        #expect(harness.actions.sessionOverlayResult(id, window: nil, pane: nil) == ControlResponse(ok: false, error: OverlayHudError.noResult))
    }

    @Test func aHudOpenedAfterACancelledProgramClearsItsFailure() async throws {
        let session = try newSession()
        let viewer = try await presenter(for: session)
        defer { close(viewer.fd) }
        let id = session.id.uuidString
        #expect(openOverlay(on: session).ok)
        #expect(harness.actions.closeSessionOverlay(id, window: nil, pane: nil).ok)

        #expect(harness.actions.openHud(id, window: nil, spec: HudSpec(message: "next")).ok)

        #expect(harness.actions.sessionOverlayResult(id, window: nil, pane: nil) == ControlResponse(ok: false, error: OverlayHudError.noResult))
    }

    @Test func aHudResizeReachesThePresenterWithItsWidthAndDeadline() async throws {
        let session = try newSession()
        let viewer = try await connect(session)
        defer { close(viewer.fd) }
        let id = session.id.uuidString
        _ = harness.actions.openHud(id, window: nil, spec: HudSpec(message: "building", hideAfter: 600))
        let opened = await offPool { viewer.first { if case .hud(let hud) = $0 { hud != nil } else { false } } }
        guard case .hud(let first?)? = opened else { Issue.record("no hud frame"); return }

        #expect(harness.actions.resizeSessionOverlay(id, window: nil, sizePercent: 40).ok)

        let resized = await offPool { viewer.first { if case .hud(let hud) = $0 { hud?.generation != first.generation } else { false } } }
        guard case .hud(let hud?)? = resized else { Issue.record("no resized hud frame"); return }
        #expect(hud.spec.sizePercent == 40)
        #expect((hud.remaining ?? 0) > 500)
    }

    @Test func aJobWhoseClaimReplyWasNotWrittenIsGivenUp() {
        let job = streams.overlayJobs.register(session: UUID(), pane: nil, owner: 1,
                                               context: OverlayLaunchContext(command: "true", cwd: "/tmp", sessionEnvironment: [:]))
        let reply = streams.claimJobStream(job)

        let adopted = streams.adopt(-1, request: ControlRequest(cmd: .sessionOverlayJobRun, target: job), response: reply, written: false)

        #expect(!adopted)
        #expect(streams.overlayJobs.job(job).map { if case .claimed = $0.state { true } else { false } } != true)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
