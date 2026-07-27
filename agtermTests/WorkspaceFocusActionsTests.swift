import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for the workspace-focus entry points on `AppActions`
/// (`AppActions+WorkspaceFocus.swift`) — the keyless ones the View menu, the ⌃⇧P palette and the
/// `focus_workspace` keybind drive, which have no clicked sidebar row and so target the frontmost window's
/// `AppStore.currentWorkspaceID`, plus the store-scoped workspace-row menu actions — Focus, Add to Focus,
/// and Delete Workspace (the last from `AppActions.swift`), which must act on the window the clicked row
/// belongs to. They live in the app-hosted target rather than `agtermUITests`
/// because they reach `AppActions` directly through `@testable import agterm`, their whole outcome is
/// MODEL state (the marked set plus the filter flag), and — unlike the XCUITest suite, which CI does not
/// run — they run on every push via `scripts/test-app.sh`.
///
/// The store-side semantics (replace-toggle, mark-only, the empty-set refusal) are pinned host-free in
/// `AppStoreFocusTests`; what is proved HERE is the wiring: which store call each menu entry point makes,
/// and its guard.
@MainActor
final class WorkspaceFocusActionsTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-workspace-focus-tests-\(UUID().uuidString)", isDirectory: true)
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

    // View ▸ Focus Workspace (and the `focus_workspace` keybind / palette entry) zooms to the CURRENT
    // workspace, and a second invocation — where the item reads "Unfocus Workspace" — clears the set. The
    // menu's label is driven by `isCurrentWorkspaceSoleFocus`, so it is asserted alongside the state it
    // describes: a label that disagreed with what the item does is exactly what this pins.
    func testFocusActiveWorkspaceZoomsThenUnfocuses() throws {
        let store = try XCTUnwrap(library.activeStore)
        let current = try XCTUnwrap(store.currentWorkspaceID)
        XCTAssertFalse(store.isCurrentWorkspaceSoleFocus, "nothing focused, so the item reads Focus Workspace")

        actions.focusActiveWorkspace()

        XCTAssertEqual(store.focusedWorkspaceIDs, [current], "the current workspace should be the marked set")
        XCTAssertTrue(store.focusEnabled, "Focus Workspace APPLIES the filter, unlike Add Workspace to Focus")
        XCTAssertTrue(store.isCurrentWorkspaceSoleFocus, "the item should now read Unfocus Workspace")

        actions.focusActiveWorkspace()

        XCTAssertTrue(store.focusedWorkspaceIDs.isEmpty, "Unfocus should CLEAR the set, not just suspend it")
        XCTAssertFalse(store.focusEnabled)
    }

    // View ▸ Add Workspace to Focus MARKS the current workspace without applying the filter — the
    // additive sibling of Focus Workspace, and the entry point that makes a working set buildable from the
    // menu (a mark that applied would hide the rows still to be marked). Once marked, the item is disabled
    // (`isCurrentWorkspaceFocusMember`), because a repeat would be a silent no-op.
    func testAddActiveWorkspaceToFocusMarksWithoutApplyingTheFilter() throws {
        let store = try XCTUnwrap(library.activeStore)
        let first = try XCTUnwrap(store.currentWorkspaceID)
        let second = store.addWorkspace(name: "second")
        let session = try XCTUnwrap(store.addSession(toWorkspace: second.id, cwd: NSHomeDirectory()))
        XCTAssertEqual(store.currentWorkspaceID, second.id, "the new session makes its workspace current")

        actions.addActiveWorkspaceToFocus()

        XCTAssertEqual(store.focusedWorkspaceIDs, [second.id])
        XCTAssertFalse(store.focusEnabled, "marking must never turn the filter on")
        XCTAssertTrue(store.isCurrentWorkspaceFocusMember, "the menu item should now be disabled")

        // move the selection to the first workspace and mark it too: the set WIDENS, it is not replaced.
        let firstSession = try XCTUnwrap(store.workspaces.first { $0.id == first }?.sessions.first)
        store.selectSession(firstSession.id)
        actions.addActiveWorkspaceToFocus()

        XCTAssertEqual(store.focusedWorkspaceIDs, [first, second.id], "a second mark should add, not replace")
        XCTAssertFalse(store.focusEnabled)
        XCTAssertEqual(session.id, store.workspaces.first { $0.id == second.id }?.sessions.first?.id)
    }

    // View ▸ Clear Focus empties the WHOLE marked set (and with it the filter) — distinct from Toggle
    // Workspace Filter, which keeps the set and only stops applying it. The menu/palette item is the only
    // driver of `clearFocus()`, so it has no accessibility-observable e2e.
    func testClearFocusEmptiesTheWholeSet() throws {
        let store = try XCTUnwrap(library.activeStore)
        let first = try XCTUnwrap(store.currentWorkspaceID)
        let second = store.addWorkspace(name: "second")
        store.setFocusMembership(first, member: true)
        store.setFocusMembership(second.id, member: true)
        store.setFocusEnabled(true)

        actions.clearFocus()

        XCTAssertTrue(store.focusedWorkspaceIDs.isEmpty, "Clear Focus should drop every member, not just one")
        XCTAssertFalse(store.focusEnabled)
        XCTAssertEqual(store.visibleWorkspaces.count, store.workspaces.count, "the whole tree should be back")
    }

    // Toggle Workspace Filter suspends and re-applies WITHOUT touching the set — the menu twin of the
    // bottom-bar grid button, and the reason Clear Focus is a separate item.
    func testToggleFocusFilterKeepsTheMarkedSet() throws {
        let store = try XCTUnwrap(library.activeStore)
        let current = try XCTUnwrap(store.currentWorkspaceID)
        store.setFocusMembership(current, member: true)
        store.setFocusEnabled(true)

        actions.toggleFocusFilter()
        XCTAssertFalse(store.focusEnabled)
        XCTAssertEqual(store.focusedWorkspaceIDs, [current], "suspending must keep the hand-curated set")

        actions.toggleFocusFilter()
        XCTAssertTrue(store.focusEnabled)
        XCTAssertEqual(store.focusedWorkspaceIDs, [current])
    }

    // The empty-set state the store refuses to enable: the toggle is a no-op there (which is why the
    // bottom-bar button renders disabled), and Clear Focus has nothing to clear.
    func testFilterEntryPointsAreNoOpsWithNothingMarked() throws {
        let store = try XCTUnwrap(library.activeStore)

        actions.toggleFocusFilter()
        XCTAssertFalse(store.focusEnabled, "an empty set must never be applied")
        actions.clearFocus()
        XCTAssertTrue(store.focusedWorkspaceIDs.isEmpty && !store.focusEnabled)
    }

    // The sidebar row menu's "Focus"/"Unfocus" is STORE-SCOPED: the clicked row belongs to one window, and
    // a right-click opens the menu WITHOUT raising a background window, so routing through the frontmost
    // store would read the row's own store (which built the label) and write another window's marked set.
    func testRowFocusTargetsItsOwnStoreNotTheFrontmostOne() throws {
        let (frontStore, otherStore) = try twoWindows()
        let clicked = try XCTUnwrap(otherStore.currentWorkspaceID)

        actions.focusWorkspace(clicked, in: otherStore)

        XCTAssertEqual(otherStore.focusedWorkspaceIDs, [clicked], "the clicked row's own window should zoom")
        XCTAssertTrue(otherStore.focusEnabled, "Focus APPLIES the filter in the window the row belongs to")
        XCTAssertTrue(frontStore.focusedWorkspaceIDs.isEmpty, "the frontmost window must not be mutated")
        XCTAssertFalse(frontStore.focusEnabled)

        actions.focusWorkspace(clicked, in: otherStore)

        XCTAssertTrue(otherStore.focusedWorkspaceIDs.isEmpty, "the second invocation reads Unfocus and clears")
        XCTAssertFalse(otherStore.focusEnabled)
    }

    // "Delete Workspace" carries the same routing requirement as the two focus items above: the row's
    // enabled state comes from its own store's `canRemoveWorkspace`, so a background window's row must
    // delete the workspace it was opened over. Routed through the frontmost store the id is absent, the
    // lookup returns nil, and the item silently does nothing — no deletion, no error, no feedback.
    func testRowDeleteWorkspaceTargetsItsOwnStoreNotTheFrontmostOne() throws {
        let (frontStore, otherStore) = try twoWindows()
        let frontWorkspaces = frontStore.workspaces.map(\.id)
        // an EMPTY workspace deletes without the confirm alert, and a second one satisfies keep-at-least-one.
        let doomed = otherStore.addWorkspace(name: "doomed")
        XCTAssertTrue(otherStore.canRemoveWorkspace, "the clicked row's window must allow the delete")

        actions.deleteWorkspace(doomed.id, in: otherStore)

        XCTAssertFalse(otherStore.workspaces.contains { $0.id == doomed.id }, "the clicked row's own window should lose it")
        XCTAssertEqual(frontStore.workspaces.map(\.id), frontWorkspaces, "the frontmost window must not be mutated")
    }

    // "Add to Focus"/"Remove from Focus" carries the same routing requirement, and additionally computes
    // its own direction from the row's store — read and write must land on the SAME window, or the menu
    // flips a membership it never read.
    func testRowMembershipTargetsItsOwnStoreNotTheFrontmostOne() throws {
        let (frontStore, otherStore) = try twoWindows()
        let clicked = try XCTUnwrap(otherStore.currentWorkspaceID)

        actions.setFocusMembership(clicked, member: true, in: otherStore)

        XCTAssertEqual(otherStore.focusedWorkspaceIDs, [clicked])
        XCTAssertFalse(otherStore.focusEnabled, "marking must never turn the filter on")
        XCTAssertTrue(frontStore.focusedWorkspaceIDs.isEmpty, "the frontmost window must not be mutated")

        actions.setFocusMembership(clicked, member: false, in: otherStore)

        XCTAssertTrue(otherStore.focusedWorkspaceIDs.isEmpty, "removing should unmark the row's own window")
        XCTAssertTrue(frontStore.focusedWorkspaceIDs.isEmpty)
    }

    /// Opens a second window and leaves the FIRST one frontmost, returning (frontmost store, other store) —
    /// the background-window row menu the store-scoped actions exist for.
    private func twoWindows() throws -> (AppStore, AppStore) {
        let frontID = try XCTUnwrap(library.activeWindowID)
        let frontStore = try XCTUnwrap(library.activeStore)
        let otherID = library.newWindow(name: "window B").id
        let otherStore = try XCTUnwrap(library.loadStore(for: otherID))
        library.frontmostWindowID = frontID
        XCTAssertFalse(frontStore === otherStore, "the two windows must own distinct stores")
        return (frontStore, otherStore)
    }
}
