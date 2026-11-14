import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerAttachedRecentTests: XCTestCase {
    private static let endpoint = ControlZmxEndpoint(executable: "/Applications/agterm.app/zmx", socketDirectory: "/tmp/agterm-zmx-abc")
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var settings: SettingsModel!
    private var servers: [ControlServer] = []

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-attached-recent-tests-\(UUID().uuidString)", isDirectory: true)
        library = WindowLibrary(directory: stateDir)
        settings = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
    }

    override func tearDown() async throws {
        for server in servers { server.stopRemotePresentations() }
        servers = []
        library.finalizeAllPendingCloses()
        settings = nil
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
        stateDir = nil
        try await super.tearDown()
    }

    func testAnEntryWhoseSessionTheOriginStillListsAttachesBackInItsPlace() async throws {
        let listed = tree(sessions: session("origin-1"))
        let runner = ScriptedRunner([ok(ControlResult(closed: ["origin-1"])), listed, listed, listed])
        let (server, store) = try makeServer(runner)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let before = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory()))
        let row = try attachedRow(in: store)
        let after = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory()))
        try await terminate(row, server)
        let entry = try XCTUnwrap(library.remoteRecentClosedItems.first)

        let route = try XCTUnwrap(server.attachedRecentRoute(ControlRequest(cmd: .recentOpen, target: entry.id.uuidString)))
        let reply = await server.runRemoteRoute(route)

        XCTAssertTrue(reply.ok, reply.error ?? "")
        let shown = try XCTUnwrap(reply.result?.id.flatMap(UUID.init(uuidString:)))
        let ids = try XCTUnwrap(store.workspaces.first { $0.id == workspace }).sessions.map(\.id)
        XCTAssertEqual(ids.firstIndex(of: shown), try XCTUnwrap(ids.firstIndex(of: before.id)) + 1)
        XCTAssertEqual(ids.firstIndex(of: after.id), try XCTUnwrap(ids.firstIndex(of: shown)) + 1)
        XCTAssertEqual(AttachedOrigin(try XCTUnwrap(store.session(withID: shown)))?.session, "origin-1")
        XCTAssertEqual(reply.result?.recentOpen?.item.kind, ControlRecentItem.remoteKind)
        XCTAssertTrue(library.remoteRecentClosedItems.isEmpty)
        XCTAssertEqual(runner.invocations.count, 4)
    }

    func testALocalEntryIsLeftToTheLocalReopen() async throws {
        let (server, store) = try makeServer(ScriptedRunner([ok(ControlResult(closed: ["origin-1"]))]))
        try await terminate(try attachedRow(in: store), server)
        let local = try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.currentWorkspaceID), cwd: NSHomeDirectory()))
        _ = store.closeSession(local.id)
        let localEntry = try XCTUnwrap(library.recentClosedItems.first)

        XCTAssertNil(server.attachedRecentRoute(ControlRequest(cmd: .recentOpen, target: localEntry.id.uuidString)))
        XCTAssertNil(server.attachedRecentRoute(ControlRequest(cmd: .recentOpen)))
    }

    func testAGoneSessionIsReopenedOnItsOriginThroughTheRecordedEntry() async throws {
        let listed = tree(sessions: session("origin-1"))
        let runner = ScriptedRunner([ok(ControlResult(closed: ["origin-1"], recentID: "r1")), tree(sessions: ""),
                                     reopened("r1", sessions: ["origin-1"]), listed, listed])
        let (server, store) = try makeServer(runner)
        try await terminate(try attachedRow(in: store), server)
        let entry = try XCTUnwrap(library.remoteRecentClosedItems.first)

        let reply = await server.reopenAttached(entry.id, window: nil)

        XCTAssertTrue(reply.ok, reply.error ?? "")
        XCTAssertTrue(line(runner, 2).contains("recent open"), line(runner, 2))
        XCTAssertTrue(line(runner, 2).contains("r1"), line(runner, 2))
        XCTAssertNotNil(shownRow("origin-1", in: store))
        XCTAssertTrue(library.remoteRecentClosedItems.isEmpty)
    }

    func testAGoneSessionWithNoRecordedEntryIsFoundInTheOriginsList() async throws {
        let listed = tree(sessions: session("origin-1"))
        let theirs = ControlRecentItem(id: "r9", kind: "session", title: "c", subtitle: nil, closedAt: 1, workspaceID: "ws1",
                                       sessionIDs: ["origin-1"])
        let runner = ScriptedRunner([ok(ControlResult(closed: ["origin-1"])), tree(sessions: ""), ok(ControlResult(recent: [theirs])),
                                     reopened("r9", sessions: ["origin-1"]), listed, listed])
        let (server, store) = try makeServer(runner)
        try await terminate(try attachedRow(in: store), server)
        let entry = try XCTUnwrap(library.remoteRecentClosedItems.first)

        let reply = await server.reopenAttached(entry.id, window: nil)

        XCTAssertTrue(reply.ok, reply.error ?? "")
        XCTAssertTrue(line(runner, 2).contains("recent list"), line(runner, 2))
        XCTAssertTrue(line(runner, 3).contains("r9"), line(runner, 3))
        XCTAssertNotNil(shownRow("origin-1", in: store))
    }

    func testAGoneSessionTheOriginKeepsNoRecordOfIsRefusedAndKeepsTheEntry() async throws {
        let runner = ScriptedRunner([ok(ControlResult(closed: ["origin-1"])), tree(sessions: ""), ok(ControlResult(recent: []))])
        let (server, store) = try makeServer(runner)
        try await terminate(try attachedRow(in: store), server)
        let entry = try XCTUnwrap(library.remoteRecentClosedItems.first)

        let reply = await server.reopenAttached(entry.id, window: nil)

        XCTAssertEqual(reply.error, "the session on buildbox is gone and buildbox keeps no record of it")
        XCTAssertEqual(library.remoteRecentClosedItems.map(\.id), [entry.id])
        XCTAssertNil(shownRow("origin-1", in: store))
    }

    func testAnUnreachableOriginKeepsTheEntryAndAddsNoRow() async throws {
        let runner = ScriptedRunner([ok(ControlResult(closed: ["origin-1"])),
                                     RemoteCommandResult(status: 255, stdout: "", stderr: "no route to host")])
        let (server, store) = try makeServer(runner)
        try await terminate(try attachedRow(in: store), server)
        let entry = try XCTUnwrap(library.remoteRecentClosedItems.first)
        let rows = store.workspaces.flatMap(\.sessions).count

        let reply = await server.reopenAttached(entry.id, window: nil)

        XCTAssertFalse(reply.ok)
        XCTAssertEqual(library.remoteRecentClosedItems.map(\.id), [entry.id])
        XCTAssertEqual(store.workspaces.flatMap(\.sessions).count, rows)
    }

    func testAnUndoableTerminateIsUndoneOnItsOriginAndItsRowAttachedAgainInItsWindow() async throws {
        let listed = tree(sessions: session("origin-1"))
        let runner = ScriptedRunner([ok(ControlResult(undoable: true, closed: ["origin-1"], undoID: "u1")),
                                     ok(ControlResult(id: "u1")), listed, listed])
        let (server, store) = try makeServer(runner)
        try await terminate(try attachedRow(in: store), server, undoable: true)
        let window = try XCTUnwrap(library.windowID(for: store))
        library.frontmostWindowID = library.newWindow().id
        let undo = try XCTUnwrap(library.takeAttachedUndo(window: window))
        XCTAssertEqual(undo.undoID, "u1")
        XCTAssertEqual(undo.sessions, ["origin-1"])

        let reply = await server.undoOriginClose(undo, window: window.uuidString)

        XCTAssertTrue(reply.ok, reply.error ?? "")
        XCTAssertTrue(line(runner, 1).contains("session undo --target u1"), line(runner, 1))
        XCTAssertNotNil(shownRow("origin-1", in: store))
        XCTAssertNil(library.attachedUndos[window])
        XCTAssertTrue(library.remoteRecentClosedItems.isEmpty)
    }

    func testCommandZInAnotherWindowLeavesThisWindowsOriginUndoAlone() async throws {
        let runner = ScriptedRunner([ok(ControlResult(undoable: true, closed: ["origin-1"], undoID: "u1"))])
        let (server, store) = try makeServer(runner)
        let actions = AppActions(library: library)
        actions.remoteAttacher = server
        try await terminate(try attachedRow(in: store), server, undoable: true)
        let window = try XCTUnwrap(library.windowID(for: store))
        let other = try XCTUnwrap(library.store(for: library.newWindow().id))

        XCTAssertFalse(actions.undoOriginCloseIfNewer(than: other))

        XCTAssertEqual(library.attachedUndos[window]?.map(\.undoID), ["u1"])
        XCTAssertEqual(runner.invocations.count, 1)
    }

    func testAnOriginUndoIsOrderedByWhenTheTerminateWasAskedFor() async throws {
        final class Answered: @unchecked Sendable { var at: Date? }
        let answered = Answered()
        let runner = ScriptedRunner([ok(ControlResult(undoable: true, closed: ["origin-1"], undoID: "u1"))])
        runner.beforeCall = { _ in answered.at = Date() }
        let (server, store) = try makeServer(runner)
        try await terminate(try attachedRow(in: store), server, undoable: true)
        let window = try XCTUnwrap(library.windowID(for: store))

        let undo = try XCTUnwrap(library.attachedUndos[window]?.last)

        XCTAssertLessThan(undo.initiated, try XCTUnwrap(answered.at))
    }

    func testAnOriginUndoLeavesByItselfWhenItsGraceEnds() async throws {
        let window = try XCTUnwrap(library.windowID(for: try XCTUnwrap(library.activeStore)))
        library.noteAttachedUndo(AttachedUndo(host: "buildbox", undoID: "u1", sessions: ["origin-1"], initiated: Date()),
                                 window: window, grace: 0.05)
        XCTAssertNotNil(library.attachedUndos[window])

        let deadline = Date().addingTimeInterval(30)
        while library.attachedUndos[window] != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }

        XCTAssertNil(library.attachedUndos[window])
    }

    func testAPageCompanionReopensUnderItsParentShownInAnotherWindow() async throws {
        let listing = tree(sessions: session("origin-1") + "," + pageRow("page-1", parent: "origin-1"))
        let runner = ScriptedRunner([listing, pageAttach("page-1", parent: "origin-1"), ok(ControlResult(closed: ["page-1"])),
                                     listing, listing, listing, pageAttach("page-1", parent: "origin-1")])
        let (server, store) = try makeServer(runner)
        server.pageLauncher = FakePageLauncher()
        let parent = try attachedRow(in: store)
        let pageID = try await attachPage("page-1", server)
        let page = try XCTUnwrap(store.session(withID: pageID))
        try await terminate(page, server)
        let entry = try XCTUnwrap(library.remoteRecentClosedItems.first)
        library.frontmostWindowID = library.newWindow().id

        let reply = await server.reopenAttached(entry.id, window: nil)

        XCTAssertTrue(reply.ok, reply.error ?? "")
        XCTAssertEqual(store.companions(of: parent.id).map(\.content), [.page])
        XCTAssertTrue(library.remoteRecentClosedItems.isEmpty)
    }

    func testAPageCompanionWhoseParentIsShownNowhereAttachesTheParentFirst() async throws {
        let listing = tree(sessions: session("origin-1") + "," + pageRow("page-1", parent: "origin-1"))
        let runner = ScriptedRunner([listing, pageAttach("page-1", parent: "origin-1"), ok(ControlResult(closed: ["page-1"])),
                                     listing, listing, listing, listing, pageAttach("page-1", parent: "origin-1")])
        let (server, store) = try makeServer(runner)
        server.pageLauncher = FakePageLauncher()
        let parent = try attachedRow(in: store)
        let pageID = try await attachPage("page-1", server)
        let page = try XCTUnwrap(store.session(withID: pageID))
        try await terminate(page, server)
        let entry = try XCTUnwrap(library.remoteRecentClosedItems.first { $0.originSessionID == "page-1" })
        _ = store.closeSession(parent.id)
        XCTAssertNil(shownRow("origin-1", in: store))

        let reply = await server.reopenAttached(entry.id, window: nil)

        XCTAssertTrue(reply.ok, reply.error ?? "")
        let row = try XCTUnwrap(shownRow("origin-1", in: store))
        XCTAssertEqual(store.companions(of: row.id).map(\.content), [.page])
        XCTAssertNil(library.remoteRecentClosedItems.first { $0.id == entry.id })
    }

    func testAPageRootReopensAtTopLevelAndAFailedPageAttachKeepsItsEntry() async throws {
        let listing = tree(sessions: pageRow("page-root", parent: nil))
        let refused = RemoteCommandResult(status: 1, stdout: #"{"ok":false,"error":"page is gone"}"#, stderr: "")
        let runner = ScriptedRunner([listing, pageAttach("page-root", parent: nil), ok(ControlResult(closed: ["page-root"])),
                                     listing, listing, listing, refused,
                                     listing, listing, listing, pageAttach("page-root", parent: nil)])
        let (server, store) = try makeServer(runner)
        server.pageLauncher = FakePageLauncher()
        let pageID = try await attachPage("page-root", server)
        let page = try XCTUnwrap(store.session(withID: pageID))
        try await terminate(page, server)
        let entry = try XCTUnwrap(library.remoteRecentClosedItems.first)

        let failed = await server.reopenAttached(entry.id, window: nil)
        XCTAssertFalse(failed.ok)
        XCTAssertEqual(library.remoteRecentClosedItems.map(\.id), [entry.id])

        let reply = await server.reopenAttached(entry.id, window: nil)
        XCTAssertTrue(reply.ok, reply.error ?? "")
        let row = try XCTUnwrap(shownRow("page-root", in: store))
        XCTAssertNil(row.parentID)
        XCTAssertEqual(row.content, .page)
        XCTAssertTrue(library.remoteRecentClosedItems.isEmpty)
    }

    func testCommandZUndoesANewerLocalCloseBeforeTheOriginsOne() async throws {
        let listed = tree(sessions: session("origin-1"))
        let runner = ScriptedRunner([ok(ControlResult(undoable: true, closed: ["origin-1"], undoID: "u1")),
                                     ok(ControlResult(id: "u1")), listed, listed])
        let (server, store) = try makeServer(runner)
        let actions = AppActions(library: library)
        actions.remoteAttacher = server
        try await terminate(try attachedRow(in: store), server, undoable: true)
        let local = try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.currentWorkspaceID), cwd: NSHomeDirectory()))
        XCTAssertTrue(store.softCloseSession(local.id, grace: 60))

        XCTAssertFalse(actions.undoOriginCloseIfNewer(than: store))
        XCTAssertTrue(store.undoPendingClose())
        XCTAssertTrue(actions.undoOriginCloseIfNewer(than: store))

        let deadline = Date().addingTimeInterval(5)
        while shownRow("origin-1", in: store) == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(shownRow("origin-1", in: store))
        XCTAssertTrue(line(runner, 1).contains("session undo --target u1"), line(runner, 1))
        XCTAssertNil(library.attachedUndos[try XCTUnwrap(library.windowID(for: store))])
    }

    private func makeServer(_ runner: ScriptedRunner) throws -> (ControlServer, AppStore) {
        let server = ControlServer(library: library, actions: AppActions(library: library), settingsModel: settings,
                                   identity: AppIdentity(version: "9.9.9", commit: "testsha"), remoteRunner: runner,
                                   socketPath: stateDir.appendingPathComponent("control-\(UUID().uuidString).sock").path)
        server.remoteCompanionPause = {}
        servers.append(server)
        return (server, try XCTUnwrap(library.activeStore))
    }

    private func attachedRow(in store: AppStore) throws -> Session {
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let row = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory(), remoteHost: "buildbox"))
        store.bindRemote(RemoteBinding(remoteSessionID: "origin-1", daemonsByLocalPane: [row.paneIdentity: ZmxSupport.daemonName(for: UUID())],
                                       presentationVersion: 1,
                                       origin: RemoteBinding.Origin(host: "buildbox", endpoint: Self.endpoint, sessionName: "c")),
                         forSession: row.id)
        return row
    }

    private func terminate(_ row: Session, _ server: ControlServer, undoable: Bool = false) async throws {
        let request = ControlRequest(cmd: .sessionTerminate, target: row.id.uuidString, args: ControlArgs(undoable: undoable ? true : nil))
        let reply = await server.runRemoteRoute(try XCTUnwrap(server.attachedRoute(request)))
        XCTAssertTrue(reply.ok, reply.error ?? "")
    }

    private func attachPage(_ id: String, _ server: ControlServer) async throws -> UUID {
        let reply = await server.attachRemoteSession(host: "buildbox", session: id, window: nil)
        XCTAssertTrue(reply.ok, reply.error ?? "")
        return try XCTUnwrap(reply.result?.id.flatMap(UUID.init(uuidString:)))
    }

    private func pageRow(_ id: String, parent: String?) -> String {
        #"{"id":"\#(id)","name":"report","windowID":"w1","windowName":"main","workspaceID":"ws1","#
            + #""workspaceName":"work","cwd":"/srv","panes":[],"#
            + (parent.map { #""parent":"\#($0)","# } ?? "") + #""content":"page"}"#
    }

    private func pageAttach(_ id: String, parent: String?) -> RemoteCommandResult {
        RemoteCommandResult(status: 0, stdout: #"{"ok":true,"result":{"id":"\#(id)","#
            + (parent.map { #""parent":"\#($0)","# } ?? "") + #""companionPage":{"#
            + #""page":"\#(UUID().uuidString)","token":"tok-1","source":{"file":{"path":"/srv/report.html","grantRoot":"/srv"}},"#
            + #""identity":"report.html","chromeless":false,"javascript":true,"navigation":false,"browse":false,"#
            + #""persistent":false,"follow":false}}}"#, stderr: "")
    }

    private func shownRow(_ session: String, in store: AppStore) -> Session? {
        store.workspaces.flatMap(\.sessions).first { AttachedOrigin($0)?.session == session }
    }

    private func line(_ runner: ScriptedRunner, _ index: Int) -> String {
        guard runner.invocations.indices.contains(index) else { return "" }
        return (runner.invocations[index].last ?? "").replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\\", with: "")
    }

    private func ok(_ result: ControlResult = ControlResult()) -> RemoteCommandResult {
        let data = (try? JSONEncoder().encode(ControlResponse(ok: true, result: result))) ?? Data()
        return RemoteCommandResult(status: 0, stdout: String(decoding: data, as: UTF8.self), stderr: "")
    }

    private func reopened(_ entry: String, sessions: [String]) -> RemoteCommandResult {
        let item = ControlRecentItem(id: entry, kind: "session", title: "c", subtitle: nil, closedAt: 1, workspaceID: "ws1",
                                     sessionIDs: sessions)
        return ok(ControlResult(recentOpen: ControlRecentOpen(item: item, window: "w1", complete: true)))
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
