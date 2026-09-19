import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerOverlayJobsTests: XCTestCase {
    private final class HelperClient: @unchecked Sendable {
        let fd: Int32
        private var buffer = Data()

        init?(path: String) {
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { return nil }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = path.utf8CString
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: bytes.count) { buf in
                    bytes.withUnsafeBufferPointer { src in buf.update(from: src.baseAddress!, count: src.count) }
                }
            }
            let connected = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    connect(descriptor, sa, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
                }
            }
            guard connected else {
                close(descriptor)
                return nil
            }
            var wait = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
            fd = descriptor
        }

        func send(_ line: String) {
            let payload = Array((line + "\n").utf8)
            _ = payload.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
        }

        func send(_ frame: OverlayJobFrame) {
            guard let line = try? frame.line() else { return }
            _ = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        }

        func readLine() -> String? {
            while true {
                if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    return line
                }
                var chunk = [UInt8](repeating: 0, count: 4096)
                let count = read(fd, &chunk, chunk.count)
                guard count > 0 else { return nil }
                buffer.append(contentsOf: chunk[0..<count])
            }
        }

        func frame() -> OverlayJobFrame? {
            readLine().flatMap { try? JSONDecoder().decode(OverlayJobFrame.self, from: Data($0.utf8)) }
        }
    }

    private final class Box<T>: @unchecked Sendable { var value: T? }

    static let context = OverlayLaunchContext(command: "revdiff", cwd: "/tmp", sessionEnvironment: ["AGTERM_ENABLED": "1"])

    private var stateDir: URL!
    private var socketPath: String!
    private var servers: [ControlServer] = []
    private var clients: [HelperClient] = []

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-overlay-jobs-tests-\(UUID().uuidString)", isDirectory: true)
        socketPath = "/tmp/agterm-job-\(UUID().uuidString.prefix(8)).sock"
    }

    override func tearDown() async throws {
        for client in clients { close(client.fd) }
        clients.removeAll()
        for server in servers { server.stop() }
        servers.removeAll()
        unlink(socketPath)
        unlink(socketPath + ".lock")
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
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
        server.start()
        XCTAssertNotNil(server.boundSocketPath)
        return server
    }

    private func offMain<T: Sendable>(_ body: @escaping @Sendable () -> T) -> T? {
        let done = expectation(description: "helper work finished")
        let box = Box<T>()
        Thread {
            box.value = body()
            done.fulfill()
        }.start()
        wait(for: [done], timeout: 10)
        return box.value
    }

    private func waitUntil(_ what: String, _ condition: @escaping @MainActor () -> Bool) {
        let met = expectation(description: what)
        Task { @MainActor in
            while !condition() { try? await Task.sleep(nanoseconds: 20_000_000) }
            met.fulfill()
        }
        wait(for: [met], timeout: 5)
    }

    private func claim(_ job: String) throws -> (HelperClient, String?, OverlayJobFrame?) {
        let client = try XCTUnwrap(HelperClient(path: socketPath))
        clients.append(client)
        let result = offMain { () -> (String?, OverlayJobFrame?) in
            client.send(#"{"cmd":"session.overlay.job.run","target":"\#(job)"}"#)
            let reply = client.readLine()
            guard reply?.contains(#""ok":true"#) == true else { return (reply, nil) }
            return (reply, client.frame())
        }
        let (reply, frame) = try XCTUnwrap(result)
        return (client, reply, frame)
    }

    func testAClaimIsAnsweredOkAndGetsTheLaunchContext() throws {
        let server = makeServer()
        let job = server.overlayJobs.register(session: UUID(), pane: nil, owner: 1, context: Self.context)

        let (_, reply, frame) = try claim(job)

        XCTAssertTrue(try XCTUnwrap(reply).contains(#""ok":true"#))
        XCTAssertEqual(frame, .context(Self.context))
    }

    func testASecondClaimIsRefusedWithAnOrdinaryReply() throws {
        let server = makeServer()
        let job = server.overlayJobs.register(session: UUID(), pane: nil, owner: 1, context: Self.context)
        _ = try claim(job)

        let (_, reply, frame) = try claim(job)

        XCTAssertTrue(try XCTUnwrap(reply).contains("job not claimable"))
        XCTAssertNil(frame)
    }

    func testTheHelpersReportsReachTheTable() throws {
        let server = makeServer()
        let job = server.overlayJobs.register(session: UUID(), pane: nil, owner: 1, context: Self.context)
        let (client, _, _) = try claim(job)

        client.send(.started)
        waitUntil("the job runs") { server.overlayJobs.job(job)?.state == .running }
        client.send(.exited(3))

        waitUntil("the job exited 3") { server.overlayJobs.job(job)?.state == .finished(.exited(3)) }
    }

    func testAHelperThatGoesAwayLeavesTheJobUnknown() throws {
        let server = makeServer()
        let job = server.overlayJobs.register(session: UUID(), pane: nil, owner: 1, context: Self.context)
        let (client, _, _) = try claim(job)
        client.send(.started)
        waitUntil("the job runs") { server.overlayJobs.job(job)?.state == .running }

        close(client.fd)
        clients.removeAll()

        waitUntil("the job ends unknown") { server.overlayJobs.job(job)?.state == .finished(.unknown) }
    }

    func testACancelReachesTheHelper() throws {
        let server = makeServer()
        let job = server.overlayJobs.register(session: UUID(), pane: nil, owner: 1, context: Self.context)
        let (client, _, _) = try claim(job)
        client.send(.started)
        waitUntil("the job runs") { server.overlayJobs.job(job)?.state == .running }

        XCTAssertTrue(server.overlayJobs.cancel(job))

        XCTAssertEqual(offMain { client.frame() } ?? nil, .cancel)
    }

    func testAnOpenJobConnectionLeavesTheAcceptThreadFree() throws {
        let server = makeServer()
        let job = server.overlayJobs.register(session: UUID(), pane: nil, owner: 1, context: Self.context)
        _ = try claim(job)
        let path = socketPath!

        let probe = offMain { () -> String? in
            guard let other = HelperClient(path: path) else { return nil }
            defer { close(other.fd) }
            other.send(#"{"cmd":"window.list"}"#)
            return other.readLine()
        }

        XCTAssertEqual(probe??.contains(#""ok":true"#), true, "a second client is served while the job runs")
    }
}
