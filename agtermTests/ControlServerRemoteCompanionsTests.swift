import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerRemoteCompanionsTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var settings: SettingsModel!
    private let created = "0E2B7C1A-5D4F-4E3B-9A61-7C2D8F0B1A23"

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-remote-companion-tests-\(UUID().uuidString)", isDirectory: true)
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

    func testTheOriginCreatesTheCompanionWhichAttachesUnderTheRowOnceItsPanesRun() async throws {
        let runner = ScriptedRunner([origin, reply(id: created), tree(sessions: ""), tree(sessions: session(created))])
        let (server, store, row) = try makeServer(runner)

        let options = CompanionOptions(command: "tail -f 'build log'", name: "logs", select: false, tint: SidebarTint(color: .red))
        let reply = await server.createCompanion(row.id.uuidString, options: options, window: nil)

        XCTAssertTrue(reply.ok, reply.error ?? "")
        XCTAssertEqual(reply.result?.parent, row.id.uuidString)
        let companion = try XCTUnwrap(reply.result?.id.flatMap(UUID.init(uuidString:)).flatMap(store.session(withID:)))
        XCTAssertEqual(companion.parentID, row.id)
        XCTAssertEqual(companion.remoteHost, "buildbox")
        XCTAssertEqual(companion.tint, SidebarTint(color: .red))
        XCTAssertNotEqual(store.selectedSessionID, companion.id)
        XCTAssertEqual(runner.invocations.count, 4, "a check, one create, then polls until the origin lists it, never a second create")
        let create = try XCTUnwrap(runner.invocations[1].last)
        for word in ["session", "new", "--parent", "origin-1", "--no-select", "--command", "--name", "logs", "--json"] {
            XCTAssertTrue(create.contains(word), word)
        }
    }

    func testDuplicateAsCompanionOnARemoteRowAsksTheOriginToDuplicate() async throws {
        let runner = ScriptedRunner([origin, reply(id: created), tree(sessions: session(created))])
        let (server, store, row) = try makeServer(runner)

        let reply = await server.duplicateAsCompanion(row.id.uuidString, window: nil, select: true)

        XCTAssertTrue(reply.ok, reply.error ?? "")
        let create = try XCTUnwrap(runner.invocations[1].last)
        for word in ["duplicate", "--companion", "--target", "origin-1", "--no-select"] {
            XCTAssertTrue(create.contains(word), word)
        }
        XCTAssertEqual(store.companions(of: row.id).count, 1)
    }

    func testAnOriginRefusalOrAnOlderOriginCreatesNothingHere() async throws {
        let refused = ScriptedRunner([origin, RemoteCommandResult(status: 1, stdout: #"{"ok":false,"error":"no session matching origin-1"}"#, stderr: "")])
        let (server, store, row) = try makeServer(refused)
        let reply = await server.createCompanion(row.id.uuidString, options: CompanionOptions(), window: nil)
        XCTAssertEqual(reply.error, "no session matching origin-1")
        XCTAssertEqual(refused.invocations.count, 2)

        let older = ScriptedRunner([origin, RemoteCommandResult(
            status: 1, stdout: #"{"ok":false,"error":"invalid request: Cannot initialize Command from invalid String value session.companion.new"}"#,
            stderr: "")])
        let (oldServer, _, _) = try makeServer(older, store: store, row: row)
        let old = await oldServer.createCompanion(row.id.uuidString, options: CompanionOptions(), window: nil)
        XCTAssertEqual(old.error, "the agterm on buildbox is too old for companions")
        XCTAssertTrue(store.companions(of: row.id).isEmpty)
    }

    // an older CLI refuses the new flag before sending anything, which read as an unknown outcome
    func testAnOlderOriginCLIRefusingTheArgumentsIsTooOldNotUnknown() async throws {
        let usage = RemoteCommandResult(status: 64, stdout: "", stderr: "Error: Unknown option '--parent'\nUsage: agtermctl session new")
        let runner = ScriptedRunner([origin, usage])
        let (server, store, row) = try makeServer(runner)

        let reply = await server.createCompanion(row.id.uuidString, options: CompanionOptions(), window: nil)

        XCTAssertEqual(reply.error, "the agterm on buildbox is too old for companions")
        XCTAssertTrue(store.companions(of: row.id).isEmpty)

        let pageUsage = RemoteCommandResult(status: 64, stdout: "", stderr: "Error: Unexpected argument 'page-attach'")
        let pages = ScriptedRunner([pageUsage])
        let (pageServer, _, _) = try makeServer(pages, store: store, row: row)
        let page = await pageServer.attachRemotePage(created, host: "buildbox", parent: row.id, select: false)
        XCTAssertEqual(page.error, "the agterm on buildbox is too old for page companions")
    }

    func testACompanionThatNeverBecomesAttachableWithinTheBudgetIsNamedAndNotCreatedAgain() async throws {
        let runner = ScriptedRunner([origin, reply(id: created)] + Array(repeating: tree(sessions: ""), count: 50))
        let (server, store, row) = try makeServer(runner)
        var now = Date()
        server.hudClock = {
            now = now.addingTimeInterval(3)
            return now
        }

        let reply = await server.createCompanion(row.id.uuidString, options: CompanionOptions(), window: nil)

        XCTAssertEqual(reply.error, "created companion \(created) on buildbox but could not attach it: it did not become attachable; "
                       + "`agtermctl zmx attach buildbox \(created)` attaches it")
        let creates = runner.invocations.filter { $0.last?.contains("--parent") == true }
        XCTAssertEqual(creates.count, 1)
        XCTAssertLessThan(runner.invocations.count, 12, "the wall-clock budget ends the polling")
        XCTAssertTrue(store.companions(of: row.id).isEmpty)
    }

    func testACreateWithNoAnswerIsAnUnknownOutcomeAndAStaleBindingCreatesNothing() async throws {
        let silent = ScriptedRunner([origin, RemoteCommandResult(status: -1, stdout: "", stderr: "the remote did not answer in time")])
        let (server, store, row) = try makeServer(silent)
        let unknown = await server.createCompanion(row.id.uuidString, options: CompanionOptions(), window: nil)
        XCTAssertEqual(unknown.error, "buildbox gave no answer (the remote did not answer in time); "
                       + "whether the companion was created there is unknown")

        let stale = ScriptedRunner([tree(sessions: "")])
        let (staleServer, _, _) = try makeServer(stale, store: store, row: row)
        let refused = await staleServer.createCompanion(row.id.uuidString, options: CompanionOptions(), window: nil)
        XCTAssertEqual(refused.error, "the session on buildbox is not attachable now; nothing was created")
        XCTAssertEqual(stale.invocations.count, 1, "nothing is created on an origin that cannot attach it")
        XCTAssertTrue(store.companions(of: row.id).isEmpty)
    }

    func testAFullReceiptOverAFailedTransportNamesTheCompanionAndAttachesNothing() async throws {
        let receipt = RemoteCommandResult(status: 255, stdout: reply(id: created).stdout, stderr: "Connection reset")
        let runner = ScriptedRunner([origin, receipt])
        let (server, store, row) = try makeServer(runner)

        let reply = await server.createCompanion(row.id.uuidString, options: CompanionOptions(), window: nil)

        XCTAssertEqual(reply.error, "created companion \(created) on buildbox but the connection failed before attaching it; "
                       + "`agtermctl zmx attach buildbox \(created)` attaches it")
        XCTAssertEqual(runner.invocations.count, 2, "nothing is created again or attached")
        XCTAssertTrue(store.companions(of: row.id).isEmpty)
    }

    func testAParentClosedDuringTheWaitLeavesTheCompanionNamedAndNoOrphanRow() async throws {
        let runner = ScriptedRunner([origin, reply(id: created), tree(sessions: session(created))])
        let (server, store, row) = try makeServer(runner)
        server.remoteCompanionPause = {}
        runner.beforeCall = { index in
            if index == 2 { Task { @MainActor in store.closeSession(row.id) } }
        }

        let reply = await server.createCompanion(row.id.uuidString, options: CompanionOptions(), window: nil)

        XCTAssertEqual(reply.error, "created companion \(created) on buildbox but could not attach it: its parent row here was closed; "
                       + "`agtermctl zmx attach buildbox \(created)` attaches it")
        XCTAssertNil(store.workspaces.flatMap(\.sessions).first { $0.parentID == row.id })
    }

    func testAnAttachFailureAfterCreationNamesTheCreatedCompanion() async throws {
        let unaddressable = tree(sessions: #"{"id":"\#(created)","name":"c","windowID":"w1","windowName":"main","workspaceID":"ws1","#
                                 + #""workspaceName":"work","cwd":"/repo","panes":[{"pane":"middle","daemon":"agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa3"}]}"#)
        let runner = ScriptedRunner([origin, reply(id: created), unaddressable])
        let (server, store, row) = try makeServer(runner)

        let reply = await server.createCompanion(row.id.uuidString, options: CompanionOptions(), window: nil)

        XCTAssertEqual(reply.error, "created companion \(created) on buildbox but could not attach it: buildbox reported panes agterm "
                       + "cannot address; `agtermctl zmx attach buildbox \(created)` attaches it")
        XCTAssertTrue(store.companions(of: row.id).isEmpty)
    }

    func testClosingARemoteCompanionHereOnlyDetachesIt() async throws {
        let runner = ScriptedRunner([origin, reply(id: created), tree(sessions: session(created))])
        let (server, store, row) = try makeServer(runner)
        let reply = await server.createCompanion(row.id.uuidString, options: CompanionOptions(), window: nil)
        let companion = try XCTUnwrap(reply.result?.id)

        let closed = server.closeSession(companion, window: nil)

        XCTAssertTrue(closed.ok, closed.error ?? "")
        XCTAssertTrue(store.companions(of: row.id).isEmpty)
        XCTAssertNotNil(store.session(withID: row.id))
        XCTAssertEqual(runner.invocations.count, 3, "the origin is never asked to end anything")
    }

    func testAPageCompanionOfARemoteRowIsCreatedThereAndShownHereThroughItsOwnChannel() async throws {
        let runner = ScriptedRunner([origin, reply(id: created), pageAttach(created)])
        let (server, store, row) = try makeServer(runner)
        let launcher = FakePageLauncher()
        server.pageLauncher = launcher
        let options = ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil,
                                                       page: .file(path: "/srv/report.html", grantRoot: "/srv"), javascript: true)

        let reply = await server.createPageCompanion(row.id.uuidString, window: nil, options: options)

        XCTAssertTrue(reply.ok, reply.error ?? "")
        let page = try XCTUnwrap(store.companions(of: row.id).first)
        XCTAssertEqual(page.content, .page)
        XCTAssertEqual(page.remoteHost, "buildbox")
        XCTAssertEqual(page.htmlOverlay?.replicaOf, UUID(uuidString: pageID))
        XCTAssertEqual(page.remotePresentation?.binding.remoteSessionID, created, "New Companion on the row makes a sibling there")
        let create = try XCTUnwrap(runner.invocations[1].last)
        for word in ["overlay", "open", "--companion", "--html", "/srv/report.html", "--cwd", "/srv", "--js"] {
            XCTAssertTrue(create.contains(word), word)
        }
        XCTAssertTrue(try XCTUnwrap(runner.invocations[2].last).contains("page-attach"))
        let serve = try XCTUnwrap(launcher.launches.last?.last)
        XCTAssertTrue(serve.contains("page-serve") && serve.contains("tok-1"), "the channel claims the attachment's own token")
        let local = try XCTUnwrap(reply.result?.pageID.flatMap(UUID.init(uuidString:)))
        XCTAssertEqual(local, page.htmlOverlay?.id, "a --block caller polls the view's own page")
        XCTAssertEqual(HtmlPageOutcomes.shared.outcome(for: local)?.outcome, .pending)
    }

    // a --block caller on a remote page companion had no outcome to read once the page ended there
    func testThePagesOutcomeThereBecomesTheViewsOutcomeWhenThatMacEndsIt() async throws {
        let submitted = RemoteCommandResult(status: 0, stdout: #"{"ok":true,"result":{"pageOutcome":{"pageID":"\#(pageID)","#
                                            + #""outcome":"submitted","value":"yes"}}}"#, stderr: "")
        let runner = ScriptedRunner([origin, reply(id: created), pageAttach(created), submitted])
        let (server, store, row) = try makeServer(runner)
        let launcher = FakePageLauncher()
        server.pageLauncher = launcher
        let options = ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil,
                                                       page: .file(path: "/srv/report.html", grantRoot: "/srv"))
        let reply = await server.createPageCompanion(row.id.uuidString, window: nil, options: options)
        let local = try XCTUnwrap(reply.result?.pageID.flatMap(UUID.init(uuidString:)))

        launcher.helpers.last?.exit()
        let deadline = Date().addingTimeInterval(5)
        while !store.companions(of: row.id).isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }

        XCTAssertTrue(store.companions(of: row.id).isEmpty, "the page ending there closes the view")
        XCTAssertEqual(HtmlPageOutcomes.shared.outcome(for: local), ControlHtmlPageOutcome(pageID: local.uuidString, outcome: .submitted, value: "yes"))
        XCTAssertTrue(try XCTUnwrap(runner.invocations.last?.last).contains("result"))
    }

    // a page parked by a soft close kept its row when its page ended there, so Undo brought back a dead page
    func testAPageEndingThereWhileParkedNeverComesBackOnUndo() async throws {
        for closesParent in [false, true] {
            let submitted = RemoteCommandResult(status: 0, stdout: #"{"ok":true,"result":{"pageOutcome":{"pageID":"\#(pageID)","#
                                                + #""outcome":"submitted","value":"yes"}}}"#, stderr: "")
            let runner = ScriptedRunner([origin, reply(id: created), pageAttach(created), submitted])
            let (server, store, row) = try makeServer(runner)
            let launcher = FakePageLauncher()
            server.pageLauncher = launcher
            let options = ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil,
                                                           page: .file(path: "/srv/report.html", grantRoot: "/srv"))
            let reply = await server.createPageCompanion(row.id.uuidString, window: nil, options: options)
            let page = try XCTUnwrap(reply.result?.id.flatMap(UUID.init(uuidString:)))
            XCTAssertTrue(store.softCloseSession(closesParent ? row.id : page, grace: 600))

            launcher.helpers.last?.exit()
            let deadline = Date().addingTimeInterval(5)
            while store.pendingCloseSession(withID: page) != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }

            XCTAssertNil(store.pendingCloseSession(withID: page), "closesParent \(closesParent)")
            XCTAssertEqual(store.undoPendingClose(), closesParent, "the parent alone is still undoable")
            XCTAssertNil(store.session(withID: page))
            XCTAssertNotNil(store.session(withID: row.id))
        }
    }

    func testAPersistentPageNeedsThisMacsBrowserStoreBeforeAnythingIsCreated() async throws {
        let runner = ScriptedRunner([])
        let (server, store, row) = try makeServer(runner)
        let registry = HtmlOverlayRegistry.shared
        let before = registry.profile
        defer { registry.profile = before }
        let broken = stateDir.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("not a uuid".utf8).write(to: broken.appendingPathComponent("browser-profile"))
        registry.profile = BrowserProfile(directory: broken)
        let options = ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil,
                                                       page: .url(try XCTUnwrap(URL(string: "https://example.com/"))), persistent: true)

        let reply = await server.createPageCompanion(row.id.uuidString, window: nil, options: options)

        XCTAssertTrue(reply.error?.hasPrefix("session.companion.page:") == true, reply.error ?? "")
        XCTAssertTrue(runner.invocations.isEmpty)
        XCTAssertTrue(store.companions(of: row.id).isEmpty)
    }

    func testALoopbackPageIsRefusedBeforeTheOriginIsAsked() async throws {
        let runner = ScriptedRunner([])
        let (server, store, row) = try makeServer(runner)
        let options = ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil,
                                                       page: .url(try XCTUnwrap(URL(string: "http://localhost:3000/"))))

        let reply = await server.createPageCompanion(row.id.uuidString, window: nil, options: options)

        XCTAssertEqual(reply.error, "a loopback page cannot be a companion of a remote session")
        XCTAssertTrue(runner.invocations.isEmpty)
        XCTAssertTrue(store.companions(of: row.id).isEmpty)
    }

    func testAListedPageRowAttachesOnlyUnderTheOneRowShowingItsParent() async throws {
        let endpoint = #"{"executable":"/Applications/agterm.app/zmx","socketDirectory":"/tmp/agterm-zmx-abc"}"#
        let pageRow = #"{"id":"\#(created)","name":"report","windowID":"w1","windowName":"main","workspaceID":"ws1","#
            + #""workspaceName":"work","cwd":"/srv","panes":[],"parent":"origin-1","content":"page"}"#
        let listing = tree(sessions: session("origin-1") + "," + pageRow)
        let runner = ScriptedRunner([listing, pageAttach(created), listing])
        let (server, store, row) = try makeServer(runner)
        server.pageLauncher = FakePageLauncher()
        let decoded = try JSONDecoder().decode(ControlZmxEndpoint.self, from: Data(endpoint.utf8))
        store.bindRemote(RemoteBinding(remoteSessionID: "origin-1", daemonsByLocalPane: [:], presentationVersion: nil,
                                       origin: RemoteBinding.Origin(host: "buildbox", endpoint: decoded, sessionName: "c")),
                         forSession: row.id)

        let attached = await server.attachRemoteSession(host: "buildbox", session: created, window: nil)

        XCTAssertTrue(attached.ok, attached.error ?? "")
        XCTAssertEqual(store.companions(of: row.id).first?.content, .page)

        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let other = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory(), remoteHost: "buildbox"))
        store.bindRemote(RemoteBinding(remoteSessionID: "origin-1", daemonsByLocalPane: [:], presentationVersion: nil,
                                       origin: RemoteBinding.Origin(host: "buildbox", endpoint: decoded, sessionName: "c")),
                         forSession: other.id)
        let ambiguous = await server.attachRemoteSession(host: "buildbox", session: created, window: nil)
        XCTAssertEqual(ambiguous.error, "more than one row here shows the page's parent")
    }

    func testAGuiNewCompanionOnARemoteRowCreatesItThroughTheOrigin() async throws {
        let runner = ScriptedRunner([origin, reply(id: created), tree(sessions: session(created))])
        let (server, store, row) = try makeServer(runner)
        server.actions.remoteAttacher = server

        server.actions.newCompanion(row.id, in: store)

        let deadline = Date().addingTimeInterval(5)
        while store.companions(of: row.id).isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store.companions(of: row.id).first?.remoteHost, "buildbox")
    }

    private func makeServer(_ runner: ScriptedRunner, store: AppStore? = nil,
                            row: Session? = nil) throws -> (ControlServer, AppStore, Session) {
        let actions = AppActions(library: library)
        let server = ControlServer(library: library, actions: actions, settingsModel: settings,
                                   identity: AppIdentity(version: "9.9.9", commit: "testsha"), remoteRunner: runner,
                                   socketPath: stateDir.appendingPathComponent("control-\(UUID().uuidString).sock").path)
        server.remoteCompanionPause = {}
        if let store, let row { return (server, store, row) }
        let active = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(active.currentWorkspaceID)
        let attached = try XCTUnwrap(active.addSession(toWorkspace: workspace, cwd: NSHomeDirectory(), remoteHost: "buildbox"))
        active.bindRemote(RemoteBinding(remoteSessionID: "origin-1", daemonsByLocalPane: [:], presentationVersion: nil),
                          forSession: attached.id)
        return (server, active, attached)
    }

    private var origin: RemoteCommandResult { tree(sessions: session("origin-1")) }
    private let pageID = "5A1E7C2B-3D4F-4E5A-8B6C-7D8E9F0A1B2C"

    private func pageAttach(_ id: String) -> RemoteCommandResult {
        RemoteCommandResult(status: 0, stdout: #"{"ok":true,"result":{"id":"\#(id)","parent":"origin-1","companionPage":{"#
            + #""page":"\#(pageID)","token":"tok-1","source":{"file":{"path":"/srv/report.html","grantRoot":"/srv"}},"#
            + #""identity":"report.html","chromeless":false,"javascript":true,"navigation":false,"browse":false,"#
            + #""persistent":false,"follow":false}}}"#, stderr: "")
    }

    private func reply(id: String) -> RemoteCommandResult {
        RemoteCommandResult(status: 0, stdout: #"{"ok":true,"result":{"id":"\#(id)","parent":"origin-1"}}"#, stderr: "")
    }

    private func session(_ id: String) -> String {
        #"{"id":"\#(id)","name":"c","windowID":"w1","windowName":"main","workspaceID":"ws1","workspaceName":"work","#
            + #""cwd":"/repo","panes":[{"pane":"left","daemon":"agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa3"}]}"#
    }

    private func tree(sessions: String) -> RemoteCommandResult {
        RemoteCommandResult(status: 0, stdout: #"{"ok":true,"result":{"remote":{"#
            + #""endpoint":{"executable":"/Applications/agterm.app/zmx","socketDirectory":"/tmp/agterm-zmx-abc"},"#
            + #""sessions":[\#(sessions)]}}}"#, stderr: "")
    }
}

/// ScriptedRunner answers each ssh call with the next scripted result, so one remote flow's several calls are covered.
private final class ScriptedRunner: RemoteCommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [RemoteCommandResult]
    private var recorded: [[String]] = []
    /// beforeCall runs with each call's index before it answers, so a test can change the model mid-flow.
    var beforeCall: (@Sendable (Int) -> Void)?

    var invocations: [[String]] { lock.withLock { recorded } }

    init(_ results: [RemoteCommandResult]) {
        self.results = results
    }

    func run(_ argv: [String], deadline _: TimeInterval) async -> RemoteCommandResult {
        beforeCall?(invocations.count)
        await Task.yield()
        return lock.withLock {
            recorded.append(argv)
            return results.isEmpty ? RemoteCommandResult(status: 255, stdout: "", stderr: "unscripted call") : results.removeFirst()
        }
    }
}
