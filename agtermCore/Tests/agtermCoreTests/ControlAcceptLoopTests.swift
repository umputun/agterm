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
        let refused = connectRefused(within: 1)
        #expect(refused, "finish closes the listener; holders: \(refused ? "" : holders())")
    }

    // a posix_spawn running in parallel, as other suites do, keeps a just-closed listener connectable for a moment
    private func connectRefused(within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            guard let fd = UnixSocket.connected(path: path) else { return true }
            close(fd)
            if Date() >= deadline { return false }
            usleep(10_000)
        }
    }

    private func holders() -> String {
        guard let lsof = ["/usr/sbin/lsof", "/usr/bin/lsof"].first(where: FileManager.default.isExecutableFile(atPath:)) else {
            return "no lsof"
        }
        let log = path + ".lsof"
        defer { unlink(log) }
        guard FileManager.default.createFile(atPath: log, contents: nil), let output = FileHandle(forWritingAtPath: log) else {
            return "no lsof output file"
        }
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsof)
        process.arguments = ["-w", "-n", path]
        process.standardOutput = output
        process.standardError = output
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return "lsof failed: \(error)" }
        guard done.wait(timeout: .now() + 10) == .success else {
            kill(process.processIdentifier, SIGKILL)
            _ = done.wait(timeout: .now() + 2)
            return "lsof timed out"
        }
        return (try? String(contentsOfFile: log, encoding: .utf8)) ?? "lsof output unreadable"
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
