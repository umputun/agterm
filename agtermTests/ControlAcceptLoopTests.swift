import Darwin
import XCTest
@testable import agterm

final class ControlAcceptLoopTests: XCTestCase {
    private var path: String!

    override func setUp() {
        path = "/tmp/agt-accept-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
    }

    override func tearDown() {
        unlink(path)
    }

    func testStopWakesALoopParkedInPoll() throws {
        let loop = try XCTUnwrap(ControlAcceptLoop(listenFD: listener()))
        let returned = expectation(description: "next returned")
        DispatchQueue.global().async {
            XCTAssertNil(loop.next())
            returned.fulfill()
        }
        usleep(100_000)

        loop.stop()

        wait(for: [returned], timeout: 2)
        loop.finish()
    }

    // regression: stop() closed the listener under a busy loop, whose next accept then hit a reused number
    func testStopLeavesTheListenerToTheLoopUntilFinish() throws {
        let loop = try XCTUnwrap(ControlAcceptLoop(listenFD: listener()))
        let client = connectClient()
        defer { close(client) }
        let conn = try XCTUnwrap(loop.next())
        defer { close(conn) }

        loop.stop()

        XCTAssertNotEqual(fcntl(loop.listenFD, F_GETFD), -1, "stop must not close the listener the loop owns")
        XCTAssertNil(loop.next())
        loop.finish()
        XCTAssertEqual(fcntl(loop.listenFD, F_GETFD), -1, "finish closes the listener")
    }

    func testStopBeforeNextEndsTheLoopAtOnce() throws {
        let loop = try XCTUnwrap(ControlAcceptLoop(listenFD: listener()))
        loop.stop()

        XCTAssertNil(loop.next())
        loop.finish()
    }

    func testAnAcceptedConnectionIsBlocking() throws {
        let loop = try XCTUnwrap(ControlAcceptLoop(listenFD: listener()))
        defer { loop.finish() }
        let client = connectClient()
        defer { close(client) }

        let conn = try XCTUnwrap(loop.next())
        defer { close(conn) }

        XCTAssertEqual(fcntl(conn, F_GETFL) & O_NONBLOCK, 0)
    }

    private func listener() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = address()
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(fd, SOMAXCONN), 0)
        return fd
    }

    private func connectClient() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = address()
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(connected, 0)
        return fd
    }

    private func address() -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            _ = path.withCString { strcpy(raw.baseAddress!.assumingMemoryBound(to: CChar.self), $0) }
        }
        return addr
    }
}
