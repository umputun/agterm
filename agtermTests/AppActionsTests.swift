import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class AppActionsTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var settings: SettingsModel!
    private var actions: AppActions!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-actions-tests-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
            library = WindowLibrary(directory: stateDir)
            settings = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
            actions = AppActions(library: library)
            actions.settingsModel = settings
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            actions = nil
            settings = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    private func remoteActiveSession(reportedCwd: String) throws -> Session {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: home, remoteHost: "user@box"))
        session.currentCwd = reportedCwd
        return session
    }

    func testNewSessionCwdFollowsTheCurrentSessionThroughTheLocalRule() throws {
        settings.setNewSessionDirectory(AppSettings.NewSessionDirectory.currentSession.rawValue)
        let local = try XCTUnwrap(library.activeStore?.activeSession)
        local.currentCwd = "/nowhere/local"
        XCTAssertEqual(actions.resolvedNewSessionCwd(), "/nowhere/local")

        let remote = try remoteActiveSession(reportedCwd: stateDir.appendingPathComponent("only-on-the-remote").path)
        XCTAssertEqual(actions.resolvedNewSessionCwd(), home)
        remote.currentCwd = stateDir.path
        XCTAssertEqual(actions.resolvedNewSessionCwd(), stateDir.path)
    }

    func testNewSessionCwdKeepsTheFocusedSplitPaneAndTheEmptyCwdFallback() throws {
        settings.setNewSessionDirectory(AppSettings.NewSessionDirectory.currentSession.rawValue)
        let local = try XCTUnwrap(library.activeStore?.activeSession)
        local.currentCwd = "/nowhere/primary"
        let split = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        local.splitSurface = split
        local.splitCwd = "/nowhere/split"
        local.hasSplit = true
        local.isSplit = true
        local.splitFocused = true
        XCTAssertEqual(actions.resolvedNewSessionCwd(), "/nowhere/split")

        local.splitFocused = false
        local.currentCwd = ""
        XCTAssertEqual(actions.resolvedNewSessionCwd(), home)
    }

    func testNewSessionCwdCustomModeIgnoresTheActiveSessionsRemoteness() throws {
        settings.setNewSessionDirectory(AppSettings.NewSessionDirectory.custom.rawValue)
        settings.setNewSessionCustomDirectory("/nowhere/custom")
        _ = try remoteActiveSession(reportedCwd: stateDir.appendingPathComponent("only-on-the-remote").path)
        XCTAssertEqual(actions.resolvedNewSessionCwd(), "/nowhere/custom")
    }
}
