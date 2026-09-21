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

    private func replica(withPaneToken: Bool = false) throws -> (Session, GhosttySurfaceView) {
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: "/tmp",
                                                     command: "ssh origin", wait: true, remoteHost: "origin"))
        store.bindRemote(RemoteBinding(remoteSessionID: "origin", daemonsByLocalPane: [
            session.paneIdentity: ZmxSupport.daemonName(for: origin),
        ], presentationVersion: 1), forSession: session.id)
        let services = agtermApp.SurfaceServices(library: library, actions: AppActions(library: library),
                                                 zmxForegroundResolver: nil, spawnRegistry: nil,
                                                 launchContext: agtermApp.LaunchSpawnContext())
        let env = withPaneToken ? ["AGTERM_PANE_ID": session.paneIdentity.uuidString] : [:]
        let view = agtermApp.makeSurface(for: session, store: store, env: env, services: services)
        session.surface = view
        return (session, view)
    }

    private func removeOriginPane(from session: Session) {
        let replacement = UUID()
        agtermApp.applyRemoteLayout(PresentationLayout(panes: [replacement], primary: replacement, shown: false),
                                   store: store, sessionID: session.id, library: library)
    }

    func testHeldReplicaForgetsItsLeadAndClosesOnlyAfterConfirmedRemoval() async throws {
        for removed in [false, true] {
            let setupChanged = expectation(description: "fixture tree change delivered")
            library.onControlEvent = { event in
                if event.kind == .treeChanged { setupChanged.fulfill() }
            }
            let (session, view) = try replica(withPaneToken: true)
            let identity = session.paneIdentity
            let book = ZmxLeadBook.shared
            defer {
                book.forget(pane: identity)
                view.teardown()
                library.onControlEvent = nil
            }
            await fulfillment(of: [setupChanged], timeout: 2)
            XCTAssertEqual(UUID(uuidString: view.paneToken), identity)
            book.begin(ZmxLeadAttachment(nonce: "held-exit", claim: true), pane: identity)
            let notice = try XCTUnwrap(ZmxLeadNotice(title: "zmx-role;held-exit:follower:1"))
            XCTAssertEqual(book.apply(notice, pane: identity), .follower)
            XCTAssertTrue(view.leadCovered)
            if removed {
                removeOriginPane(from: session)
            } else {
                agtermApp.applyRemoteLayout(PresentationLayout(panes: [origin], primary: origin, shown: false),
                                           store: store, sessionID: session.id, library: library)
            }
            XCTAssertTrue(store.session(withID: session.id) === session)
            let leadChanged = expectation(description: "held exit reports its lead change")
            library.onControlEvent = { event in
                if event.kind == .treeChanged { leadChanged.fulfill() }
            }

            try XCTUnwrap(view.onExitHeld)()

            XCTAssertNil(book.role(pane: identity))
            XCTAssertFalse(view.leadCovered)
            if removed {
                XCTAssertNil(store.session(withID: session.id))
                XCTAssertTrue(view.isDestroyed)
            } else {
                XCTAssertTrue(session.surface === view)
                XCTAssertTrue(store.session(withID: session.id) === session)
                XCTAssertFalse(view.isDestroyed)
                XCTAssertTrue(store.remotePaneIsHeld(identity, forSession: session.id))
                XCTAssertTrue(session.commandWait)
            }
            await fulfillment(of: [leadChanged], timeout: 2)
        }
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
