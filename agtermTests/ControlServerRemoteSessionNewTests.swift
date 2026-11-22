import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerRemoteSessionNewTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var settings: SettingsModel!
    private let created = "0E2B7C1A-5D4F-4E3B-9A61-7C2D8F0B1A23"
    private let build = ControlWindowNode(id: "6F1C0D2E-0000-4000-8000-000000000001", name: "build", open: true, active: true)
    private let notes = ControlWindowNode(id: "9A2B3C4D-0000-4000-8000-000000000002", name: "notes", open: true, active: false)

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-remote-session-new-tests-\(UUID().uuidString)", isDirectory: true)
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

    func testAMacWithOneWindowCreatesInTheSameNamedWorkspaceThereAndTheRowLandsHereSelected() async throws {
        let runner = ScriptedRunner([mac(), windows([build]), reply(id: created), tree(""), tree(session(created))])
        let server = makeServer(runner)
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        store.renameWorkspace(workspace, to: "dev")
        let anchor = try XCTUnwrap(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)).result?.events)

        let reply = await server.newRemoteSession(RemoteSessionCreate(host: "mac"))

        XCTAssertTrue(reply.ok, reply.error ?? "")
        let rowID = try XCTUnwrap(reply.result?.id.flatMap(UUID.init(uuidString:)))
        let row = try XCTUnwrap(store.session(withID: rowID))
        XCTAssertEqual(row.remoteHost, "mac")
        XCTAssertEqual(row.remotePresentation?.binding.remoteSessionID, created)
        XCTAssertEqual(store.workspace(forSession: rowID)?.id, workspace)
        XCTAssertEqual(store.selectedSessionID, rowID)
        XCTAssertEqual(creates(runner).count, 1, "one create, then polls until the origin lists it")
        let create = try XCTUnwrap(creates(runner).first)
        for word in ["--window=\(build.id)", "--workspace-name=dev", "--create-workspace", "--no-select"] {
            XCTAssertTrue(create.contains(word), word)
        }
        let events = try XCTUnwrap(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next), kinds: [.sessionCreated, .remoteOpened], limit: 100
        )).result?.events).items
        XCTAssertEqual(events.map(\.kind), [.sessionCreated, .remoteOpened])
        XCTAssertEqual(events.last?.payload.remoteSessionID, created)
    }

    func testARootDestinationCreatesInTheOriginsRootAndTheRowLandsInTheRoot() async throws {
        let runner = ScriptedRunner([mac(), windows([build]), reply(id: created), tree(session(created))])
        let server = makeServer(runner)
        let store = try XCTUnwrap(library.activeStore)
        let root = try XCTUnwrap(store.rootWorkspace)
        store.selectSession(try XCTUnwrap(store.addSession(toWorkspace: root.id, cwd: "/tmp")).id)

        let reply = await server.newRemoteSession(RemoteSessionCreate(host: "mac"))

        XCTAssertTrue(reply.ok, reply.error ?? "")
        let rowID = try XCTUnwrap(reply.result?.id.flatMap(UUID.init(uuidString:)))
        XCTAssertEqual(store.workspace(forSession: rowID)?.id, root.id)
        let create = try XCTUnwrap(creates(runner).first)
        XCTAssertTrue(create.contains("--workspace=root"), create)
        XCTAssertFalse(create.contains("--workspace-name"), create)
        XCTAssertFalse(create.contains("--create-workspace"), create)
    }

    func testANamedOriginWorkspaceFromARootDestinationKeepsTodaysArgvAndLandsInTheRoot() async throws {
        let runner = ScriptedRunner([mac(), windows([build]), reply(id: created), tree(session(created))])
        let server = makeServer(runner)
        let store = try XCTUnwrap(library.activeStore)
        let root = try XCTUnwrap(store.rootWorkspace)
        store.selectSession(try XCTUnwrap(store.addSession(toWorkspace: root.id, cwd: "/tmp")).id)

        let reply = await server.newRemoteSession(RemoteSessionCreate(host: "mac", workspaceName: "ops"))

        XCTAssertTrue(reply.ok, reply.error ?? "")
        let rowID = try XCTUnwrap(reply.result?.id.flatMap(UUID.init(uuidString:)))
        XCTAssertEqual(store.workspace(forSession: rowID)?.id, root.id)
        let create = try XCTUnwrap(creates(runner).first)
        XCTAssertTrue(create.contains("--workspace-name=ops"), create)
        XCTAssertTrue(create.contains("--create-workspace"), create)
    }

    func testAnOriginWithoutTopLevelSessionsRefusesARootDestinationAndNothingAttaches() async throws {
        let refusal = RemoteCommandResult(status: 1, stdout: #"{"ok":false,"error":"no such workspace: root"}"#, stderr: "")
        let runner = ScriptedRunner([mac(), windows([build]), refusal])
        let server = makeServer(runner)
        let store = try XCTUnwrap(library.activeStore)
        let root = try XCTUnwrap(store.rootWorkspace)
        store.selectSession(try XCTUnwrap(store.addSession(toWorkspace: root.id, cwd: "/tmp")).id)
        let before = store.workspaces.flatMap(\.sessions).count

        let reply = await server.newRemoteSession(RemoteSessionCreate(host: "mac"))

        XCTAssertEqual(reply.error, "no such workspace: root")
        XCTAssertEqual(store.workspaces.flatMap(\.sessions).count, before)
    }

    func testAMacWithSeveralWindowsAndNoneNamedCreatesNothing() async throws {
        let runner = ScriptedRunner([mac(), windows([build, notes])])
        let server = makeServer(runner)

        let reply = await server.newRemoteSession(RemoteSessionCreate(host: "mac"))

        XCTAssertEqual(reply.error, "mac has 2 open windows; name one with --origin-window: 6f1c0d2e build, 9a2b3c4d notes")
        XCTAssertEqual(runner.invocations.count, 2)
    }

    func testANamedOriginWindowAndWorkspaceAreTheOnesSent() async throws {
        let runner = ScriptedRunner([mac(), windows([build, notes]), reply(id: created), tree(session(created))])
        let server = makeServer(runner)

        let reply = await server.newRemoteSession(RemoteSessionCreate(host: "mac", originWindow: "9a2b", workspaceName: "-ops",
                                                                       cwd: "/srv", command: "make run"))

        XCTAssertTrue(reply.ok, reply.error ?? "")
        let create = try XCTUnwrap(creates(runner).first)
        for word in ["--window=\(notes.id)", "--workspace-name=-ops", "--cwd=/srv", "--command=make run"] {
            XCTAssertTrue(create.contains(word), word)
        }
    }

    func testTheCreateAsksTheOriginToHoldItsCommandAndAnOlderCliCreatesWithoutIt() async throws {
        let refused = RemoteCommandResult(status: 64, stdout: "", stderr: "Error: Unknown option '--attach-pending'")
        let runner = ScriptedRunner([server(), refused, reply(id: created), tree(session(created))])

        let reply = await makeServer(runner).newRemoteSession(RemoteSessionCreate(host: "srv", command: "codex"))

        XCTAssertTrue(reply.ok, reply.error ?? "")
        let sent = creates(runner)
        XCTAssertEqual(sent.count, 2)
        XCTAssertTrue(sent[0].contains("--attach-pending"), sent[0])
        XCTAssertFalse(sent[1].contains("--attach-pending"), sent[1])
        XCTAssertTrue(sent[1].contains("--command=codex"), sent[1])
    }

    func testACreateWithoutACommandAsksTheOriginNoHold() async throws {
        let runner = ScriptedRunner([server(), reply(id: created), tree(session(created))])

        let reply = await makeServer(runner).newRemoteSession(RemoteSessionCreate(host: "srv"))

        XCTAssertTrue(reply.ok, reply.error ?? "")
        let sent = creates(runner)
        XCTAssertEqual(sent.count, 1)
        XCTAssertFalse(sent[0].contains("--attach-pending"), sent[0])
    }

    func testAServerGetsNoWindowAndRefusesANamedOne() async throws {
        let runner = ScriptedRunner([server(), reply(id: created), tree(session(created))])
        let server = makeServer(runner)

        let reply = await server.newRemoteSession(RemoteSessionCreate(host: "srv"))

        XCTAssertTrue(reply.ok, reply.error ?? "")
        XCTAssertEqual(runner.invocations.count, 3, "no window list for a server")
        XCTAssertFalse(try XCTUnwrap(creates(runner).first).contains("--window"))

        let named = ScriptedRunner([self.server()])
        let refused = await makeServer(named).newRemoteSession(RemoteSessionCreate(host: "srv", originWindow: "w1"))
        XCTAssertEqual(refused.error, "srv runs agterm-server, which has no windows to name")
        XCTAssertEqual(named.invocations.count, 1)
    }

    func testAHostThatIsNeitherALiveMacNorAServerGetsNothingCreated() async throws {
        var older = ControlResult()
        older.app = AppIdentity(version: "0.40.0", commit: "abc")
        let cases: [(RemoteCommandResult, String)] = [
            (result(older), "the agterm on mac is too old to create sessions for another Mac"),
            (mac(live: false), "mac does not run Live sessions, which a remote session needs"),
            (mac(live: nil), "mac does not run Live sessions, which a remote session needs"),
            (RemoteCommandResult(status: 255, stdout: "", stderr: "ssh: connect to host mac: Connection refused"),
             "mac did not answer; nothing was created"),
        ]
        for (version, error) in cases {
            let runner = ScriptedRunner([version])

            let reply = await makeServer(runner).newRemoteSession(RemoteSessionCreate(host: "mac"))

            XCTAssertEqual(reply.error, error)
            XCTAssertEqual(runner.invocations.count, 1, error)
        }
    }

    func testAnUnknownOutcomeIsReportedAndNeverResent() async throws {
        let runner = ScriptedRunner([server(), RemoteCommandResult(status: -1, stdout: "", stderr: "the remote did not answer in time")])
        let server = makeServer(runner)

        let reply = await server.newRemoteSession(RemoteSessionCreate(host: "srv"))

        XCTAssertEqual(reply.error, "srv gave no answer (the remote did not answer in time); whether the session was created there is unknown")
        XCTAssertEqual(runner.invocations.count, 2)
    }

    func testAFullReceiptOverAFailedTransportNamesTheSessionAndResendsNothing() async throws {
        let receipt = RemoteCommandResult(status: 255, stdout: reply(id: created).stdout, stderr: "Connection reset")
        let runner = ScriptedRunner([server(), receipt])
        let server = makeServer(runner)

        let reply = await server.newRemoteSession(RemoteSessionCreate(host: "srv"))

        XCTAssertEqual(reply.error, "created session \(created) on srv but the connection failed before attaching it; "
                       + "`agtermctl zmx attach srv \(created)` attaches it")
        XCTAssertEqual(runner.invocations.count, 2)
    }

    func testAnOriginRefusalPassesThrough() async throws {
        let refused = RemoteCommandResult(status: 1, stdout: #"{"ok":false,"error":"workspace name must not be blank"}"#, stderr: "")
        let runner = ScriptedRunner([server(), refused])

        let reply = await makeServer(runner).newRemoteSession(RemoteSessionCreate(host: "srv"))

        XCTAssertEqual(reply.error, "workspace name must not be blank")
    }

    func testASessionThatNeverBecomesAttachableIsNamedWithItsRecovery() async throws {
        let runner = ScriptedRunner([server(), reply(id: created)] + Array(repeating: tree(""), count: 50))
        let server = makeServer(runner)
        var now = Date()
        server.hudClock = {
            now = now.addingTimeInterval(3)
            return now
        }

        let reply = await server.newRemoteSession(RemoteSessionCreate(host: "srv"))

        XCTAssertEqual(reply.error, "created session \(created) on srv but could not attach it: it did not become attachable; "
                       + "`agtermctl zmx attach srv \(created)` attaches it")
        XCTAssertEqual(creates(runner).count, 1)
    }

    func testAWorkspaceDeletedDuringTheWaitIsNeverRetargeted() async throws {
        let runner = ScriptedRunner([server(), reply(id: created), tree(""), tree(session(created))])
        let server = makeServer(runner)
        let store = try XCTUnwrap(library.activeStore)
        let captured = try XCTUnwrap(store.currentWorkspaceID)
        _ = store.addWorkspace(name: "other")
        store.selectWorkspace(captured)
        runner.beforeCall = { call in
            guard call == 2 else { return }
            await MainActor.run { store.removeWorkspace(captured) }
        }

        let reply = await server.newRemoteSession(RemoteSessionCreate(host: "srv"))

        XCTAssertEqual(reply.error, "created session \(created) on srv but could not attach it: the window or workspace to attach into "
                       + "was closed; `agtermctl zmx attach srv \(created)` attaches it")
        XCTAssertFalse(store.workspaces.flatMap(\.sessions).contains { $0.remoteHost == "srv" })
    }

    private func makeServer(_ runner: ScriptedRunner) -> ControlServer {
        let server = ControlServer(library: library, actions: AppActions(library: library), settingsModel: settings,
                                   identity: AppIdentity(version: "9.9.9", commit: "testsha"), remoteRunner: runner,
                                   socketPath: stateDir.appendingPathComponent("control-\(UUID().uuidString).sock").path)
        server.remoteCompanionPause = {}
        return server
    }

    private func creates(_ runner: ScriptedRunner) -> [String] {
        runner.invocations.compactMap(\.last)
            .map { $0.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\\", with: "") }
            .filter { $0.contains("agtermctl session new") }
    }

    private func result(_ result: ControlResult) -> RemoteCommandResult {
        let json = (try? JSONEncoder().encode(ControlResponse(ok: true, result: result))) ?? Data()
        return RemoteCommandResult(status: 0, stdout: String(decoding: json, as: UTF8.self), stderr: "")
    }

    private func mac(live: Bool? = true) -> RemoteCommandResult {
        var version = ControlResult()
        version.macCatalog = CatalogVersions(server: "9.9.9", protocolVersion: PresentationCodec.version, catalog: CatalogCodec.version,
                                             live: live)
        return result(version)
    }

    private func server() -> RemoteCommandResult {
        var version = ControlResult()
        version.headless = true
        return result(version)
    }

    private func windows(_ nodes: [ControlWindowNode]) -> RemoteCommandResult {
        var listing = ControlResult()
        listing.windows = nodes
        return result(listing)
    }

    private func reply(id: String) -> RemoteCommandResult {
        RemoteCommandResult(status: 0, stdout: #"{"ok":true,"result":{"id":"\#(id)"}}"#, stderr: "")
    }

    private func session(_ id: String) -> String {
        #"{"id":"\#(id)","name":"c","windowID":"w1","windowName":"main","workspaceID":"ws1","workspaceName":"dev","#
            + #""cwd":"/repo","panes":[{"pane":"left","daemon":"agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa3"}]}"#
    }

    private func tree(_ sessions: String) -> RemoteCommandResult {
        RemoteCommandResult(status: 0, stdout: #"{"ok":true,"result":{"remote":{"#
            + #""endpoint":{"executable":"/Applications/agterm.app/zmx","socketDirectory":"/tmp/agterm-zmx-abc"},"#
            + #""sessions":[\#(sessions)]}}}"#, stderr: "")
    }
}
