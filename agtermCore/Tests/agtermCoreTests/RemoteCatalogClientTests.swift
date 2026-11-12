import Foundation
import Testing
@testable import agtermCore

@MainActor
final class RemoteCatalogClientTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agts-client-\(UUID().uuidString)")
    private let store: AppStore
    private let effects = Effects()
    private let transport = Transport()
    private let mirror: RemoteCatalogMirror
    private var answers: [(Int32, String)] = []
    private var ran: [[String]] = []
    private static let versions = CatalogVersions(server: "1.2.3", protocolVersion: 1, catalog: 1)

    init() {
        store = AppStore(persistence: PersistenceStore(directory: directory), paneFinalizer: nil)
        mirror = RemoteCatalogMirror(host: "box", store: store, effects: effects, viewState: RemoteWindowViewState())
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    private final class Effects: RemoteCatalogEffects {
        func attachCommand(host: String, pane: CatalogPane) -> String { "attach \(pane.daemon)" }
        func catalogRowAdded(_: Session) {}
        func catalogRowRemoved(_: UUID) {}
        func catalogRowEnded(_: UUID) {}
        func catalogPaneNeedsAttach(_: UUID, session _: UUID) {}
        func catalogBound(_: UUID) -> Bool { true }
        func catalogStateChanged(_: RemoteCatalogMirror.State) {}
    }

    private final class Link: RemotePresentationLink {
        var sent: [CatalogFrame] = []
        var stopped = false
        let onLine: @MainActor (Data) -> Void
        let onClose: @MainActor (String) -> Void

        init(onLine: @escaping @MainActor (Data) -> Void, onClose: @escaping @MainActor (String) -> Void) {
            self.onLine = onLine
            self.onClose = onClose
        }

        func send(_ line: Data) {
            if let frame = try? CatalogCodec.decode(line.dropLast()) { sent.append(frame) }
        }

        func stop() { stopped = true }

        @MainActor func deliver(_ frame: CatalogFrame) throws { onLine(try CatalogCodec.encode(frame).dropLast()) }
    }

    private final class Transport: RemotePresentationTransport {
        var links: [Link] = []
        var argv: [[String]] = []

        func open(_ argv: [String], onLine: @escaping @MainActor (Data) -> Void,
                  onClose: @escaping @MainActor (String) -> Void) -> RemotePresentationLink {
            self.argv.append(argv)
            let link = Link(onLine: onLine, onClose: onClose)
            links.append(link)
            return link
        }
    }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var permits = 0

        func wait() async {
            await withCheckedContinuation { continuation in
                let ready = lock.withLock { () -> Bool in
                    guard permits > 0 else {
                        waiters.append(continuation)
                        return false
                    }
                    permits -= 1
                    return true
                }
                if ready { continuation.resume() }
            }
        }

        func release() {
            let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                guard !waiters.isEmpty else {
                    permits += 1
                    return nil
                }
                return waiters.removeFirst()
            }
            waiter?.resume()
        }
    }

    private func client(sleep gate: Gate? = nil) -> RemoteCatalogClient {
        RemoteCatalogClient(mirror: mirror, transport: transport, runner: { [unowned self] argv in
            ran.append(argv)
            return answers.isEmpty ? (255, "") : answers.removeFirst()
        }, sleep: { _ in await gate?.wait() })
    }

    private func versionReply(_ versions: CatalogVersions?) -> String {
        var result = ControlResult(app: AppIdentity(version: "1.2.3"))
        result.versions = versions
        return String(decoding: (try? JSONEncoder().encode(ControlResponse(ok: true, result: result))) ?? Data(), as: UTF8.self)
    }

    private func snapshot(rev: Int = 0) -> CatalogSnapshot {
        CatalogSnapshot(epoch: "e1", rev: rev, catalogID: UUID(), versions: Self.versions,
                        workspaces: [CatalogWorkspace(id: UUID(), name: "w", sessions: [])])
    }

    @Test func aServerThatAdvertisesACatalogGetsTheStreamOpenedWithHello() async throws {
        answers = [(0, versionReply(Self.versions))]
        let client = client()

        await client.connect()

        let probe = ran.first?.joined(separator: " ") ?? ""
        #expect(probe.contains("version") && probe.contains("--json"))
        #expect(transport.argv.first?.last?.contains("agtermctl catalog subscribe") == true)
        #expect(transport.links.first?.sent == [.hello(CatalogHello(version: CatalogCodec.version, pageRows: true))])
        #expect(mirror.state == .connecting)
    }

    @Test func anOriginWithNoCatalogIsRefusedAndNoStreamIsOpened() async {
        answers = [(0, versionReply(nil))]
        let client = client()

        await client.connect()

        #expect(transport.links.isEmpty)
        if case .refused(let message) = mirror.state {
            #expect(message.contains("box runs agterm 1.2.3 without a catalog"))
        } else {
            Issue.record("expected refused, got \(mirror.state)")
        }
    }

    @Test func aSnapshotConnectsAndAPingIsAcked() async throws {
        answers = [(0, versionReply(Self.versions))]
        let client = client()
        await client.connect()
        let link = try #require(transport.links.first)

        try link.deliver(.snapshot(snapshot()))
        try link.deliver(.ping)

        #expect(mirror.state == .connected)
        #expect(link.sent.last == .ack)
    }

    @Test func aGapSubscribesAgainOnAFreshStream() async throws {
        answers = [(0, versionReply(Self.versions))]
        let client = client()
        await client.connect()
        let first = try #require(transport.links.first)
        try first.deliver(.snapshot(snapshot()))

        try first.deliver(.delta(epoch: "e1", rev: 5, change: .workspaceOrder([])))

        #expect(first.stopped)
        #expect(transport.links.count == 2)
        #expect(transport.links.last?.sent == [.hello(CatalogHello(version: CatalogCodec.version, pageRows: true))])
    }

    @Test func aLostStreamShowsDisconnectedAndReconnectsAfterTheBackoff() async throws {
        answers = [(0, versionReply(Self.versions)), (0, versionReply(Self.versions))]
        let gate = Gate()
        let client = client(sleep: gate)
        await client.connect()
        let first = try #require(transport.links.first)
        try first.deliver(.snapshot(snapshot()))

        first.onClose("exit 255")
        let whileWaiting = (mirror.state, transport.links.count)
        gate.release()
        for _ in 0..<50 where transport.links.count < 2 { await Task.yield() }
        client.stop()

        #expect(whileWaiting.0 == .disconnected("the catalog stream from box ended: exit 255"))
        #expect(whileWaiting.1 == 1)
        #expect(transport.links.count == 2)
    }

    @Test func aReplacedStreamClosingLaterChangesNothing() async throws {
        answers = [(0, versionReply(Self.versions))]
        let client = client()
        await client.connect()
        let first = try #require(transport.links.first)
        try first.deliver(.snapshot(snapshot()))
        try first.deliver(.delta(epoch: "e1", rev: 5, change: .workspaceOrder([])))
        let second = try #require(transport.links.last)
        try second.deliver(.snapshot(snapshot()))

        first.onClose("exit 0")

        #expect(mirror.state == .connected)
        #expect(transport.links.count == 2)
    }

    @Test func startingDuringAFailedProbesBackoffLeavesOneRetryAndOneStream() async {
        answers = [(255, ""), (0, versionReply(Self.versions))]
        let gate = Gate()
        let client = client(sleep: gate)

        client.start()
        for _ in 0..<50 where ran.isEmpty { await Task.yield() }
        client.start()
        for _ in 0..<20 { await Task.yield() }
        let probesDuringBackoff = ran.count
        gate.release()
        for _ in 0..<50 where transport.links.isEmpty { await Task.yield() }
        client.start()
        for _ in 0..<20 { await Task.yield() }
        client.stop()

        #expect(probesDuringBackoff == 1)
        #expect(ran.count == 2)
        #expect(transport.links.count == 1)
    }

    @Test func theConnectionComesUpBeforeTheProbeAndTheStreamRidesIt() async throws {
        answers = [(0, versionReply(Self.versions))]
        var started = false
        let pool = SshConnectionPool(host: "box", root: "/tmp/agterm-ssh-501", key: "w") { [unowned self] argv in
            ran.append(argv)
            if argv.contains("check") { return started ? 0 : 255 }
            started = true
            return 0
        }
        let client = RemoteCatalogClient(mirror: mirror, transport: transport, runner: { [unowned self] argv in
            ran.append(argv)
            return answers.isEmpty ? (255, "") : answers.removeFirst()
        }, pool: pool, sleep: { _ in })

        await client.connect()

        let probe = try #require(ran.firstIndex { $0.joined(separator: " ").contains("version") })
        let start = try #require(ran.firstIndex { $0.first == "/bin/sh" })
        #expect(start < probe)
        #expect(ran[probe].contains { $0.hasPrefix("ControlPath=/tmp/agterm-ssh-501/") })
        #expect(transport.argv.first?.contains { $0.hasPrefix("ControlPath=/tmp/agterm-ssh-501/") } == true)
        #expect(pool.load == [1])
    }

    @Test func aConnectionThatCannotStartRunsNoProbeAndLeavesTheWindowDisconnected() async {
        let pool = SshConnectionPool(host: "box", root: "/tmp/agterm-ssh-501", key: "w") { [unowned self] argv in
            ran.append(argv)
            return 255
        }
        let client = RemoteCatalogClient(mirror: mirror, transport: transport, runner: { [unowned self] argv in
            ran.append(argv)
            return (0, versionReply(Self.versions))
        }, pool: pool, sleep: { _ in await Gate().wait() })

        await client.connect()
        client.stop()

        #expect(!ran.contains { $0.joined(separator: " ").contains("version") })
        #expect(transport.links.isEmpty)
        #expect(mirror.state == .disconnected("box did not answer"))
    }

    @Test func anUnreachableServerStaysDisconnected() async {
        let client = client(sleep: Gate())

        await client.connect()

        #expect(mirror.state == .disconnected("box did not answer"))
        #expect(transport.links.isEmpty)
        client.stop()
    }
}
