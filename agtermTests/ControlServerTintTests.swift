import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for `ControlServer`'s `session.tint` and `workspace.tint` arms and the creation tint.
@MainActor
final class ControlServerTintTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!
    private var server: ControlServer!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-control-tint-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            actions = AppActions(library: library)
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
            actions = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    func testSessionTintSetsKeepsPlacementOnRecolorAndClears() throws {
        let (store, session) = try addSession()

        let placed = server.setSessionTint(session.id.uuidString, window: nil, update: .set(.green, parts: [.name]))
        XCTAssertTrue(placed.ok, placed.error ?? "")
        XCTAssertEqual(placed.result?.id, session.id.uuidString)
        XCTAssertEqual(store.session(withID: session.id)?.tint, SidebarTint(color: .green, parts: [.name]))

        _ = server.setSessionTint(session.id.uuidString, window: nil, update: .set(.red, parts: nil))
        XCTAssertEqual(store.session(withID: session.id)?.tint, SidebarTint(color: .red, parts: [.name]))

        let cleared = server.setSessionTint(session.id.uuidString, window: nil, update: .clear)
        XCTAssertTrue(cleared.ok, cleared.error ?? "")
        XCTAssertNil(store.session(withID: session.id)?.tint)
    }

    func testSessionTintReportsAnUnknownTarget() throws {
        _ = try addSession()

        XCTAssertFalse(server.setSessionTint(UUID().uuidString, window: nil, update: .set(.red, parts: nil)).ok)
    }

    func testWorkspaceTintColorsOnlyTheWorkspace() throws {
        let (store, session) = try addSession()
        let workspaceID = try XCTUnwrap(store.currentWorkspaceID)

        let response = server.setWorkspaceTint(workspaceID.uuidString, window: nil, update: .set(.blue, parts: [.icon, .name]))

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(store.workspaces.first { $0.id == workspaceID }?.tint, SidebarTint(color: .blue, parts: [.icon, .name]))
        XCTAssertNil(session.tint)
    }

    func testCreateWorkspaceAndSessionCarryTheirCreationTint() throws {
        let store = try XCTUnwrap(library.activeStore)

        let workspace = server.createWorkspace(window: nil, name: "prod", collapsed: false,
                                               tint: SidebarTint(color: .red, parts: [.name]))
        XCTAssertTrue(workspace.ok, workspace.error ?? "")
        let session = server.createSession(ControlSessionCreateOptions(
            window: nil, cwd: NSTemporaryDirectory(), workspace: nil, workspaceName: "prod", createWorkspace: nil,
            command: nil, name: "db", noSelect: true), tint: SidebarTint(color: .orange))
        XCTAssertTrue(session.ok, session.error ?? "")

        let tree = store.controlTree()
        let node = try XCTUnwrap(tree.workspaces.first { $0.name == "prod" })
        XCTAssertEqual(node.tint, "red")
        XCTAssertEqual(node.tintOn, ["name"])
        XCTAssertEqual(node.sessions.first?.tint, "orange")
        XCTAssertEqual(node.sessions.first?.tintOn, ["icon"])
    }

    func testEverySessionPlacementPathCarriesTheCreationTint() throws {
        let store = try XCTUnwrap(library.activeStore)
        let workspaceID = try XCTUnwrap(store.currentWorkspaceID)
        let byID = server.createSession(ControlSessionCreateOptions(
            window: nil, cwd: NSTemporaryDirectory(), workspace: workspaceID.uuidString, workspaceName: nil,
            createWorkspace: nil, command: nil, name: "by-id", noSelect: true), tint: SidebarTint(color: .blue))
        let anchorID = try XCTUnwrap(byID.result?.id)
        let byAnchor = server.createSession(ControlSessionCreateOptions(
            window: nil, cwd: NSTemporaryDirectory(), workspace: nil, workspaceName: nil, createWorkspace: nil,
            command: nil, name: "by-anchor", after: anchorID, noSelect: true), tint: SidebarTint(color: .gray, parts: [.name]))
        XCTAssertTrue(byAnchor.ok, byAnchor.error ?? "")

        let sessions = store.workspaces.flatMap(\.sessions)
        XCTAssertEqual(sessions.first { $0.customName == "by-id" }?.tint, SidebarTint(color: .blue))
        XCTAssertEqual(sessions.first { $0.customName == "by-anchor" }?.tint, SidebarTint(color: .gray, parts: [.name]))
    }

    private func addSession() throws -> (AppStore, Session) {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        return (store, try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory())))
    }
}
