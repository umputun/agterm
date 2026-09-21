import XCTest
@testable import agterm
import agtermCore

@MainActor
final class RemoteLayoutCloseTests: XCTestCase {
    private final class LiveSurface: PaneRoleMutableSurface {
        let isRealized = true
        let paneToken = "survivor"
        var teardownCount = 0
        func teardown() { teardownCount += 1 }
        func promoteToPrimaryPane() {}
        func setPaneRole(_ role: SwappablePaneRole) {}
    }
    private var directory: URL!
    private var library: WindowLibrary!
    private var store: AppStore!
    private let origin = UUID()

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-layout-\(UUID().uuidString)")
        library = WindowLibrary(directory: directory)
        store = try XCTUnwrap(library.activeStore)
    }

    override func tearDown() async throws {
        store = nil
        library = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func replica() throws -> (Session, GhosttySurfaceView) {
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: "/tmp",
                                                     command: "ssh origin", wait: true, remoteHost: "origin"))
        store.bindRemote(RemoteBinding(remoteSessionID: "origin", daemonsByLocalPane: [
            session.paneIdentity: ZmxSupport.daemonName(for: origin),
        ], presentationVersion: 1), forSession: session.id)
        let services = agtermApp.SurfaceServices(library: library, actions: AppActions(library: library),
                                                 zmxForegroundResolver: nil, spawnRegistry: nil,
                                                 launchContext: agtermApp.LaunchSpawnContext())
        let view = agtermApp.makeSurface(for: session, store: store, env: [:], services: services)
        session.surface = view
        return (session, view)
    }

    private func removeOriginPane(from session: Session) {
        let replacement = UUID()
        agtermApp.applyRemoteLayout(PresentationLayout(panes: [replacement], primary: replacement, shown: false),
                                   store: store, sessionID: session.id, library: library)
    }

    func testLastReplicaClosesWhenRemovalPrecedesItsHeldExit() throws {
        let (session, view) = try replica()
        var closed = 0
        store.onRemoteRowVisibility = { _, shown in if !shown { closed += 1 } }

        removeOriginPane(from: session)
        XCTAssertNotNil(store.session(withID: session.id))
        try XCTUnwrap(view.onExitHeld)()

        XCTAssertNil(store.session(withID: session.id))
        XCTAssertTrue(view.isDestroyed)
        XCTAssertEqual(closed, 1)
        view.handleProcessExit()
        XCTAssertEqual(closed, 1)
    }

    func testLastReplicaClosesWhenItsHeldExitPrecedesRemoval() throws {
        let (session, view) = try replica()
        try XCTUnwrap(view.onExitHeld)()
        XCTAssertNotNil(store.session(withID: session.id))

        removeOriginPane(from: session)

        XCTAssertNil(store.session(withID: session.id))
        XCTAssertTrue(view.isDestroyed)
    }

    func testOrdinaryDisconnectAndPresentationLossKeepTheReplica() throws {
        let (session, view) = try replica()
        store.setRemoteConnection(.connected, forSession: session.id)
        store.setRemoteConnection(.failed("lost"), forSession: session.id)
        XCTAssertFalse(view.isDestroyed)
        try XCTUnwrap(view.onExitHeld)()
        XCTAssertNotNil(store.session(withID: session.id))
        XCTAssertFalse(view.isDestroyed)
        XCTAssertTrue(session.commandWait)
    }

    func testPrimaryRemovalDoesNotDiscardAPendingLocalSplit() throws {
        let (session, view) = try replica()
        store.toggleSplit(session.id)
        let local = session.splitPaneIdentity
        removeOriginPane(from: session)
        XCTAssertNotNil(store.session(withID: session.id))
        session.splitSurface = GhosttySurfaceView(workingDirectory: "/tmp")
        removeOriginPane(from: session)
        try XCTUnwrap(view.onExitHeld)()

        XCTAssertNotNil(store.session(withID: session.id))
        XCTAssertEqual(session.splitPaneIdentity, local)
        XCTAssertFalse(view.isDestroyed)
    }

    func testPrimaryRemovalPromotesALocalSurvivorWithoutClosingTheRow() throws {
        let (session, view) = try replica()
        store.toggleSplit(session.id)
        let local = try XCTUnwrap(session.splitPaneIdentity)
        let survivor = LiveSurface()
        session.splitSurface = survivor
        var closed = false
        store.onRemoteRowVisibility = { _, shown in closed = !shown }

        removeOriginPane(from: session)

        XCTAssertTrue(store.session(withID: session.id) === session)
        XCTAssertEqual(session.paneIdentity, local)
        XCTAssertTrue(session.surface === survivor)
        XCTAssertEqual(survivor.teardownCount, 0)
        XCTAssertTrue(view.isDestroyed)
        XCTAssertFalse(closed)
    }

    func testSplitRemovalKeepsALocalPrimaryWithoutWaitingForExit() throws {
        let (session, view) = try replica()
        store.toggleSplit(session.id)
        let survivor = LiveSurface()
        session.splitSurface = survivor
        XCTAssertNil(store.swapPanes(session.id))
        XCTAssertTrue(view.isSplitPane)

        removeOriginPane(from: session)

        XCTAssertTrue(session.surface === survivor)
        XCTAssertFalse(session.hasSplit)
        XCTAssertTrue(view.isDestroyed)
        XCTAssertEqual(survivor.teardownCount, 0)
        XCTAssertNotNil(store.session(withID: session.id))
    }

    func testAQueuedHeldCallbackCannotCloseALocalReplacement() throws {
        let (session, view) = try replica()
        let callback = try XCTUnwrap(view.onExitHeld)
        store.toggleSplit(session.id)
        let local = try XCTUnwrap(session.splitPaneIdentity)
        let survivor = LiveSurface()
        session.splitSurface = survivor
        removeOriginPane(from: session)

        callback()
        view.handleProcessExit()

        XCTAssertTrue(session.surface === survivor)
        XCTAssertEqual(session.paneIdentity, local)
        XCTAssertEqual(survivor.teardownCount, 0)
        XCTAssertNotNil(store.session(withID: session.id))
    }
}
