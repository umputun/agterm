import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerAttachedRestoreTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var settings: SettingsModel!
    private let originSession = "0E2B7C1A-5D4F-4E3B-9A61-7C2D8F0B1A23"
    private let pageID = "5A1E7C2B-3D4F-4E5A-8B6C-7D8E9F0A1B2C"
    private let endpoint = ControlZmxEndpoint(executable: "/Applications/agterm.app/zmx", socketDirectory: "/tmp/agterm-zmx-abc")

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-attached-restore-tests-\(UUID().uuidString)", isDirectory: true)
        library = WindowLibrary(directory: stateDir)
        settings = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
    }

    override func tearDown() async throws {
        settings = nil
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
        stateDir = nil
        try await super.tearDown()
    }

    func testARowItsOriginListsIsLeftToAttach() async throws {
        let runner = ScriptedRunner([tree(sessions: session(originSession))])
        let (server, _, row) = try makeServer(runner)

        await server.checkRestoredOrigin("buildbox")

        XCTAssertFalse(row.ended)
        XCTAssertFalse(row.awaitsOriginCheck)
        XCTAssertEqual(runner.invocations.count, 1, "a listed session needs no daemon inventory")
        XCTAssertNil(server.restoredOriginChecks["buildbox"])
    }

    func testARowItsOriginLeavesOutButStillClaimsIsNotEnded() async throws {
        let runner = ScriptedRunner([tree(sessions: ""), inventory(complete: true, claimedBy: originSession.lowercased())])
        let (server, _, row) = try makeServer(runner)

        await server.checkRestoredOrigin("buildbox")

        XCTAssertFalse(row.ended, "a closed window's session is still claimed there")
        XCTAssertFalse(row.awaitsOriginCheck)
        XCTAssertTrue(try XCTUnwrap(runner.invocations.last?.last).contains("list"))
    }

    func testAnIncompleteInventoryEndsNothing() async throws {
        let runner = ScriptedRunner([tree(sessions: ""), inventory(complete: false, claimedBy: nil)])
        let (server, _, row) = try makeServer(runner)

        await server.checkRestoredOrigin("buildbox")

        XCTAssertFalse(row.ended)
        XCTAssertNil(server.restoredOriginChecks["buildbox"])
    }

    func testARowWhoseSessionIsGoneFromTheOriginEnds() async throws {
        let runner = ScriptedRunner([tree(sessions: ""), inventory(complete: true, claimedBy: "another")])
        let (server, store, row) = try makeServer(runner)

        await server.checkRestoredOrigin("buildbox")

        XCTAssertTrue(row.ended)
        XCTAssertFalse(row.awaitsOriginCheck)
        XCTAssertEqual(row.initialCommand, RemoteSession.endedCommand(host: "buildbox"))
        XCTAssertNotNil(store.session(withID: row.id), "an ended row stays until the user closes it")
    }

    func testAnUnreachableHostLeavesATerminalRowAttachingAndTriesAgain() async throws {
        let (server, store, row) = try makeServer(ScriptedRunner([]))

        await server.checkRestoredOrigin("buildbox")

        XCTAssertFalse(row.ended)
        XCTAssertTrue(row.awaitsOriginCheck)
        XCTAssertEqual(server.restoredOriginChecks["buildbox"], 1)
        store.closeSession(row.id)
    }

    func testAnUnreachableHostMarksAPageRowFailedAndTriesAgain() async throws {
        let runner = ScriptedRunner([])
        let (server, store, row) = try makeServer(runner, page: true)

        await server.checkRestoredOrigin("buildbox")

        XCTAssertFalse(row.ended)
        XCTAssertTrue(row.awaitsOriginCheck)
        guard case .failed = row.remotePresentation?.connection else {
            return XCTFail("expected failed, got \(String(describing: row.remotePresentation?.connection))")
        }
        XCTAssertEqual(server.restoredOriginChecks["buildbox"], 1)
        store.closeSession(row.id)
    }

    func testAListedPageRowIsFilledInPlace() async throws {
        let runner = ScriptedRunner([tree(sessions: session(originSession, panes: "")), pageAttach])
        let (server, store, row) = try makeServer(runner, page: true)
        let launcher = FakePageLauncher()
        server.pageLauncher = launcher
        let rows = store.workspaces.flatMap(\.sessions).map(\.id)

        await server.checkRestoredOrigin("buildbox")

        XCTAssertEqual(store.workspaces.flatMap(\.sessions).map(\.id), rows, "the restored row keeps its id and place")
        XCTAssertEqual(row.htmlOverlay?.replicaOf, UUID(uuidString: pageID))
        XCTAssertFalse(row.awaitsOriginCheck)
        XCTAssertEqual(row.remotePresentation?.binding.remoteSessionID, originSession)
        XCTAssertTrue(try XCTUnwrap(runner.invocations.last?.last).contains("page-attach"))
        let serve = try XCTUnwrap(launcher.launches.last?.last)
        XCTAssertTrue(serve.contains("page-serve") && serve.contains("tok-1"))
        XCTAssertNil(server.restoredOriginChecks["buildbox"])
        let window = try XCTUnwrap(library.windowID(for: store))
        let saved = PersistenceStore(directory: stateDir.appendingPathComponent("windows"), fileName: "\(window.uuidString).json").load()
        let attached = try XCTUnwrap(saved.workspaces.flatMap { $0.attached ?? [] }.first { $0.session.id == row.id })
        XCTAssertEqual(attached.origin.page, true)
        XCTAssertEqual(attached.origin.sessionID, originSession)
    }

    // a page companion whose parent the origin cannot attach is left out of its tree, though the page still exists
    func testAPageRowItsOriginLeavesOutIsStillAskedForItsPage() async throws {
        let runner = ScriptedRunner([tree(sessions: ""), pageAttach])
        let (server, _, row) = try makeServer(runner, page: true)
        server.pageLauncher = FakePageLauncher()

        await server.checkRestoredOrigin("buildbox")

        XCTAssertFalse(row.ended)
        XCTAssertEqual(row.htmlOverlay?.replicaOf, UUID(uuidString: pageID))
        XCTAssertEqual(runner.invocations.count, 2, "a page owns no daemon, so no inventory is read")
    }

    func testAPageTheOriginRefusesShowsItsReasonAndIsNotAskedAgain() async throws {
        let refusal = RemoteCommandResult(status: 1, stdout: #"{"ok":false,"error":"no page session matching it"}"#, stderr: "")
        let runner = ScriptedRunner([tree(sessions: ""), refusal])
        let (server, store, row) = try makeServer(runner, page: true)

        await server.checkRestoredOrigin("buildbox")

        XCTAssertNotNil(store.session(withID: row.id))
        XCTAssertFalse(row.awaitsOriginCheck)
        XCTAssertEqual(row.remotePresentation?.connection, .failed("no page session matching it"))
        XCTAssertNil(server.restoredOriginChecks["buildbox"])
    }

    func testAPageAskNobodyAnswersIsTriedAgain() async throws {
        let runner = ScriptedRunner([tree(sessions: ""), RemoteCommandResult(status: 255, stdout: "", stderr: "ssh: timeout\n")])
        let (server, store, row) = try makeServer(runner, page: true)

        await server.checkRestoredOrigin("buildbox")

        XCTAssertTrue(row.awaitsOriginCheck)
        XCTAssertEqual(row.remotePresentation?.connection, .failed("ssh: timeout"))
        XCTAssertEqual(server.restoredOriginChecks["buildbox"], 1)
        store.closeSession(row.id)
    }

    func testARestoredURLPageClosesWhenItsPageEndsThere() async throws {
        let runner = ScriptedRunner([tree(sessions: session(originSession, panes: "")),
                                     pageAttach(source: #"{"url":{"_0":"https://example.com/"}}"#)])
        let (server, store, row) = try makeServer(runner, page: true)
        let launcher = FakePageLauncher()
        server.pageLauncher = launcher
        await server.checkRestoredOrigin("buildbox")
        XCTAssertNotNil(row.htmlOverlay, "the URL page fills the row")

        launcher.helpers.last?.exit()
        let deadline = Date().addingTimeInterval(5)
        while store.session(withID: row.id) != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }

        XCTAssertNil(store.session(withID: row.id), "its channel ending there closes the row here")
    }

    private func makeServer(_ runner: ScriptedRunner, page: Bool = false) throws -> (ControlServer, AppStore, Session) {
        let server = ControlServer(library: library, actions: AppActions(library: library), settingsModel: settings,
                                   identity: AppIdentity(version: "9.9.9", commit: "testsha"), remoteRunner: runner,
                                   socketPath: stateDir.appendingPathComponent("control-\(UUID().uuidString).sock").path)
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let row = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory(), remoteHost: "buildbox",
                                                 remoteSessionID: originSession, content: page ? .page : .terminal))
        let daemons = page ? [:] : [row.paneIdentity: "agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa3"]
        store.bindRemote(RemoteBinding(remoteSessionID: originSession, daemonsByLocalPane: daemons, presentationVersion: 1,
                                       origin: RemoteBinding.Origin(host: "buildbox", endpoint: endpoint, sessionName: "c")),
                         forSession: row.id)
        row.awaitsOriginCheck = true
        return (server, store, row)
    }

    private var pageAttach: RemoteCommandResult { pageAttach(source: #"{"file":{"path":"/srv/report.html","grantRoot":"/srv"}}"#) }

    private func pageAttach(source: String) -> RemoteCommandResult {
        RemoteCommandResult(status: 0, stdout: #"{"ok":true,"result":{"id":"\#(originSession)","companionPage":{"#
            + #""page":"\#(pageID)","token":"tok-1","source":\#(source),"#
            + #""identity":"report.html","chromeless":false,"javascript":true,"navigation":false,"browse":false,"#
            + #""persistent":false,"follow":false}}}"#, stderr: "")
    }

    private func session(_ id: String, panes: String = #"{"pane":"left","daemon":"agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa3"}"#) -> String {
        #"{"id":"\#(id)","name":"c","windowID":"w1","windowName":"main","workspaceID":"ws1","workspaceName":"work","#
            + #""cwd":"/repo","panes":[\#(panes)]}"#
    }

    private func tree(sessions: String) -> RemoteCommandResult {
        RemoteCommandResult(status: 0, stdout: #"{"ok":true,"result":{"remote":{"#
            + #""endpoint":{"executable":"/Applications/agterm.app/zmx","socketDirectory":"/tmp/agterm-zmx-abc"},"#
            + #""sessions":[\#(sessions)]}}}"#, stderr: "")
    }

    private func inventory(complete: Bool, claimedBy sessionID: String?) -> RemoteCommandResult {
        let claim = sessionID.map { #","sessionID":"\#($0)""# } ?? ""
        return RemoteCommandResult(status: 0, stdout: #"{"ok":true,"result":{"zmx":{"#
            + #""restore":{"configured":"live","requestedAtLaunch":"live","active":"live","restartRequired":false},"#
            + #""inventoryComplete":\#(complete),"entries":[{"daemon":"agterm-x","state":"running","observation":"running""#
            + claim + "}]}}}", stderr: "")
    }
}
