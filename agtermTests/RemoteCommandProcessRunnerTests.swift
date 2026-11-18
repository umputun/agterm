import XCTest
@testable import agterm
import agtermCore

/// The real process runner, which every other remote test replaces with a fake. Covers the two ways it
/// can hang: a child that never exits, and one that fills a pipe while nobody drains it.
final class RemoteCommandProcessRunnerTests: XCTestCase {
    private let runner = RemoteCommandProcessRunner()

    func testACommandThatOutlivesTheDeadlineIsKilledAndReported() async {
        let started = Date()

        let result = await runner.run(["sh", "-c", "sleep 30"], deadline: 0.4)

        XCTAssertEqual(result.status, -1)
        XCTAssertEqual(result.stderr, "the remote did not answer in time")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5,
                          "the deadline must bound a child that keeps its pipes open")
    }

    func testOutputLargerThanAPipeBufferOnBothStreamsStillCompletes() async {
        // 512 KiB each way, well past the 64 KiB pipe buffer: draining one stream at a time deadlocks here
        let script = "yes abcdefgh | head -c 524288; yes abcdefgh | head -c 524288 >&2"

        let result = await runner.run(["sh", "-c", script], deadline: 20)

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.utf8.count, 524_288)
        XCTAssertEqual(result.stderr.utf8.count, 524_288)
    }

    func testOutputHeldOpenPastTheExitIsAFailureWithoutPartialStdout() async {
        let started = Date()

        let result = await runner.run(["sh", "-c", "sleep 5 & echo row"], deadline: 10)

        XCTAssertEqual(result.status, -1)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "the remote command output did not close in time")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testANonzeroExitKeepsBothStreams() async {
        let result = await runner.run(["sh", "-c", "printf out; printf err >&2; exit 7"], deadline: 10)

        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(result.stdout, "out")
        XCTAssertEqual(result.stderr, "err")
    }

    func testAnInputFileIsTheCommandsStandardInput() async throws {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("runner-input-\(UUID().uuidString)")
        try Data("bundle bytes".utf8).write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }

        let result = await runner.run(["sh", "-c", "cat; printf done >&2"], deadline: 10, input: input)

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "bundle bytes")
        XCTAssertEqual(result.stderr, "done")
    }

    func testAnUnreadableInputFileIsAnErrorWithoutRunning() async {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("runner-missing-\(UUID().uuidString)")

        let result = await runner.run(["sh", "-c", "printf ran"], deadline: 10, input: missing)

        XCTAssertEqual(result.status, -1)
        XCTAssertEqual(result.stdout, "")
    }

    func testAMissingExecutableIsAnErrorRatherThanAHang() async {
        let result = await runner.run(["agterm-no-such-command-\(UUID().uuidString)"], deadline: 10)

        XCTAssertNotEqual(result.status, 0)
    }
}
