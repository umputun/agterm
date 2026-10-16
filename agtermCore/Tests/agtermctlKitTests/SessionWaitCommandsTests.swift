import ArgumentParser
import Darwin
import Foundation
import Testing
import agtermCore
@testable import agtermctlKit

struct SessionWaitCommandsTests {
    private let run = UUID(uuidString: "CBB5E3D0-7A9B-4C96-9EA2-18B14380DDB1")!
    private let worker = UUID(uuidString: "AAAA1111-0000-4000-8000-000000000001")!
    private let other = UUID(uuidString: "BBBB2222-0000-4000-8000-000000000002")!
    private let window = UUID(uuidString: "CCCC3333-0000-4000-8000-000000000003")!

    private final class FakeApp {
        var eventPages: [Result<ControlResponse, Error>] = []
        var trees: [String: ControlTree]
        var windows: [ControlWindowNode]
        var requests: [ControlRequest] = []
        var sleeps: [TimeInterval] = []
        var clock: TimeInterval = 0

        init(trees: [String: ControlTree], windows: [ControlWindowNode]) {
            self.trees = trees
            self.windows = windows
        }

        var dependencies: SessionWaitDependencies {
            SessionWaitDependencies(
                send: { request in
                    self.requests.append(request)
                    switch request.cmd {
                    case .windowList: return ControlResponse(ok: true, result: ControlResult(windows: self.windows))
                    case .tree:
                        guard let tree = self.trees[request.args?.window ?? ""] else {
                            return ControlResponse(ok: false, error: "window not open")
                        }
                        return ControlResponse(ok: true, result: ControlResult(tree: tree))
                    default:
                        guard !self.eventPages.isEmpty else { return self.page([]) }
                        return try self.eventPages.removeFirst().get()
                    }
                },
                sleep: { delay in
                    self.sleeps.append(delay)
                    self.clock += delay
                },
                now: { self.clock }
            )
        }

        func page(_ items: [ControlEvent], next: UInt64 = 10) -> ControlResponse {
            ControlResponse(ok: true, result: ControlResult(events: ControlEventBatch(
                run: UUID(uuidString: "CBB5E3D0-7A9B-4C96-9EA2-18B14380DDB1")!, next: next, items: items)))
        }
    }

    private func session(_ id: UUID, status: String? = nil, active: Bool = false) -> ControlSessionNode {
        ControlSessionNode(id: id.uuidString, name: "s", cwd: "/tmp", active: active, split: false, backedByZmx: nil,
                           status: status)
    }

    private func app(worker workerStatus: String? = nil, selected: UUID? = nil) -> FakeApp {
        let sessions = [session(worker, status: workerStatus, active: selected == worker),
                        session(other, status: "completed", active: selected == other)]
        return FakeApp(trees: [window.uuidString: tree(sessions)],
                       windows: [ControlWindowNode(id: window.uuidString, name: "main", open: true, active: true)])
    }

    private func tree(_ sessions: [ControlSessionNode]) -> ControlTree {
        ControlTree(workspaces: [ControlWorkspaceNode(id: UUID().uuidString, name: "w", active: true, sessions: sessions)])
    }

    private func statusEvent(_ seq: UInt64, session id: UUID, _ status: String, previous: String? = nil) -> ControlEvent {
        ControlEvent(seq: seq, ts: 1, kind: .status, session: id.uuidString,
                     payload: ControlEventPayload(name: "s", status: status, previous: previous))
    }

    private func command(_ argv: [String]) throws -> agtermctlKit.Session.Wait {
        try #require(try Agtermctl.parseAsRoot(["session", "wait"] + argv) as? agtermctlKit.Session.Wait)
    }

    @Test func currentStatusMatchesWithoutReadingEvents() throws {
        let fake = app(worker: "completed")
        let outcome = try command(["--target", worker.uuidString, "--until", "completed"]).wait(dependencies: fake.dependencies)
        #expect(outcome == .matched(id: worker, status: .completed))
        #expect(fake.requests.map(\.cmd) == [.eventsRead, .windowList, .tree])
    }

