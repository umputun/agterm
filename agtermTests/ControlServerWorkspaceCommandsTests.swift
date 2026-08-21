import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for `ControlServer`'s workspace commands, which resolve a target against the real
/// window library before touching the store.
@MainActor
final class ControlServerWorkspaceCommandsTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var server: ControlServer!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-control-workspace-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            let actions = AppActions(library: library)
            server = ControlServer(
                library: library,
                actions: actions,
                settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
                identity: AppIdentity(version: "9.9.9", commit: "testsha"),
                socketPath: stateDir.appendingPathComponent("control.sock").path
            )
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            server = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    // the workspace's first session may already be the selected one, so selecting through the store's
    // own `selectWorkspace` is what makes the command retarget rather than report a lie
    func testSelectingTheWorkspaceOwningTheSelectionDropsTheFreshWorkspace() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        // the command selects the workspace's FIRST session, so that is the one that must already be
        // selected for this to be the same-value case
        let session = try XCTUnwrap(store.workspaces.first { $0.id == owner }?.sessions.first)
        store.selectSession(session.id)
        let fresh = store.addWorkspace(name: "fresh")
        XCTAssertEqual(store.currentWorkspaceID, fresh.id)

        let response = server.selectWorkspace(owner.uuidString, window: nil)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(response.result?.id, owner.uuidString)
        XCTAssertEqual(store.selectedSessionID, session.id)
        XCTAssertEqual(store.currentWorkspaceID, owner)
    }

    // both projections must be the SAME injected identity, not two independent bundle reads
    func testVersionAndTreeReportTheInjectedIdentity() throws {
        let injected = AppIdentity(version: "9.9.9", commit: "testsha")

        let version = server.appIdentity()
        XCTAssertTrue(version.ok, version.error ?? "")
        XCTAssertEqual(version.result?.app, injected)

        let tree = server.controlTree(window: nil)
        XCTAssertTrue(tree.ok, tree.error ?? "")
        XCTAssertEqual(tree.result?.tree?.app, injected)
    }

    func testSelectingAnEmptyWorkspaceReportsAndTargetsIt() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        store.selectSession(session.id)
        let empty = store.addWorkspace(name: "empty", revealNewWorkspace: false)

        let response = server.selectWorkspace(empty.id.uuidString, window: nil)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(response.result?.id, empty.id.uuidString)
        XCTAssertEqual(store.selectedSessionID, session.id, "an empty workspace has nothing to select")
        XCTAssertEqual(store.currentWorkspaceID, empty.id)
    }

    func testSelectingAFilteredOutEmptyWorkspaceRevealsIt() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let empty = store.addWorkspace(name: "empty", revealNewWorkspace: false)
        let other = store.addWorkspace(name: "other", revealNewWorkspace: false)
        store.setFocusMembership(owner, member: true)
        store.setFocusEnabled(true)
        XCTAssertEqual(store.visibleWorkspaces.map(\.id), [owner])

        let response = server.selectWorkspace(empty.id.uuidString, window: nil)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(store.currentWorkspaceID, empty.id)
        XCTAssertEqual(store.visibleWorkspaces.map(\.id), [owner, empty.id], "the target must be on screen")
        XCTAssertTrue(store.focusEnabled, "the filter must widen, not switch off")
        XCTAssertFalse(store.focusedWorkspaceIDs.contains(other.id), "an unrelated workspace stays filtered out")
    }
}
