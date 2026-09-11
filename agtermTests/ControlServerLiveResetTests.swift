import AppKit
import Darwin
import XCTest
@testable import agterm
import agtermCore
import AgtermResponsibility

@MainActor
final class ControlServerLiveResetTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var settingsModel: SettingsModel!
    private var socketPath: String!
    private var server: ControlServer?

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-live-reset-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            settingsModel = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
            socketPath = "/tmp/agterm-lr-\(UUID().uuidString.prefix(8)).sock"
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            server?.stop()
            server = nil
            unlink(socketPath)
            unlink(socketPath + ".lock")
            settingsModel = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
        }
        try await super.tearDown()
    }

    private static let orphanProbe = LiveAttributionProbe(responsible: { .live($0) }, hostPID: { _ in nil }, appPID: 300)

    private func makeCoordinator(active: RestoreMode = .live, configured: RestoreMode = .live) -> LiveResetCoordinator {
        XCTAssertTrue(settingsModel.setRestoreMode(configured))
        return LiveResetCoordinator(settingsModel: settingsModel, selection: { nil }, activeMode: { active }, terminate: {})
    }

    private func makeServer(liveReset: LiveResetCoordinator, runner: @escaping ZmxClient.Runner,
                            probe: LiveAttributionProbe = orphanProbe,
                            remoteRunner: (any RemoteCommandRunner)? = nil,
                            responseWriter: @escaping ControlServer.ResponseWriter = ControlServer.writeResponse) -> ControlServer {
        let client = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir", runner: runner)
        let resolver = ZmxForegroundResolver(leaderProvider: { _ in [:] }, leaderProbe: { .foreground($0) })
        let server = ControlServer(library: library, actions: AppActions(library: library), settingsModel: settingsModel,
                                   identity: AppIdentity(version: "test", commit: "test"), zmxForegroundResolver: resolver,
                                   zmxClient: client, liveAttributionProbe: probe, remoteRunner: remoteRunner,
                                   socketPath: socketPath, responseWriter: responseWriter)
        liveReset.selection = { [weak server] in server?.liveResetSelection() }
        server.liveReset = liveReset
        self.server = server
        return server
    }

    private func addOrphanedSession() throws -> (session: Session, rows: String) {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.workspaces.first)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        return (session, "name=\(ZmxSupport.daemonName(for: session.paneIdentity))\tpid=200\tclients=0")
    }

    func testLiveResetSelectionJoinsClaimsAndRecords() throws {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.workspaces.first)
        let orphaned = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        let supervised = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        let rows = [
            "name=\(ZmxSupport.daemonName(for: orphaned.paneIdentity))\tpid=200\tclients=0",
            "name=\(ZmxSupport.daemonName(for: supervised.paneIdentity))\tpid=210\tclients=1",
        ].joined(separator: "\n")
        let probe = LiveAttributionProbe(responsible: { pid in pid == 210 ? .live(100) : .live(pid) },
                                         hostPID: { _ in 100 }, appPID: 300)

        let selection = try XCTUnwrap(makeServer(liveReset: makeCoordinator(), runner: { _ in rows }, probe: probe).liveResetSelection())

        XCTAssertEqual(selection.targets, [LiveReset.Target(paneIdentity: orphaned.paneIdentity, sessionID: orphaned.id,
                                                            daemon: ZmxSupport.daemonName(for: orphaned.paneIdentity), leaderPID: 200)])
        XCTAssertEqual(selection.sessionCount, 1)
        XCTAssertTrue(selection.inventoryComplete)
    }

    func testLiveResetSelectionIsNilWhenTheListingFails() {
        XCTAssertNil(makeServer(liveReset: makeCoordinator(), runner: { _ in throw ZmxClient.CommandError.timedOut }).liveResetSelection())
    }

    func testResetRefusedOutsideLive() throws {
        let fixture = try addOrphanedSession()
        for (active, configured) in [(RestoreMode.rerun, RestoreMode.live), (.live, .rerun), (.none, .none)] {
            let liveReset = makeCoordinator(active: active, configured: configured)
            let response = makeServer(liveReset: liveReset, runner: { _ in fixture.rows }).resetLiveSessions()
            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.error, LiveResetCoordinator.Refusal.notLive.message)
            XCTAssertNil(liveReset.pending)
        }
    }

    func testResetRefusedWhenTheListingFails() throws {
        let liveReset = makeCoordinator()
        let response = makeServer(liveReset: liveReset, runner: { _ in throw ZmxClient.CommandError.timedOut }).resetLiveSessions()
        XCTAssertEqual(response.error, LiveResetCoordinator.Refusal.listingFailed.message)
        XCTAssertNil(liveReset.pending)
    }

    func testResetRefusedOnIncompleteInventory() throws {
        let fixture = try addOrphanedSession()
        let windows = stateDir.appendingPathComponent("windows")
        try? FileManager.default.removeItem(at: windows)
        try "not a directory".write(to: windows, atomically: true, encoding: .utf8)
        let liveReset = makeCoordinator()

        let response = makeServer(liveReset: liveReset, runner: { _ in fixture.rows }).resetLiveSessions()

        XCTAssertEqual(response.error, LiveResetCoordinator.Refusal.inventoryIncomplete.message)
        XCTAssertNil(liveReset.pending)
    }

    func testResetRefusedWhenEmpty() throws {
        let liveReset = makeCoordinator()
        let response = makeServer(liveReset: liveReset, runner: { _ in "" }).resetLiveSessions()
        XCTAssertEqual(response.error, LiveResetCoordinator.Refusal.nothingToReset.message)
        XCTAssertNil(liveReset.pending)
    }

    private func sendTask(_ request: ControlRequest) -> Task<ControlResponse?, Never> {
        Self.detachedRoundTrip(request, at: socketPath)
    }

    private func send(_ request: ControlRequest) async -> ControlResponse? {
        await sendTask(request).value
    }

    nonisolated private static func detachedRoundTrip(_ request: ControlRequest, at path: String) -> Task<ControlResponse?, Never> {
        Task.detached { [request, path] in roundTrip(request, at: path) }
    }

    nonisolated private static func roundTrip(_ request: ControlRequest, at path: String) -> ControlResponse? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { chars in
                _ = strlcpy(chars, path, capacity)
            }
        }
        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 }
        }
        guard connected, var payload = try? JSONEncoder().encode(request) else { return nil }
        payload.append(UInt8(ascii: "\n"))
        let written = payload.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == payload.count else { return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBufferPointer { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
            if data.last == UInt8(ascii: "\n") { break }
        }
        return try? JSONDecoder().decode(ControlResponse.self, from: data)
    }

    private final class TerminationLog {
        var count = 0
    }

    private func expectTermination(of liveReset: LiveResetCoordinator) -> (expectation: XCTestExpectation, log: TerminationLog) {
        let expectation = expectation(description: "terminate")
        let log = TerminationLog()
        liveReset.terminate = { log.count += 1; expectation.fulfill() }
        return (expectation, log)
    }

    func testResetReplyCarriesCountsAndText() async throws {
        let fixture = try addOrphanedSession()
        let liveReset = makeCoordinator()
        let terminated = expectTermination(of: liveReset)
        makeServer(liveReset: liveReset, runner: { _ in fixture.rows }).start()

        let sent = await send(ControlRequest(cmd: .zmxReset, args: ControlArgs(force: true)))
        let response = try XCTUnwrap(sent)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(response.result?.liveReset, ControlLiveResetStatus(sessions: 1, panes: 1, pending: true))
        XCTAssertEqual(response.result?.text?.hasPrefix("1 live session will be reset."), true)
        XCTAssertEqual(liveReset.pending?.targets.count, 1)
        await fulfillment(of: [terminated.expectation], timeout: 2)
        XCTAssertEqual(terminated.log.count, 1)
    }

    func testTerminationWaitsForReplyWrite() async throws {
        let fixture = try addOrphanedSession()
        let liveReset = makeCoordinator()
        let terminated = expectTermination(of: liveReset)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let writerEntered = expectation(description: "reset writer held")
        makeServer(liveReset: liveReset, runner: { _ in fixture.rows }, responseWriter: { conn, response in
            if response.result?.liveReset != nil {
                writerEntered.fulfill()
                gate.wait()
            }
            return ControlServer.writeResponse(conn, response)
        }).start()

        let reply = sendTask(ControlRequest(cmd: .zmxReset, args: ControlArgs(force: true)))
        await fulfillment(of: [writerEntered], timeout: 2)
        XCTAssertEqual(terminated.log.count, 0, "the quit must wait for the reply frame")
        gate.signal()
        let replied = await reply.value
        let response = try XCTUnwrap(replied)

        XCTAssertTrue(response.ok)
        await fulfillment(of: [terminated.expectation], timeout: 2)
        XCTAssertEqual(terminated.log.count, 1)
    }

    func testUnrelatedReplyDuringHeldWriteDoesNotTerminate() async throws {
        let fixture = try addOrphanedSession()
        let liveReset = makeCoordinator()
        let terminated = expectTermination(of: liveReset)
        let resetGate = DispatchSemaphore(value: 0)
        let remoteEntered = expectation(description: "remote runner held")
        let remote = HeldRemoteRunner(onEnter: { remoteEntered.fulfill() })
        defer {
            resetGate.signal()
            remote.release()
        }
        let writerEntered = expectation(description: "reset writer held")
        makeServer(liveReset: liveReset, runner: { _ in fixture.rows }, remoteRunner: remote, responseWriter: { conn, response in
            if response.result?.liveReset != nil {
                writerEntered.fulfill()
                resetGate.wait()
            }
            return ControlServer.writeResponse(conn, response)
        }).start()

        let tree = sendTask(ControlRequest(cmd: .zmxTree, args: ControlArgs(host: "buildbox")))
        await fulfillment(of: [remoteEntered], timeout: 2)
        let reset = sendTask(ControlRequest(cmd: .zmxReset, args: ControlArgs(force: true)))
        await fulfillment(of: [writerEntered], timeout: 2)
        remote.release()
        let treeReplied = await tree.value
        let treeResponse = try XCTUnwrap(treeReplied, "the unrelated reply must be written while the reset reply is held")
        XCTAssertFalse(treeResponse.ok)
        XCTAssertEqual(terminated.log.count, 0, "another reply finishing must not quit the app")
        resetGate.signal()
        let replied = await reset.value
        let response = try XCTUnwrap(replied)

        XCTAssertTrue(response.ok)
        await fulfillment(of: [terminated.expectation], timeout: 2)
        XCTAssertEqual(terminated.log.count, 1)
    }

    private static let lastOutcome = LiveReset.Outcome(
        panes: LiveReset.PaneCounts(confirmed: 2, killed: 1, gone: 0, skipped: 1), unconfirmed: [],
        sessions: LiveReset.SessionCounts(affected: 2, reset: 1, partial: 1, unconfirmed: 0), inventoryFailed: false)

    func testTreeLiveResetReadback() throws {
        let fixture = try addOrphanedSession()
        let liveReset = makeCoordinator()
        let server = makeServer(liveReset: liveReset, runner: { _ in fixture.rows })
        server.liveResetOutcome = { nil }

        XCTAssertNil(server.controlTree(window: nil).result?.tree?.liveReset, "an untouched instance shows no field")

        server.liveResetOutcome = { Self.lastOutcome }
        XCTAssertEqual(server.controlTree(window: nil).result?.tree?.liveReset, ControlLiveResetReadback(pending: nil, last: Self.lastOutcome))

        XCTAssertEqual(liveReset.request(confirmed: true), .confirmed(try XCTUnwrap(server.liveResetSelection())))
        XCTAssertEqual(server.controlTree(window: nil).result?.tree?.liveReset, ControlLiveResetReadback(pending: 1, last: Self.lastOutcome))
    }

    func testZmxListLiveResetReadback() throws {
        let fixture = try addOrphanedSession()
        let liveReset = makeCoordinator()
        let server = makeServer(liveReset: liveReset, runner: { _ in fixture.rows })
        server.liveResetOutcome = { nil }

        XCTAssertNil(try XCTUnwrap(server.listZmxDaemons().result?.zmx).liveReset)

        _ = liveReset.request(confirmed: true)
        XCTAssertEqual(try XCTUnwrap(server.listZmxDaemons().result?.zmx).liveReset, ControlLiveResetReadback(pending: 1, last: nil))
    }

    func testFailedReplyWriteDoesNotTerminate() async throws {
        let fixture = try addOrphanedSession()
        let liveReset = makeCoordinator()
        var terminations = 0
        liveReset.terminate = { terminations += 1 }
        makeServer(liveReset: liveReset, runner: { _ in fixture.rows }, responseWriter: { conn, response in
            response.result?.liveReset != nil ? false : ControlServer.writeResponse(conn, response)
        }).start()

        _ = await send(ControlRequest(cmd: .zmxReset, args: ControlArgs(force: true)))
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(terminations, 0)
        XCTAssertNotNil(liveReset.pending, "a reply that never went out leaves the reset pending for a later quit")
    }
}

private final class HeldRemoteRunner: RemoteCommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private let onEnter: @Sendable () -> Void

    init(onEnter: @escaping @Sendable () -> Void) {
        self.onEnter = onEnter
    }

    func release() {
        lock.withLock { released = true }
    }

    func run(_: [String], deadline _: TimeInterval) async -> RemoteCommandResult {
        onEnter()
        while !lock.withLock({ released }) {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return RemoteCommandResult(status: 1, stdout: "", stderr: "held")
    }
}
