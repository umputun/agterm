import XCTest
@testable import agterm
import agtermCore

private final class LeaderStub: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: pid_t?

    var pid: pid_t? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

@MainActor
private final class RealizedReplacement {
    private let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                                  backing: .buffered, defer: false)
    private let replace = PaneLead.replace
    private var made: [GhosttySurfaceView] = []

    init() {
        window.isReleasedWhenClosed = false
        PaneLead.replace = { [weak self] old, _, _ in
            guard let self else { return nil }
            let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), command: "cat", env: old.env, backedByZmx: true)
            view.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
            window.contentView?.addSubview(view)
            view.createSurface()
            view.session = old.session
            if old.session?.surface === old { old.session?.surface = view }
            made.append(view)
            return view
        }
    }

    func restore() {
        PaneLead.replace = replace
        made.forEach { $0.destroySurface() }
        window.orderOut(nil)
    }
}

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
        let zshReplay = #"'\''/bin/sleep'\'' '\''300'\''"#
        let fishReplay = #"\'\''/bin/sleep\'\'' \'\''300\'\''"#
        let command = launched?.command ?? "no launch"
        XCTAssertTrue(command.contains(zshReplay) || command.contains(fishReplay), command)
    }

    func testARestartCommandStillReturnsToTheLoginShell() async throws {
        let (session, view) = try livePane()
        let daemon = ZmxSupport.daemonName(for: session.paneIdentity)
        let program = try spawn("/bin/sleep", ["300"])
        defer { program.terminate() }
        let server = makeServer(daemon: daemon, foreground: program.processIdentifier) { _ in }
        var launched: PaneReattach?
        let replace = PaneLead.replace
        PaneLead.replace = { _, launch, _ in
            launched = launch
            return nil
        }
        defer { PaneLead.replace = replace }

        _ = await server.restartSessionPane(
            session.id.uuidString, window: nil,
            options: ControlSessionRestartOptions(command: "echo restarted", pane: nil, paneID: view.paneToken))

        let command = launched?.command ?? "no launch"
        XCTAssertTrue(command.contains("echo restarted"), command)
        XCTAssertTrue(command.contains(" -il"), "a restart command must hand the pane back to a login shell: \(command)")
    }

    func testARestartDropsTheOldProgramsMailBeforeTheNewOneStarts() async throws {
        let (session, view) = try livePane()
        let daemon = ZmxSupport.daemonName(for: session.paneIdentity)
        let program = try spawn("/bin/sleep", ["300"])
        defer { program.terminate() }
        let server = makeServer(daemon: daemon, foreground: program.processIdentifier) { _ in }
        _ = try MessageBus.shared.send("for the old program", from: nil,
                                       to: [MessageRecipient(pane: session.paneIdentity, address: "old")], now: 1)
        defer { MessageBus.shared.dispose(pane: session.paneIdentity) }
        var pendingAtLaunch: Int?
        let replace = PaneLead.replace
        PaneLead.replace = { _, _, _ in
            pendingAtLaunch = MessageBus.shared.pending(for: session.paneIdentity)
            return nil
        }
        defer { PaneLead.replace = replace }

        _ = await server.restartSessionPane(
            session.id.uuidString, window: nil,
            options: ControlSessionRestartOptions(command: "echo restarted", pane: nil, paneID: view.paneToken))

        XCTAssertEqual(pendingAtLaunch, 0)
    }

    func testMailSentWhileTheOldProgramEndsDoesNotReachTheNewOne() async throws {
        let (session, view) = try livePane()
        defer { MessageBus.shared.dispose(pane: session.paneIdentity) }
        let recipient = MessageRecipient(pane: session.paneIdentity, address: "old")
        let shell = ProcessRecord(pid: 4242, started: 1, group: 4242, foreground: 4300)
        let program = ProcessRecord(pid: 4300, started: 2, group: 4300, foreground: 4300)
        var hungUp = false, sentDuringWait = false
        var sweeper = ProcessSweeper()
        sweeper.signal = { signal, _ in if signal == SIGHUP { hungUp = true } }
        sweeper.table = {
            guard hungUp else { return [shell, program] }
            if !sentDuringWait {
                sentDuringWait = (try? MessageBus.shared.send("sent while the old program ends", from: nil,
                                                              to: [recipient], now: 1)) != nil
            }
            return [shell]
        }
        let server = makeServer(daemon: ZmxSupport.daemonName(for: session.paneIdentity), sweeper: sweeper) { _ in }
        var pendingAtLaunch: Int?
        let replace = PaneLead.replace
        PaneLead.replace = { _, _, _ in
            pendingAtLaunch = MessageBus.shared.pending(for: session.paneIdentity)
            return nil
        }
        defer { PaneLead.replace = replace }

        _ = await server.restartSessionPane(
            session.id.uuidString, window: nil,
            options: ControlSessionRestartOptions(command: "echo restarted", pane: nil, paneID: view.paneToken))

        XCTAssertTrue(sentDuringWait)
        XCTAssertEqual(pendingAtLaunch, 0)
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

    func testARestartThatStartsANewShellPublishesTheRespawnForItsDaemon() async throws {
        let (session, view) = try livePane()
        let daemon = ZmxSupport.daemonName(for: session.paneIdentity)
        var killed = false
        let client = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir") { invocation in
            guard invocation.arguments.first == "list" else {
                killed = true
                return "killed session \(invocation.arguments[1])\n"
            }
            return "name=\(daemon)\tpid=\(killed ? 4343 : 4242)\tclients=1\tcreated=1"
        }
        let server = makeServer(client: client, leader: 4242, daemon: daemon)
        server.restartLeader = { _ in 4343 }
        let replacement = RealizedReplacement()
        defer { replacement.restore() }

        let response = await server.restartSessionPane(
            session.id.uuidString, window: nil,
            options: ControlSessionRestartOptions(command: "echo restarted", pane: nil, paneID: view.paneToken))

        XCTAssertNil(response.error)
        XCTAssertEqual(response.result?.restart?.newPid, 4343)
        XCTAssertEqual(server.respawnGenerations[session.id]?[daemon], 1)
        XCTAssertNil(server.restartHolds[session.paneIdentity])
    }

    func testAShellConfirmedAfterTheReplyDeadlineIsStillPublishedAndListedRunning() async throws {
        let (session, view) = try livePane()
        let daemon = ZmxSupport.daemonName(for: session.paneIdentity)
        let server = makeServer(daemon: daemon) { _ in }
        let leader = LeaderStub()
        server.restartLeader = { _ in leader.pid }
        server.restartWaits.shell = .milliseconds(50)
        server.originEvidence = CatalogPaneEvidence()
        let replacement = RealizedReplacement()
        defer { replacement.restore() }

        let response = await server.restartSessionPane(
            session.id.uuidString, window: nil,
            options: ControlSessionRestartOptions(command: "echo restarted", pane: nil, paneID: view.paneToken))

        XCTAssertEqual(response.error, "the old shell ended (pid 4242) and the replacement was requested but could not be verified in time")
        XCTAssertNil(server.respawnGenerations[session.id]?[daemon])
        XCTAssertEqual(server.restartHolds[session.paneIdentity], 1, "the pane stays listed running while its shell is awaited")
        leader.pid = 4343
        try await waitUntil { server.respawnGenerations[session.id]?[daemon] == 1 }
        XCTAssertNil(server.restartHolds[session.paneIdentity])
        XCTAssertEqual(server.originEvidence?.running, [session.paneIdentity])
    }

    func testAShellSeenOnlyAfterTheFollowWindowIsNeverPublished() async throws {
        let (session, view) = try livePane()
        let daemon = ZmxSupport.daemonName(for: session.paneIdentity)
        let server = makeServer(daemon: daemon) { _ in }
        server.restartLeader = { _ in
            Thread.sleep(forTimeInterval: 0.3)
            return 4343
        }
        server.restartWaits.shell = .milliseconds(50)
        server.restartWaits.follow = .milliseconds(100)
        let replacement = RealizedReplacement()
        defer { replacement.restore() }

        let response = await server.restartSessionPane(
            session.id.uuidString, window: nil,
            options: ControlSessionRestartOptions(command: "echo restarted", pane: nil, paneID: view.paneToken))

        XCTAssertEqual(response.ok, false)
        try await waitUntil { server.restartHolds[session.paneIdentity] == nil }
        XCTAssertNil(server.respawnGenerations[session.id]?[daemon])
    }

    func testALaterRestartWhoseKillFailsLeavesTheFirstRestartItsHold() async throws {
        let (session, view) = try livePane()
        let daemon = ZmxSupport.daemonName(for: session.paneIdentity)
        var kills = 0
        let client = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir") { invocation in
            guard invocation.arguments.first == "list" else {
                kills += 1
                return kills == 1 ? "killed session \(invocation.arguments[1])\n" : "error: SessionUnresponsive\n"
            }
            return "name=\(daemon)\tpid=4242\tclients=1\tcreated=1"
        }
        let server = makeServer(client: client, leader: 4242, daemon: daemon)
        let leader = LeaderStub()
        server.restartLeader = { _ in leader.pid }
        server.restartWaits.shell = .milliseconds(50)
        let replacement = RealizedReplacement()
        defer { replacement.restore() }
        _ = await server.restartSessionPane(
            session.id.uuidString, window: nil,
            options: ControlSessionRestartOptions(command: "echo first", pane: nil, paneID: view.paneToken))
        let pane = try XCTUnwrap(session.surface as? GhosttySurfaceView)

        let refused = await server.restartSessionPane(
            session.id.uuidString, window: nil,
            options: ControlSessionRestartOptions(command: "echo second", pane: nil, paneID: pane.paneToken))

        XCTAssertEqual(refused.ok, false)
        XCTAssertEqual(server.restartHolds[session.paneIdentity], 1, "the refused restart releases only its own hold")
        leader.pid = 4343
        try await waitUntil { server.respawnGenerations[session.id]?[daemon] == 1 }
        XCTAssertNil(server.restartHolds[session.paneIdentity])
    }

    func testARestartUnderUndoCloseIsPublishedWhileTheSessionIsParked() async throws {
        let (session, view) = try livePane()
        let daemon = ZmxSupport.daemonName(for: session.paneIdentity)
        let server = makeServer(daemon: daemon) { _ in }
        let leader = LeaderStub()
        server.restartLeader = { _ in leader.pid }
        server.restartWaits.shell = .milliseconds(50)
        let replacement = RealizedReplacement()
        defer { replacement.restore() }
        _ = await server.restartSessionPane(
            session.id.uuidString, window: nil,
            options: ControlSessionRestartOptions(command: "echo restarted", pane: nil, paneID: view.paneToken))
        let store = try XCTUnwrap(library.store(forSession: session.id))
        XCTAssertTrue(store.softCloseSession(session.id))

        leader.pid = 4343

        try await waitUntil { server.respawnGenerations[session.id]?[daemon] == 1 }
        XCTAssertTrue(store.pendingCloseSession(withID: session.id) === session)
        XCTAssertNil(server.restartHolds[session.paneIdentity])
    }

    func testAParentRespawnDuringTheFollowPublishesNothingForTheRestart() async throws {
        let (session, view) = try livePane()
        let store = try XCTUnwrap(library.store(forSession: session.id))
        guard case .success = store.addCompanion(to: session.id) else { return XCTFail("no companion") }
        let daemon = ZmxSupport.daemonName(for: session.paneIdentity)
        let server = makeServer(daemon: daemon) { _ in }
        let leader = LeaderStub()
        server.restartLeader = { _ in leader.pid }
        server.restartWaits.shell = .milliseconds(50)
        let replacement = RealizedReplacement()
        defer { replacement.restore() }
        _ = await server.restartSessionPane(
            session.id.uuidString, window: nil,
            options: ControlSessionRestartOptions(command: "echo restarted", pane: nil, paneID: view.paneToken))

        XCTAssertEqual(store.closePrimaryPane(session.id), .respawned)
        leader.pid = 4343

        try await waitUntil { server.restartHolds[session.paneIdentity] == nil }
        XCTAssertNil(server.respawnGenerations[session.id]?[daemon])
    }

    func testAnInventoryReadBegunBeforeAConfirmationStillListsThePaneRunning() async throws {
        let (session, _) = try livePane()
        let started = stateDir.appendingPathComponent("list-started").path
        let release = stateDir.appendingPathComponent("list-release").path
        let zmx = stateDir.appendingPathComponent("zmx-list").path
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try "#!/bin/sh\ntouch '\(started)'\nwhile [ ! -e '\(release)' ]; do sleep 0.02; done\n"
            .write(toFile: zmx, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: zmx)
        let client = ZmxClient(executablePath: zmx, socketDirectory: "/tmp/zmx-dir") { _ in "" }
        let server = makeServer(client: client, leader: 4242, daemon: ZmxSupport.daemonName(for: session.paneIdentity))
        let read = Task { await server.readOriginEvidence(always: true) }
        try await waitUntil { FileManager.default.fileExists(atPath: started) }

        server.originPaneConfirmed(session.paneIdentity)
        FileManager.default.createFile(atPath: release, contents: nil)

        let finished = await read.value
        XCTAssertTrue(finished)
        XCTAssertEqual(server.originEvidence?.running, [session.paneIdentity])
    }

    func testARestartWhosePaneClosesBeforeItsShellIsSeenPublishesNothing() async throws {
        let (session, view) = try livePane()
        let daemon = ZmxSupport.daemonName(for: session.paneIdentity)
        let server = makeServer(daemon: daemon) { _ in }
        server.restartLeader = { _ in nil }
        server.restartWaits.shell = .milliseconds(50)
        let replacement = RealizedReplacement()
        defer { replacement.restore() }
        _ = await server.restartSessionPane(
            session.id.uuidString, window: nil,
            options: ControlSessionRestartOptions(command: "echo restarted", pane: nil, paneID: view.paneToken))

        try XCTUnwrap(library.store(forSession: session.id)).closeSession(session.id)

        try await waitUntil { server.restartHolds[session.paneIdentity] == nil }
        XCTAssertNil(server.respawnGenerations[session.id]?[daemon])
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), file: file, line: line)
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
        // /bin/sh re-execs the selected shell after run returns, and an argv read across that exec is unreadable
        if path == "/bin/sh" {
            let deadline = Date().addingTimeInterval(5)
            var image = ForegroundProcess.executablePath(of: process.processIdentifier)
            while image == nil || image == path, Date() < deadline {
                usleep(1000)
                image = ForegroundProcess.executablePath(of: process.processIdentifier)
            }
            XCTAssertNotNil(image, "sh image never became readable")
            XCTAssertNotEqual(image, path, "sh never re-executed")
        }
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
        let client = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir", sweeper: sweeper) { invocation in
            guard invocation.arguments.first == "list" else {
                onKill(invocation.arguments[1])
                return "killed session \(invocation.arguments[1])\n"
            }
            return "name=\(daemon)\tpid=\(leader)\tclients=1\tcreated=1"
        }
        return makeServer(client: client, leader: leader, daemon: daemon, foreground: foreground)
    }

    private func makeServer(client: ZmxClient, leader: pid_t, daemon: String, foreground: pid_t? = nil) -> ControlServer {
        let resolver = ZmxForegroundResolver(
            leaderProvider: { [daemon: leader] },
            leaderProbe: { _ in foreground.map { .foreground($0) } ?? .noForeground })
        return ControlServer(
            library: library, actions: AppActions(library: library), settingsModel: settingsModel,
            identity: AppIdentity(version: "9.9.9", commit: "testsha"), zmxForegroundResolver: resolver, zmxClient: client,
            socketPath: stateDir.appendingPathComponent("control-\(UUID().uuidString).sock").path)
    }
}
