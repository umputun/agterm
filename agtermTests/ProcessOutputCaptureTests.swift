import XCTest
@testable import agterm

final class ProcessOutputCaptureTests: XCTestCase {
    func testReaderReturnsEverythingWrittenThroughEOF() throws {
        let (readFD, writeFD) = try makePipe()
        let reader = PipeReader(fileDescriptor: readFD)

        XCTAssertEqual(write(writeFD, "row\n", 4), 4)
        close(writeFD)

        let data = try XCTUnwrap(reader.wait(until: .now() + 2))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "row\n")
    }

    func testReaderMissReleasesTheReadEndWhileTheWriterStaysOpen() throws {
        let (readFD, writeFD) = try makePipe()
        defer { close(writeFD) }
        let reader = PipeReader(fileDescriptor: readFD)
        XCTAssertEqual(write(writeFD, "x", 1), 1)

        XCTAssertNil(reader.wait(until: .now() + 0.1))
        reader.cancel()

        XCTAssertTrue(waitForBrokenPipe(writeFD, within: 2), "cancel must close the read end the writer still holds")
    }

    func testCaptureCollectsBothStreamsPastThePipeBuffer() throws {
        let process = shell("head -c 200000 /dev/zero | tr '\\0' x; head -c 200000 /dev/zero | tr '\\0' y >&2")
        let capture = try ProcessOutputCapture(attachingTo: process)
        try process.run()
        capture.didLaunch()

        let output = try XCTUnwrap(capture.collect(until: .now() + 5))

        XCTAssertEqual(output.stdout.count, 200_000)
        XCTAssertEqual(output.stderr.count, 200_000)
        XCTAssertEqual(output.stdout.first, "x")
        XCTAssertEqual(output.stderr.first, "y")
    }

    func testCaptureGivesUpOnAWriteEndInheritedPastTheChildsExit() throws {
        let process = shell("sleep 5 & echo row")
        let capture = try ProcessOutputCapture(attachingTo: process)
        let started = Date()
        try process.run()
        capture.didLaunch()
        process.waitUntilExit()

        XCTAssertNil(capture.collect(until: .now() + 0.25))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    private func shell(_ script: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        return process
    }

    private func makePipe() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw POSIXError(.EMFILE) }
        XCTAssertEqual(fcntl(fds[1], F_SETNOSIGPIPE, 1), 0)
        return (fds[0], fds[1])
    }

    private func waitForBrokenPipe(_ fd: Int32, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if write(fd, "x", 1) == -1, errno == EPIPE { return true }
            usleep(10_000)
        }
        return false
    }
}
