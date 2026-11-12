import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerCatalogPageTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var server: ControlServer!
    private var transport: Transport!
    private var runner: Runner!
    private var launcher: FakePageLauncher!
    private var remoteWindow: UUID!
    private var remoteStore: AppStore!
    private let workspaceID = UUID()
    private let rowID = UUID()
    private static let endpoint = ControlZmxEndpoint(executable: "/srv/zmx", socketDirectory: "/run/zmx")

    private struct Timeout: Error {}

    /// Runner answers each page-attach with the next scripted reply, a held reply waiting for `release`.
    private final class Runner: RemoteCommandRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [String] = []
        private var attaches = 0
        private var holding = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        var attachCount: Int { lock.withLock { attaches } }

        private static let versions: String = {
            var result = ControlResult()
            result.versions = CatalogVersions(server: "1", protocolVersion: 1, catalog: 1)
            result.app = AppIdentity(version: "9.9.9", commit: "testsha")
            return ControlServerCatalogPageTests.json(ControlResponse(ok: true, result: result))
        }()

        func script(_ next: [String]) { lock.withLock { replies = next } }
        func hold() { lock.withLock { holding = true } }

        func release() {
            let pending = lock.withLock {
                holding = false
                defer { waiters.removeAll() }
                return waiters
            }
            for waiter in pending { waiter.resume() }
        }

        func run(_ argv: [String], deadline _: TimeInterval) async -> RemoteCommandResult {
            let line = (argv.last ?? "").replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\\", with: "")
            if line.contains("agtermctl version") { return RemoteCommandResult(status: 0, stdout: Self.versions, stderr: "") }
            guard line.contains("session overlay page-attach") else { return RemoteCommandResult(status: 0, stdout: "", stderr: "") }
            let held = lock.withLock {
                attaches += 1
                return holding
            }
            if held {
                await withCheckedContinuation { waiter in
                    let resumeNow = lock.withLock {
                        guard holding else { return true }
                        waiters.append(waiter)
                        return false
                    }
                    if resumeNow { waiter.resume() }
                }
            }
            let reply = lock.withLock { replies.isEmpty ? "" : replies.removeFirst() }
            return RemoteCommandResult(status: 0, stdout: reply, stderr: "")
        }
    }

    private final class Transport: RemotePresentationTransport {
        final class Link: RemotePresentationLink {
            func send(_: Data) {}
            func stop() {}
        }

        var catalog: (@MainActor (Data) -> Void)?

        func open(_ argv: [String], onLine: @escaping @MainActor (Data) -> Void,
                  onClose _: @escaping @MainActor (String) -> Void) -> RemotePresentationLink {
            if argv.last?.contains("catalog subscribe") == true { catalog = onLine }
            return Link()
        }
    }

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-catalog-page-tests-\(UUID().uuidString)", isDirectory: true)
        library = WindowLibrary(directory: stateDir)
        let settings = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
        runner = Runner()
        transport = Transport()
        launcher = FakePageLauncher()
        server = ControlServer(library: library, actions: AppActions(library: library), settingsModel: settings,
                               identity: AppIdentity(version: "9.9.9", commit: "testsha"), remoteRunner: runner,
                               socketPath: stateDir.appendingPathComponent("control-\(UUID().uuidString).sock").path)
        server.remoteTransport = transport
        server.pageLauncher = launcher
        server.catalogPagePause = { await Task.yield() }
        server.wireRemoteCatalogs()
        remoteWindow = library.newRemoteWindow(host: "box").id
        remoteStore = try XCTUnwrap(library.store(for: remoteWindow))
        try await until { self.transport.catalog != nil }
    }

    override func tearDown() async throws {
        runner?.release()
        launcher?.closeAll()
        server?.stop()
        server = nil
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
        stateDir = nil
        try await super.tearDown()
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw Timeout()
    }

    private func feed(rev: Int, _ sessions: [CatalogSession]) throws {
        var line = try CatalogCodec.encode(.snapshot(CatalogSnapshot(
            epoch: "e1", rev: rev, catalogID: UUID(), versions: CatalogVersions(server: "1", protocolVersion: 1, catalog: 1),
            workspaces: [CatalogWorkspace(id: workspaceID, name: "main", sessions: sessions)])))
        if line.last == UInt8(ascii: "\n") { line.removeLast() }
        transport.catalog?(line)
    }

    private var pageRow: CatalogSession {
        let page = CatalogPage(kind: "url", identity: "https://example.invalid", endpoint: Self.endpoint)
        return CatalogSession(fields: CatalogSessionFields(id: rowID, name: "docs", parent: nil, cwd: "/srv", primary: rowID,
                                                           axis: nil, shown: false, lifecycle: .live, page: page),
                              panes: [])
    }

    private func handed(_ token: String) -> String {
        let page = PresentationPage(page: UUID().uuidString, token: token, source: .url("https://example.invalid/"),
                                    identity: "https://example.invalid", chromeless: false, javascript: false, navigation: false,
                                    browse: false, persistent: false, backgroundColor: nil, pane: nil, sizePercent: nil,
                                    follow: false)
        return Self.json(ControlResponse(ok: true, result: ControlResult(companionPage: page)))
    }

    private nonisolated static func json(_ response: ControlResponse) -> String {
        String(decoding: (try? JSONEncoder().encode(response)) ?? Data(), as: UTF8.self)
    }

    private var row: Session? { remoteStore.session(withID: rowID) }

    private var shownReplica: Bool { row?.htmlOverlay?.replicaOf != nil }

    private var failure: String? {
        guard case .unreadable(let reason)? = row?.htmlOverlay?.source else { return nil }
        return reason
    }

    func testAPageRowShowsTheViewItClaimedFromItsServer() async throws {
        runner.script([handed("t1")])

        try feed(rev: 0, [pageRow])
        try await until { self.shownReplica && self.server.catalogPageClaims.isEmpty }

        XCTAssertEqual(row?.content, .page)
        XCTAssertEqual(runner.attachCount, 1)
        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertTrue(launcher.launches[0].joined(separator: " ").contains("t1"))
    }

    func testARefusedClaimIsTheRowsFailedPageAndIsNotTriedAgain() async throws {
        runner.script([Self.json(ControlResponse(ok: false, error: "no such page"))])

        try feed(rev: 0, [pageRow])
        try await until { self.server.catalogPageClaims.isEmpty && self.failure != nil }

        XCTAssertEqual(failure, "no such page")
        XCTAssertEqual(runner.attachCount, 1)
        XCTAssertTrue(launcher.launches.isEmpty)
    }

    func testAnUnreachableServerIsShownWhileTheClaimIsTriedAgain() async throws {
        runner.script(["", handed("t2")])
        var shownWhileWaiting: String?
        server.catalogPagePause = { [unowned self] in shownWhileWaiting = failure }

        try feed(rev: 0, [pageRow])
        try await until { self.shownReplica && self.server.catalogPageClaims.isEmpty }

        XCTAssertEqual(shownWhileWaiting, "box cannot be reached, retrying")
        XCTAssertEqual(runner.attachCount, 2)
    }

    func testARowRemovedDuringItsClaimIsNeverShown() async throws {
        runner.hold()
        runner.script([handed("t3")])
        try feed(rev: 0, [pageRow])
        try await until { self.runner.attachCount == 1 }

        try feed(rev: 1, [])
        runner.release()
        try await until { self.server.catalogPageClaims.isEmpty }

        XCTAssertNil(row)
        XCTAssertTrue(launcher.launches.isEmpty)
    }

    func testARowReplacedDuringItsClaimIsClaimedAgainForTheNewRow() async throws {
        runner.hold()
        runner.script([handed("stale"), handed("t4")])
        try feed(rev: 0, [pageRow])
        try await until { self.runner.attachCount == 1 }

        try feed(rev: 1, [])
        try feed(rev: 2, [pageRow])
        runner.release()
        try await until { self.shownReplica && self.server.catalogPageClaims.isEmpty }

        XCTAssertEqual(runner.attachCount, 2)
        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertTrue(launcher.launches[0].joined(separator: " ").contains("t4"))
    }

    func testClosingTheWindowStopsAClaimThatIsBeingRetried() async throws {
        runner.script([])
        server.catalogPagePause = { [unowned self] in library.removeWindow(remoteWindow) }

        try feed(rev: 0, [pageRow])
        try await until { self.server.catalogPageClaims.isEmpty }

        XCTAssertEqual(runner.attachCount, 1)
        XCTAssertTrue(launcher.launches.isEmpty)
    }

    func testADetachedPageRowEndsItsViewAndClaimsAnotherWhenReattached() async throws {
        runner.script([handed("t7"), handed("t8")])
        try feed(rev: 0, [pageRow])
        try await until { self.shownReplica && self.server.catalogPageClaims.isEmpty }
        let dispatch = try XCTUnwrap(HtmlOverlayRegistry.shared.dispatch)

        let detached = await dispatch(ControlRequest(cmd: .sessionDetach, target: rowID.uuidString))

        XCTAssertTrue(detached.ok, detached.error ?? "")
        XCTAssertNil(row)
        XCTAssertTrue(server.replicaPages.isEmpty)
        let reattached = await dispatch(ControlRequest(cmd: .sessionReattach, target: rowID.uuidString))
        XCTAssertTrue(reattached.ok, reattached.error ?? "")
        try await until { self.shownReplica && self.server.catalogPageClaims.isEmpty }
        XCTAssertEqual(runner.attachCount, 2)
        XCTAssertTrue(launcher.launches[1].joined(separator: " ").contains("t8"))
    }

    func testALostChannelShowsTheRowReconnectingAndClaimsAViewAgain() async throws {
        runner.script([handed("t5"), handed("t6")])
        try feed(rev: 0, [pageRow])
        try await until { self.shownReplica && self.server.catalogPageClaims.isEmpty }
        let first = try XCTUnwrap(row?.htmlOverlay?.id)

        runner.hold()
        launcher.closeAll()
        try await until { self.runner.attachCount == 2 }

        XCTAssertEqual(failure, "the page's connection to box ended, reconnecting")
        XCTAssertEqual(row?.content, .page)
        runner.release()
        try await until { self.shownReplica && self.server.catalogPageClaims.isEmpty }
        XCTAssertNotEqual(row?.htmlOverlay?.id, first)
        XCTAssertEqual(launcher.launches.count, 2)
    }
}
