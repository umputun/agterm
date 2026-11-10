import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerRemoteGroupTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var settings: SettingsModel!
    private let pageID = "5A1E7C2B-3D4F-4E5A-8B6C-7D8E9F0A1B2C"

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-remote-group-tests-\(UUID().uuidString)", isDirectory: true)
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

    func testAGroupArrivesUnderItsParentInTheOriginsOrderWithOnlyTheParentSelected() async throws {
        let listing = tree([parent(members: ["c1", "pg", "c2"]), terminal("c1", parent: "P"), terminal("c2", parent: "P"),
                            page("pg")])
        let runner = ScriptedRunner([listing, pageAttach()])
        let (server, store) = makeServer(runner)

        let reply = await server.attachRemoteGroup(host: "buildbox", session: "P", window: nil)

        XCTAssertTrue(reply.ok, reply.error ?? "")
        let row = try XCTUnwrap(reply.result?.id.flatMap(UUID.init(uuidString:)))
        XCTAssertEqual(store.companions(of: row).map { $0.remotePresentation?.binding.remoteSessionID }, ["c1", "pg", "c2"])
        XCTAssertEqual(store.selectedSessionID, row)
        XCTAssertEqual(reply.result?.remoteGroup?.membershipKnown, true)
        XCTAssertEqual(reply.result?.remoteGroup?.companions.map(\.origin), ["c1", "pg", "c2"])
        XCTAssertEqual(reply.result?.remoteGroup?.companions.compactMap(\.id).count, 3)
        XCTAssertEqual(runner.invocations.count, 2)
        XCTAssertEqual(runner.invocations.filter { $0.last?.contains("zmx tree") == true }.count, 1,
                       "the whole group comes from one discovery read")
        XCTAssertTrue(try XCTUnwrap(runner.invocations.last?.last).contains("page-attach"))
    }

    func testAKnownEmptyGroupIsOneRowAndOk() async throws {
        let (server, store) = makeServer(ScriptedRunner([tree([parent(members: [])])]))

        let reply = await server.attachRemoteGroup(host: "buildbox", session: "P", window: nil)

        XCTAssertTrue(reply.ok, reply.error ?? "")
        XCTAssertEqual(reply.result?.remoteGroup, ControlRemoteGroup(membershipKnown: true, companions: []))
        XCTAssertEqual(store.workspaces.flatMap(\.sessions).filter { $0.remoteHost != nil }.count, 1)
    }

    func testACompanionTargetIsRefusedBeforeAnyRowExists() async throws {
        let (server, store) = makeServer(ScriptedRunner([tree([parent(members: ["c1"]), terminal("c1", parent: "P")])]))
        let before = store.workspaces.flatMap(\.sessions).count

        let reply = await server.attachRemoteGroup(host: "buildbox", session: "c1", window: nil)

        XCTAssertEqual(reply.error, "c1 is a companion, not a group's parent")
        XCTAssertEqual(store.workspaces.flatMap(\.sessions).count, before)
    }

    func testAnUnavailableMemberIsNamedAndTheRestOfTheGroupStays() async throws {
        let (server, store) = makeServer(ScriptedRunner([tree([parent(members: ["c1", "c2"]), terminal("c1", parent: "P")])]))

        let reply = await server.attachRemoteGroup(host: "buildbox", session: "P", window: nil)

        let row = try XCTUnwrap(reply.result?.id)
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error, "kept build (\(row)) and 1 companion(s); not attached: c2-name (unavailable on buildbox)")
        XCTAssertEqual(store.companions(of: try XCTUnwrap(UUID(uuidString: row))).count, 1)
        XCTAssertEqual(reply.result?.remoteGroup?.companions.last, ControlRemoteGroupMember(origin: "c2", error: "unavailable on buildbox"))
    }

    func testAFailingTerminalMemberIsNamedWithItsReason() async throws {
        let unaddressable = #"{"id":"c1","name":"c1-name","windowID":"w1","windowName":"main","workspaceID":"ws1","#
            + #""workspaceName":"work","cwd":"/repo","parent":"P","panes":[{"pane":"middle","daemon":"\#(daemon)"}]}"#
        let (server, _) = makeServer(ScriptedRunner([tree([parent(members: ["c1"]), unaddressable])]))

        let reply = await server.attachRemoteGroup(host: "buildbox", session: "P", window: nil)

        let row = try XCTUnwrap(reply.result?.id)
        XCTAssertEqual(reply.error, "kept build (\(row)) and 0 companion(s); not attached: "
                       + "c1-name (buildbox reported panes agterm cannot address)")
    }

    func testAFailingPageMemberIsNamedAndTheTerminalsStay() async throws {
        let refused = RemoteCommandResult(status: 1, stdout: #"{"ok":false,"error":"no such page"}"#, stderr: "")
        let runner = ScriptedRunner([tree([parent(members: ["pg", "c1"]), page("pg"), terminal("c1", parent: "P")]), refused])
        let (server, store) = makeServer(runner)

        let reply = await server.attachRemoteGroup(host: "buildbox", session: "P", window: nil)

        let row = try XCTUnwrap(reply.result?.id)
        XCTAssertEqual(reply.error, "kept build (\(row)) and 1 companion(s); not attached: report (no such page)")
        XCTAssertEqual(store.companions(of: try XCTUnwrap(UUID(uuidString: row))).map(\.content), [.terminal])
    }

    func testAParentClosedDuringAPageWaitStopsTheGroupWithAMemberAfterIt() async throws {
        let runner = ScriptedRunner([tree([parent(members: ["pg", "c1"]), page("pg"), terminal("c1", parent: "P")]), pageAttach()])
        let (server, store) = makeServer(runner)
        runner.beforeCall = { index in
            guard index == 1 else { return }
            await MainActor.run { if let row = Self.attachedParent(in: store) { store.closeSession(row.id) } }
        }

        let reply = await server.attachRemoteGroup(host: "buildbox", session: "P", window: nil)

        let row = try XCTUnwrap(reply.result?.id)
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error, "parent row \(row) was closed; not attached: report, c1-name")
        XCTAssertTrue(store.workspaces.flatMap(\.sessions).filter { $0.remoteHost != nil }.isEmpty, "no orphan rows")
    }

    func testAParentClosedDuringTheLastPageWaitIsReportedAsClosed() async throws {
        let runner = ScriptedRunner([tree([parent(members: ["c1", "pg"]), terminal("c1", parent: "P"), page("pg")]), pageAttach()])
        let (server, store) = makeServer(runner)
        runner.beforeCall = { index in
            guard index == 1 else { return }
            await MainActor.run { if let row = Self.attachedParent(in: store) { store.closeSession(row.id) } }
        }

        let reply = await server.attachRemoteGroup(host: "buildbox", session: "P", window: nil)

        let row = try XCTUnwrap(reply.result?.id)
        XCTAssertEqual(reply.error, "parent row \(row) was closed; not attached: report")
        XCTAssertNotNil(reply.result?.remoteGroup?.companions.first?.id, "the receipt keeps the row c1 created before the close")
    }

    func testAParentMovedDuringAPageWaitTakesTheLaterMembersWithIt() async throws {
        let runner = ScriptedRunner([tree([parent(members: ["pg", "c1"]), page("pg"), terminal("c1", parent: "P")]), pageAttach()])
        let (server, store) = makeServer(runner)
        let other = store.addWorkspace(name: "other", revealNewWorkspace: false).id
        XCTAssertNotEqual(store.currentWorkspaceID, other, "the parent must start outside the workspace it is moved to")
        runner.beforeCall = { index in
            guard index == 1 else { return }
            await MainActor.run {
                if let row = Self.attachedParent(in: store) { _ = store.moveSession(row.id, toWorkspace: other) }
            }
        }

        let reply = await server.attachRemoteGroup(host: "buildbox", session: "P", window: nil)

        XCTAssertTrue(reply.ok, reply.error ?? "")
        let row = try XCTUnwrap(reply.result?.id.flatMap(UUID.init(uuidString:)))
        XCTAssertEqual(store.workspace(forSession: row)?.id, other)
        XCTAssertEqual(store.companions(of: row).count, 2)
        for companion in store.companions(of: row) {
            XCTAssertEqual(store.workspace(forSession: companion.id)?.id, other)
        }
        XCTAssertTrue(store.workspaces.filter { $0.id != other }.flatMap(\.sessions).allSatisfy { $0.remoteHost == nil })
    }

    func testAnOriginWithoutMembershipAttachesTheChildrenItListedAndSaysMembershipIsUnknown() async throws {
        let (server, store) = makeServer(ScriptedRunner([tree([parent(members: nil), terminal("c1", parent: "P")])]))

        let reply = await server.attachRemoteGroup(host: "buildbox", session: "P", window: nil)

        XCTAssertTrue(reply.ok, reply.error ?? "")
        XCTAssertEqual(reply.result?.remoteGroup?.membershipKnown, false)
        let row = try XCTUnwrap(reply.result?.id.flatMap(UUID.init(uuidString:)))
        XCTAssertEqual(store.companions(of: row).map { $0.remotePresentation?.binding.remoteSessionID }, ["c1"])
    }

    func testTheDispatcherReachesTheAppsGroupAttach() async throws {
        let (server, _) = makeServer(ScriptedRunner([tree([parent(members: ["c1"]), terminal("c1", parent: "P")])]))

        let reply = await ControlDispatcher(actions: server)
            .dispatch(ControlRequest(cmd: .zmxAttachGroup, target: "P", args: ControlArgs(host: "buildbox")))

        XCTAssertEqual(reply?.ok, true, reply?.error ?? "")
        XCTAssertEqual(reply?.result?.remoteGroup?.companions.map(\.origin), ["c1"])
    }

    func testAPageRootGroupArrivesAsATopLevelReplicaRowWithItsCompanionsUnderIt() async throws {
        let listing = tree([pageRoot(members: ["c1", "pg"]), terminal("c1", parent: "PR"), page("pg", parent: "PR")])
        let runner = ScriptedRunner([listing, pageAttach(id: "PR", page: rootPageID), pageAttach(id: "pg", parent: "PR")])
        let (server, store) = makeServer(runner)

        let reply = await server.attachRemoteGroup(host: "buildbox", session: "PR", window: nil)

        XCTAssertTrue(reply.ok, reply.error ?? "")
        let rowID = try XCTUnwrap(reply.result?.id.flatMap(UUID.init(uuidString:)))
        let row = try XCTUnwrap(store.session(withID: rowID))
        XCTAssertNil(row.parentID)
        XCTAssertEqual(row.content, .page)
        XCTAssertEqual(row.remoteHost, "buildbox")
        XCTAssertEqual(row.htmlOverlay?.replicaOf, UUID(uuidString: rootPageID))
        XCTAssertEqual(store.workspace(forSession: rowID)?.id, store.currentWorkspaceID)
        XCTAssertEqual(store.selectedSessionID, rowID)
        let binding = try XCTUnwrap(row.remotePresentation?.binding)
        XCTAssertEqual(binding.remoteSessionID, "PR")
        XCTAssertEqual(binding.origin, RemoteBinding.Origin(host: "buildbox", endpoint: endpoint, sessionName: "dash"))
        XCTAssertTrue(binding.daemonsByPane.isEmpty, "a page owns no daemon")
        XCTAssertEqual(store.companions(of: rowID).map { $0.remotePresentation?.binding.remoteSessionID }, ["c1", "pg"])
        XCTAssertEqual(store.companions(of: rowID).last?.remotePresentation?.binding.origin?.endpoint, endpoint)
        XCTAssertEqual(reply.result?.remoteGroup?.companions.compactMap(\.id).count, 2)
        XCTAssertTrue(try XCTUnwrap(runner.invocations[1].last).contains("page-attach"))
    }

    func testAPageRootGroupKeepsTheRootAndNamesAnUnavailableMember() async throws {
        let listing = tree([pageRoot(members: ["c1", "c2"]), terminal("c1", parent: "PR")])
        let (server, store) = makeServer(ScriptedRunner([listing, pageAttach(id: "PR", page: rootPageID)]))

        let reply = await server.attachRemoteGroup(host: "buildbox", session: "PR", window: nil)

        let row = try XCTUnwrap(reply.result?.id)
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error, "kept dash (\(row)) and 1 companion(s); not attached: c2-name (unavailable on buildbox)")
        XCTAssertEqual(store.companions(of: try XCTUnwrap(UUID(uuidString: row))).count, 1)
    }

    func testAPageRootTheOriginRefusesLeavesNoRow() async throws {
        let refused = RemoteCommandResult(status: 1, stdout: #"{"ok":false,"error":"a page on this Mac's loopback cannot be "#
                                          + #"shown on another Mac"}"#, stderr: "")
        let (server, store) = makeServer(ScriptedRunner([tree([pageRoot(members: ["c1"]), terminal("c1", parent: "PR")]), refused]))

        let reply = await server.attachRemoteGroup(host: "buildbox", session: "PR", window: nil)

        XCTAssertEqual(reply.error, "a page on this Mac's loopback cannot be shown on another Mac")
        XCTAssertTrue(store.workspaces.flatMap(\.sessions).allSatisfy { $0.remoteHost == nil })
    }

    func testAPageRootWhoseWorkspaceClosesDuringTheHandoffLeavesNoRow() async throws {
        let runner = ScriptedRunner([tree([pageRoot(members: ["c1"]), terminal("c1", parent: "PR")]), pageAttach(id: "PR", page: rootPageID)])
        let (server, store) = makeServer(runner)
        _ = store.addWorkspace(name: "other", revealNewWorkspace: false)
        let destination = try XCTUnwrap(store.currentWorkspaceID)
        runner.beforeCall = { index in
            guard index == 1 else { return }
            await MainActor.run { store.removeWorkspace(destination) }
        }

        let reply = await server.attachRemoteGroup(host: "buildbox", session: "PR", window: nil)

        XCTAssertEqual(reply.error, "the window or workspace to attach into was closed")
        XCTAssertNil(reply.result?.id)
        XCTAssertTrue(store.workspaces.flatMap(\.sessions).allSatisfy { $0.remoteHost == nil })
        XCTAssertEqual(runner.invocations.count, 2, "no member is attempted")
    }

    func testAPageRootWhoseWindowClosesDuringTheHandoffLeavesNoRow() async throws {
        let runner = ScriptedRunner([tree([pageRoot(members: [])]), pageAttach(id: "PR", page: rootPageID)])
        let (server, front) = makeServer(runner)
        let windows = try XCTUnwrap(library)
        let destination = windows.newWindow(name: "closing").id
        let destinationStore = try XCTUnwrap(windows.loadStore(for: destination))
        runner.beforeCall = { index in
            guard index == 1 else { return }
            await MainActor.run { windows.closeWindow(destination) }
        }

        let reply = await server.attachRemoteGroup(host: "buildbox", session: "PR", window: destination.uuidString)

        XCTAssertEqual(reply.error, "the window or workspace to attach into was closed")
        XCTAssertTrue(destinationStore.workspaces.flatMap(\.sessions).allSatisfy { $0.remoteHost == nil })
        XCTAssertTrue(front.workspaces.flatMap(\.sessions).allSatisfy { $0.remoteHost == nil })
    }

    // a page root parked by a soft close kept its group when its page ended there, so Undo brought back a dead page
    func testAPageRootEndingThereWhileItsGroupIsParkedFinalizesTheGroup() async throws {
        let listing = tree([pageRoot(members: ["c1", "pg"]), terminal("c1", parent: "PR"), page("pg", parent: "PR")])
        let (server, store) = makeServer(ScriptedRunner([listing, pageAttach(id: "PR", page: rootPageID), pageAttach(id: "pg", parent: "PR")]))
        let launcher = try XCTUnwrap(server.pageLauncher as? FakePageLauncher)
        let reply = await server.attachRemoteGroup(host: "buildbox", session: "PR", window: nil)
        XCTAssertTrue(reply.ok, reply.error ?? "")
        let root = try XCTUnwrap(reply.result?.id.flatMap(UUID.init(uuidString:)))
        let members = store.companions(of: root).map(\.id)
        XCTAssertEqual(members.count, 2)
        XCTAssertTrue(store.softCloseSession(root, grace: 600))
        XCTAssertNotNil(store.pendingCloseSession(withID: root))

        try XCTUnwrap(launcher.helpers.first).exit()
        let deadline = Date().addingTimeInterval(5)
        while store.pendingCloseSession(withID: root) != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }

        XCTAssertNil(store.pendingCloseSession(withID: root))
        for member in members { XCTAssertNil(store.pendingCloseSession(withID: member)) }
        XCTAssertFalse(store.undoPendingClose())
        XCTAssertNil(store.session(withID: root))
        XCTAssertTrue(members.allSatisfy { store.session(withID: $0) == nil })
    }

    private static func attachedParent(in store: AppStore) -> Session? {
        store.workspaces.flatMap(\.sessions).first { $0.remoteHost == "buildbox" && $0.parentID == nil }
    }

    private func makeServer(_ runner: ScriptedRunner) -> (ControlServer, AppStore) {
        let actions = AppActions(library: library)
        let server = ControlServer(library: library, actions: actions, settingsModel: settings,
                                   identity: AppIdentity(version: "9.9.9", commit: "testsha"), remoteRunner: runner,
                                   socketPath: stateDir.appendingPathComponent("control-\(UUID().uuidString).sock").path)
        server.pageLauncher = FakePageLauncher()
        return (server, library.activeStore!) // swiftlint:disable:this force_unwrapping
    }

    private let daemon = "agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa3"

    private func parent(members: [String]?) -> String {
        let list = members.map { ids in
            #","companions":["# + ids.map { #"{"id":"\#($0)","name":"\#(name(of: $0))"}"# }.joined(separator: ",") + "]"
        } ?? ""
        return #"{"id":"P","name":"build","windowID":"w1","windowName":"main","workspaceID":"ws1","workspaceName":"work","#
            + #""cwd":"/repo","panes":[{"pane":"left","daemon":"\#(daemon)"}]\#(list)}"#
    }

    private func terminal(_ id: String, parent: String) -> String {
        #"{"id":"\#(id)","name":"\#(name(of: id))","windowID":"w1","windowName":"main","workspaceID":"ws1","#
            + #""workspaceName":"work","cwd":"/repo","parent":"\#(parent)","panes":[{"pane":"left","daemon":"\#(daemon)"}]}"#
    }

    private func page(_ id: String, parent: String = "P") -> String {
        #"{"id":"\#(id)","name":"report","windowID":"w1","windowName":"main","workspaceID":"ws1","workspaceName":"work","#
            + #""cwd":"/srv","parent":"\#(parent)","content":"page","panes":[]}"#
    }

    private let rootPageID = "6B2F8D3C-4E5A-4F6B-9C7D-8E9F0A1B2C3D"
    private let endpoint = ControlZmxEndpoint(executable: "/Applications/agterm.app/zmx", socketDirectory: "/tmp/agterm-zmx-abc")

    private func pageRoot(members: [String]) -> String {
        let list = members.map { #"{"id":"\#($0)","name":"\#(name(of: $0))"}"# }.joined(separator: ",")
        return #"{"id":"PR","name":"dash","windowID":"w1","windowName":"main","workspaceID":"ws1","workspaceName":"work","#
            + #""cwd":"/srv","content":"page","panes":[],"companions":[\#(list)]}"#
    }

    private func name(of id: String) -> String { id == "pg" ? "report" : "\(id)-name" }

    private func tree(_ sessions: [String]) -> RemoteCommandResult {
        RemoteCommandResult(status: 0, stdout: #"{"ok":true,"result":{"remote":{"#
            + #""endpoint":{"executable":"/Applications/agterm.app/zmx","socketDirectory":"/tmp/agterm-zmx-abc"},"#
            + #""sessions":[\#(sessions.joined(separator: ","))]}}}"#, stderr: "")
    }

    private func pageAttach(id: String = "pg", parent: String = "P", page: String? = nil) -> RemoteCommandResult {
        RemoteCommandResult(status: 0, stdout: #"{"ok":true,"result":{"id":"\#(id)","parent":"\#(parent)","companionPage":{"#
            + #""page":"\#(page ?? pageID)","token":"tok-1","source":{"file":{"path":"/srv/report.html","grantRoot":"/srv"}},"#
            + #""identity":"report.html","chromeless":false,"javascript":true,"navigation":false,"browse":false,"#
            + #""persistent":false,"follow":false}}}"#, stderr: "")
    }
}
