import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for which `session.scratch` calls move the window's selection.
@MainActor
final class ControlServerScratchTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var server: ControlServer!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-control-scratch-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            server = ControlServer(
                library: library,
                actions: AppActions(library: library),
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

    private func twoSessions() throws -> (store: AppStore, background: Session, selected: Session) {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let background = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        let selected = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        store.selectSession(selected.id)
        return (store, background, selected)
    }

    func testShowingABackgroundScratchLeavesTheSelection() throws {
        let (store, background, selected) = try twoSessions()

        let shown = server.scratchSession(background.id.uuidString, window: nil, mode: "on", command: nil, follow: false)
        XCTAssertTrue(shown.ok, "\(shown)")
        XCTAssertTrue(background.scratchActive)
        XCTAssertEqual(store.selectedSessionID, selected.id)

        let shownAgain = server.scratchSession(background.id.uuidString, window: nil, mode: "on", command: nil, follow: false)
        XCTAssertTrue(shownAgain.ok, "\(shownAgain)")
        XCTAssertEqual(store.selectedSessionID, selected.id)
    }

    func testFollowSelectsTheTargetOnlyWhenShowing() throws {
        let (store, background, selected) = try twoSessions()

        let hidden = server.scratchSession(background.id.uuidString, window: nil, mode: "off", command: nil, follow: true)
        XCTAssertTrue(hidden.ok, "\(hidden)")
        XCTAssertEqual(store.selectedSessionID, selected.id)

        let followed = server.scratchSession(background.id.uuidString, window: nil, mode: "on", command: nil, follow: true)
        XCTAssertTrue(followed.ok, "\(followed)")
        XCTAssertTrue(background.scratchActive)
        XCTAssertEqual(store.selectedSessionID, background.id)
    }

    func testTheFourArgumentEntryPointShowsWithoutSelecting() throws {
        let (store, background, selected) = try twoSessions()

        let shown = server.scratchSession(background.id.uuidString, window: nil, mode: "on", command: nil)
        XCTAssertTrue(shown.ok, "\(shown)")
        XCTAssertTrue(background.scratchActive)
        XCTAssertEqual(store.selectedSessionID, selected.id)
    }
}
