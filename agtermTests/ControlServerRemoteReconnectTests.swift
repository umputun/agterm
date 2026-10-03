import XCTest
@testable import agterm
@testable import agtermCore

@MainActor
final class ControlServerRemoteReconnectTests: XCTestCase {
    private final class Probe: RemoteCommandRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [[String]] = []
        let status: Int32
        let stderr: String
        var argvs: [[String]] { lock.withLock { seen } }

        init(status: Int32, stderr: String = "") {
            self.status = status
            self.stderr = stderr
        }

        func run(_ argv: [String], deadline: TimeInterval) async -> RemoteCommandResult {
            lock.withLock { seen.append(argv) }
            return RemoteCommandResult(status: status, stdout: "", stderr: stderr)
        }
    }

    private var directory: URL!
    private var library: WindowLibrary!
    private var store: AppStore!
    private var pane: UUID?

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-reconnect-\(UUID().uuidString)")
        library = WindowLibrary(directory: directory)
        store = try XCTUnwrap(library.activeStore)
    }

    override func tearDown() async throws {
        if let pane { RemoteReconnectBook.shared.cancel(pane: pane) }
        PaneLead.reconnect = nil
        store = nil
        library = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func server(probe status: Int32) -> ControlServer {
        server(runner: Probe(status: status))
    }

    private func server(runner: any RemoteCommandRunner) -> ControlServer {
        ControlServer(library: library, actions: AppActions(library: library),
                      settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: directory)),
                      identity: AppIdentity(version: "test", commit: "test"), remoteRunner: runner,
                      socketPath: directory.appendingPathComponent("control.sock").path)
    }

    func testRetryingRemoteLinksProbesAWaitingPaneBeforeItsBackoff() async throws {
        let (session, view) = try replica()
        let probe = Probe(status: 255)
        let server = server(runner: probe)
        let frozen = Date()
        server.hudClock = { frozen }
        let book = RemoteReconnectBook.shared

        server.waitToReconnect(view, cover: false)
        server.tickReconnects()
        for _ in 0..<200 where book.entries[session.paneIdentity]?.probing != false {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(probe.argvs.count, 1)
        server.tickReconnects()
        XCTAssertEqual(book.entries[session.paneIdentity]?.probing, false, "the next probe waits for its backoff")

        server.retryRemoteLinksNow()
        for _ in 0..<200 where probe.argvs.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(probe.argvs.count, 2)
    }

    private func replica() throws -> (Session, GhosttySurfaceView) {
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: "/tmp", command: "ssh mini",
                                                     wait: true, remoteHost: "mini"))
        store.bindRemote(RemoteBinding(remoteSessionID: "origin", daemonsByLocalPane: [
            session.paneIdentity: ZmxSupport.daemonName(for: UUID()),
        ], presentationVersion: 1), forSession: session.id)
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(),
                                      env: ["AGTERM_PANE_ID": session.paneIdentity.uuidString], backedByZmx: false)
        view.session = session
        session.surface = view
        pane = session.paneIdentity
        return (session, view)
    }

    func testAHostThatAnswersGetsThePaneAttachedAgainUnheld() async throws {
        let (session, view) = try replica()
        let probe = Probe(status: 0)
        let server = server(runner: probe)
        let reconnected = expectation(description: "reconnected")
        PaneLead.reconnect = { old, cover in
            XCTAssertTrue(old === view)
            XCTAssertTrue(cover)
            reconnected.fulfill()
            return true
        }
        store.remotePaneHeld(session.paneIdentity, forSession: session.id)
        XCTAssertTrue(store.remotePaneIsHeld(session.paneIdentity, forSession: session.id))

        server.waitToReconnect(view, cover: true)
        server.tickReconnects()
        await fulfillment(of: [reconnected], timeout: 2)

        XCTAssertFalse(store.remotePaneIsHeld(session.paneIdentity, forSession: session.id))
        XCTAssertFalse(RemoteReconnectBook.shared.waiting(pane: session.paneIdentity))
        XCTAssertEqual(probe.argvs, [try RemoteSession.probeCommand(host: "mini")])
    }

    func testAnUncoveredReconnectLeavesThePaneUncovered() throws {
        let (session, view) = try replica()
        let endpoint = ControlZmxEndpoint(executable: "/Applications/agterm.app/zmx", socketDirectory: "/tmp/agterm-zmx-t")
        store.bindRemote(RemoteBinding(remoteSessionID: "origin", daemonsByLocalPane: [
            session.paneIdentity: ZmxSupport.daemonName(for: UUID()),
        ], presentationVersion: 1, origin: RemoteBinding.Origin(host: "mini", endpoint: endpoint, sessionName: "build")),
                         forSession: session.id)
        defer { ZmxLeadBook.shared.forget(pane: session.paneIdentity) }
        let services = agtermApp.SurfaceServices(library: library, actions: AppActions(library: library),
                                                 zmxForegroundResolver: nil, spawnRegistry: nil,
                                                 launchContext: agtermApp.LaunchSpawnContext())

        XCTAssertTrue(agtermApp.reattachPane(view, claim: false, cover: false, services: services))

        XCTAssertFalse(ZmxLeadBook.shared.covered(pane: session.paneIdentity),
                       "an origin that never reports a role would leave it covered for good")
    }

    func testAnAttachThatDidNotStartKeepsThePaneWaitingAndHeld() async throws {
        let (session, view) = try replica()
        let server = server(probe: 0)
        let attempted = expectation(description: "attempted")
        PaneLead.reconnect = { _, _ in
            attempted.fulfill()
            return false
        }
        store.remotePaneHeld(session.paneIdentity, forSession: session.id)

        server.waitToReconnect(view, cover: false)
        server.tickReconnects()
        await fulfillment(of: [attempted], timeout: 2)

        XCTAssertTrue(RemoteReconnectBook.shared.waiting(pane: session.paneIdentity))
        XCTAssertTrue(store.remotePaneIsHeld(session.paneIdentity, forSession: session.id))
        XCTAssertEqual(RemoteReconnectBook.shared.entries[session.paneIdentity]?.failures, 1)
    }

    func testARowClosedForUndoKeepsWaitingAndAttachesOnceRestored() async throws {
        let (session, view) = try replica()
        let server = server(probe: 0)
        var attached: [GhosttySurfaceView] = []
        PaneLead.reconnect = { old, _ in
            attached.append(old)
            return true
        }
        let book = RemoteReconnectBook.shared
        XCTAssertTrue(store.softCloseSession(session.id, grace: 60))

        server.waitToReconnect(view, cover: false)
        server.tickReconnects()
        try await settleProbe(session.paneIdentity)
        XCTAssertTrue(book.waiting(pane: session.paneIdentity))
        XCTAssertTrue(attached.isEmpty)

        XCTAssertTrue(store.undoPendingClose())
        book.retryNow(pane: session.paneIdentity, now: Date())
        server.tickReconnects()
        try await settleProbe(session.paneIdentity)

        XCTAssertEqual(attached, [view])
        XCTAssertFalse(book.waiting(pane: session.paneIdentity))
    }

    private func settleProbe(_ pane: UUID) async throws {
        for _ in 0..<100 where RemoteReconnectBook.shared.entries[pane]?.probing == true {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testAFailedProbesReasonIsOnThePanesTreeNodeUntilTheWaitEnds() async throws {
        let (session, view) = try replica()
        let server = server(runner: Probe(status: 255, stderr: "Host key verification failed.\r\n"))
        PaneLead.reconnect = { _, _ in true }
        func leftNode() -> ControlSurfaceNode? {
            store.controlTree(paneForeground: { _ in nil }).workspaces.flatMap(\.sessions)
                .first { $0.id == session.id.uuidString }?.surfaces?.first { $0.kind == "left" }
        }
        XCTAssertNil(leftNode()?.reconnect)

        server.waitToReconnect(view, cover: false)
        server.tickReconnects()
        try await settleProbe(session.paneIdentity)

        XCTAssertEqual(leftNode()?.reconnect, ControlReconnect(failures: 1, reason: "Host key verification failed."))

        RemoteReconnectBook.shared.cancel(pane: session.paneIdentity)
        XCTAssertNotNil(leftNode())
        XCTAssertNil(leftNode()?.reconnect)
    }

    func testAHostThatDoesNotAnswerKeepsThePaneWaiting() async throws {
        let (session, view) = try replica()
        let server = server(probe: 255)
        PaneLead.reconnect = { _, _ in
            XCTFail("no attach before the host answers")
            return true
        }

        server.waitToReconnect(view, cover: false)
        server.tickReconnects()
        let book = RemoteReconnectBook.shared
        for _ in 0..<100 where book.entries[session.paneIdentity]?.probing == true {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(book.entries[session.paneIdentity]?.failures, 1)
        XCTAssertTrue(book.waiting(pane: session.paneIdentity))
    }

    func testAPaneThatClosedWhileWaitingIsDropped() throws {
        let (session, view) = try replica()
        let server = server(probe: 0)
        PaneLead.reconnect = { _, _ in
            XCTFail("a closed pane is never attached")
            return true
        }
        server.waitToReconnect(view, cover: false)

        session.surface = nil
        server.tickReconnects()

        XCTAssertFalse(RemoteReconnectBook.shared.waiting(pane: session.paneIdentity))
    }

    func testAPaneAlreadyClosedWhenParkedIsNeverRegistered() throws {
        let (session, view) = try replica()
        let server = server(probe: 0)
        PaneLead.reconnect = { _, _ in
            XCTFail("a pane already closed is never attached")
            return true
        }
        session.surface = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), backedByZmx: false)

        server.waitToReconnect(view, cover: false)

        XCTAssertFalse(RemoteReconnectBook.shared.waiting(pane: session.paneIdentity))
    }
}
