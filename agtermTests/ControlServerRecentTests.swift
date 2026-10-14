import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerRecentTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var server: ControlServer!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-recent-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            server = ControlServer(
                library: library,
                actions: AppActions(library: library),
                settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
                identity: AppIdentity(version: "9.9.9", commit: "testsha"),
                socketPath: stateDir.appendingPathComponent("control-\(UUID().uuidString).sock").path
            )
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            server = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
        }
        try await super.tearDown()
    }

    private func closeNewSession(in store: AppStore, name: String) throws -> UUID {
        let workspace = store.addWorkspace(name: "project-\(name)")
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp", name: name))
        store.closeSession(session.id)
        return session.id
    }

    func testListReportsEntriesNewestFirstAndClearEmptiesIt() throws {
        let store = try XCTUnwrap(library.activeStore)
        let older = try closeNewSession(in: store, name: "older")
        let newer = try closeNewSession(in: store, name: "newer")

        let listed = try XCTUnwrap(server.listRecentClosed().result?.recent)
        XCTAssertEqual(listed.map(\.sessionIDs), [[newer.uuidString], [older.uuidString]])
        XCTAssertEqual(listed.map(\.title), ["newer", "older"])

        XCTAssertEqual(server.clearRecentClosed(), ControlResponse(ok: true))
        XCTAssertEqual(server.listRecentClosed().result?.recent, [])
        XCTAssertEqual(server.clearRecentClosed(), ControlResponse(ok: true))
    }

    func testOpenWithoutAnIdReopensTheNewestEntryAndConsumesIt() throws {
        let store = try XCTUnwrap(library.activeStore)
        let windowID = try XCTUnwrap(library.activeWindowID)
        let older = try closeNewSession(in: store, name: "older")
        let newer = try closeNewSession(in: store, name: "newer")

        let open = try XCTUnwrap(server.openRecentClosed(nil, window: nil).result?.recentOpen)

        XCTAssertEqual(open.window, windowID.uuidString)
        XCTAssertTrue(open.complete)
        XCTAssertEqual(open.item.sessionIDs, [newer.uuidString])
        XCTAssertNotNil(store.session(withID: newer))
        XCTAssertNil(store.session(withID: older))
        XCTAssertEqual(server.listRecentClosed().result?.recent?.map(\.sessionIDs), [[older.uuidString]])
    }

    func testOpenByPrefixReopensThatEntry() throws {
        let store = try XCTUnwrap(library.activeStore)
        let older = try closeNewSession(in: store, name: "older")
        _ = try closeNewSession(in: store, name: "newer")
        let entry = try XCTUnwrap(library.recentClosedItems.last)

        let response = server.openRecentClosed(String(entry.id.uuidString.prefix(12)), window: nil)

        XCTAssertEqual(response.result?.recentOpen?.item.id, entry.id.uuidString)
        XCTAssertNotNil(store.session(withID: older))
    }

    func testAnUnknownWindowOrEntryRestoresNothing() throws {
        let store = try XCTUnwrap(library.activeStore)
        let closed = try closeNewSession(in: store, name: "api")
        let before = library.recentClosedItems

        let badWindow = server.openRecentClosed(nil, window: "ffffffff")
        let badEntry = server.openRecentClosed("ffffffff", window: nil)

        XCTAssertFalse(badWindow.ok)
        XCTAssertEqual(badEntry, ControlResponse(ok: false, error: "no such recent item: ffffffff"))
        XCTAssertNil(store.session(withID: closed))
        XCTAssertEqual(library.recentClosedItems, before)
    }

    func testAClearThatCannotBeWrittenIsAnErrorAndKeepsTheEntries() throws {
        let store = try XCTUnwrap(library.activeStore)
        _ = try closeNewSession(in: store, name: "api")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: stateDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stateDir.path) }

        XCTAssertEqual(server.clearRecentClosed(), ControlResponse(ok: false, error: "could not clear recent items"))
        XCTAssertEqual(server.listRecentClosed().result?.recent?.count, 1)
    }

    func testAClosedWindowRestoresNothing() throws {
        let store = try XCTUnwrap(library.activeStore)
        let closedSession = try closeNewSession(in: store, name: "api")
        let closedWindow = library.newWindow()
        library.closeWindow(closedWindow.id)
        let before = library.recentClosedItems

        XCTAssertFalse(server.openRecentClosed(nil, window: closedWindow.id.uuidString).ok)
        XCTAssertNil(store.session(withID: closedSession))
        XCTAssertEqual(library.recentClosedItems, before)
    }

    func testAnEmptyListIsRefused() {
        XCTAssertEqual(server.openRecentClosed(nil, window: nil),
                       ControlResponse(ok: false, error: "no recently closed items"))
    }

    func testOpenRoutesToTheWindowHoldingTheWorkspaceWithoutMovingFrontmost() throws {
        let source = try XCTUnwrap(library.activeStore)
        let sourceID = try XCTUnwrap(library.activeWindowID)
        let workspace = source.addWorkspace(name: "project")
        let session = try XCTUnwrap(source.addSession(toWorkspace: workspace.id, cwd: "/tmp", name: "api"))
        let other = library.newWindow()
        let frontmost = library.frontmostWindowID
        source.closeSession(session.id)

        let open = try XCTUnwrap(server.openRecentClosed(nil, window: other.id.uuidString).result?.recentOpen)

        XCTAssertEqual(open.window, sourceID.uuidString)
        XCTAssertNotNil(source.session(withID: session.id))
        XCTAssertNil(library.store(for: other.id)?.session(withID: session.id))
        XCTAssertEqual(library.frontmostWindowID, frontmost)
    }

    func testOpenDuringTheGraceWindowRestoresTheOriginalGroup() throws {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = store.addWorkspace(name: "project")
        let first = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp", name: "a"))
        let second = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp", name: "b"))
        XCTAssertTrue(store.softCloseSessions([first.id, second.id], grace: 60))

        let open = try XCTUnwrap(server.openRecentClosed(nil, window: nil).result?.recentOpen)

        XCTAssertTrue(open.complete)
        XCTAssertTrue(store.session(withID: first.id) === first)
        XCTAssertTrue(store.session(withID: second.id) === second)
        XCTAssertEqual(server.listRecentClosed().result?.recent, [])
    }
}
