import AppKit
import SwiftUI
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
    private var window: NSWindow!

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
            window?.orderOut(nil)
            window = nil
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

    func testCollapseWorkspacesWithATopLevelSessionCurrentKeepsNoRowOpen() throws {
        let store = try XCTUnwrap(library.activeStore)
        let named = try XCTUnwrap(store.namedWorkspaces.first).id
        let root = try XCTUnwrap(store.rootWorkspace).id
        store.setWorkspaceExpanded(named, expanded: false)
        try XCTUnwrap(store.addSession(toWorkspace: root, cwd: "/tmp"))
        XCTAssertEqual(store.currentWorkspaceID, root)
        mountSidebar(for: store)

        actions.collapseOtherWorkspaces(in: store)

        XCTAssertTrue(store.sidebarExpandedWorkspaceIDs.isEmpty)
        XCTAssertTrue(store.namedWorkspaces.allSatisfy { !$0.isExpanded })
    }

    private func mountSidebar(for store: AppStore) {
        let host = NSHostingView(rootView: WorkspaceSidebar(store: store, actions: actions).frame(width: 240, height: 400))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
    }
}
