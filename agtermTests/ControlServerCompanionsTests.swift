import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerCompanionsTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!
    private var settings: SettingsModel!
    private var server: ControlServer!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-control-companion-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            actions = AppActions(library: library)
            settings = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
            server = ControlServer(library: library, actions: actions, settingsModel: settings,
                                   identity: AppIdentity(version: "9.9.9", commit: "testsha"),
                                   socketPath: stateDir.appendingPathComponent("control.sock").path)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            server = nil
            settings = nil
            actions = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    func testACompanionIsCreatedUnderItsParentWithItsTintAndAnswersWithTheParent() async throws {
        let (store, parent) = try addSession()
        let options = CompanionOptions(cwd: "/tmp", name: "logs", select: false, tint: SidebarTint(color: .red))

        let reply = await server.createCompanion(parent.id.uuidString, options: options, window: nil)

        XCTAssertTrue(reply.ok, reply.error ?? "")
        let companion = try XCTUnwrap(reply.result?.id.flatMap(UUID.init(uuidString:)).flatMap(store.session(withID:)))
        XCTAssertEqual(reply.result?.parent, parent.id.uuidString)
        XCTAssertEqual(companion.parentID, parent.id)
        XCTAssertEqual(companion.customName, "logs")
        XCTAssertEqual(companion.tint, SidebarTint(color: .red))
        XCTAssertNotEqual(store.selectedSessionID, companion.id)
    }

    func testARemoteRowWithNoOriginBindingCreatesNothing() async throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let remote = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory(), remoteHost: "far"))

        let reply = await server.createCompanion(remote.id.uuidString, options: CompanionOptions(), window: nil)
        let copy = await server.duplicateAsCompanion(remote.id.uuidString, window: nil, select: true)

        XCTAssertEqual(reply.error, "the remote session is not attached")
        XCTAssertEqual(copy.error, "the remote session is not attached")
        XCTAssertTrue(store.companions(of: remote.id).isEmpty)
    }

    func testClosingAParentReportsEveryClosedIdAndTheGroupCount() throws {
        settings.setCloseGraceUndoEnabled(false)
        let (store, parent, children) = try group()

        let reply = server.closeSession(parent.id.uuidString, window: nil)

        XCTAssertEqual(reply.result?.id, parent.id.uuidString)
        XCTAssertEqual(reply.result?.affected, 3)
        XCTAssertEqual(reply.result?.closed, ([parent] + children).map(\.id.uuidString))
        XCTAssertNil(store.session(withID: children[0].id))
    }

    func testAPlainCloseKeepsItsBareReceipt() throws {
        let (_, session) = try addSession()

        let reply = server.closeSession(session.id.uuidString, window: nil)

        XCTAssertNil(reply.result?.affected)
        XCTAssertEqual(reply.result?.closed, [session.id.uuidString])
    }

    func testABatchNamingAParentAndItsChildCountsEachOnceHardAndSoft() throws {
        for soft in [false, true] {
            settings.setCloseGraceUndoEnabled(soft)
            let (store, parent, children) = try group()
            let other = try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.currentWorkspaceID), cwd: "/tmp"))

            let reply = server.closeSessions([parent.id.uuidString, children[0].id.uuidString, other.id.uuidString],
                                             window: nil)

            XCTAssertEqual(reply.result?.affected, 4, "soft: \(soft)")
            XCTAssertEqual(Set(reply.result?.closed ?? []), Set(([parent, other] + children).map(\.id.uuidString)), "soft: \(soft)")
        }
    }

    // a child named before its parent was archived on its own, so reopening the parent lost the child
    func testAHardBatchNamingTheChildFirstKeepsTheGroupInOneRecentEntry() throws {
        settings.setCloseGraceUndoEnabled(false)
        let (store, parent, children) = try group()

        let reply = server.closeSessions([children[1].id.uuidString, parent.id.uuidString], window: nil)

        XCTAssertEqual(reply.result?.closed, ([parent] + children).map(\.id.uuidString))
        let entries = library.recentClosedItems.filter { $0.session?.snapshot.id == children[1].id }
        XCTAssertTrue(entries.isEmpty, "the child rides the parent's entry")
        let entry = try XCTUnwrap(library.recentClosedItems.first { $0.session?.snapshot.id == parent.id })
        XCTAssertNotNil(library.reopenRecentClosedReportingWindow(entry.id))
        XCTAssertEqual(store.companions(of: parent.id).map(\.id), children.map(\.id))
    }

    func testMovingACompanionOutOfItsGroupIsRefusedAndAnOrdinaryNoOpIsNot() throws {
        let (store, parent, children) = try group()
        let other = store.addWorkspace(name: "other")
        let home = try XCTUnwrap(store.workspace(forSession: parent.id)?.id)

        let refused = server.moveSession(children[0].id.uuidString, window: nil, move: .workspace(other.id.uuidString))
        let batch = server.moveSessions(children.map(\.id.uuidString), window: nil, move: .workspace(other.id.uuidString))
        let noOp = server.moveSessions([parent.id.uuidString], window: nil, move: .workspace(home.uuidString))

        XCTAssertEqual(refused.error, ControlServer.companionMoveError)
        XCTAssertEqual(batch.error, ControlServer.companionMoveError)
        XCTAssertTrue(noOp.ok, noOp.error ?? "")
        XCTAssertEqual(store.workspace(forSession: children[0].id)?.id, home)
    }

    func testFoldingAParentPersistsAndALoneSessionIsRefused() throws {
        let (store, parent, _) = try group()
        let lone = try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.currentWorkspaceID), cwd: "/tmp"))
        let posted = expectation(forNotification: .agtermSetSessionExpanded, object: store)

        let folded = server.setSessionExpansion(parent.id.uuidString, window: nil, expanded: false)
        let refused = server.setSessionExpansion(lone.id.uuidString, window: nil, expanded: false)

        wait(for: [posted], timeout: 1)
        XCTAssertTrue(folded.ok)
        XCTAssertFalse(parent.isExpanded)
        XCTAssertEqual(refused.error, "session has no companions")
    }

    func testReopeningACompanionWhoseParentIsGoneNamesThatReason() throws {
        let directory = stateDir.appendingPathComponent("orphan", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entryID = UUID()
        let snapshot = SessionSnapshot(id: UUID(), customName: "logs", cwd: "/tmp", parentID: UUID())
        RecentClosedStore(directory: directory).record(RecentClosedItem(
            id: entryID, kind: .session, title: "logs", subtitle: nil, closedAt: Date(),
            session: RecentClosedSession(workspaceID: UUID(), workspaceName: "gone", workspaceIndex: 0, sessionIndex: 0,
                                         snapshot: snapshot)))
        let orphanLibrary = WindowLibrary(directory: directory)
        let orphanServer = ControlServer(library: orphanLibrary, actions: AppActions(library: orphanLibrary),
                                         settingsModel: SettingsModel(library: orphanLibrary,
                                                                      settingsStore: SettingsStore(directory: directory)),
                                         identity: AppIdentity(version: "9.9.9", commit: "testsha"),
                                         socketPath: directory.appendingPathComponent("control.sock").path)

        let reply = orphanServer.openRecentClosed(entryID.uuidString, window: nil)

        XCTAssertEqual(reply.error, ControlServer.companionWithoutParentError)
    }

    func testAPageCompanionRefusesTerminalCommandsAndKeepsOrdinaryOnes() throws {
        let (store, parent) = try addSession()
        let page = try store.addPageCompanion(to: parent.id, overlay: HtmlOverlay(source: .file(path: "/tmp/p.html", grantRoot: nil))).get()
        let id = page.id.uuidString

        for request in [ControlRequest(cmd: .sessionType, target: id, args: ControlArgs(text: "ls")),
                        ControlRequest(cmd: .sessionSplit, target: id), ControlRequest(cmd: .sessionHudOpen, target: id),
                        ControlRequest(cmd: .surfaceZoom, target: "surface:\(id):left"),
                        ControlRequest(cmd: .surfaceCursor, target: id),
                        ControlRequest(cmd: .sessionOverlayResize, target: id, args: ControlArgs(sizePercent: 50)),
                        ControlRequest(cmd: .askOpen, target: id)] {
            XCTAssertEqual(server.pageCompanionRefusal(request)?.error, "\(request.cmd.rawValue): not available on a page companion")
        }
        for request in [ControlRequest(cmd: .sessionRename, target: id), ControlRequest(cmd: .sessionClose, target: id),
                        ControlRequest(cmd: .sessionType, target: parent.id.uuidString),
                        ControlRequest(cmd: .sessionOverlayResize, target: id, args: ControlArgs(full: true)),
                        ControlRequest(cmd: .askOpen, target: id, args: ControlArgs(style: "gui")),
                        ControlRequest(cmd: .surfaceZoom, target: "surface:\(id):left", args: ControlArgs(mode: "hide"))] {
            XCTAssertNil(server.pageCompanionRefusal(request), "\(request.cmd.rawValue)")
        }
    }

    // a selected page refused the zoom exit and cursor read of another session's zoomed terminal
    func testWithAPageSelectedActiveZoomAndCursorStillReachTheZoomTarget() throws {
        let (store, parent) = try addSession()
        let page = try store.addPageCompanion(to: parent.id, overlay: HtmlOverlay(source: .file(path: "/tmp/p.html", grantRoot: nil))).get()
        store.selectSession(page.id)

        for mode in ["hide", "toggle", "show"] {
            XCTAssertNil(server.pageCompanionRefusal(ControlRequest(cmd: .surfaceZoom, args: ControlArgs(mode: mode))), mode)
        }
        XCTAssertNil(server.pageCompanionRefusal(ControlRequest(cmd: .surfaceCursor, target: "active")))
        XCTAssertNil(server.pageCompanionRefusal(ControlRequest(cmd: .surfaceZoom, target: "surface:\(parent.id.uuidString):left")))
    }

    func testAPageCompanionIsCreatedWithoutTouchingTheParentsOverlaySlot() async throws {
        let (store, parent) = try addSession()
        let options = ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: "#112233",
                                                       follow: false, pane: nil, page: .file(path: "/tmp/p.html", grantRoot: nil))

        let reply = await server.createPageCompanion(parent.id.uuidString, window: nil, options: options)

        XCTAssertTrue(reply.ok, reply.error ?? "")
        XCTAssertEqual(reply.result?.parent, parent.id.uuidString)
        XCTAssertNotNil(reply.result?.pageID)
        let page = try XCTUnwrap(reply.result?.id.flatMap(UUID.init(uuidString:)).flatMap(store.session(withID:)))
        XCTAssertEqual(page.content, .page)
        XCTAssertEqual(page.htmlOverlay?.id.uuidString, reply.result?.pageID)
        XCTAssertEqual(page.overlayBackgroundColor, "#112233")
        XCTAssertFalse(parent.overlayActive)
        XCTAssertNotEqual(store.selectedSessionID, page.id)
    }

    func testDuplicateAsCompanionRefusesAPageOrUnrealizedSourceAndCreatesNothing() async throws {
        let (store, parent) = try addSession()
        let page = try store.addPageCompanion(to: parent.id, overlay: HtmlOverlay(source: .file(path: "/tmp/p.html", grantRoot: nil))).get()
        let before = store.workspaces.flatMap(\.sessions).map(\.id)

        let cases = [(page.id, "a page companion has no terminal to duplicate"),
                     (parent.id, "left pane is not realized; nothing was created")]
        for (id, error) in cases {
            let reply = await server.duplicateAsCompanion(id.uuidString, window: nil, select: true)
            XCTAssertEqual(reply.error, error)
        }
        XCTAssertEqual(store.workspaces.flatMap(\.sessions).map(\.id), before)
    }

    func testDuplicateAsCompanionRefusesAPaneUnderAVisibleProgramOverlayAndCreatesNothing() async throws {
        let (store, covered) = try addSession()
        let (_, paneCovered) = try addSession()
        XCTAssertTrue(store.openOverlay(covered.id, command: "top"))
        XCTAssertNil(store.openPaneOverlay(paneCovered.id, pane: .left, command: "top"))
        let before = store.workspaces.flatMap(\.sessions).map(\.id)

        let sessionWide = await server.duplicateAsCompanion(covered.id.uuidString, window: nil, select: true)
        let paneLocal = await server.duplicateAsCompanion(paneCovered.id.uuidString, window: nil, select: true)
        XCTAssertEqual(sessionWide.error, "a program overlay covers the session; nothing was created")
        XCTAssertEqual(paneLocal.error, "left pane is covered by a program overlay; nothing was created")
        XCTAssertEqual(store.workspaces.flatMap(\.sessions).map(\.id), before)

        XCTAssertNil(store.setOverlaysHidden(covered.id, pane: nil, hidden: true))
        let uncovered = await server.duplicateAsCompanion(covered.id.uuidString, window: nil, select: true)
        XCTAssertEqual(uncovered.error, "left pane is not realized; nothing was created", "a hidden overlay does not block the copy")
    }

    private func addSession() throws -> (AppStore, Session) {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        return (store, try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory())))
    }

    private func group() throws -> (AppStore, Session, [Session]) {
        let (store, parent) = try addSession()
        let children = try (0..<2).map { _ in try store.addCompanion(to: parent.id, options: CompanionOptions(select: false)).get() }
        return (store, parent, children)
    }
}
