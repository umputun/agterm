import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerCompanionPageTests: XCTestCase {
    private final class Client: @unchecked Sendable {
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
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 }
            }
            guard connected else {
                close(descriptor)
                return nil
            }
            var wait = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
            fd = descriptor
        }

        func send(_ text: String) {
            let payload = Array((text + "\n").utf8)
            _ = payload.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
        }

        func send(_ frame: PageServeFrame) {
            guard let line = try? PageServeCodec.encode(frame) else { return }
            _ = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        }

        func readLine() -> String? {
            while true {
                if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    return line
                }
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                let count = read(fd, &chunk, chunk.count)
                guard count > 0 else { return nil }
                buffer.append(contentsOf: chunk[0..<count])
            }
        }

        func frame() -> PageServeFrame? { readLine().flatMap { try? PageServeCodec.decode(Data($0.utf8)) } }
    }

    private final class Box<T>: @unchecked Sendable { var value: T? }

    private var stateDir: URL!
    private var socketPath: String!
    private var docs: URL!
    private var server: ControlServer!
    private var store: AppStore!
    private var parent: Session!
    private var clients: [Client] = []

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-companion-page-\(UUID().uuidString)")
        socketPath = "/tmp/agterm-cpg-\(UUID().uuidString.prefix(8)).sock"
        docs = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-cpg-docs-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try Data("<p>index</p>".utf8).write(to: docs.appendingPathComponent("index.html"))
        let library = WindowLibrary(directory: stateDir)
        server = ControlServer(library: library, actions: AppActions(library: library),
                               settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
                               identity: AppIdentity(version: "9.9.9"), socketPath: socketPath)
        server.start()
        XCTAssertNotNil(server.boundSocketPath)
        store = try XCTUnwrap(library.activeStore)
        parent = try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.currentWorkspaceID), cwd: NSHomeDirectory()))
    }

    override func tearDown() async throws {
        for client in clients { close(client.fd) }
        clients.removeAll()
        server.stop()
        server = nil
        unlink(socketPath)
        unlink(socketPath + ".lock")
        try? FileManager.default.removeItem(at: stateDir)
        try? FileManager.default.removeItem(at: docs)
        try await super.tearDown()
    }

    func testEachViewerClaimsItsOwnAttachmentAndOneLeavingEndsNeitherThePageNorTheOther() throws {
        let page = try filePage()
        let first = try attach(page)
        let second = try attach(page)

        let (one, reply) = try claim(first.token)
        XCTAssertTrue(try XCTUnwrap(reply).contains(#""ok":true"#))
        XCTAssertTrue(try XCTUnwrap(claim(first.token).1).contains("page not claimable"), "a token is claimed once")
        let (two, _) = try claim(second.token)
        waitUntil("both channels adopted") { self.server.companionPageStreams.count == 2 }

        close(one.fd)
        clients.removeAll { $0 === one }
        waitUntil("the closed attachment is gone") { self.server.companionPageStreams.count == 1 }

        XCTAssertNotNil(store.session(withID: page.id), "a viewer leaving ends nothing on this Mac")
        let index = docs.appendingPathComponent("index.html").path
        let served = offMain { () -> PageServeFrame? in
            two.send(.resource(id: 1, path: index))
            return two.frame()
        }
        XCTAssertEqual(served ?? nil, .head(id: 1, mimeType: "text/html"))
    }

    func testAnExpiredOrUnansweredClaimLeavesThePageAlone() throws {
        let page = try filePage()
        var now = Date()
        server.hudClock = { now }
        let stale = try attach(page)
        now = now.addingTimeInterval(AppStore.pageClaimWindow + 1)
        XCTAssertEqual(server.claimPageServe(stale.token).error, "page not claimable")

        let fresh = try attach(page)
        let claimed = try XCTUnwrap(server.claimPageServe(fresh.token).result?.id.flatMap(UUID.init(uuidString:)))
        server.pageClaimUnanswered(claimed)

        XCTAssertNotNil(store.session(withID: page.id))
        XCTAssertTrue(server.pendingCompanionClaims.isEmpty)
    }

    func testClosingThePageHereEndsEveryAttachmentAndEveryUnclaimedToken() throws {
        let page = try filePage()
        let (one, _) = try claim(try attach(page).token)
        let (two, _) = try claim(try attach(page).token)
        let unclaimed = try attach(page)
        waitUntil("both channels adopted") { self.server.companionPageStreams.count == 2 }

        store.closeSession(page.id)

        let ends = offMain { [one.readLine(), two.readLine()] }
        XCTAssertEqual(ends?.compactMap { $0 }, [], "both channels end")
        waitUntil("no attachment remains") { self.server.companionPageStreams.isEmpty }
        XCTAssertNil(server.companionPageTokens[unclaimed.token])
    }

    // a soft-closed page's window came from the live rows only, so its requests reached the frontmost window
    func testASoftClosedPageStillAnswersForItsOwnWindow() throws {
        let page = try filePage()
        let window = try XCTUnwrap(server.library.windowID(for: store))
        let serving = CompanionPageServing(claim: UUID(), session: page.id, page: try XCTUnwrap(page.htmlOverlay?.id))

        XCTAssertTrue(store.softCloseSession(page.id))

        XCTAssertEqual(server.companionPagePlace(serving)?.window, window)
    }

    func testOnlyAPageCompanionIsHandedOutAndALoopbackPageIsNot() throws {
        XCTAssertEqual(server.attachCompanionPage(parent.id.uuidString, window: nil).error, "not a page companion")
        let loopback = try store.addPageCompanion(to: parent.id, overlay: HtmlOverlay(source: .url(try XCTUnwrap(URL(string: "http://localhost:3000/"))))).get()
        XCTAssertEqual(server.attachCompanionPage(loopback.id.uuidString, window: nil).error,
                       "a page on this Mac's loopback cannot be shown on another Mac")
    }

    func testAUrlAttachmentHasALifetimeChannelAndNoBridge() throws {
        let page = try store.addPageCompanion(to: parent.id, overlay: HtmlOverlay(source: .url(try XCTUnwrap(URL(string: "https://example.com/"))))).get()
        let (client, reply) = try claim(try attach(page).token)
        XCTAssertTrue(try XCTUnwrap(reply).contains(#""ok":true"#))
        waitUntil("the channel adopted") { self.server.companionPageStreams.count == 1 }

        let answer = offMain { () -> PageServeFrame? in
            client.send(.bridge(id: 4, request: #"{"cmd":"tree"}"#))
            return client.frame()
        }
        XCTAssertEqual(answer ?? nil, .failure(id: 4, error: "a URL page has no bridge"))
    }

    private func filePage() throws -> Session {
        let index = docs.appendingPathComponent("index.html").path
        return try store.addPageCompanion(to: parent.id, overlay: HtmlOverlay(source: .file(path: index, grantRoot: docs.path))).get()
    }

    private func attach(_ page: Session) throws -> PresentationPage {
        let reply = server.attachCompanionPage(page.id.uuidString, window: nil)
        XCTAssertEqual(reply.result?.parent, parent.id.uuidString)
        return try XCTUnwrap(reply.result?.companionPage, reply.error ?? "")
    }

    private func claim(_ token: String) throws -> (Client, String?) {
        let client = try XCTUnwrap(Client(path: socketPath))
        clients.append(client)
        let reply = offMain { () -> String? in
            client.send(#"{"cmd":"session.overlay.page.serve","target":"\#(token)"}"#)
            return client.readLine()
        } ?? nil
        return (client, reply)
    }

    private func offMain<T: Sendable>(_ body: @escaping @Sendable () -> T) -> T? {
        let done = expectation(description: "client work finished")
        let box = Box<T>()
        Thread {
            box.value = body()
            done.fulfill()
        }.start()
        wait(for: [done], timeout: 15)
        return box.value
    }

    private func waitUntil(_ what: String, _ condition: @escaping @MainActor () -> Bool) {
        let met = expectation(description: what)
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(8)
            while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
            met.fulfill()
        }
        wait(for: [met], timeout: 10)
        XCTAssertTrue(condition(), what)
    }
}
