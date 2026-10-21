import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerPageServeTests: XCTestCase {
    private final class HelperClient: @unchecked Sendable {
        let fd: Int32
        private var buffer = Data()

        convenience init?(path: String) {
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
            self.init(fd: descriptor)
        }

        init(fd: Int32) {
            var wait = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
            self.fd = fd
        }

        func send(_ line: String) {
            let payload = Array((line + "\n").utf8)
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

        func frame() -> PageServeFrame? {
            readLine().flatMap { try? PageServeCodec.decode(Data($0.utf8)) }
        }

        func body(_ id: Int) -> (mime: String?, data: Data, error: String?) {
            var mime: String?
            var data = Data()
            while let frame = frame() {
                switch frame {
                case .head(id, let type): mime = type
                case .chunk(id, let bytes): data.append(bytes)
                case .end(id): return (mime, data, nil)
                case .failure(id, let error): return (mime, data, error)
                default: continue
                }
            }
            return (mime, data, "channel closed")
        }
    }

    private final class Sink: PresentationSink {
        var frames: [PresentationFrame] = []

        func offer(_ frame: PresentationFrame) -> Bool {
            frames.append(frame)
            return true
        }

        func close(_: PresentationHub.CloseReason) {}

        var bodies: [PresentationFrame.Body] { frames.map(\.body) }

        var token: String? { bodies.compactMap { if case .pageRequest(let r) = $0 { r.token } else { nil } }.last }
    }

    private final class Box<T>: @unchecked Sendable { var value: T? }

    private var stateDir: URL!
    private var socketPath: String!
    private var docs: URL!
    private var servers: [ControlServer] = []
    private var clients: [HelperClient] = []
    private var leads: [UUID] = []

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-page-serve-tests-\(UUID().uuidString)", isDirectory: true)
        socketPath = "/tmp/agterm-page-\(UUID().uuidString.prefix(8)).sock"
        docs = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-page-docs-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try Data("<p>index</p>".utf8).write(to: docs.appendingPathComponent("index.html"))
    }

    override func tearDown() async throws {
        for client in clients { close(client.fd) }
        clients.removeAll()
        for server in servers { server.stop() }
        servers.removeAll()
        for pane in leads { ZmxLeadBook.shared.forget(pane: pane) }
        RemotePageEnds.shared.onEnd = nil
        unlink(socketPath)
        unlink(socketPath + ".lock")
        try? FileManager.default.removeItem(at: stateDir)
        try? FileManager.default.removeItem(at: docs)
        try await super.tearDown()
    }

    private struct Fixture {
        let server: ControlServer
        let store: AppStore
        let session: Session
        let presenter: Sink
        let presenterID: PresentationHub.SubscriberID
    }

    private func fixture(responseWriter: @escaping ControlServer.ResponseWriter = ControlServer.writeResponse) throws -> Fixture {
        let library = WindowLibrary(directory: stateDir)
        let server = ControlServer(
            library: library,
            actions: AppActions(library: library),
            settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
            identity: AppIdentity(version: "9.9.9"),
            socketPath: socketPath,
            responseWriter: responseWriter
        )
        servers.append(server)
        server.start()
        server.attachPresentationHub()
        XCTAssertNotNil(server.boundSocketPath)
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory()))
        let attachment = ZmxLeadAttachment(claim: false)
        ZmxLeadBook.shared.begin(attachment, pane: session.paneIdentity)
        let notice = try XCTUnwrap(ZmxLeadNotice(title: "zmx-role;\(attachment.nonce):follower:1"))
        _ = ZmxLeadBook.shared.apply(notice, pane: session.paneIdentity)
        leads.append(session.paneIdentity)
        let presenter = Sink()
        let hello = PresentationHello(version: 1, kinds: PresentationHub.supportedKinds, mode: .presenter)
        let id = try server.presentationHub.subscribe(session: session.id, hello: hello, sink: presenter) {
            PresentationSnapshot(status: nil, hud: nil)
        }
        server.presentationHub.receive(PresentationFrame(gen: presenter.frames[0].gen, rev: 0, body: .presenterAcquire), from: id)
        return Fixture(server: server, store: store, session: session, presenter: presenter, presenterID: id)
    }

    private func openFile(_ fix: Fixture, grant: Bool = true) throws -> UUID {
        let options = ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: nil,
                                                       backgroundColor: nil, page: .file(path: docs.appendingPathComponent("index.html").path,
                                                                                         grantRoot: grant ? docs.path : nil),
                                                       javascript: true)
        let response = fix.server.openSessionOverlay(fix.session.id.uuidString, window: nil, options: options)
        XCTAssertTrue(response.ok, response.error ?? "")
        return try XCTUnwrap(response.result?.pageID.flatMap(UUID.init(uuidString:)))
    }

    private func offMain<T: Sendable>(_ body: @escaping @Sendable () -> T) -> T? {
        let done = expectation(description: "helper work finished")
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

    private func claim(_ token: String) throws -> (HelperClient, String?) {
        let client = try XCTUnwrap(HelperClient(path: socketPath))
        clients.append(client)
        let reply = offMain { () -> String? in
            client.send(#"{"cmd":"session.overlay.page.serve","target":"\#(token)"}"#)
            return client.readLine()
        } ?? nil
        return (client, reply)
    }

    func testARemoteOpenSkipsTheLocalPageFollowAndStore() throws {
        let fix = try fixture()
        let other = try XCTUnwrap(fix.store.addSession(toWorkspace: try XCTUnwrap(fix.store.currentWorkspaceID), cwd: "/tmp"))
        fix.store.selectSession(other.id)
        let options = ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil,
                                                       follow: true, page: .url(try XCTUnwrap(URL(string: "https://example.com/a?b=1"))),
                                                       persistent: true)

        let response = fix.server.openSessionOverlay(fix.session.id.uuidString, window: nil, options: options)

        XCTAssertTrue(response.ok, response.error ?? "")
        let page = try XCTUnwrap(response.result?.pageID.flatMap(UUID.init(uuidString:)))
        XCTAssertNil(HtmlOverlayRegistry.shared.existing(page))
        XCTAssertEqual(fix.store.selectedSessionID, other.id)
        XCTAssertFalse(fix.session.overlayActive)
        XCTAssertNotNil(fix.presenter.token)
    }

    func testALoopbackUrlForThePresenterIsRefused() throws {
        let fix = try fixture()
        let options = ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil,
                                                       page: .url(try XCTUnwrap(URL(string: "http://localhost:8080/"))))
        let response = fix.server.openSessionOverlay(fix.session.id.uuidString, window: nil, options: options)
        XCTAssertEqual(response.error, OverlayHtmlError.remoteLoopback)
    }

    func testAPageTooLargeForOneFrameIsRefused() throws {
        let fix = try fixture()
        let query = String(repeating: "q", count: PresentationCodec.maxFrameBytes)
        let options = ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil,
                                                       page: .url(try XCTUnwrap(URL(string: "https://example.com/?q=\(query)"))))
        let response = fix.server.openSessionOverlay(fix.session.id.uuidString, window: nil, options: options)
        XCTAssertEqual(response.error, OverlayHtmlError.remoteTooLarge)
        XCTAssertTrue(fix.session.remoteOverlays.slots.isEmpty)
        XCTAssertFalse(fix.session.overlayActive)
    }

    func testAClaimedChannelServesThePageAndAFileInsideItsGrant() throws {
        let fix = try fixture()
        let big = Data((0..<200_000).map { UInt8($0 % 251) })
        try big.write(to: docs.appendingPathComponent("big.bin"))
        _ = try openFile(fix)
        let (client, reply) = try claim(try XCTUnwrap(fix.presenter.token))
        XCTAssertTrue(try XCTUnwrap(reply).contains(#""ok":true"#))
        let index = docs.appendingPathComponent("index.html").path, bigPath = docs.appendingPathComponent("big.bin").path

        let served = offMain { () -> [(String?, Data, String?)] in
            client.send(.resource(id: 1, path: index))
            let first = client.body(1)
            client.send(.resource(id: 2, path: bigPath))
            return [first, client.body(2)]
        }

        let answers = try XCTUnwrap(served)
        XCTAssertEqual(answers[0].0, "text/html")
        XCTAssertEqual(answers[0].1, Data("<p>index</p>".utf8))
        XCTAssertNil(answers[1].2)
        XCTAssertEqual(answers[1].1, big)
    }

    func testAFileOutsideTheGrantIsRefusedOnTheChannel() throws {
        let fix = try fixture()
        _ = try openFile(fix)
        let (client, _) = try claim(try XCTUnwrap(fix.presenter.token))
        let outside = docs.deletingLastPathComponent().appendingPathComponent("elsewhere.txt").path

        let answer = offMain { () -> String? in
            client.send(.resource(id: 1, path: outside))
            return client.body(1).error
        } ?? nil

        XCTAssertEqual(answer, "file is outside the page's folder")
    }

    func testACancelledTransferStopsAndTheNextRequestIsServed() throws {
        let fix = try fixture()
        try Data(count: 8 * 1024 * 1024).write(to: docs.appendingPathComponent("huge.bin"))
        _ = try openFile(fix)
        let (client, _) = try claim(try XCTUnwrap(fix.presenter.token))
        let huge = docs.appendingPathComponent("huge.bin").path, index = docs.appendingPathComponent("index.html").path

        let result = offMain { () -> (sawHugeEnd: Bool, index: Data?) in
            client.send(.resource(id: 1, path: huge))
            client.send(.cancel(id: 1))
            Thread.sleep(forTimeInterval: 0.3)
            client.send(.resource(id: 2, path: index))
            var sawHugeEnd = false
            var indexData = Data()
            while let frame = client.frame() {
                switch frame {
                case .end(1): sawHugeEnd = true
                case .chunk(2, let data): indexData.append(data)
                case .end(2): return (sawHugeEnd, indexData)
                default: continue
                }
            }
            return (sawHugeEnd, nil)
        }

        let answer = try XCTUnwrap(result)
        XCTAssertFalse(answer.sawHugeEnd)
        XCTAssertEqual(answer.index, Data("<p>index</p>".utf8))
    }

    func testARelayedSubmitIsRecordedOnThisMac() throws {
        let fix = try fixture()
        let page = try openFile(fix)
        let (client, _) = try claim(try XCTUnwrap(fix.presenter.token))

        let afterSubmit = offMain { () -> String? in
            client.send(.bridge(id: 7, request: #"{"cmd":"session.overlay.submit","args":{"value":"notes"}}"#))
            return client.readLine()
        } ?? nil

        XCTAssertNil(afterSubmit, "the submit closes the page, and its channel with it")
        XCTAssertEqual(HtmlPageOutcomes.shared.outcome(for: page)?.value, "notes")
        XCTAssertTrue(fix.presenter.bodies.contains(.pageClose(PresentationPageChange(page: page.uuidString))))
        XCTAssertTrue(fix.session.remoteOverlays.slots.isEmpty)
    }

    func testABridgeRequestForAPageThatEndedIsRefused() throws {
        let fix = try fixture()
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let peer = HelperClient(fd: pair[1])
        clients.append(peer)
        let owner = ControlStreamOwner(descriptor: pair[0], limits: ControlServer.pageServeLimits)
        let stream = PageServeStream(page: UUID(), source: .file(path: docs.appendingPathComponent("index.html").path,
                                                                 grantRoot: docs.path), owner: owner, server: fix.server)
        owner.start(onLine: { _ in }, onClose: {})
        defer { stream.shutdown() }
        XCTAssertTrue(stream.bridgeSlots.tryAcquire())

        stream.receive(.bridge(id: 3, request: #"{"cmd":"tree"}"#))

        XCTAssertEqual(offMain { peer.frame() } ?? nil, .failure(id: 3, error: "page closed"))
    }

    func testABridgeRequestAdmittedBeforeItsPageClosedDoesNotRun() throws {
        let fix = try fixture()
        let page = try openFile(fix)
        _ = try claim(try XCTUnwrap(fix.presenter.token))
        waitUntil("the channel is adopted") { fix.server.pageServeStreams[page] != nil }
        let stream = try XCTUnwrap(fix.server.pageServeStreams[page])
        XCTAssertTrue(stream.bridgeSlots.tryAcquire())

        stream.receive(.bridge(id: 4, request: #"{"cmd":"session.rename","args":{"name":"renamed"}}"#))
        fix.server.endRemotePage(page)

        waitUntil("the channel closes") { fix.server.pageServeStreams[page] == nil }
        XCTAssertNil(fix.session.customName)
    }

    func testAMalformedFrameEndsThePageAndKeepsThePresenter() throws {
        let fix = try fixture()
        let page = try openFile(fix)
        let (client, _) = try claim(try XCTUnwrap(fix.presenter.token))
        waitUntil("the channel is adopted") { fix.server.pageServeStreams[page] != nil }

        client.send("not a frame")

        waitUntil("the page ends") { fix.session.remoteOverlays.slots.isEmpty }
        XCTAssertEqual(HtmlPageOutcomes.shared.outcome(for: page)?.outcome, .dismissed)
        XCTAssertTrue(fix.presenter.bodies.contains(.pageClose(PresentationPageChange(page: page.uuidString))))
        XCTAssertTrue(fix.server.presentationHub.hasPresenter(session: fix.session.id))
        XCTAssertNil(offMain { client.readLine() } ?? nil)
    }

    func testAFileThatFailsToReadAnswersAFailure() throws {
        let fix = try fixture()
        let folder = docs.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try openFile(fix)
        let (client, _) = try claim(try XCTUnwrap(fix.presenter.token))

        let answer = offMain { () -> String? in
            client.send(.resource(id: 1, path: folder.path))
            return client.body(1).error
        } ?? nil

        XCTAssertEqual(answer, "file cannot be read")
    }

    func testShuttingDownWithPipelinedRequestsClosesTheChannel() throws {
        let fix = try fixture()
        try Data(count: 8 * 1024 * 1024).write(to: docs.appendingPathComponent("huge.bin"))
        let page = try openFile(fix)
        let (client, _) = try claim(try XCTUnwrap(fix.presenter.token))
        waitUntil("the channel is adopted") { fix.server.pageServeStreams[page] != nil }
        let huge = docs.appendingPathComponent("huge.bin").path

        for id in 1...(ControlServer.pageServeResourceLimit * 3) { client.send(.resource(id: id, path: huge)) }
        Thread.sleep(forTimeInterval: 0.3)
        fix.server.pageServeStreams[page]?.shutdown()

        waitUntil("the channel's threads finish") { fix.server.pageServeStreams[page] == nil }
        XCTAssertFalse(fix.session.remoteOverlays.slots.isEmpty)
    }

    func testASaturatedChannelStillServesCancelsAndBridgeCalls() throws {
        let fix = try fixture()
        try Data(count: 8 * 1024 * 1024).write(to: docs.appendingPathComponent("huge.bin"))
        let page = try openFile(fix)
        let (client, _) = try claim(try XCTUnwrap(fix.presenter.token))
        waitUntil("the channel is adopted") { fix.server.pageServeStreams[page] != nil }
        let huge = docs.appendingPathComponent("huge.bin").path
        let limit = ControlServer.pageServeResourceLimit

        let seen = offMain { () -> (failures: [Int: String], ends: Set<Int>, replied: Bool) in
            for id in 1...limit { client.send(.resource(id: id, path: huge)) }
            for id in 1...limit { client.send(.cancel(id: id)) }
            client.send(.bridge(id: 100, request: #"{"cmd":"version"}"#))
            var failures: [Int: String] = [:], ends: Set<Int> = [], replied = false
            while failures.count < limit || !replied, let frame = client.frame() {
                switch frame {
                case .failure(let id, let error): failures[id] = error
                case .end(let id): ends.insert(id)
                case .reply(100, _): replied = true
                default: continue
                }
            }
            return (failures, ends, replied)
        }

        let answer = try XCTUnwrap(seen)
        for id in 1...limit { XCTAssertEqual(answer.failures[id], PageServeFrame.cancelled, "transfer \(id)") }
        XCTAssertTrue(answer.ends.isEmpty)
        XCTAssertTrue(answer.replied)
        XCTAssertFalse(fix.session.remoteOverlays.slots.isEmpty)
        XCTAssertTrue(fix.server.presentationHub.hasPresenter(session: fix.session.id))
    }

    func testOverloadWithAFullWriterQueueEndsThePageWithoutWaiting() throws {
        let fix = try fixture()
        try Data(count: 8 * 1024 * 1024).write(to: docs.appendingPathComponent("huge.bin"))
        let page = try openFile(fix)
        let (client, _) = try claim(try XCTUnwrap(fix.presenter.token))
        waitUntil("the channel is adopted") { fix.server.pageServeStreams[page] != nil }
        let huge = docs.appendingPathComponent("huge.bin").path
        client.send(.resource(id: 1, path: huge))
        let filled = Date().addingTimeInterval(0.5)
        waitUntil("the transfer fills the writer queue") { Date() >= filled }
        let started = Date()

        for id in 2...(ControlServer.pageServeResourceLimit + 1) { client.send(.resource(id: id, path: huge)) }

        waitUntil("the page ends") { fix.session.remoteOverlays.slots.isEmpty }
        XCTAssertLessThan(Date().timeIntervalSince(started), Double(ControlServer.pageServeLimits.writeTimeoutSeconds) - 1)
        XCTAssertTrue(fix.server.presentationHub.hasPresenter(session: fix.session.id))
    }

    func testAdmissionRefusesPastItsLimitUntilASlotIsReleased() {
        let admission = PageServeAdmission(limit: 2)

        XCTAssertTrue(admission.tryAcquire())
        XCTAssertTrue(admission.tryAcquire())
        XCTAssertFalse(admission.tryAcquire())
        admission.release()
        XCTAssertTrue(admission.tryAcquire())
    }

    func testReloadAndNavigationOfARemotePageReachThePresenter() throws {
        let fix = try fixture()
        _ = try openFile(fix)
        let target = fix.session.id.uuidString

        XCTAssertTrue(fix.server.reloadSessionOverlay(target, window: nil, pane: nil, current: true).ok)
        XCTAssertTrue(fix.server.navigateSessionOverlay(target, window: nil, pane: nil, navigation: .back).ok)
        let browser = fix.server.navigateSessionOverlay(target, window: nil, pane: nil, navigation: .browser)

        XCTAssertEqual(browser.error, OverlayHtmlError.remotePage)
        let actions = fix.presenter.bodies.compactMap { if case .pageCommand(let command) = $0 { command.action } else { nil } }
        XCTAssertEqual(actions, [.reloadCurrent, .back])
    }

    func testAResultOrReadOfARemotePageGivesThePageAnswers() throws {
        let fix = try fixture()
        _ = try openFile(fix)
        let target = fix.session.id.uuidString

        XCTAssertEqual(fix.server.sessionOverlayResult(target, window: nil, pane: nil).error, OverlayHtmlError.noResult)
        XCTAssertEqual(fix.server.copySessionOverlaySelection(target, window: nil, pane: nil).error, OverlayHtmlError.noRead)
        let text = fix.server.readSessionOverlayText(target, window: nil,
                                                     options: ControlSessionOverlayTextOptions(pane: nil, all: false, lines: nil))
        XCTAssertEqual(text.error, OverlayHtmlError.noRead)
    }

    func testATokenClaimsOnce() throws {
        let fix = try fixture()
        _ = try openFile(fix)
        let token = try XCTUnwrap(fix.presenter.token)
        _ = try claim(token)

        let (_, reply) = try claim(token)

        XCTAssertTrue(try XCTUnwrap(reply).contains("page not claimable"))
    }

    func testAClaimWhoseReplyFailsEndsThePage() throws {
        let fix = try fixture(responseWriter: { _, response in !response.ok })
        let page = try openFile(fix)

        let (_, reply) = try claim(try XCTUnwrap(fix.presenter.token))

        XCTAssertNil(reply)
        waitUntil("the page ends") { fix.session.remoteOverlays.slots.isEmpty }
        XCTAssertTrue(fix.server.pendingPageClaims.isEmpty)
        XCTAssertNil(fix.server.pageServeStreams[page])
        XCTAssertEqual(HtmlPageOutcomes.shared.outcome(for: page)?.outcome, .dismissed)
    }

    func testLosingTheHelperEndsOnlyThePage() throws {
        let fix = try fixture()
        let page = try openFile(fix)
        let (client, _) = try claim(try XCTUnwrap(fix.presenter.token))
        waitUntil("the channel is adopted") { fix.server.pageServeStreams[page] != nil }

        close(client.fd)
        clients.removeAll()

        waitUntil("the page ends") { fix.session.remoteOverlays.slots.isEmpty }
        XCTAssertTrue(fix.presenter.bodies.contains(.pageClose(PresentationPageChange(page: page.uuidString))))
        XCTAssertTrue(fix.server.presentationHub.hasPresenter(session: fix.session.id))
    }

    func testLosingThePresenterEndsThePageAndClosesItsChannel() throws {
        let fix = try fixture()
        let page = try openFile(fix)
        let (client, _) = try claim(try XCTUnwrap(fix.presenter.token))
        waitUntil("the channel is adopted") { fix.server.pageServeStreams[page] != nil }

        fix.server.presentationHub.unsubscribe(fix.presenterID)

        XCTAssertTrue(fix.session.remoteOverlays.slots.isEmpty)
        XCTAssertEqual(HtmlPageOutcomes.shared.outcome(for: page)?.outcome, .dismissed)
        XCTAssertNil(offMain { client.readLine() } ?? nil)
    }
}
