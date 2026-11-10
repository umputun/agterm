import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerRemoteActionsTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var settings: SettingsModel!
    private var server: ControlServer!
    private var transport: Transport!
    private var runner: Runner!
    private var remoteWindow: UUID!
    private var remoteStore: AppStore!
    private let workspaceID = UUID()
    private let otherWorkspaceID = UUID()
    private static let endpoint = ControlZmxEndpoint(executable: "/srv/zmx", socketDirectory: "/run/zmx")

    private struct Timeout: Error {}

    private final class Runner: RemoteCommandRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        private var rev = 0
        private let versions: String
        var created: UUID?

        var operations: [String] { lock.withLock { recorded } }

        init() {
            var result = ControlResult()
            result.versions = CatalogVersions(server: "1", protocolVersion: 1, catalog: 1)
            result.app = AppIdentity(version: "9.9.9", commit: "testsha")
            versions = Self.json(ControlResponse(ok: true, result: result))
        }

        func run(_ argv: [String], deadline _: TimeInterval) async -> RemoteCommandResult {
            let line = (argv.last ?? "").replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\\", with: "")
            if argv.contains("-O") { return RemoteCommandResult(status: 0, stdout: "", stderr: "") }
            if line.contains("agtermctl version") { return RemoteCommandResult(status: 0, stdout: versions, stderr: "") }
            guard let opRange = line.range(of: "--op-id ") else { return RemoteCommandResult(status: 0, stdout: "", stderr: "") }
            let opID = String(line[opRange.upperBound...].prefix(36))
            return lock.withLock {
                recorded.append(line)
                rev += 1
                var result = ControlResult(id: line.contains("session new") ? created?.uuidString : nil)
                result.receipt = CatalogReceipt(opID: opID, epoch: "e1", outcome: .applied, rev: rev)
                return RemoteCommandResult(status: 0, stdout: Self.json(ControlResponse(ok: true, result: result)), stderr: "")
            }
        }

        private static func json(_ response: ControlResponse) -> String {
            String(decoding: (try? JSONEncoder().encode(response)) ?? Data(), as: UTF8.self)
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
            .appendingPathComponent("agterm-remote-actions-tests-\(UUID().uuidString)", isDirectory: true)
        library = WindowLibrary(directory: stateDir)
        settings = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
        runner = Runner()
        transport = Transport()
        server = ControlServer(library: library, actions: AppActions(library: library), settingsModel: settings,
                               identity: AppIdentity(version: "9.9.9", commit: "testsha"), remoteRunner: runner,
                               socketPath: stateDir.appendingPathComponent("control-\(UUID().uuidString).sock").path)
        server.remoteTransport = transport
        server.wireRemoteCatalogs()
        remoteWindow = library.newRemoteWindow(host: "box").id
        remoteStore = try XCTUnwrap(library.store(for: remoteWindow))
        try await until { self.transport.catalog != nil }
    }

    override func tearDown() async throws {
        server?.stop()
        server = nil
        settings = nil
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

    private func feed(_ frame: CatalogFrame) throws {
        var line = try CatalogCodec.encode(frame)
        if line.last == UInt8(ascii: "\n") { line.removeLast() }
        transport.catalog?(line)
    }

    private func catalogSession(_ id: UUID = UUID(), name: String = "build", split: Bool = false) -> CatalogSession {
        let panes = (split ? [UUID(), UUID()] : [UUID()]).map {
            CatalogPane(identity: $0, daemon: "agterm-\($0.uuidString)", endpoint: Self.endpoint)
        }
        return CatalogSession(fields: CatalogSessionFields(id: id, name: name, parent: nil, cwd: "/srv", primary: panes[0].identity,
                                                           axis: split ? "vertical" : nil, shown: split, lifecycle: .live),
                              panes: panes)
    }

    private func open(_ sessions: [CatalogSession]) throws {
        try feed(.snapshot(CatalogSnapshot(epoch: "e1", rev: 0, catalogID: UUID(),
                                           versions: CatalogVersions(server: "1", protocolVersion: 1, catalog: 1),
                                           workspaces: [CatalogWorkspace(id: workspaceID, name: "main", sessions: sessions),
                                                        CatalogWorkspace(id: otherWorkspaceID, name: "spare", sessions: [])])))
        XCTAssertEqual(remoteStore.remoteActions?.mirror.state, .connected)
    }

    private func send(_ cmd: Command, target: String? = nil, args: ControlArgs? = nil) async throws -> ControlResponse {
        let dispatch = try XCTUnwrap(HtmlOverlayRegistry.shared.dispatch)
        return await dispatch(ControlRequest(cmd: cmd, target: target, args: args))
    }

    private func shownIDs() -> Set<UUID> { Set(remoteStore.workspaces.flatMap(\.sessions).map(\.id)) }

    func testAControlCloseOfACatalogRowInABackgroundWindowAsksTheServerAndTheRowLeavesWithItsRemoval() async throws {
        let entry = catalogSession()
        try open([entry])
        let local = library.newWindow().id
        XCTAssertEqual(library.activeWindowID, local)

        let reply = try await send(.sessionClose, target: entry.id.uuidString)

        XCTAssertTrue(reply.ok, reply.error ?? "")
        XCTAssertEqual(runner.operations.count, 1)
        XCTAssertTrue(runner.operations[0].contains("session close --target \(entry.id.uuidString)"))
        XCTAssertTrue(shownIDs().contains(entry.id))
        try feed(.delta(epoch: "e1", rev: 1, change: .sessionRemoved(entry.id)))
        XCTAssertFalse(shownIDs().contains(entry.id))
        XCTAssertTrue(library.recentClosedItems.isEmpty)
    }

    func testAControlCloseOfALocalRowClosesItHereAndSendsNothing() async throws {
        let localStore = try XCTUnwrap(library.store(for: library.newWindow().id))
        let session = try XCTUnwrap(localStore.activeSession)
        let extra = try XCTUnwrap(localStore.addSession(toWorkspace: try XCTUnwrap(localStore.currentWorkspaceID), cwd: "/tmp"))

        let reply = try await send(.sessionClose, target: session.id.uuidString)

        XCTAssertTrue(reply.ok, reply.error ?? "")
        XCTAssertNil(localStore.session(withID: session.id))
        XCTAssertNotNil(localStore.session(withID: extra.id))
        XCTAssertTrue(runner.operations.isEmpty)
    }

    func testControlSplitRenameAndMoveOfACatalogRowGoToTheServerAndChangeNothingHere() async throws {
        let entry = catalogSession()
        try open([entry])
        let id = entry.id.uuidString

        let split = try await send(.sessionSplit, target: id, args: ControlArgs(mode: "on"))
        let close = try await send(.sessionSplitClose, target: id)
        let rename = try await send(.sessionRename, target: id, args: ControlArgs(name: "renamed"))
        let move = try await send(.sessionMove, target: id, args: ControlArgs(workspace: otherWorkspaceID.uuidString))

        for reply in [split, close, rename, move] { XCTAssertTrue(reply.ok, reply.error ?? "") }
        XCTAssertEqual(runner.operations.count, 4)
        XCTAssertTrue(runner.operations[0].contains("session split visibility on --target \(id)"))
        XCTAssertTrue(runner.operations[1].contains("session split close --target \(id)"))
        XCTAssertTrue(runner.operations[2].contains("session rename --target \(id)"))
        XCTAssertTrue(runner.operations[2].hasSuffix("-- renamed"))
        XCTAssertTrue(runner.operations[3].contains("session move --target \(id)"))
        XCTAssertTrue(runner.operations[3].hasSuffix("-- \(otherWorkspaceID.uuidString)"))
        let row = try XCTUnwrap(remoteStore.session(withID: entry.id))
        XCTAssertFalse(row.hasSplit)
        XCTAssertEqual(row.displayName, "build")
        XCTAssertEqual(remoteStore.sessionLocation(ofSession: entry.id)?.workspace, workspaceID)
    }

    func testControlSplitOffOfAShownCatalogSplitAsksTheServerAndKeepsItShownHere() async throws {
        let entry = catalogSession(split: true)
        try open([entry])

        let reply = try await send(.sessionSplit, target: entry.id.uuidString, args: ControlArgs(mode: "off"))

        XCTAssertTrue(reply.ok, reply.error ?? "")
        XCTAssertEqual(runner.operations.count, 1)
        XCTAssertTrue(runner.operations[0].contains("session split visibility off --target \(entry.id.uuidString)"))
        XCTAssertEqual(remoteStore.session(withID: entry.id)?.isSplit, true)
    }

    func testSessionNewInABackgroundRemoteWindowRepliesWithTheServersRowAndSelectsItWhenItArrives() async throws {
        let entry = catalogSession()
        try open([entry])
        _ = remoteStore.selectSession(entry.id)
        let local = try XCTUnwrap(library.store(for: library.newWindow().id))
        let localRows = local.workspaces.flatMap(\.sessions).count
        let created = UUID()
        runner.created = created

        let reply = try await send(.sessionNew, args: ControlArgs(window: remoteWindow.uuidString))

        XCTAssertTrue(reply.ok, reply.error ?? "")
        XCTAssertEqual(reply.result?.id, created.uuidString)
        XCTAssertEqual(runner.operations.count, 1)
        XCTAssertTrue(runner.operations[0].contains("session new --workspace \(workspaceID.uuidString)"))
        XCTAssertEqual(shownIDs(), [entry.id])
        XCTAssertEqual(local.workspaces.flatMap(\.sessions).count, localRows)
        try feed(.delta(epoch: "e1", rev: 1, change: .sessionAdded(catalogSession(created, name: "new"), workspace: workspaceID, index: 1)))
        XCTAssertEqual(remoteStore.selectedSessionID, created)
    }

    func testACommandThatMakesALocalRowIsRefusedInARemoteWindow() async throws {
        let entry = catalogSession()
        try open([entry])

        let reply = try await send(.sessionCompanionConvert, target: entry.id.uuidString)

        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error, "session.companion.convert is not available in a remote window")
        XCTAssertTrue(runner.operations.isEmpty)
    }

    func testSessionDetachOfALocalSessionIsRefused() async throws {
        let localStore = try XCTUnwrap(library.store(for: library.newWindow().id))
        let session = try XCTUnwrap(localStore.activeSession)

        let reply = try await send(.sessionDetach, target: session.id.uuidString)

        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error, "session.detach acts only on a remote window")
        XCTAssertNotNil(localStore.session(withID: session.id))
    }

    func testTheTreeReadsARowPendingUntilTheServerReachesItsReceipt() async throws {
        let entry = catalogSession()
        try open([entry])

        _ = try await send(.sessionRename, target: entry.id.uuidString, args: ControlArgs(name: "renamed"))
        let pending = try await send(.tree, args: ControlArgs(window: remoteWindow.uuidString))
        try feed(.delta(epoch: "e1", rev: 1, change: .sessionChanged(CatalogSessionFields(
            id: entry.id, name: "renamed", parent: nil, cwd: "/srv", primary: entry.fields.primary, axis: nil, shown: false,
            lifecycle: .live))))
        let settled = try await send(.tree, args: ControlArgs(window: remoteWindow.uuidString))

        let before = try XCTUnwrap(pending.result?.tree?.workspaces.flatMap(\.sessions).first { $0.id == entry.id.uuidString })
        let after = try XCTUnwrap(settled.result?.tree?.workspaces.flatMap(\.sessions).first { $0.id == entry.id.uuidString })
        XCTAssertEqual(before.pending, "pending")
        XCTAssertNil(after.pending)
        XCTAssertEqual(after.name, "renamed")
        XCTAssertEqual(settled.result?.tree?.remote?.host, "box")
        XCTAssertEqual(settled.result?.tree?.remote?.state, "connected")
    }

    func testDetachAndReattachThroughControlHideAndRestoreTheRowAndTheTreeAndWindowListFollow() async throws {
        let hidden = catalogSession(), shown = catalogSession(name: "other")
        try open([hidden, shown])

        let detach = try await send(.sessionDetach, target: hidden.id.uuidString)
        let detachedList = try XCTUnwrap(server.fastPathResponse(for: ControlRequest(cmd: .windowList)))
        let detachedTree = try await send(.tree, args: ControlArgs(window: remoteWindow.uuidString))
        let detachedRows = shownIDs()
        let reattach = try await send(.sessionReattach, target: hidden.id.uuidString)
        let reattachedList = try XCTUnwrap(server.fastPathResponse(for: ControlRequest(cmd: .windowList)))
        let reattachedTree = try await send(.tree, args: ControlArgs(window: remoteWindow.uuidString))

        XCTAssertTrue(detach.ok, detach.error ?? "")
        XCTAssertEqual(detach.result?.affected, 1)
        XCTAssertEqual(detachedRows, [shown.id])
        XCTAssertEqual(detachedTree.result?.tree?.remote?.detachedSessions, [hidden.id.uuidString])
        let detachedNode = try XCTUnwrap(detachedList.result?.windows?.first { $0.id == remoteWindow.uuidString })
        XCTAssertEqual(detachedNode.remote?.detachedSessions, [hidden.id.uuidString])
        XCTAssertEqual(detachedNode.remote?.state, "connected")
        XCTAssertTrue(reattach.ok, reattach.error ?? "")
        XCTAssertEqual(shownIDs(), [hidden.id, shown.id])
        XCTAssertNil(reattachedTree.result?.tree?.remote?.detachedSessions)
        let reattachedNode = try XCTUnwrap(reattachedList.result?.windows?.first { $0.id == remoteWindow.uuidString })
        XCTAssertNil(reattachedNode.remote?.detachedSessions)
        XCTAssertTrue(runner.operations.isEmpty)
    }
}
