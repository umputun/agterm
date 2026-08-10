import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for `AppActions`' palette surface: the ⌃⇧P palette's "Move Session to X" destinations,
/// built from live `AppStore` state in the app target so it needs a window library and a real store (the
/// store-side resolution behind it is pinned host-free in `AppStoreCurrentWorkspaceTests`), and the built-in
/// dispatch `perform(_:)` routes a keybound action through.
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

    private func actionRow(_ command: PaletteCommand) throws -> PaletteItem {
        let title = command.title(in: actions.paletteContext)
        return try XCTUnwrap(actions.paletteActions().first { $0.title == title })
    }

    // the palette deliberately LISTS rows the menu disables, so a user can still look the action up. It must
    // render them inert instead of running an action the same keystroke would be refused for.
    func testARowTheMenuDisablesIsListedButInert() throws {
        let store = try XCTUnwrap(library.activeStore)
        store.selectSession(nil)
        XCTAssertNil(store.activeSession)

        let inert = try actionRow(.renameSession)
        XCTAssertFalse(inert.enabled, "the menu item is disabled with no session, so the row is inert")
        inert.run()
        XCTAssertFalse(actions.renamePending, "an inert row runs nothing")

        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory()))
        store.selectSession(session.id)

        let live = try actionRow(.renameSession)
        XCTAssertTrue(live.enabled, "with a session the same row is live")
        live.run()
        XCTAssertTrue(actions.renamePending, "and runs the action its menu item would")
    }

    // an action neither a palette row nor `paletteLessHandler(for:)` covers can still be bound in
    // keymap.conf, where it would swallow its key and do nothing.
    func testEveryBuiltinActionReachesADispatchPath() {
        let viaPalette = Set(PaletteCommand.allCases.compactMap(\.builtinAction))
        let paletteLess = Set(BuiltinAction.allCases.filter { actions.paletteLessHandler(for: $0) != nil })

        XCTAssertTrue(viaPalette.isDisjoint(with: paletteLess), "an action must have exactly one dispatch path")
        XCTAssertEqual(viaPalette.union(paletteLess), Set(BuiltinAction.allCases))
    }
}
