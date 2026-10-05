import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerRestartTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var settingsModel: SettingsModel!

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-restart-tests-\(UUID().uuidString)", isDirectory: true)
        library = WindowLibrary(directory: stateDir)
        settingsModel = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
    }

    override func tearDown() async throws {
        settingsModel = nil
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    func testARestartThatCannotRebuildThePaneClosesItInsteadOfLeavingItWithoutAShell() async throws {
        let (session, view) = try livePane()
        let daemon = ZmxSupport.daemonName(for: session.paneIdentity)
        var killed: [String] = []
        let server = makeServer(daemon: daemon) { killed.append($0) }

        let response = await server.restartSessionPane(
            session.id.uuidString, window: nil,
            options: ControlSessionRestartOptions(command: "cld", pane: nil, paneID: view.paneToken))

        XCTAssertEqual(response.error, "the old shell ended (pid 4242) and the pane could not be rebuilt; it was closed")
        XCTAssertEqual(killed, [daemon], "the identity the restart killed must not be finalized again")
        XCTAssertNil(library.store(forSession: session.id), "a pane left without a shell closes like any other")
    }

    func testARestartWhoseOldProgramOutlivesTheKillClosesThePaneAndStartsNothing() async throws {
        let (session, view) = try livePane()
        let daemon = ZmxSupport.daemonName(for: session.paneIdentity)
        var sweeper = ProcessSweeper()
        sweeper.table = {
            [ProcessRecord(pid: 4242, started: 1, group: 4242, foreground: 4300),
             ProcessRecord(pid: 4300, started: 2, group: 4300, foreground: 4300)]
        }
        var signals: [Int32] = []
        sweeper.signal = { signal, _ in signals.append(signal) }
        let server = makeServer(daemon: daemon, sweeper: sweeper) { _ in }

        let response = await server.restartSessionPane(
            session.id.uuidString, window: nil,
            options: ControlSessionRestartOptions(command: "cld", pane: nil, paneID: view.paneToken))

        XCTAssertEqual(response.error, "the old shell ended (pid 4242) but its program is still running; "
            + "nothing was started and the pane was closed")
        XCTAssertEqual(signals, [SIGHUP, SIGKILL])
        XCTAssertNil(library.store(forSession: session.id))
    }

    func testASessionSoftClosedDuringTheRestartIsNotLeftForUndoToRestore() async throws {
        let (session, view) = try livePane()
        let store = try XCTUnwrap(library.store(forSession: session.id))
        let workspace = try XCTUnwrap(store.workspaces.first)
        let other = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        XCTAssertTrue(store.softCloseSession(other.id, grace: 60))
        var sweeper = ProcessSweeper()
        sweeper.table = {
            [ProcessRecord(pid: 4242, started: 1, group: 4242, foreground: 4300),
             ProcessRecord(pid: 4300, started: 2, group: 4300, foreground: 4300)]
        }
        var closed = false
        sweeper.signal = { _, _ in
            guard !closed else { return }
            closed = true
            XCTAssertTrue(store.softCloseSession(session.id))
        }
        let server = makeServer(daemon: ZmxSupport.daemonName(for: session.paneIdentity), sweeper: sweeper) { _ in }

        let response = await server.restartSessionPane(
            session.id.uuidString, window: nil,
            options: ControlSessionRestartOptions(command: "cld", pane: nil, paneID: view.paneToken))

        XCTAssertEqual(response.ok, false)
        XCTAssertNil(store.pendingCloseSession(withID: session.id), "undo must not be able to restore the dead pane")
        XCTAssertNotNil(store.pendingCloseSession(withID: other.id), "an unrelated pending close keeps its undo")
        XCTAssertTrue(store.undoPendingClose())
        XCTAssertNotNil(store.session(withID: other.id))
    }

    func testAnUnreadableProcessTableRefusesTheRestartBeforeAnythingIsKilled() async throws {
        let (session, view) = try livePane()
        var sweeper = ProcessSweeper()
        sweeper.table = { nil }
        var killed: [String] = []
        let server = makeServer(daemon: ZmxSupport.daemonName(for: session.paneIdentity), sweeper: sweeper) { killed.append($0) }

        let response = await server.restartSessionPane(
            session.id.uuidString, window: nil,
            options: ControlSessionRestartOptions(command: "cld", pane: nil, paneID: view.paneToken))

        XCTAssertEqual(response.error, "the process table cannot be read, so the old program could not be tracked; "
            + "nothing was changed")
        XCTAssertEqual(killed, [])
        XCTAssertNotNil(library.store(forSession: session.id))
    }

    func testAnUnknownPaneIDIsRefusedBeforeAnythingIsKilled() async throws {
        let (session, _) = try livePane()
        var killed: [String] = []
        let server = makeServer(daemon: ZmxSupport.daemonName(for: session.paneIdentity)) { killed.append($0) }
        let unknown = UUID().uuidString

        let response = await server.restartSessionPane(
            session.id.uuidString, window: nil,
            options: ControlSessionRestartOptions(command: "cld", pane: .left, paneID: unknown))

        XCTAssertEqual(response.error, "unknown pane id: \(unknown)")
        XCTAssertEqual(killed, [])
        XCTAssertNotNil(library.store(forSession: session.id))
    }

    func testAPaneWithoutALiveDaemonIsRefused() async throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.workspaces.first?.sessions.first)
        session.surface = GhosttySurfaceView(workingDirectory: "/tmp",
                                             env: ["AGTERM_PANE_ID": session.paneIdentity.uuidString])
        let server = makeServer(daemon: "unused") { _ in }

        let response = await server.restartSessionPane(
            session.id.uuidString, window: nil,
            options: ControlSessionRestartOptions(command: "cld", pane: .left))

        XCTAssertEqual(response.error, "session.restart needs Live sessions mode; this pane has no live shell to replace")
    }

    private func livePane() throws -> (Session, GhosttySurfaceView) {
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.workspaces.first?.sessions.first)
        let view = GhosttySurfaceView(workingDirectory: "/tmp", env: ["AGTERM_PANE_ID": session.paneIdentity.uuidString],
                                      backedByZmx: true)
        view.session = session
        session.surface = view
        return (session, view)
    }

    private func makeServer(daemon: String, sweeper: ProcessSweeper? = nil,
                            onKill: @escaping (String) -> Void) -> ControlServer {
        let client = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir", sweeper: sweeper) { invocation in
            guard invocation.arguments.first == "list" else {
                onKill(invocation.arguments[1])
                return "killed session \(invocation.arguments[1])\n"
            }
            return "name=\(daemon)\tpid=4242\tclients=1\tcreated=1"
        }
        return ControlServer(
            library: library, actions: AppActions(library: library), settingsModel: settingsModel,
            identity: AppIdentity(version: "9.9.9", commit: "testsha"), zmxClient: client,
            socketPath: stateDir.appendingPathComponent("control-\(UUID().uuidString).sock").path)
    }
}