    @Test func anchorIsTakenBeforeTheTreeIsRead() throws {
        let fake = app(worker: "active")
        fake.eventPages = [.success(fake.page([], next: 7)), .success(fake.page([statusEvent(8, session: worker, "completed")], next: 8))]
        _ = try command(["--target", worker.uuidString, "--until", "completed"]).wait(dependencies: fake.dependencies)
        #expect(fake.requests.map(\.cmd) == [.eventsRead, .windowList, .tree, .eventsRead])
        #expect(fake.requests.first?.args?.after == nil)
        #expect(fake.requests.last?.args?.after == "7")
        #expect(fake.requests.last?.args?.run == run.uuidString)
        #expect(fake.requests.last?.args?.kinds == ["status", "session.closed"])
    }

    @Test func absentStatusReadsAsIdle() throws {
        let fake = app(worker: nil)
        let outcome = try command(["--target", worker.uuidString, "--until", "idle"]).wait(dependencies: fake.dependencies)
        #expect(outcome == .matched(id: worker, status: .idle))
    }

    @Test func laterEventForTheSessionMatchesAndOthersAreIgnored() throws {
        let fake = app(worker: "active")
        fake.eventPages = [
            .success(fake.page([])),
            .success(fake.page([statusEvent(11, session: other, "blocked"), statusEvent(12, session: worker, "active")])),
            .success(fake.page([statusEvent(13, session: worker, "blocked", previous: "active")])),
        ]
        let outcome = try command(["--target", worker.uuidString, "--until", "completed", "--until", "blocked"])
            .wait(dependencies: fake.dependencies)
        #expect(outcome == .matched(id: worker, status: .blocked))
    }

    @Test func repeatedStatusEventCountsAsReached() throws {
        let fake = app(worker: "active")
        fake.eventPages = [.success(fake.page([])), .success(fake.page([statusEvent(11, session: worker, "completed", previous: "completed")]))]
        let outcome = try command(["--target", worker.uuidString, "--until", "completed"]).wait(dependencies: fake.dependencies)
        #expect(outcome == .matched(id: worker, status: .completed))
    }

    @Test func sessionClosedEndsTheWait() throws {
        let fake = app(worker: "active")
        fake.eventPages = [
            .success(fake.page([])),
            .success(fake.page([ControlEvent(seq: 11, ts: 1, kind: .sessionClosed, session: other.uuidString),
                                ControlEvent(seq: 12, ts: 1, kind: .sessionClosed, session: worker.uuidString)])),
        ]
        let outcome = try command(["--target", worker.uuidString, "--until", "completed"]).wait(dependencies: fake.dependencies)
        #expect(outcome == .closed)
    }

    @Test func deadlinePassesWithoutAMatch() throws {
        let fake = app(worker: "active")
        let outcome = try command(["--target", worker.uuidString, "--until", "completed", "--timeout", "1"])
            .wait(dependencies: fake.dependencies)
        #expect(outcome == .timedOut)
        #expect(fake.sleeps.allSatisfy { $0 <= agtermctlKit.Session.Wait.pollDelay })
        #expect(fake.clock == 1)
    }

    @Test func refusedConnectRetriesWithinTheDeadline() throws {
        let fake = app(worker: "active")
        fake.eventPages = [
            .success(fake.page([])),
            .failure(SocketClientError("refused", connectErrno: ECONNREFUSED)),
            .success(fake.page([statusEvent(11, session: worker, "completed")])),
        ]
        let outcome = try command(["--target", worker.uuidString, "--until", "completed", "--timeout", "5"])
            .wait(dependencies: fake.dependencies)
        #expect(outcome == .matched(id: worker, status: .completed))
        #expect(fake.sleeps == [EventStreamState.firstRetryDelay])
    }

