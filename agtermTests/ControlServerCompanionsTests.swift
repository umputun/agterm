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

    func testACompanionIsCreatedUnderItsParentWithItsTintAndAnswersWithTheParent() throws {
        let (store, parent) = try addSession()
        let options = CompanionOptions(cwd: "/tmp", name: "logs", select: false, tint: SidebarTint(color: .red))

        let reply = server.createCompanion(parent.id.uuidString, options: options, window: nil)

        XCTAssertTrue(reply.ok, reply.error ?? "")
        let companion = try XCTUnwrap(reply.result?.id.flatMap(UUID.init(uuidString:)).flatMap(store.session(withID:)))
        XCTAssertEqual(reply.result?.parent, parent.id.uuidString)
        XCTAssertEqual(companion.parentID, parent.id)
        XCTAssertEqual(companion.customName, "logs")
        XCTAssertEqual(companion.tint, SidebarTint(color: .red))
        XCTAssertNotEqual(store.selectedSessionID, companion.id)
    }

    func testARemoteParentIsRefused() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let remote = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory(), remoteHost: "far"))

        let reply = server.createCompanion(remote.id.uuidString, options: CompanionOptions(), window: nil)

        XCTAssertEqual(reply.error, "companions of a remote session are not supported yet")
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
