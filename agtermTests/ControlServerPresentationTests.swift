import Darwin
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerPresentationTests: XCTestCase {
    private final class StreamClient: @unchecked Sendable {
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

        func frame() -> PresentationFrame? {
            readLine().flatMap { try? PresentationCodec.decode(Data($0.utf8)) }
        }
    }

    private var stateDir: URL!
    private var socketPath: String!
    private var servers: [ControlServer] = []
    private var clients: [StreamClient] = []

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-presentation-tests-\(UUID().uuidString)", isDirectory: true)
        socketPath = "/tmp/agterm-pres-\(UUID().uuidString.prefix(8)).sock"
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

    private func makeServer(backed: Bool = true) throws -> (ControlServer, AppStore, Session) {
        let library = WindowLibrary(directory: stateDir)
        let server = ControlServer(
            library: library,
            actions: AppActions(library: library),
            settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
            identity: AppIdentity(version: "9.9.9"),
            socketPath: socketPath
        )
        servers.append(server)
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: "/tmp"))
        session.surface = GhosttySurfaceView(workingDirectory: "/tmp", backedByZmx: backed)
        server.start()
        XCTAssertNotNil(server.boundSocketPath)
        return (server, store, session)
    }

    private func offMain<T: Sendable>(_ body: @escaping @Sendable () -> T) -> T? {
        let done = expectation(description: "client work finished")
        let box = Box<T>()
        Thread {
            box.value = body()
            done.fulfill()
        }.start()
        wait(for: [done], timeout: 10)
        return box.value
    }

    private final class Box<T>: @unchecked Sendable { var value: T? }
    private struct UnexpectedFrame: Error {}

    private func openStream(for session: Session) throws -> (StreamClient, PresentationSnapshot) {
        let client = try XCTUnwrap(StreamClient(path: socketPath))
        clients.append(client)
        let id = session.id.uuidString
        let opened = offMain { () -> (String?, PresentationFrame?, PresentationFrame?) in
            client.send(#"{"cmd":"zmx.present","target":"\#(id)"}"#)
            let reply = client.readLine()
            client.send(#"{"kind":"hello","gen":0,"rev":0,"hello":{"version":1,"kinds":["status","hud"],"mode":"mirror"}}"#)
            return (reply, client.frame(), client.frame())
        }
        let (reply, hello, snapshot) = try XCTUnwrap(opened)
        XCTAssertTrue(try XCTUnwrap(reply).contains(#""ok":true"#), reply ?? "")
        guard case .hello(let answer)? = hello?.body, case .snapshot(let state)? = snapshot?.body else {
            XCTFail("expected hello then a snapshot, got \(String(describing: hello)) and \(String(describing: snapshot))")
            throw UnexpectedFrame()
        }
        XCTAssertEqual(answer.kinds, ["status", "hud"])
        return (client, state)
    }

    func testAnOpenStreamLeavesTheAcceptThreadFree() throws {
        let (_, _, session) = try makeServer()
        _ = try openStream(for: session)
        let path = socketPath!

        let probe = offMain { () -> String? in
            guard let other = StreamClient(path: path) else { return nil }
            defer { close(other.fd) }
            other.send(#"{"cmd":"window.list"}"#)
            return other.readLine()
        }

        XCTAssertEqual(probe??.contains(#""ok":true"#), true, "a second client is served while the stream is open")
    }

    func testAStatusChangeReachesTheViewerAfterTheSnapshot() throws {
        let (_, store, session) = try makeServer()
        store.applyControlStatus(AgentIndicator(status: .active), forSession: session.id)
        let (client, snapshot) = try openStream(for: session)
        XCTAssertEqual(snapshot.status?.status, .active)

        store.applyControlStatus(AgentIndicator(status: .blocked, statusPane: .left), forSession: session.id)

        let frame = try XCTUnwrap(offMain { client.frame() } ?? nil)
        guard case .status(let status) = frame.body else { return XCTFail("expected status, got \(frame)") }
        XCTAssertEqual(status?.status, .blocked)
        XCTAssertEqual(status?.pane, .identity(session.paneIdentity))
    }

    func testAClientThatGoesAwayIsUnsubscribed() throws {
        let (server, _, session) = try makeServer()
        let (client, _) = try openStream(for: session)
        XCTAssertEqual(server.presentationHub.subscriberCount(session: session.id), 1)

        close(client.fd)
        clients.removeAll()

        waitForRelease(of: session, by: server)
    }

    private func waitForRelease(of session: Session, by server: ControlServer) {
        let gone = expectation(description: "the stream was released")
        Task { @MainActor in
            while server.presentationHub.subscriberCount(session: session.id) != 0
                    || !server.presentationStreams.isEmpty {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            gone.fulfill()
        }
        wait(for: [gone], timeout: 5)
    }

    func testStoppingTheServerEndsItsStreams() throws {
        let (server, _, session) = try makeServer()
        let (client, _) = try openStream(for: session)

        server.stop()

        let next = offMain { client.readLine() }
        XCTAssertNil(next ?? nil, "the viewer sees end of stream")
    }

    func testASessionThatIsNotLiveBackedIsRefusedWithAnOrdinaryReply() throws {
        let (server, _, session) = try makeServer(backed: false)
        let client = try XCTUnwrap(StreamClient(path: socketPath))
        clients.append(client)
        let id = session.id.uuidString

        let reply = offMain { () -> String? in
            client.send(#"{"cmd":"zmx.present","target":"\#(id)"}"#)
            return client.readLine()
        }

        XCTAssertEqual(reply??.contains(#""ok":false"#), true)
        XCTAssertEqual(reply??.contains("not live-backed"), true)
        XCTAssertTrue(server.presentationStreams.isEmpty)
    }

    func testAPeerThatNeverSendsHelloIsDroppedAfterTheDeadline() throws {
        let (server, _, session) = try makeServer()
        server.presentationHelloDeadline = 0.2
        let client = try XCTUnwrap(StreamClient(path: socketPath))
        clients.append(client)
        let id = session.id.uuidString

        let next = offMain { () -> String? in
            client.send(#"{"cmd":"zmx.present","target":"\#(id)"}"#)
            _ = client.readLine()
            return client.readLine()
        }

        XCTAssertNil(next ?? nil, "silence after the reply ends in end of stream, well inside the client's 3s wait")
        waitForRelease(of: session, by: server)
    }

    func testAStreamEndsWhenItsSourceSessionIsClosed() throws {
        let (server, store, session) = try makeServer()
        let (client, _) = try openStream(for: session)

        store.closeSession(session.id)
        server.refreshWindowCache()

        let next = offMain { client.readLine() }
        XCTAssertNil(next ?? nil)
    }

    func testAnOutgoingFrameOverTheLimitEndsTheStreamRatherThanVanishing() throws {
        let (_, store, session) = try makeServer()
        let (client, _) = try openStream(for: session)

        store.recordNotificationEvent(forSession: session.id, title: "big",
                                      body: String(repeating: "x", count: PresentationCodec.maxFrameBytes),
                                      origin: .control)

        let next = offMain { client.readLine() }
        XCTAssertNil(next ?? nil)
    }

    func testAFloodingViewerBacksUpIntoItsOwnSocketWhileTheMainActorIsBusy() throws {
        let (_, _, session) = try makeServer()
        let (client, _) = try openStream(for: session)
        let flags = fcntl(client.fd, F_GETFL)
        XCTAssertEqual(fcntl(client.fd, F_SETFL, flags | O_NONBLOCK), 0)
        let line = Array((#"{"kind":"ping","gen":0,"rev":0}"# + "\n").utf8)
        let total = line.count * 8000
        let flood = Flood()
        let fd = client.fd

        let writer = Thread {
            var offset = 0
            while !flood.stopped, flood.written < total {
                let count = line[offset...].withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    flood.add(count)
                    offset = (offset + count) % line.count
                } else {
                    usleep(1000)
                }
            }
            flood.finish()
        }
        writer.start()
        Thread.sleep(forTimeInterval: 0.8)
        flood.stop()
        flood.waitUntilFinished()

        XCTAssertLessThan(flood.written, total / 2,
                          "with the main actor held, a bounded handoff takes a few dozen lines and the socket buffers; an unbounded one takes everything the writer retries")
    }

    private final class Flood: @unchecked Sendable {
        private let lock = NSLock()
        private let done = DispatchSemaphore(value: 0)
        private var bytes = 0
        private var stopping = false

        var written: Int { lock.withLock { bytes } }
        var stopped: Bool { lock.withLock { stopping } }
        func add(_ count: Int) { lock.withLock { bytes += count } }
        func stop() { lock.withLock { stopping = true } }
        func finish() { done.signal() }
        func waitUntilFinished() { done.wait() }
    }

    func testAStreamThatDoesNotOpenWithHelloIsClosed() throws {
        let (_, _, session) = try makeServer()
        let client = try XCTUnwrap(StreamClient(path: socketPath))
        clients.append(client)
        let id = session.id.uuidString

        let next = offMain { () -> String? in
            client.send(#"{"cmd":"zmx.present","target":"\#(id)"}"#)
            _ = client.readLine()
            client.send(#"{"kind":"ping","gen":0,"rev":0}"#)
            return client.readLine()
        }

        XCTAssertNil(next ?? nil)
    }
}