    @Test func missingSocketFailsAtOnce() throws {
        let fake = app(worker: "active")
        fake.eventPages = [.success(fake.page([])), .failure(SocketClientError("no socket", connectErrno: ENOENT))]
        #expect(throws: SocketClientError.self) {
            try command(["--target", worker.uuidString, "--until", "completed"]).wait(dependencies: fake.dependencies)
        }
    }

    @Test func runChangeFailsTheWait() throws {
        let fake = app(worker: "active")
        fake.eventPages = [.success(fake.page([])), .success(ControlResponse(ok: false, error: "event run changed"))]
        #expect(throws: EventStreamError.self) {
            try command(["--target", worker.uuidString, "--until", "completed"]).wait(dependencies: fake.dependencies)
        }
    }

    @Test func activeResolvesToTheFrontmostWindowsSelection() throws {
        let fake = app(worker: "completed", selected: worker)
        #expect(try command(["--until", "completed"]).wait(dependencies: fake.dependencies) == .matched(id: worker, status: .completed))
    }

    @Test func prefixResolvesInABackgroundWindow() throws {
        let fake = app(worker: "active", selected: worker)
        let background = UUID()
        let hidden = UUID(uuidString: "EEEE5555-0000-4000-8000-000000000005")!
        fake.windows.append(ControlWindowNode(id: background.uuidString, name: "back", open: true, active: false))
        fake.trees[background.uuidString] = tree([session(hidden, status: "blocked", active: true)])
        #expect(try command(["--target", "eeee", "--until", "blocked"]).wait(dependencies: fake.dependencies)
            == .matched(id: hidden, status: .blocked))
    }

    @Test func prefixMatchingSessionsInTwoWindowsIsAmbiguous() throws {
        let fake = app(worker: "completed")
        let background = UUID()
        let twin = UUID(uuidString: "AAAA1111-0000-4000-8000-000000000009")!
        fake.windows.append(ControlWindowNode(id: background.uuidString, name: "back", open: true, active: false))
        fake.trees[background.uuidString] = tree([session(twin, status: "completed")])
        #expect(throws: SocketClientError.self) {
            try command(["--target", "aaaa", "--until", "completed"]).wait(dependencies: fake.dependencies)
        }
    }

    @Test(arguments: ["DDDD", ""])
    func unresolvedTargetFails(target: String) throws {
        let fake = app(worker: "completed")
        #expect(throws: SocketClientError.self) {
            try command(["--target", target, "--until", "completed"]).wait(dependencies: fake.dependencies)
        }
    }

    @Test func closedWindowsAreNotRead() throws {
        let fake = app(worker: "completed")
        fake.windows.append(ControlWindowNode(id: UUID().uuidString, name: "closed", open: false, active: false))
        _ = try command(["--target", worker.uuidString, "--until", "completed"]).wait(dependencies: fake.dependencies)
        #expect(fake.requests.filter { $0.cmd == .tree }.map { $0.args?.window } == [window.uuidString])
    }

    @Test func outputIsTheStatusOrOneJSONObject() throws {
        #expect(try command(["--until", "idle"]).output(id: worker, status: .completed) == "completed")
        #expect(try command(["--until", "idle", "--json"]).output(id: worker, status: .completed)
            == #"{"id":"\#(worker.uuidString)","status":"completed"}"#)
    }

    @Test(arguments: [
        [String](), ["--until", "done"], ["--until", "completed", "--timeout", "0"],
        ["--until", "completed", "--timeout", "-1"], ["--until", "completed", "--timeout", "inf"],
    ])
    func rejectsInvalidArguments(argv: [String]) {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["session", "wait"] + argv) }
    }

    @Test func watchdogFiresWhileTheCallerIsBlocked() {
        let fired = DispatchSemaphore(value: 0)
        let watchdog = SessionWaitWatchdog(seconds: 0.05) { fired.signal() }
        defer { watchdog.cancel() }
        #expect(fired.wait(timeout: .now() + 5) == .success)
    }

    // regression: a timer on the shared global queue starved when its worker threads were all blocked
    @Test func watchdogFiresWhileTheGlobalQueueIsExhausted() throws {
        let probe = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug/session-wait-watchdog-probe")
        let process = Process()
        process.executableURL = probe
        try process.run()
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            Issue.record("watchdog probe did not exit within 15 s")
            return
        }
        #expect(process.terminationStatus == 0, "exit 1: the watchdog did not fire; exit 3: the global queue was not exhausted")
    }

    @Test func cancelledWatchdogDoesNotFire() {
        let fired = DispatchSemaphore(value: 0)
        let watchdog = SessionWaitWatchdog(seconds: 0.05) { fired.signal() }
        watchdog.cancel()
        #expect(fired.wait(timeout: .now() + 0.3) == .timedOut)
    }
}
