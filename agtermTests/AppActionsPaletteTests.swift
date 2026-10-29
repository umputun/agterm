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

    func testPaletteContextReportsWorkspaceRowsForTheOrdinaryTreeAndTheFlaggedTreeLayout() throws {
        let store = try XCTUnwrap(library.activeStore)
        addTeardownBlock { @MainActor in GhosttyApp.shared.setFlaggedViewLayout(.flat) }
        XCTAssertTrue(actions.paletteContext.sidebarShowsWorkspaceRows)

        store.setSidebarMode(.flagged)
        XCTAssertFalse(actions.paletteContext.sidebarShowsWorkspaceRows)

        GhosttyApp.shared.setFlaggedViewLayout(.tree)
        XCTAssertTrue(actions.paletteContext.sidebarShowsWorkspaceRows)
        XCTAssertFalse(actions.paletteContext.sidebarShowsWorkspaceTree)
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

    // the palette's rows outlive a selection change made while it is open, so the target is read at run.
    func testTintRowsTintTheSessionSelectedWhenTheyRun() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let first = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        let second = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        store.selectSession(first.id)
        let red = try XCTUnwrap(actions.paletteActions().first { $0.title == "Tint Session: Red" })

        store.selectSession(second.id)
        XCTAssertTrue(red.isEnabled())
        red.run()

        XCTAssertNil(first.tint)
        XCTAssertEqual(second.tint, SidebarTint(color: .red))
        let none = try XCTUnwrap(actions.paletteActions().first { $0.title == "Tint Session: None" })
        none.run()
        XCTAssertNil(second.tint)
    }

    private func actionRow(_ command: PaletteCommand) throws -> PaletteItem {
        let title = command.title(in: actions.paletteContext)
        return try XCTUnwrap(actions.paletteActions().first { $0.title == title })
    }

    func testSwapPanesGuiTwinWaitsForBothSurfaceSlots() async throws {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory()))
        store.selectSession(session.id)
        store.setSplitVisibility(session.id, shown: true)
        let primary = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        let split = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        split.setPaneRole(.split)
        let realize = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000)
            session.surface = primary
            session.splitSurface = split
        }

        actions.swapActiveSessionPanes()
        for _ in 0..<20 where session.surface !== split {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        await realize.value

        XCTAssertTrue(session.surface === split)
        XCTAssertTrue(session.splitSurface === primary)
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

    func testASessionRowShowsTheStatusOfTheMomentUnderTheOpenPalette() throws {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory()))
        let row = try XCTUnwrap(actions.paletteSessions().first { $0.id == session.id.uuidString })
        XCTAssertEqual(row.indicator(), AgentIndicator())

        store.setAgentIndicator(AgentIndicator(status: .active), forSession: session.id)
        XCTAssertEqual(row.indicator().status, .active)

        let completed = AgentIndicator(status: .completed, color: "#00aa00", shape: .star)
        store.setAgentIndicator(completed, forSession: session.id)
        XCTAssertEqual(row.indicator(), completed)

        store.setAgentIndicator(AgentIndicator(), forSession: session.id)
        XCTAssertEqual(row.indicator().status, .idle)
    }

    // an action neither a palette row nor `paletteLessHandler(for:)` covers can still be bound in
    // keymap.conf, where it would swallow its key and do nothing.
    func testEveryBuiltinActionReachesADispatchPath() {
        let viaPalette = Set(PaletteCommand.allCases.compactMap(\.builtinAction))
        let paletteLess = Set(BuiltinAction.allCases.filter { actions.paletteLessHandler(for: $0) != nil })

        XCTAssertTrue(viaPalette.isDisjoint(with: paletteLess), "an action must have exactly one dispatch path")
        XCTAssertEqual(viaPalette.union(paletteLess), Set(BuiltinAction.allCases))
    }

    func testFlaggedEditorListsEverySessionInTreeOrderIncludingFocusHiddenOnes() throws {
        let store = try XCTUnwrap(library.activeStore)
        let first = try XCTUnwrap(store.currentWorkspaceID)
        let seeded = store.workspaces[0].sessions
        let a = try XCTUnwrap(store.addSession(toWorkspace: first, cwd: NSHomeDirectory()))
        let other = store.addWorkspace(name: "other")
        let b = try XCTUnwrap(store.addSession(toWorkspace: other.id, cwd: NSHomeDirectory(), select: false))
        let c = try XCTUnwrap(store.addSession(toWorkspace: other.id, cwd: NSHomeDirectory(), select: false))
        store.setFocusMembership(first, member: true)
        store.setFocusEnabled(true)
        XCTAssertFalse(store.visibleWorkspaces.contains { $0.id == other.id })

        let rows = actions.paletteFlaggedEditor()
        XCTAssertEqual(rows.map(\.id), (seeded + [a, b, c]).map(\.id.uuidString))
        let firstName = store.workspaces[0].name
        XCTAssertEqual(rows.map(\.subtitle), Array(repeating: firstName, count: seeded.count + 1) + ["other", "other"])
        XCTAssertTrue(rows.allSatisfy { $0.mark?() == .flag(false) })
    }

    func testFlaggedEditorRowTogglesTheFlagAndItsMarkFollows() throws {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory()))
        let row = try XCTUnwrap(actions.paletteFlaggedEditor().first { $0.id == session.id.uuidString })

        XCTAssertTrue(row.runIfEnabled())
        XCTAssertTrue(session.flagged)
        XCTAssertEqual(row.mark?(), .flag(true))

        XCTAssertTrue(row.runIfEnabled())
        XCTAssertFalse(session.flagged)
        XCTAssertEqual(row.mark?(), .flag(false))
    }

    func testFlaggedEditorRowGoesInertWhenItsSessionCloses() throws {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory()))
        let row = try XCTUnwrap(actions.paletteFlaggedEditor().first { $0.id == session.id.uuidString })

        store.closeSession(session.id)

        XCTAssertFalse(row.isEnabled())
        XCTAssertFalse(row.runIfEnabled())
    }

    func testFocusEditorTogglesMembershipWithoutEverEnablingTheFilter() throws {
        let store = try XCTUnwrap(library.activeStore)
        let first = try XCTUnwrap(store.currentWorkspaceID)
        let other = store.addWorkspace(name: "other")
        let rows = actions.paletteFocusEditor()
        XCTAssertEqual(rows.map(\.id), store.workspaces.map(\.id.uuidString))
        let firstRow = try XCTUnwrap(rows.first { $0.id == first.uuidString })
        let otherRow = try XCTUnwrap(rows.first { $0.id == other.id.uuidString })

        XCTAssertTrue(firstRow.runIfEnabled())
        XCTAssertEqual(store.focusedWorkspaceIDs, [first])
        XCTAssertEqual(firstRow.mark?(), .focus(true))
        XCTAssertFalse(store.focusEnabled, "marking never turns the filter on")

        XCTAssertTrue(firstRow.runIfEnabled())
        XCTAssertTrue(firstRow.runIfEnabled())
        XCTAssertEqual(store.focusedWorkspaceIDs, [first])
        XCTAssertFalse(store.focusEnabled, "re-adding the last member leaves it off too")

        store.setFocusEnabled(true)
        XCTAssertTrue(otherRow.runIfEnabled())
        XCTAssertTrue(firstRow.runIfEnabled())
        XCTAssertEqual(store.focusedWorkspaceIDs, [other.id])
        XCTAssertTrue(store.focusEnabled, "an applied filter stays on while members remain")
        XCTAssertEqual(firstRow.mark?(), .focus(false))
    }

    func testEditorBuiltinsOpenTheirModeOnTheNextRunloopTick() throws {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        _ = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory(), select: false))
        let palette = PaletteController()
        actions.palette = palette

        for (action, mode) in [(BuiltinAction.editFlaggedSessions, PaletteMode.flaggedEditor),
                               (.editFocusedWorkspaces, .focusEditor)] {
            palette.close()
            actions.perform(action, in: nil)
            XCTAssertNil(palette.mode, "\(action.rawValue) defers past the action palette's own close")
            let opened = expectation(description: action.rawValue)
            DispatchQueue.main.async { opened.fulfill() }
            wait(for: [opened], timeout: 1)
            XCTAssertEqual(palette.mode, mode)
        }
    }

    func testSessionRowsGroupCompanionsUnderIdenticallyNamedParents() throws {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.workspaces.first)
        for session in workspace.sessions { store.renameSession(session.id, to: "zeta") }
        let first = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp", name: "api"))
        let second = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp", name: "api"))
        _ = try store.addCompanion(to: first.id, options: CompanionOptions(name: "zz")).get()
        _ = try store.addCompanion(to: second.id, options: CompanionOptions(name: "aa")).get()

        let titles = actions.paletteSessions().map(\.title)

        XCTAssertEqual(titles.prefix(4), ["api", "api › zz", "api", "api › aa"])
        XCTAssertEqual(actions.paletteFlaggedEditor().map(\.title).suffix(4), ["api", "api › zz", "api", "api › aa"])
    }

    // a flagged child dragged ahead of its parent split the group in the empty session palette
    func testAFlaggedChildAheadOfItsParentStillListsUnderItInTheSessionPalette() throws {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.workspaces.first)
        for session in workspace.sessions { store.renameSession(session.id, to: "zeta") }
        let first = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp", name: "api"))
        let second = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp", name: "api"))
        let firstChild = try store.addCompanion(to: first.id, options: CompanionOptions(name: "a")).get()
        let secondChild = try store.addCompanion(to: second.id, options: CompanionOptions(name: "b")).get()
        store.setFlag(true, forSessions: [first.id, firstChild.id, second.id, secondChild.id])
        XCTAssertTrue(store.moveFlagged([firstChild.id], to: .before, of: first.id))
        store.setSidebarMode(.flagged)

        let rows = CommandPalette.ranked(actions.paletteSessions(), query: "",
                                         keepsSourceOrder: PaletteMode.sessions.keepsSourceOrder, callerSupplied: false)

        XCTAssertEqual(rows.map(\.id), [first, firstChild, second, secondChild].map(\.id.uuidString))
        XCTAssertEqual(CommandPalette.ranked(rows.reversed(), query: "", keepsSourceOrder: false, callerSupplied: false).map(\.title),
                       ["api", "api", "api › a", "api › b"])
    }

    func testAnAttentionCompanionRowNamesItsParent() throws {
        let store = try XCTUnwrap(library.activeStore)
        let parent = try XCTUnwrap(store.addSession(toWorkspace: store.workspaces[0].id, cwd: "/tmp", name: "api"))
        let companion = try store.addCompanion(to: parent.id, options: CompanionOptions(name: "logs")).get()
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: companion.id)

        XCTAssertEqual(actions.paletteAttention().first { $0.id == companion.id.uuidString }?.title, "api › logs")
    }

    func testAttentionRowsNameTheirWindowAndFollowItsCover() throws {
        let front = try XCTUnwrap(library.activeWindowID)
        let back = library.newWindow(name: "back")
        library.frontmostWindowID = front
        let backStore = try XCTUnwrap(library.store(for: back.id))
        let session = try XCTUnwrap(backStore.addSession(toWorkspace: backStore.workspaces[0].id, cwd: NSHomeDirectory(),
                                                         select: false))
        backStore.setAgentIndicator(AgentIndicator(status: .blocked), forSession: session.id)

        let row = try XCTUnwrap(actions.paletteAttention().first { $0.id == session.id.uuidString })
        XCTAssertEqual(row.subtitle?.hasPrefix("back · "), true)
        XCTAssertEqual(row.indicator().status, .blocked)
        XCTAssertTrue(row.isEnabled())

        let zoom = TerminalZoomController()
        TerminalZoomRegistry.shared.register(back.id, controller: zoom)
        defer { TerminalZoomRegistry.shared.unregister(back.id) }
        zoom.set(.on, target: .session(session.id, .primary))
        XCTAssertFalse(row.isEnabled(), "the row asks the owning window's cover, not the frontmost one's")
    }

    func testAnAttentionRowGoesInertWhenItsWindowClosesUnderThePalette() throws {
        let front = try XCTUnwrap(library.activeWindowID)
        let back = library.newWindow(name: "back")
        library.frontmostWindowID = front
        let backStore = try XCTUnwrap(library.store(for: back.id))
        let session = try XCTUnwrap(backStore.addSession(toWorkspace: backStore.workspaces[0].id, cwd: NSHomeDirectory(),
                                                         select: false))
        backStore.setAgentIndicator(AgentIndicator(status: .blocked), forSession: session.id)
        let row = try XCTUnwrap(actions.paletteAttention().first { $0.id == session.id.uuidString })
        let invalidated = expectation(description: "the row's enablement is invalidated by the close")
        withObservationTracking {
            XCTAssertTrue(row.isEnabled())
        } onChange: {
            invalidated.fulfill()
        }

        library.closeWindow(back.id)

        wait(for: [invalidated], timeout: 1)
        XCTAssertFalse(row.isEnabled())
        XCTAssertFalse(row.runIfEnabled())
    }
}
