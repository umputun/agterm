import XCTest
@testable import agterm
import agtermCore

@MainActor
final class HookProcessRunnerTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        try await super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-hook-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
        try await super.tearDown()
    }

    private struct Outcome {
        var deliveryFailures: [String] = []
        var exits: [Int32] = []
        var failureBeforeExit: Bool?
    }

    private final class OutcomeBox: @unchecked Sendable {
        var outcome = Outcome()
        var exitedInline = true
    }

    private final class Probe: @unchecked Sendable {
        var writeEnd: Int32?
        var closedAtExit: Bool?
    }

    private func openDescriptors() -> Set<Int32> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []
        return Set(names.compactMap(Int32.init))
    }

    private func run(_ command: String, event: ControlEvent = ControlEvent(seq: 1, ts: 1, kind: .status),
                     runner: HookProcessRunner? = nil, timeout: TimeInterval = 10) async throws -> (Outcome, Int32) {
        let runner = runner ?? HookProcessRunner(socketProvider: { "/tmp/test.sock" })
        let box = OutcomeBox()
        let exited = expectation(description: "exit")
        let entry = HookEntry(identity: HookIdentity(kind: event.kind, command: command), line: 1)
        let pid = try runner.launch(
            entry: entry, event: event,
            onDeliveryFailure: { box.outcome.deliveryFailures.append($0) },
            onExit: { status in
                box.outcome.exits.append(status)
                box.outcome.failureBeforeExit = !box.outcome.deliveryFailures.isEmpty
                exited.fulfill()
            })
        box.exitedInline = !box.outcome.exits.isEmpty
        await fulfillment(of: [exited], timeout: timeout)
        XCTAssertFalse(box.exitedInline, "onExit must never run inline from launch")
        XCTAssertEqual(box.outcome.exits.count, 1)
        return (box.outcome, pid)
    }

    func testTheWriteEndIsClosedBeforeExitIsReported() async throws {
        // 300 KB into a child that holds stdin open without reading keeps the write, and the descriptor, alive until exit
        let runner = HookProcessRunner(socketProvider: { "" })
        let entry = HookEntry(identity: HookIdentity(kind: .notify, command: "sleep 0.5; exit 0"), line: 1)
        let exited = expectation(description: "exit")
        let probe = Probe()
        let before = openDescriptors()

        _ = try runner.launch(entry: entry, event: largeEvent(), onDeliveryFailure: { _ in }, onExit: { _ in
            if let fd = probe.writeEnd { probe.closedAtExit = fcntl(fd, F_GETFD) == -1 && errno == EBADF }
            exited.fulfill()
        })
        let opened = openDescriptors().subtracting(before)
        XCTAssertEqual(opened.count, 1, "the blocked write keeps exactly the pipe's write end open: \(opened)")
        probe.writeEnd = opened.first

        await fulfillment(of: [exited], timeout: 10)
        XCTAssertEqual(probe.closedAtExit, true, "the write end must be closed before onExit")
    }

    private func largeEvent() -> ControlEvent {
        ControlEvent(seq: 7, ts: 7, kind: .notify, window: "w", workspace: "ws", session: "s",
                     payload: ControlEventPayload(name: "n", title: "t", body: String(repeating: "x", count: 300_000)))
    }

    func testStdinCarriesTheEventAndTheEnvironmentIsFullySet() async throws {
        let stdin = scratch.appendingPathComponent("stdin").path
        let env = scratch.appendingPathComponent("env").path
        let event = ControlEvent(seq: 3, ts: 3.5, kind: .status, window: "win-1", workspace: "ws-1", session: "sess-1",
                                 payload: ControlEventPayload(name: "api", status: "blocked", previous: "active"))
        let script = """
        cat > '\(stdin)'; printf '%s\\n' "$AGT_EVENT_KIND" "$AGT_EVENT_STATUS" "$AGT_SESSION_ID" "$AGT_WORKSPACE_ID" \
        "$AGT_WINDOW_ID" "$AGT_SOCKET" "$PWD" "$PATH" > '\(env)'
        """

        let (outcome, pid) = try await run(script, event: event)

        XCTAssertEqual(outcome.exits, [0])
        XCTAssertEqual(outcome.deliveryFailures, [])
        XCTAssertGreaterThan(pid, 0)
        let raw = try String(contentsOfFile: stdin, encoding: .utf8)
        XCTAssertTrue(raw.hasSuffix("\n"))
        XCTAssertEqual(raw.filter { $0 == "\n" }.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(ControlEvent.self, from: Data(raw.utf8)), event)
        let lines = try String(contentsOfFile: env, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(Array(lines[0..<6]), ["status", "blocked", "sess-1", "ws-1", "win-1", "/tmp/test.sock"])
        XCTAssertEqual(lines[6], Substring(FileManager.default.currentDirectoryPath), "a hook runs in the app's cwd")
        XCTAssertTrue(lines[7].contains("/opt/homebrew/bin"), "PATH is widened like a custom command's")
    }

    func testMissingFieldsAreExportedEmptyNotInherited() async throws {
        let env = scratch.appendingPathComponent("env").path
        setenv("AGT_SESSION_ID", "inherited-and-wrong", 1)
        setenv("AGT_EVENT_HOST", "inherited-and-wrong", 1)
        defer {
            unsetenv("AGT_SESSION_ID")
            unsetenv("AGT_EVENT_HOST")
        }
        let script = "printf '[%s][%s][%s][%s]' \"$AGT_EVENT_STATUS\" \"$AGT_SESSION_ID\" \"$AGT_WINDOW_ID\" \"$AGT_EVENT_HOST\" > '\(env)'"

        let (outcome, _) = try await run(script, event: ControlEvent(seq: 1, ts: 1, kind: .treeChanged))

        XCTAssertEqual(outcome.exits, [0])
        XCTAssertEqual(try String(contentsOfFile: env, encoding: .utf8), "[][][][]")
    }

    func testRemoteEdgeExportsTheHostAndCarriesItOnStdin() async throws {
        let stdin = scratch.appendingPathComponent("stdin").path
        let env = scratch.appendingPathComponent("env").path
        let event = ControlEvent(seq: 4, ts: 4.5, kind: .remoteOpened, window: "win-1", workspace: "ws-1",
                                 session: "sess-1", payload: ControlEventPayload(name: "far", host: "buildbox"))
        let script = "cat > '\(stdin)'; printf '%s' \"$AGT_EVENT_HOST\" > '\(env)'"

        let (outcome, _) = try await run(script, event: event)

        XCTAssertEqual(outcome.exits, [0])
        XCTAssertEqual(try String(contentsOfFile: env, encoding: .utf8), "buildbox")
        let raw = try String(contentsOfFile: stdin, encoding: .utf8)
        XCTAssertEqual(try JSONDecoder().decode(ControlEvent.self, from: Data(raw.utf8)), event)
        XCTAssertTrue(raw.contains(#""host":"buildbox""#))
    }

    func testEarlyStdinCloseWithALargePayloadIsNotADeliveryFailure() async throws {
        let (clean, _) = try await run("exec <&-; exit 0", event: largeEvent())
        XCTAssertEqual(clean.exits, [0])
        XCTAssertEqual(clean.deliveryFailures, [])

        let (failed, _) = try await run("exec <&-; exit 1", event: largeEvent())
        XCTAssertEqual(failed.exits, [1], "the exit status is judged separately from delivery")
        XCTAssertEqual(failed.deliveryFailures, [])
    }

    func testAMissingShellThrowsWithItsReasonAndRunsNoCallback() async throws {
        let shell = scratch.appendingPathComponent("no-such-shell")
        let runner = HookProcessRunner(socketProvider: { "" }, executableURL: shell)
        let box = OutcomeBox()
        let entry = HookEntry(identity: HookIdentity(kind: .status, command: "true"), line: 1)
        let before = openDescriptors()

        XCTAssertThrowsError(try runner.launch(
            entry: entry, event: ControlEvent(seq: 1, ts: 1, kind: .status),
            onDeliveryFailure: { box.outcome.deliveryFailures.append($0) },
            onExit: { box.outcome.exits.append($0) })) { error in
            // the scheduler shows `localizedDescription`; a bare CustomStringConvertible loses the detail there
            XCTAssertTrue(error.localizedDescription.contains("no-such-shell") || error.localizedDescription.contains("exist"),
                          "the reason must survive localizedDescription: \(error.localizedDescription)")
        }

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(box.outcome.exits, [])
        XCTAssertEqual(box.outcome.deliveryFailures, [])
        XCTAssertEqual(openDescriptors(), before, "a failed spawn closes both pipe ends")
    }

    func testADeliveryFailureIsReportedWhileTheChildIsStillAliveAndBeforeExit() async throws {
        let runner = HookProcessRunner(socketProvider: { "" }, encode: { _ in
            throw HookProcessRunner.LaunchError(detail: "boom")
        })
        let box = OutcomeBox()
        let failed = expectation(description: "delivery failure")
        let exited = expectation(description: "exit")
        let entry = HookEntry(identity: HookIdentity(kind: .status, command: "sleep 1"), line: 1)

        _ = try runner.launch(
            entry: entry, event: ControlEvent(seq: 1, ts: 1, kind: .status),
            onDeliveryFailure: { box.outcome.deliveryFailures.append($0); failed.fulfill() },
            onExit: {
                box.outcome.exits.append($0)
                box.outcome.failureBeforeExit = !box.outcome.deliveryFailures.isEmpty
                exited.fulfill()
            })

        await fulfillment(of: [failed], timeout: 0.5)
        XCTAssertEqual(box.outcome.exits, [], "the failure arrives while the child still sleeps, not at exit")
        XCTAssertEqual(box.outcome.deliveryFailures, ["encode: boom"])
        await fulfillment(of: [exited], timeout: 10)
        XCTAssertEqual(box.outcome.exits, [0])
        XCTAssertEqual(box.outcome.failureBeforeExit, true)
    }

    func testAChildThatExitsBeforeEncodingCompletesWithoutAFailure() async throws {
        let runner = HookProcessRunner(socketProvider: { "" }, encode: { event in
            Thread.sleep(forTimeInterval: 0.3)
            return try JSONEncoder().encode(event)
        })

        let (outcome, _) = try await run("exit 0", event: largeEvent(), runner: runner)

        XCTAssertEqual(outcome.exits, [0])
        XCTAssertEqual(outcome.deliveryFailures, [])
    }

    func testAGrandchildHoldingStdinDoesNotDelayExitOrCleanup() async throws {
        let started = Date()
        // a plain `(cmd) &` gets /dev/null as stdin in a non-interactive sh; fd 3 hands the pipe down explicitly
        let script = "exec 3<&0; (sleep 3 <&3 3<&-) & exec 3<&-; exit 0"

        let (outcome, _) = try await run(script, event: largeEvent(), timeout: 2)

        XCTAssertEqual(outcome.exits, [0])
        XCTAssertEqual(outcome.deliveryFailures, [])
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the blocked write is cancelled at the child's exit")
    }

    func testHookFailureBannerIdentifierIsNamespacedPerHook() {
        XCTAssertEqual(NotificationManager.hookFailureIdentifier(kind: "status", command: "~/s.sh"),
                       "hook-failure:status:~/s.sh")
        XCTAssertNotEqual(NotificationManager.hookFailureIdentifier(kind: "status", command: "x"),
                          NotificationManager.hookFailureIdentifier(kind: "notify", command: "x"))
    }
}
