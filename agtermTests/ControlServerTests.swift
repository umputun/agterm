import Darwin
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for `ControlServer`'s bind lifecycle. The server is `@MainActor` and needs the real
/// window library, so this cannot move to `agtermCore`.
@MainActor
final class ControlServerTests: XCTestCase {
    private var stateDir: URL!
    private var socketPath: String!
    private var servers: [ControlServer] = []

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-control-server-tests-\(UUID().uuidString)", isDirectory: true)
            // NOT under stateDir: the hosted app's container path alone can exceed sun_path's ~104 bytes,
            // which start() refuses before it reaches anything this file tests.
            socketPath = "/tmp/agterm-test-\(UUID().uuidString.prefix(8)).sock"
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            for server in servers { server.stop() }
            servers.removeAll()
            unlink(socketPath)
            unlink(socketPath + ".lock")
            try? FileManager.default.removeItem(at: stateDir)
        }
        try await super.tearDown()
    }

    func testStartBindsAndStopUnlinksThePath() {
        let server = makeServer()
        server.start()

        XCTAssertEqual(server.boundSocketPath, socketPath, "start should bind the resolved path")
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath), "bind should create the socket node")

        server.stop()
        XCTAssertNil(server.boundSocketPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath), "stop should unlink the path")
    }

    /// The defect this pins: a second instance resolving the same path used to unlink the first one's live
    /// socket and bind its own, leaving the first listening on an fd nothing could reach again.
    func testStartRefusesAPathAnotherInstanceIsServing() {
        let first = makeServer()
        first.start()
        XCTAssertNotNil(first.boundSocketPath, "the first server should own the path")

        let second = makeServer()
        second.start()

        XCTAssertNil(second.boundSocketPath, "the second server should refuse rather than displace the first")
        XCTAssertEqual(first.boundSocketPath, socketPath, "the first server should still hold the path")
        XCTAssertTrue(connects(to: socketPath), "the first server should still be reachable through the path")
    }

    /// The refusal is only half the guard: `stop()` returning early on the refused instance is what stops
    /// it unlinking the owner's socket on quit, which is the second half of the original orphaning.
    func testARefusedServerStopDoesNotUnlinkTheOwnersSocket() {
        let first = makeServer()
        first.start()

        let second = makeServer()
        second.start()
        second.stop()

        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath),
                      "the refused server's stop should leave the owner's socket node in place")
        XCTAssertEqual(first.boundSocketPath, socketPath)
        XCTAssertTrue(connects(to: socketPath), "the owner should still be reachable after the refusal quits")
    }

    /// A refused instance must not advertise a path it does not serve: every shell it spawns would carry
    /// the OTHER instance's socket in `AGTERM_SOCKET` and drive that app instead. It advertises an
    /// unbindable path rather than nothing, because the status hooks read an ABSENT variable as
    /// "resolve the default", which is that same other instance.
    ///
    /// Refusal must be known WITHOUT `start()`: the launch window's surfaces snapshot the environment
    /// during the initial render pass, and `start()` only runs from the scene's `.task` afterwards, so a
    /// refusal decided there would reach that first shell too late.
    func testARefusedServerAdvertisesAnUnbindablePathBeforeStart() {
        let first = makeServer()
        first.start()
        XCTAssertEqual(first.resolvedSocketPath, socketPath, "the owner should advertise its path")

        let second = makeServer()

        XCTAssertEqual(second.resolvedSocketPath, socketPath + ControlServer.unavailableSuffix,
                       "a refused server should advertise a path nothing serves, from construction on")
        XCTAssertFalse(connects(to: second.resolvedSocketPath), "that path must not connect anywhere")
        XCTAssertNotEqual(second.resolvedSocketPath, socketPath, "and must not be the owner's")

        second.start()
        XCTAssertEqual(second.resolvedSocketPath, socketPath + ControlServer.unavailableSuffix,
                       "start should not change it")
    }

    /// The lock is taken in `init`, so `stop()` has to release it even when `start()` never bound —
    /// otherwise an instance that failed to bind holds the path against every later one for its lifetime.
    func testStopReleasesALockTakenWithoutBinding() {
        let never = makeServer()
        XCTAssertEqual(never.resolvedSocketPath, socketPath, "precondition: it owns the path from init")

        never.stop()

        let next = makeServer()
        XCTAssertEqual(next.resolvedSocketPath, socketPath, "the freed lock should let the next server own it")
        next.start()
        XCTAssertEqual(next.boundSocketPath, socketPath)
    }

    /// `start()` re-runs from every window scene's task, so a server refused while the owner was alive
    /// reaches it again once the owner quits. It must then serve — and advertise — the real path.
    func testAServerThatBindsAfterRefusingAdvertisesTheRealPath() {
        let first = makeServer()
        first.start()

        let second = makeServer()
        second.start()
        XCTAssertNil(second.boundSocketPath, "precondition: the second server was refused")

        first.stop()
        second.start()

        XCTAssertEqual(second.boundSocketPath, socketPath, "the freed path should be bindable")
        XCTAssertEqual(second.resolvedSocketPath, socketPath,
                       "a server that went on to bind must stop advertising the unavailable path")
        XCTAssertTrue(connects(to: socketPath))
    }

    /// A live owner whose backlog is saturated answers `connect` with the same ECONNREFUSED a dead socket
    /// node returns, so ownership cannot rest on a connect probe. Fill the backlog and quit accepting.
    func testStartRefusesAnOwnerWhoseBacklogIsSaturated() {
        let first = makeServer()
        first.start()
        XCTAssertNotNil(first.boundSocketPath)

        // the first connection is accepted and parks the serial loop in a read that only times out after
        // ControlServer.readTimeoutSeconds, so everything after it queues until the backlog is full.
        var clients: [Int32] = []
        defer { for fd in clients { close(fd) } }
        for _ in 0..<24 {
            let fd = connectFD(to: socketPath)
            if fd < 0 { break }
            clients.append(fd)
        }
        XCTAssertFalse(connects(to: socketPath), "the fixture should have saturated the listen backlog")

        let second = makeServer()
        second.start()

        XCTAssertNil(second.boundSocketPath, "a saturated owner is still an owner")
        XCTAssertEqual(first.boundSocketPath, socketPath)
    }

    func testStartBindsOverAForceQuitLeftover() {
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(stale, 0)
        XCTAssertTrue(bindListener(stale, at: socketPath), "the fixture should leave a listening socket behind")
        // close WITHOUT unlink: exactly what a force-quit that skipped applicationWillTerminate leaves.
        close(stale)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        let server = makeServer()
        server.start()

        XCTAssertEqual(server.boundSocketPath, socketPath, "a leftover node should be unlinked and rebound")
        XCTAssertTrue(connects(to: socketPath))
    }

    /// The defect this pins: answering with the `DecodingError`'s `localizedDescription` says only "the data
    /// couldn't be read" and never names the `cmd`, which is what tells a caller its agterm is older than its
    /// agtermctl.
    func testAnUnknownCommandErrorNamesTheRejectedCmd() {
        let server = makeServer()
        server.start()
        XCTAssertEqual(server.boundSocketPath, socketPath, "precondition: the server should be serving")

        let response = roundTrip(#"{"cmd":"restore.bogus"}"#)

        XCTAssertNotNil(response, "a malformed request should still get a response")
        XCTAssertTrue(response?.contains("restore.bogus") ?? false,
                      "the error should name the rejected cmd, got: \(response ?? "nil")")
    }

    private func makeServer() -> ControlServer {
        let library = WindowLibrary(directory: stateDir)
        let server = ControlServer(
            library: library,
            actions: AppActions(library: library),
            settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
            identity: AppIdentity(version: "9.9.9"),
            socketPath: socketPath
        )
        servers.append(server)
        return server
    }

    private func address(for path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: bytes.count) { buf in
                bytes.withUnsafeBufferPointer { src in buf.update(from: src.baseAddress!, count: src.count) }
            }
        }
        return addr
    }

    private func connects(to path: String) -> Bool {
        let fd = connectFD(to: path)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// A connected fd the caller keeps open, or -1. Holding them is what saturates the listen backlog.
    private func connectFD(to path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = address(for: path)
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        if !ok { close(fd); return -1 }
        return fd
    }

    /// One request line in, one response line out. Safe to block this main-actor test on the read: a decode
    /// failure is answered from `acceptQueue` before `handleConnection` hops to the main actor at all.
    private func roundTrip(_ line: String) -> String? {
        let fd = connectFD(to: socketPath)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let payload = Array((line + "\n").utf8)
        let written = payload.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == payload.count else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBufferPointer { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count > 0 else { return nil }
        return String(decoding: buffer[0..<count], as: UTF8.self)
    }

    private func bindListener(_ fd: Int32, at path: String) -> Bool {
        var addr = address(for: path)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return bound == 0 && listen(fd, 1) == 0
    }
}
