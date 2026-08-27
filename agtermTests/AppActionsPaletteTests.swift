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
        actions.paletteActions().map(\.id).filter { $0.hasPrefix("move-") && !$0.hasPrefix("move-window-") }
    }

    private func moveWindowDestinationIDs() -> [String] {
        actions.paletteActions().map(\.id).filter { $0.hasPrefix("move-window-") }
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

    func testNoMoveToWindowDestinationsWithASingleOpenWindow() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        store.selectSession(session.id)

        XCTAssertTrue(moveWindowDestinationIDs().isEmpty, "the only open window is not a destination")
    }

    func testMoveToWindowListsTheOtherOpenWindowAndMovesTheSessionThere() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        store.selectSession(session.id)
        let sourceID = try XCTUnwrap(library.activeWindowID)
        let other = library.newWindow(name: "work")
        let destination = try XCTUnwrap(library.store(for: other.id))
        library.frontmostWindowID = sourceID // the palette is driven from the window the session is in

        let row = try XCTUnwrap(actions.paletteActions().first { $0.id == "move-window-\(other.id)" })
        XCTAssertEqual(row.title, "Move Session to Window: work")
        XCTAssertEqual(moveWindowDestinationIDs(), ["move-window-\(other.id)"])
        row.run()

        XCTAssertNil(store.session(withID: session.id), "the source window gave the session up")
        XCTAssertTrue(destination.session(withID: session.id) === session, "the same instance, with its shell")
    }

    func testMoveSessionsToWindowMovesAWholeSidebarSelection() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let first = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        let second = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        let other = library.newWindow(name: "work")
        let destination = try XCTUnwrap(library.store(for: other.id))

        XCTAssertEqual(actions.moveSessions([first.id, second.id], toWindow: other.id), 2)

        let moved = try XCTUnwrap(destination.workspaces.first).sessions.map(\.id)
        XCTAssertEqual(moved.suffix(2), [first.id, second.id], "the selection keeps its order")
        XCTAssertNil(store.session(withID: first.id))
        XCTAssertNil(store.session(withID: second.id))
    }

    // the gate reads the SOURCE window: a background sidebar's Move must not be judged by whatever modal
    // the frontmost window happens to have up.
    func testMoveToWindowIsGatedOnTheSourceWindowNotTheFrontmostOne() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        let sourceID = try XCTUnwrap(library.windowID(forSession: session.id))
        let other = library.newWindow(name: "work")
        let destination = try XCTUnwrap(library.store(for: other.id))
        library.frontmostWindowID = other.id

        let zoom = TerminalZoomController()
        TerminalZoomRegistry.shared.register(other.id, controller: zoom)
        defer { TerminalZoomRegistry.shared.unregister(other.id) }
        zoom.set(.on, target: .session(session.id, .primary))

        XCTAssertTrue(actions.moveSession(session.id, toWindow: other.id),
                      "the frontmost window's zoom is not the gate")
        XCTAssertTrue(destination.session(withID: session.id) === session)

        XCTAssertFalse(actions.moveSession(session.id, toWindow: sourceID),
                       "the session's own window is the zoomed one now, so the move back is refused")
        XCTAssertNil(store.session(withID: session.id))
    }

    func testMoveSessionToAClosedWindowIsRefused() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        let other = library.newWindow(name: "work")
        library.closeWindow(other.id)

        XCTAssertFalse(actions.moveSession(session.id, toWindow: other.id))
        XCTAssertTrue(store.session(withID: session.id) === session)
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
        XCTAssertFalse(inert.isEnabled(), "the menu item is disabled with no session, so the row is inert")
        inert.run()
        XCTAssertFalse(actions.renamePending, "an inert row runs nothing")

        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory()))
        store.selectSession(session.id)

        let live = try actionRow(.renameSession)
        XCTAssertTrue(live.isEnabled(), "with a session the same row is live")
        live.run()
        XCTAssertTrue(actions.renamePending, "and runs the action its menu item would")
    }

    // the palette keeps its rows while the user types, so a session exiting under an open one must make the row
    // inert on the spot. A snapshot taken when the list was built let a dead row through the guard and, worse,
    // dismissed the palette on a keystroke that did nothing.
    func testARowFollowsStateThatChangesUnderTheOpenPalette() throws {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory()))
        store.selectSession(session.id)

        let row = try actionRow(.renameSession)
        XCTAssertTrue(row.isEnabled(), "the row is built while the action is available")

        store.selectSession(nil)
        XCTAssertFalse(row.isEnabled(), "the same row reads the state of the moment, not of its build")
        XCTAssertFalse(row.runIfEnabled(), "choosing it runs nothing, so the palette must not dismiss either")
        XCTAssertFalse(actions.renamePending)

        store.selectSession(session.id)
        XCTAssertTrue(row.isEnabled(), "and it is live again once the session is back")
        XCTAssertTrue(row.runIfEnabled(), "which is what dismisses the palette")
        XCTAssertTrue(actions.renamePending)
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
