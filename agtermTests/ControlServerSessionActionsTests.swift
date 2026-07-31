import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for `ControlServer`'s session actions, which need the real app target for window
/// resolution and the store registry.
@MainActor
final class ControlServerSessionActionsTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var server: ControlServer!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-control-session-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            let actions = AppActions(library: library)
            server = ControlServer(
                library: library,
                actions: actions,
                settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
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

    private func overlayOptions(follow: Bool) -> ControlSessionOverlayOpenOptions {
        ControlSessionOverlayOpenOptions(command: "true", cwd: nil, wait: false, sizePercent: nil,
                                         backgroundColor: nil, follow: follow)
    }

    func testFollowSelectsTheTargetWhenNothingIsSelected() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        store.selectSession(nil)

        let response = server.openSessionOverlay(session.id.uuidString, window: nil,
                                                 options: overlayOptions(follow: true))

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(store.selectedSessionID, session.id)
    }

    // --follow is documented as a no-op when its target is already active, and it stays one only because
    // a same-value selection leaves the fresh-workspace target alone.
    func testFollowOnTheAlreadyActiveSessionKeepsTheFreshWorkspaceCurrent() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        store.selectSession(session.id)
        let fresh = store.addWorkspace(name: "fresh")

        let response = server.openSessionOverlay(session.id.uuidString, window: nil,
                                                 options: overlayOptions(follow: true))

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(store.selectedSessionID, session.id)
        XCTAssertEqual(store.currentWorkspaceID, fresh.id, "an already-active follow must not retarget")
    }

    func testFollowOnAnotherSessionSelectsItAndDropsTheFreshWorkspace() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let first = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        let second = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        store.selectSession(second.id)
        store.addWorkspace(name: "fresh")

        let response = server.openSessionOverlay(first.id.uuidString, window: nil,
                                                 options: overlayOptions(follow: true))

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(store.selectedSessionID, first.id)
        XCTAssertEqual(store.currentWorkspaceID, owner)
    }
}
