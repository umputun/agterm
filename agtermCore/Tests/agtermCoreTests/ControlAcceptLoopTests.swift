import Foundation
import Testing
@testable import agtermCore

final class ControlAcceptLoopTests {
    private let path = "/tmp/agt-accept-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"

    deinit {
        unlink(path)
    }

    @Test func stopWakesALoopParkedInPoll() async throws {
        let loop = try #require(ControlAcceptLoop(listenFD: UnixSocket.listening(path: path)))
        let returned = Task.detached { loop.next() }
        try await Task.sleep(nanoseconds: 100_000_000)

        loop.stop()

        #expect(await returned.value == nil)
        loop.finish()
    }

    // regression: stop() closed the listener under a busy loop, whose next accept then hit a reused number
    @Test func stopLeavesTheListenerToTheLoopUntilFinish() throws {
        let loop = try #require(ControlAcceptLoop(listenFD: UnixSocket.listening(path: path)))
        let client = try #require(UnixSocket.connected(path: path))
        defer { close(client) }
        let conn = try #require(loop.next())
        defer { close(conn) }

        loop.stop()

        let late = UnixSocket.connected(path: path)
        defer { late.map { _ = close($0) } }
        #expect(late != nil, "stop must not close the listener the loop owns")
        #expect(loop.next() == nil)
        loop.finish()
        let after = UnixSocket.connected(path: path)
        defer { after.map { _ = close($0) } }
        #expect(after == nil, "finish closes the listener")
    }

    @Test func stopBeforeNextEndsTheLoopAtOnce() throws {
        let loop = try #require(ControlAcceptLoop(listenFD: UnixSocket.listening(path: path)))
        loop.stop()

        #expect(loop.next() == nil)
        loop.finish()
    }

    @Test func anAcceptedConnectionIsBlocking() throws {
        let loop = try #require(ControlAcceptLoop(listenFD: UnixSocket.listening(path: path)))
        defer { loop.finish() }
        let client = try #require(UnixSocket.connected(path: path))
        defer { close(client) }

        let conn = try #require(loop.next())
        defer { close(conn) }

        #expect(fcntl(conn, F_GETFL) & O_NONBLOCK == 0)
    }
}
