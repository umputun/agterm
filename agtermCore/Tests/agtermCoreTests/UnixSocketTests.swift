import Foundation
import Testing
@testable import agtermCore

struct UnixSocketTests {
    private func path() -> String { "/tmp/agt-unix-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock" }

    @Test func aListeningSocketAcceptsAConnection() throws {
        let path = path()
        defer { unlink(path) }
        let listener = try UnixSocket.listening(path: path)
        defer { close(listener) }

        let client = try #require(UnixSocket.connected(path: path))
        close(client)
        var info = stat()
        #expect(stat(path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
    }

    @Test func bothEndsCloseOnExec() throws {
        let path = path()
        defer { unlink(path) }
        let listener = try UnixSocket.listening(path: path)
        defer { close(listener) }
        let client = try #require(UnixSocket.connected(path: path))
        defer { close(client) }

        #expect(fcntl(listener, F_GETFD) & FD_CLOEXEC != 0)
        #expect(fcntl(client, F_GETFD) & FD_CLOEXEC != 0)
    }

    @Test func aStaleFileAtThePathIsReplaced() throws {
        let path = path()
        defer { unlink(path) }
        FileManager.default.createFile(atPath: path, contents: Data("stale".utf8))

        let listener = try UnixSocket.listening(path: path)
        close(listener)
    }

    @Test func aPathTooLongForTheAddressIsRefused() {
        let path = "/tmp/" + String(repeating: "a", count: 200) + ".sock"

        #expect(UnixSocket.address(for: path) == nil)
        #expect(throws: UnixSocket.Failure.pathTooLong(path)) { try UnixSocket.listening(path: path) }
    }

    @Test func connectingWhereNothingListensFails() {
        #expect(UnixSocket.connected(path: path()) == nil)
    }
}
