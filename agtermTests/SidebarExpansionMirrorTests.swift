import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for the Coordinator's expansion mirror — the store-side copy of which workspace rows the
/// outline renders open, which `AppStore.isCurrentWorkspaceCollapsed` reads so Collapse/Expand Workspace
/// folds what the user can see rather than what was persisted. Hosted rather than host-free because the
/// mirror is pushed from the Coordinator, and a store-only test cannot tell an unconditional push from a
/// delta-guarded one.
@MainActor
final class SidebarExpansionMirrorTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-expansion-mirror-tests-\(UUID().uuidString)", isDirectory: true)
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

    // a fresh Coordinator starts with an empty set, so seeding an all-collapsed tree assigns empty over
    // empty. Re-introducing a `!= oldValue` guard on the didSet would skip that push and strand the previous
    // mount's ids in the store, leaving Collapse Workspace reading "expanded" over a visibly folded row.
    func testSeedingAnAllCollapsedTreeClearsAStaleMirror() throws {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        store.setWorkspaceExpanded(workspace, expanded: false)
        store.noteSidebarExpansion([workspace]) // what a previous mount left behind
        XCTAssertFalse(store.isCurrentWorkspaceCollapsed, "precondition: the stale mirror reads expanded")

        WorkspaceSidebar.Coordinator(store: store, actions: actions).seedExpansionFromModel()

        XCTAssertTrue(store.sidebarExpandedWorkspaceIDs.isEmpty, "a remount must publish what it actually shows")
        XCTAssertTrue(store.isCurrentWorkspaceCollapsed, "so the toggle folds against the folded row")
    }

    // the other direction, so the test above cannot pass by the mirror being cleared unconditionally.
    func testSeedingPublishesTheExpandedWorkspaces() throws {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        store.setWorkspaceExpanded(workspace, expanded: true)
        store.noteSidebarExpansion([])

        WorkspaceSidebar.Coordinator(store: store, actions: actions).seedExpansionFromModel()

        XCTAssertEqual(store.sidebarExpandedWorkspaceIDs, [workspace])
        XCTAssertFalse(store.isCurrentWorkspaceCollapsed)
    }
}
