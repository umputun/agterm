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
        private let fd: Int32
        private let state = NSCondition()
        private var queue: [PresentationFrame] = []
        private var storedGen = 0
        private var ended: String?
        private var disconnected = false
        private let writes = NSLock()
        private let finished = DispatchSemaphore(value: 0)

        private(set) var missed: String?

        var gen: Int { state.withLock { storedGen } }

        init(fd: Int32) {
            self.fd = fd
            Thread { [self] in readFrames() }.start()
        }

        func send(_ body: PresentationFrame.Body) throws {
            try write(try PresentationCodec.encode(PresentationFrame(gen: gen, rev: 0, body: body)))
        }

        func write(_ data: Data) throws {
            try writes.withLock {
                guard !disconnected else { throw UnixSocket.Failure.system("viewer disconnected") }
                try sendNoSignal(fd, data)
            }
        }

        func disconnect() {
            let first = writes.withLock {
                defer { disconnected = true }
                return !disconnected
            }
            guard first else { return }
            shutdown(fd, Int32(SHUT_RDWR))
            finished.wait()
            close(fd)
        }

        func next(within seconds: TimeInterval = 60) -> PresentationFrame? {
            let deadline = Date().addingTimeInterval(seconds)
            state.lock()
            defer { state.unlock() }
            while queue.isEmpty {
                if let ended {
                    missed = ended
                    return nil
                }
                guard state.wait(until: deadline) else {
                    missed = "no frame within \(seconds) s"
                    return nil
                }
            }
            return queue.removeFirst()
        }

        private func readFrames() {
            var bytes: [UInt8] = []
            var byte: UInt8 = 0
            var reason = "end of stream"
            while true {
                let count = read(fd, &byte, 1)
                if count < 0, errno == EINTR { continue }
                guard count == 1 else {
                    if count < 0 { reason = "read failed: \(String(cString: strerror(errno)))" }
                    break
                }
                guard byte == UInt8(ascii: "\n") else {
                    bytes.append(byte)
                    continue
                }
                guard let frame = try? PresentationCodec.decode(Data(bytes)) else {
                    reason = "undecodable frame"
                    break
                }
                bytes.removeAll()
                if frame.body == .ping { try? send(.ack) }
                state.withLock {
                    if case .hello = frame.body { storedGen = frame.gen }
                    queue.append(frame)
                    state.broadcast()
                }
            }
            state.withLock {
                ended = reason
                state.broadcast()
            }
            finished.signal()
        }

        private(set) var bodies: [PresentationFrame.Body] = []
        private(set) var delivered: [PresentationFrame.Body] = []
        private var committed: [PresentationFrame.Body] = []
        private var batch = PresentationPendingBatch()

        private func takeCommitted(_ match: (PresentationFrame.Body) -> Bool) -> PresentationFrame.Body? {
            guard let index = committed.firstIndex(where: match) else { return nil }
            let found = committed[index]
            committed.removeSubrange(...index)
            return found
        }

        func first(within seconds: TimeInterval = 60, where match: (PresentationFrame.Body) -> Bool) -> PresentationFrame.Body? {
            if let found = takeCommitted(match) { return found }
            let deadline = Date().addingTimeInterval(seconds)
            while true {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else {
                    missed = "no match within \(seconds) s"
                    return nil
                }
                guard let frame = next(within: remaining) else { return nil }
                bodies.append(frame.body)
                if case .pendingChunk(let chunk) = frame.body {
                    batch.add(chunk)
                    continue
                }
                if frame.body == .pendingCommit {
                    let entries = (try? batch.commit()) ?? []
                    delivered += entries
                    committed += entries
                    if match(frame.body) { return frame.body }
                    if let found = takeCommitted(match) { return found }
                    continue
                }
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

    @Test func aPresenterNegotiatesForwardedClicks() async throws {
        let session = try newSession()
        var fds: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, UnixSocket.streamType, 0, &fds) == 0)
        streams.adoptPresentationStream(descriptor: fds[0], session: session.id)
        let viewer = Viewer(fd: fds[1])
        defer { viewer.disconnect() }
        try viewer.send(.hello(PresentationHello(version: PresentationCodec.version, kinds: PresentationHub.supportedKinds,
                                                 mode: .presenter)))

        let answer = await offPool { viewer.first { if case .hello = $0 { true } else { false } } }
        guard case .hello(let hello)? = answer else { Issue.record("no hello"); return }
        #expect(hello.kinds.contains(PresentationHub.linkClickKind))
    }

    @Test func aViewerGetsTheSnapshotThenTheSessionsChanges() async throws {
        let session = try newSession()
        let viewer = try await connect(session)
        defer { viewer.disconnect() }

        _ = harness.store.setContext("build", forSession: session.id)

        let change = await offPool { viewer.first { if case .context = $0 { true } else { false } } }
        #expect(change == .context("build"))
    }

    @Test func aNotificationReachesTheSessionsViewers() async throws {
        let session = try newSession()
        let viewer = try await connect(session)
        defer { viewer.disconnect() }

        _ = harness.actions.sendNotification(session.id.uuidString, window: nil, title: "done", body: "build passed")

        let frame = await offPool { viewer.first { if case .notify = $0 { true } else { false } } }
        guard case .notify(let notify)? = frame else { Issue.record("no notify frame"); return }
        #expect(notify.title == "done")
        #expect(notify.body == "build passed")
    }

    @Test func aHudReachesTheSessionsViewersAndItsCloseWithdrawsIt() async throws {
        let session = try newSession()
        let viewer = try await connect(session)
        defer { viewer.disconnect() }

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
                guard stopping.wait(timeout: .now() + 0.05) == .timedOut, (try? origin.write(ping)) != nil else { break }
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
        origin.disconnect()
        viewer.disconnect()

        #expect(!found)
        #expect(waited < 10)
        #expect(ack == .ack)
    }

    // regression: a viewer acked pings only inside a read, so a test slow between two reads lost its presenter
    @Test func aViewerAcksAPingWhileNoTestIsReading() async throws {
        let ping = try PresentationCodec.encode(PresentationFrame(gen: 0, rev: 0, body: .ping))
        var fds: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, UnixSocket.streamType, 0, &fds) == 0)
        let viewer = Viewer(fd: fds[1])
        let origin = Viewer(fd: fds[0])
        defer {
            origin.disconnect()
            viewer.disconnect()
        }

        try origin.write(ping)
        let ack = await offPool { origin.first(within: 5) { $0 == .ack } }

        #expect(ack == .ack)
    }

    @Test func aStreamThatSendsNoHelloIsClosed() async throws {
        let session = try newSession()
        streams.presentationHelloDeadline = 0.2
        var fds: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, UnixSocket.streamType, 0, &fds) == 0)
        streams.adoptPresentationStream(descriptor: fds[0], session: session.id)
        let viewer = Viewer(fd: fds[1])
        defer { viewer.disconnect() }

        let frame = await offPool { viewer.next() }

        #expect(frame == nil)
    }

    @Test func aRespawnReachesTheSessionsViewers() async throws {
        let session = try newSession()
        let viewer = try await connect(session)
        defer { viewer.disconnect() }
        let daemon = ZmxSupport.daemonName(for: session.paneIdentity)

        streams.noteRespawn(session: session.id, daemon: daemon)

        let frame = await offPool { viewer.first { if case .respawn = $0 { true } else { false } } }
        guard case .respawn(let respawns)? = frame else { Issue.record("no respawn frame"); return }
        #expect(respawns.epoch == streams.originEpoch)
        #expect(respawns.generations == [daemon: 1])
    }

    private func drop(_ viewer: Viewer, from session: Session) async {
        viewer.disconnect()
        let released = await eventually { !streams.presentationHub.hasPresenter(session: session.id) }
        #expect(released)
    }

    private func presenter(for session: Session, kinds: [String] = PresentationHub.supportedKinds) async throws -> Viewer {
        let viewer = try await connect(session, mode: .presenter, kinds: kinds)
        try viewer.send(.presenterAcquire)
        let granted = await offPool { viewer.first { $0 == .presenterGranted || $0 == .presenterRefused } }
        #expect(granted == .presenterGranted)
        return viewer
    }

    @Test func aSkippedIfIdleWriteSendsThePresenterNoSound() async throws {
        let session = try newSession()
        let viewer = try await presenter(for: session)
        defer { viewer.disconnect() }
        let target = session.id.uuidString
        _ = await harness.actions.setSessionStatus(target, window: nil, update: ControlSessionStatusUpdate(
            status: .blocked, blink: nil, autoReset: nil, sound: "Glass"))
        let played = await offPool { viewer.first { if case .sound = $0 { true } else { false } } }
        #expect(played != nil)

        _ = await harness.actions.setSessionStatus(target, window: nil, update: ControlSessionStatusUpdate(
            status: .active, blink: nil, autoReset: nil, sound: "Glass", ifIdle: true))
        _ = harness.actions.sendNotification(target, window: nil, title: "marker", body: "after the skipped write")

        let next = await offPool {
            viewer.first { body in
                switch body {
                case .sound, .notify: true
                default: false
                }
            }
        }
        guard case .notify? = next else { Issue.record("expected the marker notification, got \(String(describing: next))"); return }
    }

    @Test func aPickThePresenterAnswersSettles() async throws {
        let session = try newSession()
        let viewer = try await presenter(for: session)
        defer { viewer.disconnect() }
        let pick = PendingPick(id: UUID().uuidString, items: [ControlPickItem(id: "a", label: "A")])

        #expect(harness.actions.openPick(pick, session: session.id.uuidString, window: nil, follow: false).ok)
        let request = await offPool { viewer.first { if case .pickRequest = $0 { true } else { false } } }
        guard case .pickRequest(let shown)? = request else { Issue.record("no pick request: \(viewer.missed ?? ""), session \(session.id)"); return }
        try viewer.send(.pickResolve(PresentationPickAnswer(id: shown.id, owner: shown.owner, item: "a")))

        let settled = await eventually { harness.actions.pickResult(pick.id, window: nil).result?.pick?.result == .picked }
        #expect(settled, "session \(session.id)")
    }

    @Test func aPickWhosePresenterLeavesWaitsForTheNextOne() async throws {
        let session = try newSession()
        let viewer = try await presenter(for: session)
        let pick = PendingPick(id: UUID().uuidString, items: [ControlPickItem(id: "a", label: "A")])
        #expect(harness.actions.openPick(pick, session: session.id.uuidString, window: nil, follow: false).ok)
        let first = await offPool { viewer.first { if case .pickRequest = $0 { true } else { false } } }
        guard case .pickRequest(let old)? = first else { Issue.record("no pick request"); return }

        await drop(viewer, from: session)
        let returned = await eventually {
            harness.store.controlTree().workspaces.flatMap(\.sessions).first { $0.id == session.id.uuidString }?
                .interactions?.first?.state == ControlInteraction.unpresented
        }
        #expect(returned)
        let next = try await presenter(for: session)
        defer { next.disconnect() }

        let offered = await offPool { next.first { if case .pickRequest = $0 { true } else { false } } }
        guard case .pickRequest(let shown)? = offered else { Issue.record("no pick offer"); return }
        #expect(shown.id == pick.id)
        #expect(shown.owner > old.owner)
        streams.receivePresenterFrame(.pickResolve(PresentationPickAnswer(id: pick.id, owner: old.owner, item: "a")), forSession: session.id)
        #expect(harness.actions.pickResult(pick.id, window: nil).result?.pick?.result == .pending)
        try next.send(.pickResolve(PresentationPickAnswer(id: pick.id, owner: shown.owner, item: "a")))
        let settled = await eventually { harness.actions.pickResult(pick.id, window: nil).result?.pick?.result == .picked }
        #expect(settled)
    }

    @Test func anAskOpenedWithNoPresenterIsOfferedToTheNextCapableOne() async throws {
        let session = try newSession()
        let ask = Self.ask()
        #expect(openAsk(ask, on: session).ok)
        let older = try await presenter(for: session, kinds: PresentationHub.supportedKinds.filter { $0 != PresentationHub.pendingSnapshotKind })

        let unoffered = await offPool { older.first(within: 0.5) { if case .askRequest = $0 { true } else { false } } }
        #expect(unoffered == nil)
        await drop(older, from: session)
        let capable = try await presenter(for: session)
        defer { capable.disconnect() }

        let offered = await offPool { capable.first { if case .askRequest = $0 { true } else { false } } }
        guard case .askRequest(let shown)? = offered else { Issue.record("no ask offer"); return }
        #expect(shown.id == ask.id)
        #expect(shown.owner == harness.store.presentationHub?.presenterGeneration(session: session.id))
        let node = harness.store.controlTree().workspaces.flatMap(\.sessions).first { $0.id == session.id.uuidString }
        #expect(node?.interactions?.first?.state == ControlInteraction.offered)
    }

    @Test func aFollowedPickOpenedOfflineIsOfferedWithItsFollow() async throws {
        let session = try newSession()
        let pick = PendingPick(id: UUID().uuidString, items: [ControlPickItem(id: "a", label: "A")])
        #expect(harness.actions.openPick(pick, session: session.id.uuidString, window: nil, follow: true).ok)

        let viewer = try await presenter(for: session)
        defer { viewer.disconnect() }

        let offered = await offPool { viewer.first { if case .pickRequest = $0 { true } else { false } } }
        guard case .pickRequest(let shown)? = offered else { Issue.record("no pick offer"); return }
        #expect(shown.follow == true)
    }

    @Test func anExpiredAskIsNeverHandedToAConnectedPresenter() async throws {
        let session = try newSession()
        let viewer = try await presenter(for: session)
        defer { viewer.disconnect() }
        var late = Self.ask()
        late.deadline = Date().addingTimeInterval(-1)

        #expect(openAsk(late, on: session).ok)

        let request = await offPool { viewer.first(within: 0.5) { if case .askRequest = $0 { true } else { false } } }
        #expect(request == nil)
        let cancelled = await eventually { askOutcome(late.id)?.result == .cancelled }
        #expect(cancelled)
    }

    @Test func everythingHeldForASessionReachesTheNextPresenterAsChunksAndOneCommit() async throws {
        let session = try newSession()
        let ask = Self.ask()
        #expect(openAsk(ask, on: session).ok)
        #expect(openOverlay(on: session).ok)

        let viewer = try await presenter(for: session)
        defer { viewer.disconnect() }

        let commit = await offPool { viewer.first { $0 == .pendingCommit } }
        #expect(commit == .pendingCommit)
        let entries = viewer.delivered
        #expect(entries.contains { if case .askRequest(let shown) = $0 { shown.id == ask.id } else { false } })
        #expect(entries.contains { if case .overlayRequest = $0 { true } else { false } })
        #expect(!viewer.bodies.contains { if case .askRequest = $0 { true } else { false } })
    }

    @Test func aFormAskWaitsForAPresenterThatDrawsForms() async throws {
        let session = try newSession()
        let ask = Self.ask(form: .input(AskInputForm(mode: .line)))
        #expect(openAsk(ask, on: session).ok)
        let plain = try await presenter(for: session, kinds: PresentationHub.supportedKinds.filter { $0 != PresentationHub.askFormKind })

        let unoffered = await offPool { plain.first(within: 0.5) { if case .askRequest = $0 { true } else { false } } }

        #expect(unoffered == nil)
        #expect(session.askPending?.id == ask.id)
        plain.disconnect()
    }

    @Test func anAskPastItsDeadlineIsNotOfferedAndAnAnswerPastItEndsIt() async throws {
        let session = try newSession()
        var late = Self.ask()
        late.deadline = Date().addingTimeInterval(60)
        #expect(openAsk(late, on: session).ok)
        streams.now = { Date().addingTimeInterval(120) }

        let capable = try await presenter(for: session)
        defer { capable.disconnect() }

        #expect(askOutcome(late.id)?.result == .cancelled)
        streams.now = Date.init
        var answered = Self.ask()
        answered.deadline = Date().addingTimeInterval(60)
        #expect(openAsk(answered, on: session).ok)
        let request = await offPool { capable.first { if case .askRequest = $0 { true } else { false } } }
        guard case .askRequest(let shown)? = request else { Issue.record("no ask request"); return }
        streams.now = { Date().addingTimeInterval(120) }

        streams.receivePresenterFrame(.askResolve(PresentationAskAnswer(id: shown.id, owner: shown.owner, button: "yes")),
                                      forSession: session.id)

        #expect(askOutcome(answered.id)?.result == .cancelled)
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
        defer { viewer.disconnect() }
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

    @Test func anAskWhosePresenterLeavesWaitsAndAStaleAnswerIsDropped() async throws {
        let session = try newSession()
        let viewer = try await presenter(for: session)
        let ask = Self.ask()
        #expect(openAsk(ask, on: session).ok)
        let request = await offPool { viewer.first { if case .askRequest = $0 { true } else { false } } }
        guard case .askRequest(let shown)? = request else { Issue.record("no ask request"); return }

        viewer.disconnect()

        let returned = await eventually { session.askPending?.id == ask.id && !session.askPresentedRemotely }
        #expect(returned)
        streams.receivePresenterFrame(.askResolve(PresentationAskAnswer(id: shown.id, owner: shown.owner, button: "yes")),
                                      forSession: session.id)
        #expect(askOutcome(ask.id)?.result == .pending)
    }

    @Test func anAskThePresenterRefusesWaitsUnpresented() async throws {
        let session = try newSession()
        let viewer = try await presenter(for: session)
        defer { viewer.disconnect() }
        let ask = Self.ask()
        #expect(openAsk(ask, on: session).ok)
        let request = await offPool { viewer.first { if case .askRequest = $0 { true } else { false } } }
        guard case .askRequest(let shown)? = request else { Issue.record("no ask request"); return }

        try viewer.send(.askRejected(PresentationAskRef(id: shown.id, owner: shown.owner)))

        let returned = await eventually { !session.askPresentedRemotely }
        #expect(returned)
        #expect(askOutcome(ask.id)?.result == .pending)
    }

    @Test func aCancelledAskIsWithdrawnFromThePresenter() async throws {
        let session = try newSession()
        let viewer = try await presenter(for: session)
        defer { viewer.disconnect() }
        let ask = Self.ask()
        #expect(openAsk(ask, on: session).ok)

        #expect(harness.actions.cancelAsk(ask.id, window: nil).ok)

        let dismiss = await offPool { viewer.first { if case .askDismiss = $0 { true } else { false } } }
        guard case .askDismiss(let ref)? = dismiss else { Issue.record("no ask dismiss"); return }
        #expect(ref.id == ask.id)
        #expect(askOutcome(ask.id)?.result == .cancelled)
    }

    @Test func aFormAskThePresenterCannotDrawWaitsUnpresented() async throws {
        let session = try newSession()
        let viewer = try await presenter(for: session, kinds: PresentationHub.supportedKinds.filter { $0 != PresentationHub.askFormKind })
        defer { viewer.disconnect() }

        let reply = openAsk(Self.ask(form: .input(AskInputForm(mode: .line))), on: session)

        #expect(reply.ok)
        #expect(session.askPending != nil)
        #expect(!session.askPresentedRemotely)
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
        defer { viewer.disconnect() }

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
        defer { viewer.disconnect() }
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
        defer { viewer.disconnect() }
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
        defer { viewer.disconnect() }
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
        defer { viewer.disconnect() }
        #expect(openOverlay(on: session).ok)

        let reply = harness.actions.openHud(session.id.uuidString, window: nil, spec: HudSpec(message: "building"))

        #expect(reply == ControlResponse(ok: false, error: "overlay already open"))
        #expect(!session.hudActive)
    }

    @Test func aHudIsRefusedWhileTheSessionsPageIsShownOnThePresenter() async throws {
        let session = try newSession()
        let viewer = try await presenter(for: session)
        defer { viewer.disconnect() }
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
        defer { viewer.disconnect() }
        #expect(harness.actions.openHud(session.id.uuidString, window: nil, spec: HudSpec(message: "done", hideAfter: 60)).ok)

        #expect(openOverlay(on: session).ok)

        #expect(!session.hudActive)
        #expect(harness.actions.hudAutoHide[session.id] == nil)
        #expect(session.remoteOverlays.slot(nil) != nil)
    }

    @Test func aHudOpenedAfterAFinishedProgramClearsItsResult() async throws {
        let session = try newSession()
        let viewer = try await presenter(for: session)
        defer { viewer.disconnect() }
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
        defer { viewer.disconnect() }
        let id = session.id.uuidString
        #expect(openOverlay(on: session).ok)
        #expect(harness.actions.closeSessionOverlay(id, window: nil, pane: nil).ok)

        #expect(harness.actions.openHud(id, window: nil, spec: HudSpec(message: "next")).ok)

        #expect(harness.actions.sessionOverlayResult(id, window: nil, pane: nil) == ControlResponse(ok: false, error: OverlayHudError.noResult))
    }

    @Test func aHudResizeReachesThePresenterWithItsWidthAndDeadline() async throws {
        let session = try newSession()
        let viewer = try await connect(session)
        defer { viewer.disconnect() }
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

    @Test func aProgramOpenedOfflineIsOfferedWithATokenThatAClaimMustCarry() async throws {
        let session = try newSession()
        #expect(openOverlay(on: session).ok)
        let job = try #require(session.remoteOverlays.slot(nil)?.job)
        #expect(streams.claimJobStream(job).ok == false)

        let viewer = try await presenter(for: session)
        defer { viewer.disconnect() }

        let request = await offPool { viewer.first { if case .overlayRequest = $0 { true } else { false } } }
        guard case .overlayRequest(let shown)? = request, let token = shown.token else { Issue.record("no tokened offer"); return }
        #expect(shown.job == job)
        #expect(session.remoteOverlays.slot(nil)?.owner == harness.store.presentationHub?.presenterGeneration(session: session.id),
                "job \(String(describing: harness.store.overlayJobs?.job(job)?.state)), presenter \(streams.presentationHub.hasPresenter(session: session.id))")
        #expect(streams.claimJobStream(job).ok == false)
        #expect(streams.claimJobStream(job, token: "other").ok == false)
        #expect(streams.claimJobStream(job, token: token).ok)
    }

    @Test func anUnclaimedJobReturnsToPendingAndItsOldTokenIsRefusedAfterTheReoffer() async throws {
        let session = try newSession()
        let first = try await presenter(for: session)
        #expect(openOverlay(on: session).ok)
        let offered = await offPool { first.first { if case .overlayRequest = $0 { true } else { false } } }
        guard case .overlayRequest(let old)? = offered, let oldToken = old.token else { Issue.record("no offer"); return }

        first.disconnect()
        let withdrawn = await eventually { streams.overlayJobs.job(old.job)?.state == .unpresented }
        #expect(withdrawn)
        #expect(streams.claimJobStream(old.job, token: oldToken).ok == false)
        let next = try await presenter(for: session)
        defer { next.disconnect() }

        let reoffered = await offPool { next.first { if case .overlayRequest = $0 { true } else { false } } }
        guard case .overlayRequest(let fresh)? = reoffered, let freshToken = fresh.token else { Issue.record("no re-offer"); return }
        #expect(fresh.job == old.job)
        #expect(freshToken != oldToken)
        #expect(streams.claimJobStream(old.job, token: oldToken).ok == false)
        #expect(streams.claimJobStream(old.job, token: freshToken).ok)
    }

    @Test func aClaimedJobKeepsItsHonestOutcomeAcrossPresenterLoss() async throws {
        let session = try newSession()
        let first = try await presenter(for: session)
        #expect(openOverlay(on: session).ok)
        let offered = await offPool { first.first { if case .overlayRequest = $0 { true } else { false } } }
        guard case .overlayRequest(let shown)? = offered else { Issue.record("no offer"); return }
        #expect(streams.claimJobStream(shown.job, token: shown.token).ok)

        await drop(first, from: session)
        let next = try await presenter(for: session)
        defer { next.disconnect() }

        let reoffered = await offPool { next.first(within: 0.5) { if case .overlayRequest = $0 { true } else { false } } }
        #expect(reoffered == nil)
        streams.overlayJobs.helperGone(shown.job)
        #expect(streams.overlayJobs.job(shown.job)?.state == .finished(.unknown))
    }

    @Test func aClaimedPageReturnsToPendingAndIsReofferedUnderANewToken() async throws {
        let session = try newSession()
        let path = harness.scratch.root + "/page.md"
        try Data("# hi".utf8).write(to: URL(fileURLWithPath: path))
        let first = try await presenter(for: session)
        #expect(openOverlay(on: session, page: .markdown(path: path)).ok)
        let offered = await offPool { first.first { if case .pageRequest = $0 { true } else { false } } }
        guard case .pageRequest(let old)? = offered else { Issue.record("no page offer"); return }
        #expect(streams.claimPageStream(old.token).ok)
        let node = harness.store.controlTree().workspaces.flatMap(\.sessions).first { $0.id == session.id.uuidString }
        #expect(node?.interactions?.first?.state == ControlInteraction.claimed)

        first.disconnect()
        let returned = await eventually { session.remoteOverlays.slot(nil)?.owner == nil }
        #expect(returned)
        let next = try await presenter(for: session)
        defer { next.disconnect() }

        let reoffered = await offPool { next.first { if case .pageRequest = $0 { true } else { false } } }
        guard case .pageRequest(let fresh)? = reoffered else { Issue.record("no page re-offer"); return }
        #expect(fresh.page == old.page)
        #expect(fresh.token != old.token)
        #expect(streams.claimPageStream(old.token).ok == false)
        #expect(streams.claimPageStream(fresh.token).ok)
    }

    // regression: the grant was taken off a held page for an older presenter, and the next capable one lost it too
    @Test func aHeldMarkdownPageOffersItsGrantOnlyToAPresenterThatFollowsLinks() async throws {
        let session = try newSession()
        let path = harness.scratch.root + "/page.md"
        try Data("# hi".utf8).write(to: URL(fileURLWithPath: path))
        let grant = try #require(MarkdownPage.linkGrant(for: path))
        let older = try await presenter(for: session, kinds: PresentationHub.supportedKinds.filter { $0 != PresentationHub.pageLinksKind })
        #expect(harness.actions.openSessionOverlay(session.id.uuidString, window: nil, options: ControlSessionOverlayOpenOptions(
            command: "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil, page: .markdown(path: path), navigation: true)).ok)
        let first = await offPool { older.first { if case .pageRequest = $0 { true } else { false } } }
        guard case .pageRequest(let plain)? = first else { Issue.record("no page offer"); return }
        #expect(plain.markdownLinks == nil)
        #expect(!plain.navigation)

        await drop(older, from: session)
        let returned = await eventually { session.remoteOverlays.slot(nil)?.owner == nil }
        #expect(returned)
        let next = try await presenter(for: session)
        defer { next.disconnect() }

        let reoffered = await offPool { next.first { if case .pageRequest = $0 { true } else { false } } }
        guard case .pageRequest(let linked)? = reoffered else { Issue.record("no page re-offer"); return }
        #expect(linked.markdownLinks == grant)
        #expect(linked.navigation)
        #expect(streams.claimPageStream(linked.token).ok)
        #expect(streams.pendingPageClaims[linked.token]?.served.links == grant)
    }

    @Test func anOldPageChannelClosingAfterANewClaimLeavesThePageServed() async throws {
        let session = try newSession()
        let path = harness.scratch.root + "/page.md"
        try Data("# hi".utf8).write(to: URL(fileURLWithPath: path))
        let first = try await presenter(for: session)
        #expect(openOverlay(on: session, page: .markdown(path: path)).ok)
        let offered = await offPool { first.first { if case .pageRequest = $0 { true } else { false } } }
        guard case .pageRequest(let old)? = offered, let page = UUID(uuidString: old.page) else { Issue.record("no page offer"); return }
        var oldPair: [Int32] = [-1, -1], newPair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, UnixSocket.streamType, 0, &oldPair) == 0)
        #expect(socketpair(AF_UNIX, UnixSocket.streamType, 0, &newPair) == 0)
        defer { close(newPair[1]) }
        #expect(streams.claimPageStream(old.token).ok)
        streams.adoptPageServeStream(descriptor: oldPair[0], page: page, token: old.token)
        first.disconnect()
        let returned = await eventually { session.remoteOverlays.slot(nil)?.owner == nil }
        #expect(returned)
        let next = try await presenter(for: session)
        defer { next.disconnect() }
        let reoffered = await offPool { next.first { if case .pageRequest = $0 { true } else { false } } }
        guard case .pageRequest(let fresh)? = reoffered else { Issue.record("no page re-offer"); return }
        #expect(streams.claimPageStream(fresh.token).ok)
        streams.adoptPageServeStream(descriptor: newPair[0], page: page, token: fresh.token)
        let replacement = try #require(streams.pageServeStreams[page])

        close(oldPair[1])
        try await Task.sleep(for: .milliseconds(200))

        #expect(streams.pageServeStreams[page] === replacement)
        #expect(session.remoteOverlays.slot(nil)?.page != nil)
    }

    @Test func aChannelNoLongerRegisteredForItsPageClosesWithoutEndingIt() async throws {
        let session = try newSession()
        let path = harness.scratch.root + "/page.md"
        try Data("# hi".utf8).write(to: URL(fileURLWithPath: path))
        let viewer = try await presenter(for: session)
        defer { viewer.disconnect() }
        #expect(openOverlay(on: session, page: .markdown(path: path)).ok)
        let offered = await offPool { viewer.first { if case .pageRequest = $0 { true } else { false } } }
        guard case .pageRequest(let shown)? = offered, let page = UUID(uuidString: shown.page) else { Issue.record("no page offer"); return }
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, UnixSocket.streamType, 0, &pair) == 0)
        #expect(streams.claimPageStream(shown.token).ok)
        streams.adoptPageServeStream(descriptor: pair[0], page: page, token: shown.token)
        let unregistered = try #require(streams.pageServeStreams[page])
        streams.pageServeStreams[page] = nil

        close(pair[1])
        try await Task.sleep(for: .milliseconds(200))

        #expect(session.remoteOverlays.slot(nil)?.page != nil)
        withExtendedLifetime(unregistered) {}
    }

    private func offeredPage(_ session: Session, to viewer: Viewer) async throws -> PresentationPage? {
        let path = harness.scratch.root + "/page-\(UUID().uuidString).md"
        try Data("# hi".utf8).write(to: URL(fileURLWithPath: path))
        #expect(openOverlay(on: session, page: .markdown(path: path)).ok)
        let offered = await offPool { viewer.first { if case .pageRequest = $0 { true } else { false } } }
        guard case .pageRequest(let page)? = offered else { return nil }
        return page
    }

    @Test func aPageChannelEndingBeforeItsPresenterKeepsThePageForTheNextOne() async throws {
        let session = try newSession()
        let first = try await presenter(for: session)
        let shown = try #require(try await offeredPage(session, to: first))
        let page = try #require(UUID(uuidString: shown.page))
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, UnixSocket.streamType, 0, &pair) == 0)
        #expect(streams.claimPageStream(shown.token).ok)
        streams.adoptPageServeStream(descriptor: pair[0], page: page, token: shown.token)

        close(pair[1])
        let kept = await eventually { session.remoteOverlays.slot(nil)?.owner == nil }
        #expect(kept)
        let withdrawal = await offPool { first.first { if case .pageClose = $0 { true } else { false } } }
        #expect(withdrawal == .pageClose(PresentationPageChange(page: shown.page, reason: PresentationPageChange.channelLost)))
        try first.send(.pageClosed(PresentationPageChange(page: shown.page, reason: PresentationPageChange.channelLost)))
        try await Task.sleep(for: .milliseconds(200))
        #expect(session.remoteOverlays.slot(nil)?.page != nil)
        await drop(first, from: session)
        let next = try await presenter(for: session)
        defer { next.disconnect() }

        let reoffered = await offPool { next.first { if case .pageRequest = $0 { true } else { false } } }
        guard case .pageRequest(let fresh)? = reoffered else { Issue.record("no page re-offer"); return }
        #expect(fresh.page == shown.page)
    }

    // regression: a close sent after the channel's EOF reached the server was dropped, and the page held its slot
    @Test func aPageClosedOnThePresenterAfterItsChannelEndedIsEnded() async throws {
        let session = try newSession()
        let viewer = try await presenter(for: session)
        defer { viewer.disconnect() }
        let shown = try #require(try await offeredPage(session, to: viewer), "\(viewer.missed ?? ""), session \(session.id)")
        let page = try #require(UUID(uuidString: shown.page))
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, UnixSocket.streamType, 0, &pair) == 0)
        #expect(streams.claimPageStream(shown.token).ok)
        streams.adoptPageServeStream(descriptor: pair[0], page: page, token: shown.token)

        close(pair[1])
        #expect(await eventually { session.remoteOverlays.slot(nil)?.owner == nil }, "session \(session.id)")
        try viewer.send(.pageClosed(PresentationPageChange(page: shown.page)))

        #expect(await eventually { session.remoteOverlays.slot(nil) == nil }, "session \(session.id)")
        #expect(try await offeredPage(session, to: viewer) != nil, "\(viewer.missed ?? ""), session \(session.id)")
    }

    @Test func aPresenterReportingItsChannelLostBeforeTheServerSeesItKeepsThePage() async throws {
        let session = try newSession()
        let first = try await presenter(for: session)
        let shown = try #require(try await offeredPage(session, to: first))

        try first.send(.pageClosed(PresentationPageChange(page: shown.page, reason: PresentationPageChange.channelLost)))
        let kept = await eventually { session.remoteOverlays.slot(nil)?.owner == nil }
        #expect(kept)
        await drop(first, from: session)
        let next = try await presenter(for: session)
        defer { next.disconnect() }

        let reoffered = await offPool { next.first { if case .pageRequest = $0 { true } else { false } } }
        guard case .pageRequest(let fresh)? = reoffered else { Issue.record("no page re-offer"); return }
        #expect(fresh.page == shown.page)
    }

    private func loopbackPage() throws -> HtmlSource {
        .url(try #require(URL(string: "http://localhost:3000/app")))
    }

    @Test func aLoopbackPageReachesAPresenterThatForwardsAsAForward() async throws {
        let session = try newSession()
        let viewer = try await presenter(for: session)
        defer { viewer.disconnect() }

        #expect(openOverlay(on: session, page: try loopbackPage()).ok)

        let offered = await offPool { viewer.first { if case .pageRequest = $0 { true } else { false } } }
        guard case .pageRequest(let page)? = offered else { Issue.record("no page offer"); return }
        #expect(page.source == .forwarded("http://localhost:3000/app"))
    }

    @Test func aLoopbackPageIsRefusedForAConnectedPresenterThatCannotForward() async throws {
        let session = try newSession()
        let viewer = try await presenter(for: session, kinds: PresentationHub.supportedKinds.filter { $0 != PresentationHub.pageForwardKind })
        defer { viewer.disconnect() }

        let reply = openOverlay(on: session, page: try loopbackPage())

        #expect(!reply.ok)
        #expect(reply.error?.contains("loopback") == true)
        #expect(session.remoteOverlays.slots.isEmpty)
    }

    @Test func aHeldLoopbackPageWaitsPastAPresenterThatCannotForward() async throws {
        let session = try newSession()
        #expect(openOverlay(on: session, page: try loopbackPage()).ok)
        let older = try await presenter(for: session, kinds: PresentationHub.supportedKinds.filter { $0 != PresentationHub.pageForwardKind })

        let skipped = await offPool { older.first(within: 0.5) { if case .pageRequest = $0 { true } else { false } } }
        #expect(skipped == nil)
        await drop(older, from: session)
        let next = try await presenter(for: session)
        defer { next.disconnect() }

        let offered = await offPool { next.first { if case .pageRequest = $0 { true } else { false } } }
        guard case .pageRequest(let page)? = offered else { Issue.record("no page offer"); return }
        #expect(page.source == .forwarded("http://localhost:3000/app"))
    }

    @Test func aPageThePresenterClosesEnds() async throws {
        let session = try newSession()
        let viewer = try await presenter(for: session)
        defer { viewer.disconnect() }
        let shown = try #require(try await offeredPage(session, to: viewer))

        try viewer.send(.pageClosed(PresentationPageChange(page: shown.page)))

        let ended = await eventually { session.remoteOverlays.slot(nil) == nil }
        #expect(ended)
    }

    @Test func anAutoSizedPictureKeepsItsPointOverrideAcrossAReoffer() async throws {
        let session = try newSession()
        let first = try await presenter(for: session)
        let path = harness.scratch.root + "/shot.png"
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52,
                            0, 0, 0x02, 0x80, 0, 0, 0x01, 0xE0, 8, 6, 0, 0, 0, 0, 0, 0, 0]
        try Data(png).write(to: URL(fileURLWithPath: path))
        #expect(openOverlay(on: session, page: .image(path: path)).ok)
        _ = await offPool { first.first { if case .pageRequest = $0 { true } else { false } } }
        #expect(harness.actions.resizeSessionOverlay(session.id.uuidString, window: nil, sizePercent: nil,
                                                     points: OverlayPointSize(width: 300)).ok)

        first.disconnect()
        let returned = await eventually { session.remoteOverlays.slot(nil)?.owner == nil }
        #expect(returned)
        let next = try await presenter(for: session)
        defer { next.disconnect() }

        let reoffered = await offPool { next.first { if case .pageRequest = $0 { true } else { false } } }
        guard case .pageRequest(let fresh)? = reoffered else { Issue.record("no page re-offer"); return }
        #expect(fresh.sizePercent == nil)
        #expect(fresh.points.isEmpty)
        let resize = await offPool { next.first { if case .pageCommand(let command) = $0 { command.action == .resize } else { false } } }
        guard case .pageCommand(let command)? = resize else { Issue.record("no merge resize"); return }
        #expect(command.points.width == 300)
        #expect(command.sizePercent == ImagePage.basePercent)
        #expect(command.merge == true)
    }

    @Test func aStaleClaimCannotTakeOrEndTheReofferedPage() async throws {
        let session = try newSession()
        let first = try await presenter(for: session)
        let old = try #require(try await offeredPage(session, to: first))
        let page = try #require(UUID(uuidString: old.page))
        #expect(streams.claimPageStream(old.token).ok)
        first.disconnect()
        let returned = await eventually { session.remoteOverlays.slot(nil)?.owner == nil }
        #expect(returned)
        let next = try await presenter(for: session)
        defer { next.disconnect() }
        let reoffered = await offPool { next.first { if case .pageRequest = $0 { true } else { false } } }
        guard case .pageRequest(let fresh)? = reoffered else { Issue.record("no page re-offer"); return }
        #expect(streams.claimPageStream(fresh.token).ok)
        var stale: [Int32] = [-1, -1], current: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, UnixSocket.streamType, 0, &stale) == 0)
        #expect(socketpair(AF_UNIX, UnixSocket.streamType, 0, &current) == 0)
        defer { close(stale[1]); close(current[1]) }

        streams.adoptPageServeStream(descriptor: stale[0], page: page, token: old.token)
        streams.pageClaimUnanswered(page, token: old.token)

        #expect(streams.pageServeStreams[page] == nil)
        #expect(session.remoteOverlays.slot(nil)?.page != nil)
        streams.adoptPageServeStream(descriptor: current[0], page: page, token: fresh.token)
        #expect(streams.pageServeStreams[page] != nil)
    }

    @Test func aReofferedPageComesBackAtItsCurrentSizeAndHidden() async throws {
        let session = try newSession()
        let first = try await presenter(for: session)
        let shown = try #require(try await offeredPage(session, to: first))
        let id = session.id.uuidString
        #expect(harness.actions.resizeSessionOverlay(id, window: nil, sizePercent: 40).ok)
        _ = await offPool { first.first { if case .pageCommand = $0 { true } else { false } } }
        try first.send(.pageState(PresentationPageState(page: shown.page, title: nil, address: nil, load: .loaded, error: nil,
                                                        canGoBack: false, canGoForward: false, hidden: true, appliedSeq: 0)))
        try await Task.sleep(for: .milliseconds(200))

        first.disconnect()
        let returned = await eventually { session.remoteOverlays.slot(nil)?.owner == nil }
        #expect(returned)
        let next = try await presenter(for: session)
        defer { next.disconnect() }

        let reoffered = await offPool { next.first { if case .pageRequest = $0 { true } else { false } } }
        guard case .pageRequest(let fresh)? = reoffered else { Issue.record("no page re-offer: \(next.missed ?? ""), session \(session.id)"); return }
        #expect(fresh.sizePercent == 40)
        let hide = await offPool { next.first { if case .pageCommand(let command) = $0 { command.action == .hide } else { false } } }
        #expect(hide != nil, "\(next.missed ?? ""), session \(session.id)")
    }

    @Test func offeredPagesAndJobsReadBackTheirWindows() async throws {
        let session = try newSession()
        let viewer = try await presenter(for: session)
        defer { viewer.disconnect() }
        #expect(openOverlay(on: session).ok)
        let job = try #require(session.remoteOverlays.slot(nil)?.job)

        let node = harness.store.controlTree().workspaces.flatMap(\.sessions).first { $0.id == session.id.uuidString }
        let deadline = try #require(node?.interactions?.first { $0.id == job }?.deadline)
        #expect(deadline == harness.jobClock.addingTimeInterval(OverlayJobs.launchWindow).timeIntervalSince1970)
    }

    @Test func aJobWhoseClaimReplyWasNotWrittenIsGivenUp() {
        let job = streams.overlayJobs.register(session: UUID(), pane: nil, owner: 1,
                                               context: OverlayLaunchContext(command: "true", cwd: "/tmp", sessionEnvironment: [:]))
        let reply = streams.claimJobStream(job)

        let adopted = streams.adopt(-1, request: ControlRequest(cmd: .sessionOverlayJobRun, target: job), response: reply, written: false)

        #expect(!adopted)
        #expect(streams.overlayJobs.job(job).map { if case .claimed = $0.state { true } else { false } } != true)
    }

    private func clickSession() throws -> Session {
        let session = try newSession()
        session.currentCwd = harness.scratch.root
        return session
    }

    private func write(_ name: String, _ text: String = "# notes\n") throws -> String {
        let path = harness.scratch.root + "/" + name
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func click(_ raw: String, on session: Session, pane: UUID? = nil, mode: LinkOpenMode = .overlay,
                       from viewer: Viewer) throws {
        try viewer.send(.linkClick(PresentationLinkClick(raw: raw, pane: pane ?? session.paneIdentity, mode: mode)))
    }

    private func pageRequest(from viewer: Viewer) async -> PresentationPage? {
        let body = await offPool { viewer.first { if case .pageRequest = $0 { true } else { false } } }
        guard case .pageRequest(let page)? = body else { return nil }
        return page
    }

    private func refusal(from viewer: Viewer) async -> RemoteLinkRefusal? {
        let body = await offPool { viewer.first { if case .linkRefused = $0 { true } else { false } } }
        guard case .linkRefused(let refusal)? = body else { return nil }
        return refusal.reason
    }

    @Test func aClickedMarkdownFileInThePanesDirectoryOpensAsAClickedPageWithItsLinks() async throws {
        let session = try clickSession()
        let viewer = try await presenter(for: session)
        defer { viewer.disconnect() }
        let path = try write("notes.md")

        try click("./notes.md", on: session, from: viewer)

        let page = try #require(await pageRequest(from: viewer))
        #expect(page.source == .markdown(path: path))
        #expect(page.navigation)
        #expect(page.markdownLinks != nil)
        #expect(session.remoteOverlays.slot(nil)?.page?.overlay.clicked == true)
    }

    @Test(arguments: LinkOpenMode.allCases)
    func everyPageKindOpensInEveryLinkMode(mode: LinkOpenMode) async throws {
        let session = try clickSession()
        let viewer = try await presenter(for: session)
        defer { viewer.disconnect() }
        let pages = [("notes.md", "# notes\n"), ("main.go", "package main\n"), ("page.html", "<!doctype html><p>hi</p>\n")]

        for (name, text) in pages {
            _ = try write(name, text)
            try click("./" + name, on: session, mode: mode, from: viewer)
            let page = await pageRequest(from: viewer)
            #expect(page != nil, "\(name) in \(mode): \(viewer.missed ?? ""), session \(session.id)")
            #expect(harness.actions.closeSessionOverlay(session.id.uuidString, window: nil, pane: nil).ok, "\(name) in \(mode)")
        }
    }

    @Test func aClickedTextLocationOpensAtItsLine() async throws {
        let session = try clickSession()
        let viewer = try await presenter(for: session)
        defer { viewer.disconnect() }
        let path = try write("main.go", "package main\n\nfunc main() {}\n")

        try click("./main.go:3", on: session, from: viewer)

        let page = try #require(await pageRequest(from: viewer))
        #expect(page.source == .text(path: path, line: 3))
    }

    @Test(arguments: [("./gone.md", RemoteLinkRefusal.notFound), ("./gone.bin", .notFound), ("./data.bin", .notAPage),
                      ("agterm://session/0F5C1E2A-3B4D-4E6F-8A9B-0C1D2E3F4A5B", .notAPage)])
    func aClickThatNamesNoPageIsRefused(raw: String, reason: RemoteLinkRefusal) async throws {
        let session = try clickSession()
        let viewer = try await presenter(for: session)
        defer { viewer.disconnect() }
        try Data([0, 1, 2]).write(to: URL(fileURLWithPath: harness.scratch.root + "/data.bin"))

        try click(raw, on: session, from: viewer)

        #expect(await refusal(from: viewer) == reason)
        #expect(session.remoteOverlays.slot(nil) == nil)
    }

    @Test func aClickInAPaneTheSessionDoesNotHaveIsRefused() async throws {
        let session = try clickSession()
        let viewer = try await presenter(for: session)
        defer { viewer.disconnect() }
        _ = try write("notes.md")

        try click("./notes.md", on: session, pane: UUID(), from: viewer)

        #expect(await refusal(from: viewer) == .paneNotAttached)
    }

    @Test func aClickWhileTheHudIsUpIsNotOpened() async throws {
        let session = try clickSession()
        let viewer = try await presenter(for: session)
        defer { viewer.disconnect() }
        _ = try write("notes.md")
        #expect(harness.actions.openHud(session.id.uuidString, window: nil, spec: HudSpec(message: "building")).ok)

        try click("./notes.md", on: session, from: viewer)

        #expect(await refusal(from: viewer) == .notOpened)
        #expect(session.remoteOverlays.slot(nil) == nil)
    }

    @Test func aClickWhosePresenterChangedBeforeItsFileWasCheckedIsDropped() async throws {
        let session = try clickSession()
        let first = try await presenter(for: session)
        _ = try write("notes.md")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let check = streams.checkPage
        streams.checkPage = { page, options in
            entered.signal()
            release.wait()
            return check(page, options)
        }

        try click("./notes.md", on: session, from: first)
        #expect(await offPool { entered.wait(timeout: .now() + 60) == .success })
        await drop(first, from: session)
        let second = try await presenter(for: session)
        defer { second.disconnect() }
        release.signal()

        let late = await offPool {
            second.first(within: 2) { if case .pageRequest = $0 { true } else if case .linkRefused = $0 { true } else { false } }
        }
        #expect(late == nil)
        #expect(session.remoteOverlays.slot(nil) == nil)
    }

    @Test func aClickReplacesAHiddenClickedPageOnlyOnceTheNewFileChecksOut() async throws {
        let session = try clickSession()
        let viewer = try await presenter(for: session)
        defer { viewer.disconnect() }
        _ = try write("a.md")
        let replacement = try write("b.md")
        try FileManager.default.createDirectory(atPath: harness.scratch.root + "/broken.md", withIntermediateDirectories: false)
        try click("./a.md", on: session, from: viewer)
        let shown = try #require(await pageRequest(from: viewer))
        try viewer.send(.pageState(PresentationPageState(page: shown.page, title: nil, address: nil, load: .loaded, error: nil,
                                                         canGoBack: false, canGoForward: false, hidden: true, appliedSeq: 0)))

        try click("./broken.md", on: session, from: viewer)
        #expect(await refusal(from: viewer) == .notOpened, "\(viewer.missed ?? ""), session \(session.id)")
        #expect(session.remoteOverlays.slot(nil)?.job == shown.page)

        try click("./b.md", on: session, from: viewer)
        let next = try #require(await pageRequest(from: viewer), "\(viewer.missed ?? ""), session \(session.id)")
        #expect(next.source == .markdown(path: replacement))
        #expect(session.remoteOverlays.slot(nil)?.job == next.page)
    }

    @Test func hidingAPageShownOnThePresenterSendsItAndToggleShowsItAgain() async throws {
        let session = try newSession()
        let viewer = try await presenter(for: session)
        defer { viewer.disconnect() }
        let path = harness.scratch.root + "/notes.md"
        try Data("# notes\n".utf8).write(to: URL(fileURLWithPath: path))
        #expect(openOverlay(on: session, page: .markdown(path: path)).ok)
        #expect(await pageRequest(from: viewer) != nil)

        let hidden = harness.actions.setSessionOverlayVisibility(session.id.uuidString, window: nil, pane: nil, mode: .hide)
        let hide = await offPool { viewer.first { if case .pageCommand(let command) = $0 { command.action == .hide } else { false } } }
        let shown = harness.actions.setSessionOverlayVisibility(session.id.uuidString, window: nil, pane: nil, mode: .toggle)
        let show = await offPool { viewer.first { if case .pageCommand(let command) = $0 { command.action == .show } else { false } } }

        #expect(hidden.result?.text == "hidden")
        #expect(hide != nil)
        #expect(shown.result?.text == "shown")
        #expect(show != nil)
    }

    @Test func hidingWithNoOverlayIsRefused() throws {
        let session = try newSession()

        let reply = harness.actions.setSessionOverlayVisibility(session.id.uuidString, window: nil, pane: nil, mode: .hide)

        #expect(!reply.ok)
    }

    final class LogClient: @unchecked Sendable {
        enum Answer: Equatable, Sendable {
            case tail(BoundedFile.TailRead)
            case unchanged
            case failure(String)
            case closed
        }

        private let fd: Int32
        private var buffer = Data()

        init(fd: Int32) {
            var wait = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
            self.fd = fd
        }

        deinit { close(fd) }

        func send(_ frame: PageServeFrame) throws {
            let line = try PageServeCodec.encode(frame)
            _ = line.withUnsafeBytes { UnixSocket.write(fd, $0.baseAddress!, $0.count) }
        }

        func frame() -> PageServeFrame? {
            while true {
                if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = Data(buffer[buffer.startIndex..<newline])
                    buffer.removeSubrange(buffer.startIndex...newline)
                    return try? PageServeCodec.decode(line)
                }
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                let count = read(fd, &chunk, chunk.count)
                guard count > 0 else { return nil }
                buffer.append(contentsOf: chunk[0..<count])
            }
        }

        func answer(_ id: Int) -> Answer {
            var head: (stamp: BoundedFile.FileStamp, offset: Int)?
            var data = Data()
            while let frame = frame() {
                switch frame {
                case .logUnchanged(id): return .unchanged
                case .logHead(id, let stamp, let offset): head = (stamp, offset)
                case .chunk(id, let bytes): data.append(bytes)
                case .end(id): return head.map { .tail(BoundedFile.TailRead(data: data, offset: $0.offset, stamp: $0.stamp)) } ?? .closed
                case .failure(id, let error): return .failure(error)
                default: continue
                }
            }
            return .closed
        }
    }

    private func logChannel(_ source: HtmlSource, log: TextLog? = TextLog(tail: 50, follow: true)) async throws -> (LogClient, Viewer) {
        let session = try newSession()
        let viewer = try await presenter(for: session)
        let overlay = HtmlOverlay(source: source, textLog: log)
        let options = ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil,
                                                       page: source, textLog: log)
        #expect(streams.handOver(overlay, in: session, options: options) == .opened)
        let offered = await offPool { viewer.first { if case .pageRequest = $0 { true } else { false } } }
        guard case .pageRequest(let shown)? = offered else {
            viewer.disconnect()
            throw POSIXError(.ENOENT)
        }
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, UnixSocket.streamType, 0, &pair) == 0)
        #expect(streams.claimPageStream(shown.token).ok)
        streams.adoptPageServeStream(descriptor: pair[0], page: overlay.id, token: shown.token)
        return (LogClient(fd: pair[1]), viewer)
    }

    private func logFile(_ text: String) throws -> String {
        let path = harness.scratch.root + "/log-\(UUID().uuidString).log"
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func stamp(_ path: String) throws -> BoundedFile.FileStamp {
        guard case .success(let read?) = BoundedFile.readTail(path: path, maxBytes: 1, unchangedFrom: nil) else {
            throw POSIXError(.EIO)
        }
        return read.stamp
    }

    @Test func aLogTailAnswersTheTailThenUnchangedUntilTheFileMoves() async throws {
        let path = try logFile("a\nb\n")
        let (client, viewer) = try await logChannel(.text(path: path, line: nil))
        defer { viewer.disconnect() }
        let first = try stamp(path)

        let answers = try await offPool { () throws -> [LogClient.Answer] in
            try client.send(.logTail(id: 1, stamp: nil))
            let fresh = client.answer(1)
            try client.send(.logTail(id: 2, stamp: first))
            let same = client.answer(2)
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("c\n".utf8))
            try handle.close()
            try client.send(.logTail(id: 3, stamp: first))
            return [fresh, same, client.answer(3)]
        }

        #expect(answers[0] == .tail(BoundedFile.TailRead(data: Data("a\nb\n".utf8), offset: 0, stamp: first)))
        #expect(answers[1] == .unchanged)
        #expect(answers[2] == .tail(BoundedFile.TailRead(data: Data("a\nb\nc\n".utf8), offset: 0, stamp: try stamp(path))))
    }

    @Test func anEmptyOrTruncatedLogAnswersWhatTheFileHoldsNow() async throws {
        let path = try logFile("one\ntwo\nthree\n")
        let (client, viewer) = try await logChannel(.text(path: path, line: nil))
        defer { viewer.disconnect() }
        let before = try stamp(path)

        let answers = try await offPool { () throws -> [LogClient.Answer] in
            try Data("x\n".utf8).write(to: URL(fileURLWithPath: path))
            try client.send(.logTail(id: 1, stamp: before))
            let truncated = client.answer(1)
            try Data().write(to: URL(fileURLWithPath: path))
            try client.send(.logTail(id: 2, stamp: nil))
            return [truncated, client.answer(2)]
        }

        guard case .tail(let truncated) = answers[0], case .tail(let empty) = answers[1] else {
            Issue.record("expected two tails: \(answers)")
            return
        }
        #expect(truncated.data == Data("x\n".utf8) && truncated.offset == 0)
        #expect(empty.data.isEmpty && empty.offset == 0)
    }

    @Test func aLogPastTheTailCapAnswersOnlyItsLastBytes() async throws {
        let path = try logFile(String(repeating: "0123456789\n", count: TextPage.maxTailBytes / 11 + 100))
        let local = try BoundedFile.readTail(path: path, maxBytes: TextPage.maxTailBytes).get()
        let (client, viewer) = try await logChannel(.text(path: path, line: nil))
        defer { viewer.disconnect() }

        let answer = try await offPool { () throws -> LogClient.Answer in
            try client.send(.logTail(id: 1, stamp: nil))
            return client.answer(1)
        }

        #expect(answer == local.map { LogClient.Answer.tail($0) })
        #expect(try #require(local).offset > 0)
    }

    @Test func aLogRemovedAfterItsPageOpenedAnswersAFailure() async throws {
        let path = try logFile("a\n")
        let (client, viewer) = try await logChannel(.text(path: path, line: nil))
        defer { viewer.disconnect() }
        try FileManager.default.removeItem(atPath: path)

        let answer = try await offPool { () throws -> LogClient.Answer in
            try client.send(.logTail(id: 1, stamp: nil))
            return client.answer(1)
        }

        #expect(answer == .failure("file cannot be read"))
    }

    @Test(arguments: [false, true])
    func aPageThatIsNotALogRefusesALogTail(markdown: Bool) async throws {
        let path = try logFile("a\n")
        let source: HtmlSource = markdown ? .markdown(path: path) : .text(path: path, line: nil)
        let (client, viewer) = try await logChannel(source, log: markdown ? TextLog(tail: 50, follow: true) : nil)
        defer { viewer.disconnect() }

        let answer = try await offPool { () throws -> LogClient.Answer in
            try client.send(.logTail(id: 1, stamp: nil))
            return client.answer(1)
        }

        #expect(answer == .failure("not a log page"))
    }

    @Test func aCancelledLogTailStopsBeforeItsEnd() async throws {
        let path = try logFile(String(repeating: "0123456789\n", count: TextPage.maxTailBytes / 11))
        let (client, viewer) = try await logChannel(.text(path: path, line: nil))
        defer { viewer.disconnect() }

        let answer = try await offPool { () throws -> LogClient.Answer in
            try client.send(.logTail(id: 1, stamp: nil))
            try client.send(.cancel(id: 1))
            Thread.sleep(forTimeInterval: 0.3)
            return client.answer(1)
        }

        #expect(answer == .failure(PageServeFrame.cancelled))
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
