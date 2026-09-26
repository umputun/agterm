import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerRemoteReconnectTests: XCTestCase {
    private struct Probe: RemoteCommandRunner {
        let status: Int32
        func run(_ argv: [String], deadline: TimeInterval) async -> RemoteCommandResult {
            RemoteCommandResult(status: status, stdout: "", stderr: "")
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
        ControlServer(library: library, actions: AppActions(library: library),
                      settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: directory)),
                      identity: AppIdentity(version: "test", commit: "test"), remoteRunner: Probe(status: status),
                      socketPath: directory.appendingPathComponent("control.sock").path)
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
        let server = server(probe: 0)
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
