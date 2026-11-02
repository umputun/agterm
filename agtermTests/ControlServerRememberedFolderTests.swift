import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for `session.new` placement and cwd from a workspace's remembered folder.
@MainActor
final class ControlServerRememberedFolderTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var settings: SettingsModel!
    private var server: ControlServer!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-control-folder-tests-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
            library = WindowLibrary(directory: stateDir)
            settings = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
            server = ControlServer(library: library, actions: AppActions(library: library), settingsModel: settings,
                                   identity: AppIdentity(version: "9.9.9", commit: "testsha"),
                                   socketPath: stateDir.appendingPathComponent("control.sock").path)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            server = nil
            settings = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    func testCwdJoinsTheWorkspaceRememberingThatFolderUnlessAWorkspaceIsNamed() throws {
        settings.setNewSessionDirectory(AppSettings.NewSessionDirectory.currentSession.rawValue)
        let (store, current, other) = try twoWorkspaces(otherFolder: "/nowhere/api")

        XCTAssertEqual(try workspace(of: newSession(cwd: "/nowhere/api/"), in: store), other)
        XCTAssertEqual(try workspace(of: newSession(cwd: "/nowhere/web"), in: store), current)
        XCTAssertEqual(try workspace(of: newSession(cwd: "/nowhere/api", workspace: current.uuidString), in: store), current)

        settings.setNewSessionDirectory(AppSettings.NewSessionDirectory.home.rawValue)
        XCTAssertEqual(try workspace(of: newSession(cwd: "/nowhere/api"), in: store), current)
    }

    func testNoCwdOpensInTheTargetWorkspacesExistingRememberedFolder() throws {
        let folder = stateDir.appendingPathComponent("proj").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let (store, _, other) = try twoWorkspaces(otherFolder: folder)
        let target = other.uuidString

        XCTAssertEqual(try cwd(of: newSession(workspace: target), in: store), NSHomeDirectory())
        settings.setNewSessionDirectory(AppSettings.NewSessionDirectory.currentSession.rawValue)
        XCTAssertEqual(try cwd(of: newSession(workspace: target), in: store), folder)
        try FileManager.default.removeItem(atPath: folder)
        XCTAssertEqual(try cwd(of: newSession(workspace: target), in: store), NSHomeDirectory())
    }

    private func twoWorkspaces(otherFolder: String) throws -> (AppStore, UUID, UUID) {
        let store = try XCTUnwrap(library.activeStore)
        let current = try XCTUnwrap(store.currentWorkspaceID)
        let other = store.addWorkspace(name: "other", revealNewWorkspace: false).id
        let reporter = try XCTUnwrap(store.addSession(toWorkspace: other, cwd: NSHomeDirectory(), select: false))
        store.rememberFolder(otherFolder, reportedBy: reporter.id)
        XCTAssertEqual(store.currentWorkspaceID, current)
        return (store, current, other)
    }

    private func newSession(cwd: String? = nil, workspace: String? = nil) throws -> UUID {
        let response = server.createSession(ControlSessionCreateOptions(
            window: nil, cwd: cwd, workspace: workspace, workspaceName: nil, createWorkspace: nil,
            command: nil, name: nil, noSelect: true))
        XCTAssertTrue(response.ok, response.error ?? "")
        return try XCTUnwrap(response.result?.id.flatMap(UUID.init(uuidString:)))
    }

    private func workspace(of sessionID: UUID, in store: AppStore) -> UUID? {
        store.workspaces.first { $0.sessions.contains { $0.id == sessionID } }?.id
    }

    private func cwd(of sessionID: UUID, in store: AppStore) throws -> String {
        try XCTUnwrap(store.session(withID: sessionID)).initialCwd
    }
}
