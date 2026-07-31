import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for the ⌃⇧P palette's "Move Session to X" destinations. The list is built from live
/// `AppStore` state in the app target, so it needs a window library and a real store; the store-side
/// resolution it depends on is pinned host-free in `AppStoreCurrentWorkspaceTests`.
@MainActor
final class AppActionsPaletteTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-palette-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            actions = AppActions(library: library)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            actions = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    private func moveDestinationIDs() -> [String] {
        actions.paletteActions().map(\.id).filter { $0.hasPrefix("move-") }
    }

    // a freshly created workspace is `currentWorkspaceID` while the selection still sits elsewhere, so
    // filtering the list by the current workspace dropped the one destination the user just made.
    func testMoveDestinationsExcludeTheSessionsOwnWorkspaceAndKeepAFreshOne() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        store.selectSession(session.id)
        let fresh = store.addWorkspace(name: "fresh")
        XCTAssertEqual(store.currentWorkspaceID, fresh.id, "a foreground create is current before anything is selected in it")

        let destinations = moveDestinationIDs()

        XCTAssertEqual(destinations, ["move-\(fresh.id)"], "the fresh workspace is the only other destination")
        XCTAssertFalse(destinations.contains("move-\(owner)"), "moving a session into its own workspace is a no-op")
    }

    func testNoMoveDestinationsWithoutASelectedSession() throws {
        let store = try XCTUnwrap(library.activeStore)
        store.addWorkspace(name: "fresh")
        store.selectSession(nil)

        XCTAssertTrue(moveDestinationIDs().isEmpty, "there is no session to move")
    }
}
