import Darwin
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerRespawnTests: XCTestCase {
    private final class Viewer: PresentationSink {
        var frames: [PresentationFrame] = []
        func offer(_ frame: PresentationFrame) -> Bool {
            frames.append(frame)
            return true
        }
        func close(_: PresentationHub.CloseReason) {}
        var respawns: [PresentationRespawns] { frames.compactMap { if case .respawn(let value) = $0.body { value } else { nil } } }
    }

    private var stateDir: URL!
    private var library: WindowLibrary!
    private var settings: SettingsModel!
    private var savedReconnect: ((GhosttySurfaceView, Bool) -> Bool)?
    private var reconnects: [GhosttySurfaceView] = []

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-respawn-\(UUID().uuidString)")
        library = WindowLibrary(directory: stateDir)
        settings = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
        savedReconnect = PaneLead.reconnect
        PaneLead.reconnect = { [weak self] old, _ in
            self?.reconnects.append(old)
            if let session = old.session { RemoteRespawnBook.shared.attachStarted(pane: session.paneIdentity, session: session.id) }
            return true
        }
    }

    override func tearDown() async throws {
        PaneLead.reconnect = savedReconnect
        settings = nil
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    func testTheOriginPublishesARespawnOnceADifferentLiveLeaderRunsUnderTheName() async throws {
        let daemon = ZmxSupport.daemonName(for: UUID())
        let server = makeServer(listing: "name=\(daemon)\tpid=\(getpid())\tclients=0\tcreated=1")
        let session = try XCTUnwrap(library.activeStore?.activeSession)
        let viewer = Viewer()
        try server.presentationHub.subscribe(session: session.id, hello: PresentationHello(version: PresentationCodec.version, kinds: [], mode: .mirror),
                                             sink: viewer) { PresentationSnapshot(status: nil, hud: nil) }

        server.ownerRespawned(session: session.id, daemon: daemon, prior: 1)
        let deadline = Date().addingTimeInterval(5)
        while viewer.respawns.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }

        XCTAssertEqual(viewer.respawns, [PresentationRespawns(epoch: server.originEpoch, generations: [daemon: 1])])
        XCTAssertEqual(server.respawnGenerations[session.id], [daemon: 1])
    }

    func testAHeldViewerPaneReattachesOnlyAfterTheOriginRespawnedIt() throws {
        let server = makeServer(listing: "")
        let (row, view, daemon) = try remoteRow()

        server.applyRemoteRespawns(PresentationRespawns(epoch: "e1", generations: [:]), seed: true, forSession: row.id)
        server.remotePaneHeld(view)
        XCTAssertTrue(reconnects.isEmpty, "a clean exit with no respawn keeps the exit prompt")

        server.applyRemoteRespawns(PresentationRespawns(epoch: "e1", generations: [daemon: 1]), seed: false, forSession: row.id)
        XCTAssertEqual(reconnects.map(ObjectIdentifier.init), [ObjectIdentifier(view)])
    }

    func testARespawnKnownBeforeTheHeldExitReattachesAtTheExit() throws {
        let server = makeServer(listing: "")
        let (row, view, daemon) = try remoteRow()

        server.applyRemoteRespawns(PresentationRespawns(epoch: "e1", generations: [daemon: 2]), seed: true, forSession: row.id)
        server.applyRemoteRespawns(PresentationRespawns(epoch: "e1", generations: [daemon: 3]), seed: false, forSession: row.id)
        XCTAssertTrue(reconnects.isEmpty, "a live pane is not reattached")
        server.remotePaneHeld(view)

        XCTAssertEqual(reconnects.count, 1)
    }

    func testALocalWaitExitIsNotEnteredAndAClosedRowsEntryIsPruned() throws {
        let server = makeServer(listing: "")
        let store = try XCTUnwrap(library.activeStore)
        let local = try XCTUnwrap(store.activeSession)
        let localView = GhosttySurfaceView(workingDirectory: "/tmp", backedByZmx: false)
        localView.session = local
        local.surface = localView
        server.remotePaneHeld(localView)
        XCTAssertNil(RemoteRespawnBook.shared.entries[local.paneIdentity], "a local pane never enters the book")

        let (row, _, _) = try remoteRow()
        server.applyRemoteRespawns(PresentationRespawns(epoch: "e1", generations: [:]), seed: true, forSession: row.id)
        XCTAssertNotNil(RemoteRespawnBook.shared.entries[row.paneIdentity])
        store.closeSession(row.id)
        server.pruneRespawnBook()
        XCTAssertNil(RemoteRespawnBook.shared.entries[row.paneIdentity])
    }

    // a prune on the hidden-row callback ran before the soft close registered its pending record, so undo lost the held exit
    func testASoftClosedRowKeepsItsHeldExitThroughUndoAndIsPrunedOnceFinal() throws {
        let server = makeServer(listing: "")
        server.attachPresentationHub()
        let store = try XCTUnwrap(library.activeStore)
        let (row, view, daemon) = try remoteRow()
        server.applyRemoteRespawns(PresentationRespawns(epoch: "e1", generations: [:]), seed: true, forSession: row.id)
        server.remotePaneHeld(view)

        XCTAssertTrue(store.softCloseSession(row.id))
        server.pruneRespawnBook()
        XCTAssertEqual(RemoteRespawnBook.shared.entries[row.paneIdentity]?.held, true, "a soft-closed row keeps its state")
        XCTAssertTrue(store.undoPendingClose())
        server.applyRemoteRespawns(PresentationRespawns(epoch: "e1", generations: [daemon: 1]), seed: true, forSession: row.id)
        XCTAssertEqual(reconnects.count, 1, "the respawn delivered after undo still reattaches the held pane")

        XCTAssertTrue(store.softCloseSession(row.id))
        XCTAssertTrue(store.finalizePendingClose(ofSession: row.id))
        server.startRemoteTick()
        let deadline = Date().addingTimeInterval(5)
        while RemoteRespawnBook.shared.entries[row.paneIdentity] != nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertNil(RemoteRespawnBook.shared.entries[row.paneIdentity], "the tick prunes the last row's entry once it is final")
    }

    private func makeServer(listing: String) -> ControlServer {
        ControlServer(library: library, actions: AppActions(library: library), settingsModel: settings,
                      identity: AppIdentity(version: "9.9.9", commit: "testsha"),
                      zmxClient: ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir", runner: { _ in listing }),
                      socketPath: stateDir.appendingPathComponent("control-\(UUID().uuidString).sock").path)
    }

    private func remoteRow() throws -> (Session, GhosttySurfaceView, String) {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let row = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory(), remoteHost: "buildbox"))
        let daemon = ZmxSupport.daemonName(for: UUID())
        store.bindRemote(RemoteBinding(remoteSessionID: "origin-1", daemonsByLocalPane: [row.paneIdentity: daemon],
                                       presentationVersion: PresentationCodec.version), forSession: row.id)
        let view = GhosttySurfaceView(workingDirectory: "/tmp", backedByZmx: false)
        view.session = row
        row.surface = view
        return (row, view, daemon)
    }
}
