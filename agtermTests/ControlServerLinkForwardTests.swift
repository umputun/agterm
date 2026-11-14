import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerLinkForwardTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var server: ControlServer!
    private var runner: Runner!
    private var transport: Transport!
    private var forwards: FakeForwardLauncher!
    private static let endpoint = ControlZmxEndpoint(executable: "/srv/zmx", socketDirectory: "/run/zmx")
    private struct Timeout: Error {}

    private final class Runner: RemoteCommandRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [[String]] = []
        private let versions: String = {
            var result = ControlResult()
            result.versions = CatalogVersions(server: "1", protocolVersion: 1, catalog: 1)
            result.app = AppIdentity(version: "9.9.9", commit: "testsha")
            return String(decoding: (try? JSONEncoder().encode(ControlResponse(ok: true, result: result))) ?? Data(), as: UTF8.self)
        }()

        var controls: [[String]] { lock.withLock { recorded } }

        func run(_ argv: [String], deadline _: TimeInterval) async -> RemoteCommandResult {
            if argv.contains("-O") {
                lock.withLock { recorded.append(argv) }
                return RemoteCommandResult(status: 0, stdout: argv.contains("check") ? "Master running (pid=4242)\n" : "", stderr: "")
            }
            let line = (argv.last ?? "").replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\\", with: "")
            if line.contains("agtermctl version") { return RemoteCommandResult(status: 0, stdout: versions, stderr: "") }
            return RemoteCommandResult(status: 0, stdout: "", stderr: "")
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

    private final class Answers {
        var urls: [String: URL?] = [:]
    }

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-link-forward-tests-\(UUID().uuidString)", isDirectory: true)
        library = WindowLibrary(directory: stateDir)
        runner = Runner()
        transport = Transport()
        forwards = FakeForwardLauncher()
        server = ControlServer(library: library, actions: AppActions(library: library),
                               settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
                               identity: AppIdentity(version: "9.9.9", commit: "testsha"), remoteRunner: runner,
                               socketPath: stateDir.appendingPathComponent("control-\(UUID().uuidString).sock").path)
        server.remoteTransport = transport
        server.forwardLauncher = forwards
    }

    override func tearDown() async throws {
        forwards?.processes.forEach { $0.terminate() }
        server?.stop()
        server = nil
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
        stateDir = nil
        try await super.tearDown()
    }

    func testEachClickOnOnePortOpensItsOwnAddressThroughOneForward() async throws {
        let row = try attachedRow()
        let answers = Answers()

        click("http://localhost:3000/a", row, answers, as: "a")
        click("http://localhost:3000/b?q=2#part", row, answers, as: "b")
        XCTAssertTrue(answers.urls.isEmpty)
        try await until { answers.urls.count == 2 }

        let port = try XCTUnwrap(forwards.localPort)
        XCTAssertEqual(answers.urls["a"], URL(string: "http://localhost:\(port)/a"))
        XCTAssertEqual(answers.urls["b"], URL(string: "http://localhost:\(port)/b?q=2#part"))
        click("http://localhost:3000/c", row, answers, as: "c")
        XCTAssertEqual(answers.urls["c"], URL(string: "http://localhost:\(port)/c"))
        XCTAssertEqual(forwards.launches.count, 1)
        XCTAssertTrue(try XCTUnwrap(forwards.launches.first?.last).hasSuffix("'-L' 'localhost:\(port):localhost:3000' 'buildbox'"))
    }

    func testARowThatGoesAwayGetsNoAddressWhileAnotherStillWaitsAndTheLastOneEndsTheForward() async throws {
        forwards.listens = false
        let first = try attachedRow(), second = try attachedRow()
        let answers = Answers()
        click("http://localhost:3000/a", first, answers, as: "a")
        click("http://localhost:3000/b", second, answers, as: "b")

        server.stopRemotePresentation(first.id)
        let late = FakeForwardLauncher.listen(try XCTUnwrap(forwards.localPort))
        defer { close(late) }
        try await until { answers.urls["b"] != nil }

        XCTAssertNil(answers.urls["a"] as URL??)
        XCTAssertFalse(forwards.processes[0].terminated)
        server.stopRemotePresentation(second.id)
        XCTAssertTrue(forwards.processes[0].terminated)
    }

    func testAFailedForwardAnswersNothingAndTheNextClickStartsAnother() async throws {
        forwards.listens = false
        let row = try attachedRow()
        let answers = Answers()
        click("http://localhost:3000/a", row, answers, as: "a")

        forwards.processes[0].onExit?("channel 2: open failed: connect failed: Connection refused\n")

        XCTAssertEqual(answers.urls["a"], .some(nil))
        forwards.listens = true
        click("http://localhost:3000/a", row, answers, as: "again")
        XCTAssertEqual(forwards.launches.count, 2)
        try await until { answers.urls["again"] != nil }
    }

    func testAServerWindowRowForwardsOnItsPoolUntilTheWindowCloses() async throws {
        server.wireRemoteCatalogs()
        let window = library.newRemoteWindow(host: "box").id
        try await until { self.transport.catalog != nil }
        let rowID = UUID()
        let pane = CatalogPane(identity: UUID(), daemon: "agterm-\(UUID().uuidString)", endpoint: Self.endpoint)
        var line = try CatalogCodec.encode(.snapshot(CatalogSnapshot(
            epoch: "e1", rev: 0, catalogID: UUID(), versions: CatalogVersions(server: "1", protocolVersion: 1, catalog: 1),
            workspaces: [CatalogWorkspace(id: UUID(), name: "main", sessions: [CatalogSession(
                fields: CatalogSessionFields(id: rowID, name: "build", parent: nil, cwd: "/srv", primary: pane.identity,
                                             axis: nil, shown: false, lifecycle: .live),
                panes: [pane])])])))
        if line.last == UInt8(ascii: "\n") { line.removeLast() }
        transport.catalog?(line)
        XCTAssertNotNil(server.catalogPool(forSession: rowID))
        let answers = Answers()

        click("http://localhost:3000/a", try XCTUnwrap(library.store(for: window)?.session(withID: rowID)), answers, as: "a")
        try await until { answers.urls["a"] != nil }

        XCTAssertTrue(forwards.launches.isEmpty)
        XCTAssertTrue(runner.controls.contains { $0.contains("forward") })
        server.stopRemotePresentation(rowID)
        click("http://localhost:3000/b", try XCTUnwrap(library.store(for: window)?.session(withID: rowID)), answers, as: "b")
        XCTAssertNotNil(answers.urls["b"] as URL??)
        XCTAssertFalse(runner.controls.contains { $0.contains("cancel") })
        server.stopRemoteCatalog(window: window)
        try await until { self.runner.controls.contains { $0.contains("cancel") } }
    }

    private func attachedRow() throws -> Session {
        let store = try XCTUnwrap(library.activeStore)
        return try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.currentWorkspaceID), cwd: NSHomeDirectory(),
                                              remoteHost: "buildbox"))
    }

    private func click(_ address: String, _ row: Session, _ answers: Answers, as name: String) {
        guard let page = ForwardedPage(address) else { return XCTFail("not a loopback address: \(address)") }
        server.forwardLoopback(page, row: row.id) { answers.urls[name] = $0 }
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw Timeout()
    }
}
