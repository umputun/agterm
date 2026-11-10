import XCTest
@testable import agterm
import agtermCore

@MainActor
final class RemotePortForwardTests: XCTestCase {
    private var launcher: FakeForwardLauncher!

    override func setUp() async throws {
        try await super.setUp()
        launcher = FakeForwardLauncher()
    }

    override func tearDown() async throws {
        launcher.processes.forEach { $0.terminate() }
        try await super.tearDown()
    }

    private func forward(port: Int, timeout: Duration = .seconds(10), events: @escaping @MainActor (PortForwardEvent) -> Void) -> RemotePortForward {
        RemotePortForward(argv: ["ssh", "-L", "127.0.0.1:\(port):127.0.0.1:80", "box"], host: "127.0.0.1", port: port,
                          launcher: launcher, timeout: timeout, onEvent: events)
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(condition(), what)
    }

    func testAListenerThatAnswersMakesTheForwardReadyOnce() throws {
        let port = try XCTUnwrap(RemotePortForward.freePort(host: "127.0.0.1"))
        var events: [PortForwardEvent] = []
        let forward = forward(port: port) { events.append($0) }

        forward.start()

        waitUntil("ready") { events == [.ready] }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(events, [.ready])
        forward.stop()
        XCTAssertTrue(launcher.processes[0].terminated)
    }

    func testAForwardThatNeverAnswersFailsAtItsDeadlineAndIsStopped() throws {
        launcher.listens = false
        let port = try XCTUnwrap(RemotePortForward.freePort(host: "127.0.0.1"))
        var events: [PortForwardEvent] = []
        let forward = forward(port: port, timeout: .milliseconds(300)) { events.append($0) }

        forward.start()

        waitUntil("failed") { !events.isEmpty }
        XCTAssertEqual(events, [.failed("the port forward did not come up")])
        XCTAssertTrue(launcher.processes[0].terminated)
    }

    func testAForwardStoppedBeforeItAnswersReportsNothing() throws {
        launcher.listens = false
        let port = try XCTUnwrap(RemotePortForward.freePort(host: "127.0.0.1"))
        var events: [PortForwardEvent] = []
        let forward = forward(port: port, timeout: .milliseconds(300)) { events.append($0) }
        forward.start()

        forward.stop()
        launcher.processes[0].onExit?("killed")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        XCTAssertTrue(events.isEmpty)
    }

    func testAForwardWritingMoreThanThePipeHoldsStillExitsAndReportsItsLastLine() throws {
        var reported: String?
        let process = try RemoteForwardProcessLauncher().launch(
            ["/bin/sh", "-c", "head -c 200000 /dev/zero | tr '\\0' x >&2; echo; echo 'bind: Address already in use' >&2"]) {
                reported = $0
            }
        defer { process.terminate() }

        waitUntil("the child exits") { reported != nil }
        XCTAssertLessThanOrEqual(reported?.utf8.count ?? .max, RemoteForwardProcessLauncher.tailBytes)
        XCTAssertTrue(reported?.hasSuffix("bind: Address already in use\n") == true)
    }

    func testAForwardWhoseChildKeepsStderrOpenReportsItsExitPromptlyAndIsReleased() throws {
        var reported: String?
        let started = Date()
        weak var released: (any RemoteForwardProcess)?
        try autoreleasepool {
            let process = try RemoteForwardProcessLauncher().launch(
                ["/bin/sh", "-c", "sleep 5 & echo 'kex_exchange_identification: Connection closed' >&2; exit 255"]) { reported = $0 }
            released = process
        }

        waitUntil("the exit is reported") { reported != nil }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(reported, "kex_exchange_identification: Connection closed\n")
        waitUntil("the process handle is released while the child still holds stderr") { released == nil }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }

    func testAFreePortIsOneNothingListensOn() throws {
        let port = try XCTUnwrap(RemotePortForward.freePort(host: "127.0.0.1"))
        XCTAssertFalse(RemotePortForward.accepts(host: "127.0.0.1", port: port))
        let fd = FakeForwardLauncher.listen(port)
        defer { close(fd) }
        XCTAssertTrue(RemotePortForward.accepts(host: "127.0.0.1", port: port))
    }
}
