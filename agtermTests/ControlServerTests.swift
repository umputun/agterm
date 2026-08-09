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

    private func makeServer() -> ControlServer {
        let library = WindowLibrary(directory: stateDir)
        let server = ControlServer(
            library: library,
            actions: AppActions(library: library),
            settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
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
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = address(for: path)
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
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
