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

    func testAReplayLaunchesTheProgramsArgvInTheDirectoryItRunsIn() async throws {
        let (session, view) = try livePane()
        let daemon = ZmxSupport.daemonName(for: session.paneIdentity)
        let directory = try programDirectory()
        let program = try spawn("/bin/sleep", ["300"], in: directory)
        defer { program.terminate() }
        var killed: [String] = []
        let server = makeServer(daemon: daemon, foreground: program.processIdentifier) { killed.append($0) }
        var launched: PaneReattach?
        let replace = PaneLead.replace
        PaneLead.replace = { _, launch, _ in
            launched = launch
            return nil
        }
        defer { PaneLead.replace = replace }

        _ = await server.restartSessionPane(
            session.id.uuidString, window: nil,
            options: ControlSessionRestartOptions(command: nil, pane: nil, paneID: view.paneToken))

        XCTAssertEqual(killed, [daemon])
        XCTAssertEqual(launched?.workingDirectory, directory.path)
        XCTAssertNotEqual(directory.path, session.cwd(for: .left))
        XCTAssertEqual(launched?.command.contains(#"'\''/bin/sleep'\'' '\''300'\''"#), true, launched?.command ?? "no launch")
    }

    func testAShellStartedAsAJobIsReplayedLikeAnyProgram() async throws {
        let (session, view) = try livePane()
        let daemon = ZmxSupport.daemonName(for: session.paneIdentity)
        let shell = try spawn("/bin/sh", ["-c", "read line"])
        defer { shell.terminate() }
        var killed: [String] = []
        let server = makeServer(daemon: daemon, foreground: shell.processIdentifier) { killed.append($0) }

        _ = await server.restartSessionPane(
            session.id.uuidString, window: nil,
            options: ControlSessionRestartOptions(command: nil, pane: nil, paneID: view.paneToken))

        XCTAssertEqual(killed, [daemon])
    }

    func testAReplayIsRefusedBeforeAnythingIsKilledWhenThePanesRootShellRunsItsOwnLine() async throws {
        let shell = try spawn("/bin/sh", ["-c", "read line"])
        defer { shell.terminate() }

        try await assertReplayRefused(foreground: shell.processIdentifier, leader: shell.processIdentifier,
                                      RestartReplay.Refusal.shell("sh"))
    }

    func testAReplayIsRefusedBeforeAnythingIsKilledWhenTheProgramsDirectoryIsGone() async throws {
        let directory = try programDirectory()
        let program = try spawn("/bin/sleep", ["300"], in: directory)
        defer { program.terminate() }
        try FileManager.default.removeItem(at: directory)

        try await assertReplayRefused(foreground: program.processIdentifier, RestartReplay.Refusal.noDirectory)
    }

    func testAReplayIsRefusedBeforeAnythingIsKilledWhenAShellHoldsThePane() async throws {
        let shell = try spawn("/bin/sh", ["-s"])
        defer { shell.terminate() }

        try await assertReplayRefused(foreground: shell.processIdentifier, RestartReplay.Refusal.shell("sh"))
    }

    func testAReplayIsRefusedBeforeAnythingIsKilledWhenTheForegroundCannotBeRead() async throws {
        try await assertReplayRefused(foreground: nil, RestartReplay.Refusal.unreadable)
    }

    func testAReplayIsRefusedBeforeAnythingIsKilledWhenTheProgramIsDenylisted() async throws {
        let program = try spawn("/bin/sleep", ["300"])
        defer { program.terminate() }
        let denylist = GhosttyApp.shared.restoreDenylist
        GhosttyApp.shared.setRestoreDenylist(["sleep"])
        defer { GhosttyApp.shared.setRestoreDenylist(denylist) }

        try await assertReplayRefused(foreground: program.processIdentifier, RestartReplay.Refusal.denylisted("sleep"))
    }

    func testAReplayIsRefusedBeforeAnythingIsKilledWhenTheLineIsTooLong() async throws {
        let long = String(repeating: "a", count: ControlSessionRestartOptions.maxCommandBytes)
        let program = try spawn("/bin/sh", ["-c", "read line", long])
        defer { program.terminate() }

        try await assertReplayRefused(foreground: program.processIdentifier, RestartReplay.Refusal.tooLong)
    }

    private func assertReplayRefused(foreground: pid_t?, leader: pid_t = 4242, _ refusal: RestartReplay.Refusal,
                                     file: StaticString = #filePath, line: UInt = #line) async throws {
        let (session, view) = try livePane()
        var killed: [String] = []
        let server = makeServer(daemon: ZmxSupport.daemonName(for: session.paneIdentity), foreground: foreground,
                                leader: leader) { killed.append($0) }

        let response = await server.restartSessionPane(
            session.id.uuidString, window: nil,
            options: ControlSessionRestartOptions(command: nil, pane: nil, paneID: view.paneToken))

        XCTAssertEqual(response.error, refusal.message, file: file, line: line)
        XCTAssertEqual(killed, [], file: file, line: line)
        XCTAssertTrue(session.surface === view, file: file, line: line)
        XCTAssertNotNil(library.store(forSession: session.id), file: file, line: line)
    }

    private func programDirectory() throws -> URL {
        let directory = stateDir.appendingPathComponent("program-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return URL(fileURLWithPath: try XCTUnwrap(directory.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath))
    }

    private func spawn(_ path: String, _ arguments: [String], in directory: URL? = nil) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = Pipe()
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        return process
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

    private func makeServer(daemon: String, sweeper: ProcessSweeper? = nil, foreground: pid_t? = nil,
                            leader: pid_t = 4242, onKill: @escaping (String) -> Void) -> ControlServer {
        let resolver = ZmxForegroundResolver(
            leaderProvider: { _ in [daemon: leader] },
            leaderProbe: { _ in foreground.map { .foreground($0) } ?? .noForeground })
        let client = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir", sweeper: sweeper) { invocation in
            guard invocation.arguments.first == "list" else {
                onKill(invocation.arguments[1])
                return "killed session \(invocation.arguments[1])\n"
            }
            return "name=\(daemon)\tpid=\(leader)\tclients=1\tcreated=1"
        }
        return ControlServer(
            library: library, actions: AppActions(library: library), settingsModel: settingsModel,
            identity: AppIdentity(version: "9.9.9", commit: "testsha"), zmxForegroundResolver: resolver, zmxClient: client,
            socketPath: stateDir.appendingPathComponent("control-\(UUID().uuidString).sock").path)
    }
}
