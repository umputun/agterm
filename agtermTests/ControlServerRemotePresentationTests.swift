import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerRemotePresentationTests: XCTestCase {
    private var stateDir: URL!
    private var servers: [ControlServer] = []

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-remote-presentation-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        for server in servers { server.stop() }
        servers.removeAll()
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    private func fixture() throws -> (server: ControlServer, store: AppStore, session: Session) {
        let library = WindowLibrary(directory: stateDir)
        let server = ControlServer(
            library: library,
            actions: AppActions(library: library),
            settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
            identity: AppIdentity(version: "9.9.9"),
            socketPath: "/tmp/agterm-rp-\(UUID().uuidString.prefix(8)).sock"
        )
        servers.append(server)
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory(),
                                                     remoteHost: "buildbox"))
        store.bindRemote(RemoteBinding(remoteSessionID: "s1", daemonsByLocalPane: [:], presentationVersion: 1),
                         forSession: session.id)
        return (server, store, session)
    }

    private func hud(_ message: String, remaining: Double? = nil, generation: Int = 1) -> PresentationHud {
        PresentationHud(spec: HudSpec(message: message, hideAfter: 600), pane: nil, generation: generation,
                        remaining: remaining)
    }

    private func body(of session: Session) -> String {
        (try? String(contentsOfFile: ControlServer.bodyFile(for: session.id), encoding: .utf8)) ?? ""
    }

    func testAMirroredHudIsWrittenToThePanelAndMarkedAsTheBridges() throws {
        let fix = try fixture()

        fix.server.showRemoteHud(hud("deploying"), forSession: fix.session.id)

        XCTAssertTrue(fix.session.hudActive)
        XCTAssertTrue(body(of: fix.session).contains("deploying"), "the panel's body is on disk, not only in the model")
        XCTAssertEqual(fix.session.remotePresentation?.hudBridged, true)
    }

    func testTheViewerCountsDownWhatIsLeftNotTheConfiguredInterval() throws {
        let fix = try fixture()
        let start = Date(timeIntervalSince1970: 1_789_000_000)
        fix.server.hudClock = { start }

        fix.server.showRemoteHud(hud("deploying", remaining: 7), forSession: fix.session.id)

        XCTAssertEqual(fix.server.hudAutoHide[fix.session.id]?.deadline, start.addingTimeInterval(7))
    }

    func testAPersistentOriginPanelArmsNoTimerHere() throws {
        let fix = try fixture()

        fix.server.showRemoteHud(hud("waiting"), forSession: fix.session.id)

        XCTAssertNil(fix.server.hudAutoHide[fix.session.id])
    }

    func testAnUpdateRepaintsInPlace() throws {
        let fix = try fixture()
        fix.server.showRemoteHud(hud("one"), forSession: fix.session.id)
        let slot = fix.session.overlaySlotGeneration

        fix.server.showRemoteHud(hud("two", generation: 2), forSession: fix.session.id)

        XCTAssertEqual(fix.session.overlaySlotGeneration, slot, "an update must not re-create the panel's surface")
        XCTAssertTrue(body(of: fix.session).contains("two"))
    }

    func testAPaneHiddenHereKeepsTheMirroredPanelSessionWideAcrossUpdates() throws {
        let fix = try fixture()
        let remoteRight = UUID()
        fix.store.toggleSplit(fix.session.id)
        let split = try XCTUnwrap(fix.session.splitPaneIdentity)
        fix.store.bindRemote(RemoteBinding(remoteSessionID: "s1",
                                           daemonsByLocalPane: [split: ZmxSupport.daemonName(for: remoteRight)],
                                           presentationVersion: 1), forSession: fix.session.id)
        fix.store.setSplitVisibility(fix.session.id, shown: false)
        let first = PresentationHud(spec: HudSpec(message: "one"), pane: .identity(remoteRight), generation: 1,
                                    remaining: nil)
        let second = PresentationHud(spec: HudSpec(message: "two"), pane: .identity(remoteRight), generation: 2,
                                     remaining: nil)

        fix.server.showRemoteHud(first, forSession: fix.session.id)
        XCTAssertNil(fix.session.hudPaneIdentity)
        fix.server.showRemoteHud(second, forSession: fix.session.id)

        XCTAssertTrue(fix.session.hudActive)
        XCTAssertNil(fix.session.hudPaneIdentity, "an update must not move the panel onto a pane the deck does not lay out")
        XCTAssertTrue(body(of: fix.session).contains("two"))
    }

    func testAbsenceTakesTheMirroredPanelDown() throws {
        let fix = try fixture()
        fix.server.showRemoteHud(hud("deploying"), forSession: fix.session.id)

        fix.server.showRemoteHud(nil, forSession: fix.session.id)

        XCTAssertFalse(fix.session.hudActive)
    }

    func testAPanelWithNothingLeftIsNotShown() throws {
        let fix = try fixture()

        fix.server.showRemoteHud(hud("late", remaining: 0), forSession: fix.session.id)

        XCTAssertFalse(fix.session.hudActive)
    }

    func testAPanelThisMacsOwnProgramOpenedIsNeitherReplacedNorClosed() throws {
        let fix = try fixture()
        XCTAssertTrue(fix.server.openHud(fix.session.id.uuidString, window: nil, spec: HudSpec(message: "local")).ok)

        fix.server.showRemoteHud(hud("mirrored"), forSession: fix.session.id)
        fix.server.showRemoteHud(nil, forSession: fix.session.id)

        XCTAssertTrue(fix.session.hudActive)
        XCTAssertTrue(body(of: fix.session).contains("local"))
        XCTAssertEqual(fix.session.remotePresentation?.hudBridged, false)
    }

    func testAMirroredPanelYieldsToAProgramOverlay() throws {
        let fix = try fixture()
        XCTAssertTrue(fix.store.openOverlay(fix.session.id, command: "htop"))

        fix.server.showRemoteHud(hud("mirrored"), forSession: fix.session.id)

        XCTAssertTrue(fix.session.programOverlayActive)
        XCTAssertFalse(fix.session.hudActive)
        XCTAssertEqual(fix.session.remotePresentation?.hudBridged, false)
    }

    func testASessionThatIsNotAttachedIgnoresAMirroredPanel() throws {
        let fix = try fixture()
        let workspace = try XCTUnwrap(fix.store.currentWorkspaceID)
        let local = try XCTUnwrap(fix.store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory()))

        fix.server.showRemoteHud(hud("mirrored"), forSession: local.id)

        XCTAssertFalse(local.hudActive)
    }

    @MainActor
    private final class Transport: RemotePresentationTransport {
        final class Link: RemotePresentationLink {
            var stopped = false
            var sent: [PresentationFrame.Body] = []
            func send(_ line: Data) {
                if let frame = try? PresentationCodec.decode(line.dropLast()) { sent.append(frame.body) }
            }
            func stop() { stopped = true }
        }

        var launches: [[String]] = []
        var links: [Link] = []
        var deliver: [(Data) -> Void] = []

        func open(_ argv: [String], onLine: @escaping @MainActor (Data) -> Void,
                  onClose: @escaping @MainActor (String) -> Void) -> RemotePresentationLink {
            launches.append(argv)
            deliver.append(onLine)
            let link = Link()
            links.append(link)
            return link
        }

        func feed(_ body: PresentationFrame.Body, rev: Int) throws {
            let line = try PresentationCodec.encode(PresentationFrame(gen: 3, rev: rev, body: body)).dropLast()
            deliver.last?(Data(line))
        }
    }

    private func connected() throws -> (fix: (server: ControlServer, store: AppStore, session: Session),
                                        transport: Transport) {
        let fix = try fixture()
        let transport = Transport()
        fix.server.remoteTransport = transport
        fix.server.startRemotePresentation(for: fix.session)
        try transport.feed(.hello(PresentationHello(version: 1, kinds: ["status"], mode: .mirror)), rev: 0)
        return (fix, transport)
    }

    func testStartingOpensTheBridgeForTheOriginsSession() throws {
        let (fix, transport) = try connected()

        XCTAssertEqual(transport.launches.count, 1)
        XCTAssertEqual(transport.launches[0].prefix(2), ["ssh", "-T"])
        XCTAssertTrue(try XCTUnwrap(transport.launches[0].last).contains("present"))
        XCTAssertNotNil(fix.server.remoteClients[fix.session.id])
    }

    func testTheSnapshotReachesTheRowAndMarksItConnected() throws {
        let (fix, transport) = try connected()
        let status = PresentationStatus(status: .blocked, blink: false, color: nil, shape: nil, pane: nil,
                                        changedAt: nil)

        try transport.feed(.snapshot(PresentationSnapshot(status: status, hud: nil)), rev: 1)

        XCTAssertEqual(fix.session.agentIndicator.status, .blocked)
        XCTAssertEqual(fix.session.remotePresentation?.connection, .connected)
    }

    func testAMirroredHudFrameIsShownOnTheRow() throws {
        let (fix, transport) = try connected()
        try transport.feed(.snapshot(PresentationSnapshot(status: nil, hud: nil)), rev: 1)

        try transport.feed(.hud(hud("deploying")), rev: 2)

        XCTAssertTrue(fix.session.hudActive)
        XCTAssertTrue(body(of: fix.session).contains("deploying"))
    }

    func testAHandedOverAskIsShownOnTheRowAndItsAnswerGoesBack() throws {
        let (fix, transport) = try connected()
        try transport.feed(.snapshot(PresentationSnapshot(status: nil, hud: nil)), rev: 1)
        let ask = PresentationAsk(PendingAsk(id: "a1", title: "deploy?", buttons: [ControlAskButton(id: "yes", label: "Yes")]),
                                  pane: nil, owner: 2)

        try transport.feed(.askRequest(ask), rev: 2)

        XCTAssertEqual(fix.session.askPending?.id, "a1")
        XCTAssertTrue(fix.session.askReplica)
        fix.session.resolveAsk(id: "a1", ControlAskResult(result: .answered, id: "yes", label: "Yes", index: 0))
        XCTAssertEqual(transport.links[0].sent.last, .askResolve(PresentationAskAnswer(id: "a1", owner: 2, button: "yes")))
    }

    func testAnAskTheRowCannotShowIsRefused() throws {
        let (fix, transport) = try connected()
        try transport.feed(.snapshot(PresentationSnapshot(status: nil, hud: nil)), rev: 1)
        fix.session.openAsk(PendingAsk(id: "local", title: "local", buttons: [ControlAskButton(id: "ok", label: "OK")]))

        try transport.feed(.askRequest(PresentationAsk(PendingAsk(id: "a1", title: "deploy?",
                                                                  buttons: [ControlAskButton(id: "yes", label: "Yes")]),
                                                       pane: nil, owner: 2)), rev: 2)

        XCTAssertEqual(transport.links[0].sent.last, .askRejected(PresentationAskRef(id: "a1", owner: 2)))
        XCTAssertEqual(fix.session.askPending?.id, "local")
    }

    private let handedOverlay = PresentationOverlay(job: "job-1", pane: nil, sizePercent: 50, backgroundColor: nil,
                                                    follow: false, wait: false)

    func testAHandedOverOverlayRunsTheJobsHelperOverSshAndItsCloseGoesBack() throws {
        let (fix, transport) = try connected()
        try transport.feed(.snapshot(PresentationSnapshot(status: nil, hud: nil)), rev: 1)

        try transport.feed(.overlayRequest(handedOverlay), rev: 2)

        let host = try XCTUnwrap(fix.session.remoteHost)
        XCTAssertEqual(fix.session.overlayCommand,
                       CommandRestore.shellQuotedLine(try RemoteSession.runJobCommand(host: host, job: "job-1")))
        XCTAssertEqual(fix.session.overlaySizePercent, 50)
        fix.store.closeOverlay(fix.session.id)
        XCTAssertEqual(transport.links[0].sent.last, .overlayClosed(PresentationOverlayChange(job: "job-1")))
    }

    func testAnOverlayTheRowCannotShowIsRefused() throws {
        let (fix, transport) = try connected()
        try transport.feed(.snapshot(PresentationSnapshot(status: nil, hud: nil)), rev: 1)
        fix.store.openOverlay(fix.session.id, command: "top")

        try transport.feed(.overlayRequest(handedOverlay), rev: 2)

        XCTAssertEqual(transport.links[0].sent.last, .overlayRejected(PresentationOverlayChange(job: "job-1")))
        XCTAssertEqual(fix.session.overlayCommand, "top")
    }

    func testTheOriginsResizeAndCloseReachTheOverlay() throws {
        let (fix, transport) = try connected()
        try transport.feed(.snapshot(PresentationSnapshot(status: nil, hud: nil)), rev: 1)
        try transport.feed(.overlayRequest(handedOverlay), rev: 2)

        try transport.feed(.overlayResize(PresentationOverlayChange(job: "job-1", sizePercent: 70)), rev: 3)
        XCTAssertEqual(fix.session.overlaySizePercent, 70)
        try transport.feed(.overlayClose(PresentationOverlayChange(job: "job-1")), rev: 4)

        XCTAssertFalse(fix.session.overlayActive)
    }

    private func replica(_ style: ControlAskStyle) -> PresentationAsk {
        PresentationAsk(PendingAsk(id: UUID().uuidString, title: "deploy?", buttons: [ControlAskButton(id: "yes", label: "Yes")],
                                   style: style), pane: nil, owner: 2)
    }

    private func unselect(_ fix: (server: ControlServer, store: AppStore, session: Session)) throws {
        let other = try XCTUnwrap(fix.store.workspaces.flatMap(\.sessions).first { $0.id != fix.session.id })
        fix.store.selectSession(other.id)
    }

    func testAGuiReplicaForARowNotSelectedIsRefused() throws {
        let (fix, transport) = try connected()
        try transport.feed(.snapshot(PresentationSnapshot(status: nil, hud: nil)), rev: 1)
        try unselect(fix)
        let ask = replica(.gui)

        try transport.feed(.askRequest(ask), rev: 2)

        XCTAssertEqual(transport.links[0].sent.last, .askRejected(PresentationAskRef(id: ask.id, owner: 2)))
        XCTAssertNil(fix.session.askPending)
    }

    func testAGuiReplicaUnderZoomIsRefused() throws {
        let (fix, transport) = try connected()
        try transport.feed(.snapshot(PresentationSnapshot(status: nil, hud: nil)), rev: 1)
        fix.store.selectSession(fix.session.id)
        let windowID = try XCTUnwrap(fix.server.library.windowID(for: fix.store))
        let zoom = TerminalZoomController()
        TerminalZoomRegistry.shared.register(windowID, controller: zoom)
        defer { TerminalZoomRegistry.shared.unregister(windowID) }
        zoom.set(.on, target: .session(fix.session.id, .primary))
        let ask = replica(.gui)

        try transport.feed(.askRequest(ask), rev: 2)

        XCTAssertEqual(transport.links[0].sent.last, .askRejected(PresentationAskRef(id: ask.id, owner: 2)))
    }

    func testAGuiReplicaUnderTheDashboardIsRefused() throws {
        let (fix, transport) = try connected()
        try transport.feed(.snapshot(PresentationSnapshot(status: nil, hud: nil)), rev: 1)
        fix.store.selectSession(fix.session.id)
        let windowID = try XCTUnwrap(fix.server.library.windowID(for: fix.store))
        let dashboard = DashboardController()
        DashboardControllerRegistry.shared.register(windowID, controller: dashboard)
        defer { DashboardControllerRegistry.shared.unregister(windowID) }
        dashboard.open(members: [DashboardMember(session: fix.session.id, surface: .primary)])
        let ask = replica(.gui)

        try transport.feed(.askRequest(ask), rev: 2)

        XCTAssertEqual(transport.links[0].sent.last, .askRejected(PresentationAskRef(id: ask.id, owner: 2)))
    }

    func testATerminalReplicaForARowNotSelectedWaitsHiddenLikeALocalOne() throws {
        let (fix, transport) = try connected()
        try transport.feed(.snapshot(PresentationSnapshot(status: nil, hud: nil)), rev: 1)
        try unselect(fix)
        let ask = replica(.terminal)

        try transport.feed(.askRequest(ask), rev: 2)

        XCTAssertEqual(fix.session.askPending?.id, ask.id)
        XCTAssertTrue(fix.session.askReplica)
        XCTAssertNotEqual(transport.links[0].sent.last, .askRejected(PresentationAskRef(id: ask.id, owner: 2)))
    }

    func testASoftCloseStopsTheClientAndUndoStartsAFreshOne() throws {
        let (fix, transport) = try connected()
        fix.server.refreshWindowCache()

        XCTAssertTrue(fix.store.softCloseSession(fix.session.id))
        XCTAssertTrue(transport.links[0].stopped)
        XCTAssertNil(fix.server.remoteClients[fix.session.id])

        XCTAssertTrue(fix.store.undoPendingClose())
        XCTAssertEqual(transport.launches.count, 2)
        XCTAssertNotNil(fix.server.remoteClients[fix.session.id])
    }

    func testStartingTwiceKeepsOneClient() throws {
        let (fix, transport) = try connected()

        fix.server.startRemotePresentation(for: fix.session)

        XCTAssertEqual(transport.launches.count, 1)
    }

    func testStoppingTheServerStopsEveryClient() throws {
        let (fix, transport) = try connected()

        fix.server.stop()

        XCTAssertTrue(transport.links[0].stopped)
        XCTAssertTrue(fix.server.remoteClients.isEmpty)
    }

    func testALocalSessionGetsNoClient() throws {
        let fix = try fixture()
        let transport = Transport()
        fix.server.remoteTransport = transport
        let workspace = try XCTUnwrap(fix.store.currentWorkspaceID)
        let local = try XCTUnwrap(fix.store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory()))

        fix.server.startRemotePresentation(for: local)

        XCTAssertTrue(transport.launches.isEmpty)
    }

    @MainActor
    private final class BridgeTransport: RemotePresentationTransport {
        let argv: [String]
        private let process = RemotePresentationProcess()

        init(argv: [String]) { self.argv = argv }

        func open(_ ignored: [String], onLine: @escaping @MainActor (Data) -> Void,
                  onClose: @escaping @MainActor (String) -> Void) -> RemotePresentationLink {
            process.open(argv, onLine: onLine, onClose: onClose)
        }
    }

    private func waitUntil(_ what: String, _ condition: @escaping @MainActor () -> Bool) {
        let met = expectation(description: what)
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(8)
            while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
            met.fulfill()
        }
        wait(for: [met], timeout: 10)
        XCTAssertTrue(condition(), what)
    }

    func testStatusAndHudTravelFromAnOriginSessionToItsViewerAndLeaveWithTheStream() throws {
        let library = WindowLibrary(directory: stateDir)
        let socketPath = "/tmp/agterm-e2e-\(UUID().uuidString.prefix(8)).sock"
        let server = ControlServer(
            library: library,
            actions: AppActions(library: library),
            settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
            identity: AppIdentity(version: "9.9.9"),
            socketPath: socketPath
        )
        servers.append(server)
        defer {
            unlink(socketPath)
            unlink(socketPath + ".lock")
        }
        server.start()
        XCTAssertNotNil(server.boundSocketPath)
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let origin = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory()))
        origin.surface = GhosttySurfaceView(workingDirectory: NSHomeDirectory(), backedByZmx: true)
        let viewer = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory(),
                                                    remoteHost: "buildbox"))
        store.bindRemote(RemoteBinding(remoteSessionID: origin.id.uuidString,
                                       daemonsByLocalPane: [viewer.paneIdentity: ZmxSupport.daemonName(for: origin.paneIdentity)],
                                       presentationVersion: PresentationCodec.version), forSession: viewer.id)
        let cli = try XCTUnwrap(Bundle.main.executableURL).deletingLastPathComponent()
            .appendingPathComponent("agtermctl").path
        server.remoteTransport = BridgeTransport(argv: [cli, "zmx", "present", origin.id.uuidString,
                                                        "--socket", socketPath])

        server.startRemotePresentation(for: viewer)
        waitUntil("the viewer's stream connects") { viewer.remotePresentation?.connection == .connected }
        waitUntil("the viewer is granted the presenter role") { viewer.remotePresentation?.mode == .presenter }

        store.applyControlStatus(AgentIndicator(status: .blocked, blink: true), forSession: origin.id)
        waitUntil("the origin's status reaches the viewer row") { viewer.agentIndicator.status == .blocked }
        XCTAssertTrue(viewer.agentIndicator.blink)

        XCTAssertTrue(server.openHud(origin.id.uuidString, window: nil, spec: HudSpec(message: "deploying")).ok)
        waitUntil("the origin's HUD is painted on the viewer") {
            viewer.hudActive && self.body(of: viewer).contains("deploying")
        }
        XCTAssertFalse(DeckPaneGates.coverActive(viewer), "the deck mounts it as a passive panel")
        XCTAssertFalse(OverlayPanelStyle.resolve(viewer).interactive)
        XCTAssertEqual(viewer.hudSpec?.message, "deploying")
        XCTAssertEqual(store.controlTree().workspaces.flatMap(\.sessions).first { $0.id == origin.id.uuidString }?
            .presenters, ControlPresentersNode(mirrors: 0, presenter: true))

        server.shutdownPresentationStreams()
        waitUntil("the mirrored status and HUD leave with the stream") {
            viewer.agentIndicator.status == .idle && !viewer.hudActive
        }
        XCTAssertEqual(viewer.remotePresentation?.mode, .mirror)
        XCTAssertTrue(origin.hudActive, "the origin keeps drawing its own panel")
        XCTAssertEqual(origin.agentIndicator.status, .blocked)
    }
}
