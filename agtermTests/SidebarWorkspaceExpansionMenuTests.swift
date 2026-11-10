import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class SidebarWorkspaceExpansionMenuTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!
    private var window: NSWindow!
    private var outline: SidebarOutlineView!
    private var coordinator: WorkspaceSidebar.Coordinator!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-workspace-expansion-menu-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            actions = AppActions(library: library)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            window?.orderOut(nil)
            window = nil
            outline = nil
            coordinator = nil
            GhosttyApp.shared.setHiddenInterfaceElements([])
            actions = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    func testExpandedWorkspaceCollapsesAndPersists() throws {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try seed(store, name: "target")
        buildSidebar(for: store)

        try perform("Collapse Workspace", onWorkspace: workspace.id)

        XCTAssertFalse(outline.isItemExpanded(try node(of: workspace.id)))
        XCTAssertEqual(isExpanded(workspace.id, in: store), false)
    }

    func testCollapsedWorkspaceExpandsAndPersists() throws {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try seed(store, name: "target")
        store.setWorkspaceExpanded(workspace.id, expanded: false)
        buildSidebar(for: store)

        try perform("Expand Workspace", onWorkspace: workspace.id)

        XCTAssertTrue(outline.isItemExpanded(try node(of: workspace.id)))
        XCTAssertEqual(isExpanded(workspace.id, in: store), true)
    }

    func testFoldsTheClickedWorkspaceNotTheActiveOne() throws {
        let store = try XCTUnwrap(library.activeStore)
        let clicked = try seed(store, name: "clicked")
        _ = try seed(store, name: "active")
        let activeID = try XCTUnwrap(store.currentWorkspaceID)
        XCTAssertNotEqual(activeID, clicked.id)
        buildSidebar(for: store)

        try perform("Collapse Workspace", onWorkspace: clicked.id)

        XCTAssertFalse(outline.isItemExpanded(try node(of: clicked.id)))
        XCTAssertTrue(outline.isItemExpanded(try node(of: activeID)))
        XCTAssertEqual(isExpanded(activeID, in: store), true)
    }

    func testFoldsWithChevronsHidden() throws {
        GhosttyApp.shared.setHiddenInterfaceElements([.workspaceChevrons])
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try seed(store, name: "target")
        buildSidebar(for: store)

        try perform("Collapse Workspace", onWorkspace: workspace.id)
        XCTAssertFalse(outline.isItemExpanded(try node(of: workspace.id)))

        try perform("Expand Workspace", onWorkspace: workspace.id)
        XCTAssertTrue(outline.isItemExpanded(try node(of: workspace.id)))
    }

    private func seed(_ store: AppStore, name: String) throws -> Workspace {
        let workspace = store.addWorkspace(name: name)
        _ = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp/\(name)", select: false))
        return workspace
    }

    private func perform(_ title: String, onWorkspace id: UUID) throws {
        let row = try XCTUnwrap(rowIndex { $0.kind == .workspace && $0.id == id }, "no sidebar row for that workspace")
        let menu = try XCTUnwrap(coordinator.menu(forRow: row))
        let item = try XCTUnwrap(menu.items.first { $0.title == title }, "no '\(title)' item; menu had \(menu.items.map(\.title))")
        XCTAssertTrue(item.isEnabled)
        coordinator.perform(item.action, with: item)
    }

    private func isExpanded(_ id: UUID, in store: AppStore) -> Bool? {
        store.workspaces.first { $0.id == id }?.isExpanded
    }

    private func node(of id: UUID) throws -> SidebarNode {
        let row = try XCTUnwrap(rowIndex { $0.id == id })
        return try XCTUnwrap(outline.item(atRow: row) as? SidebarNode)
    }

    private func rowIndex(matching predicate: (SidebarNode) -> Bool) -> Int? {
        (0..<outline.numberOfRows).first { row in
            (outline.item(atRow: row) as? SidebarNode).map(predicate) ?? false
        }
    }

    private func buildSidebar(for store: AppStore) {
        outline = SidebarOutlineView()
        coordinator = WorkspaceSidebar.Coordinator(store: store, actions: actions)
        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.headerView = nil
        outline.rowSizeStyle = .custom
        outline.rowHeight = AppSettings.sidebarRowHeight(fontSize: GhosttyApp.shared.sidebarFontSize)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        scroll.documentView = outline
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll

        coordinator.outlineView = outline
        coordinator.renameController.outlineView = outline
        coordinator.seedExpansionFromModel()
        coordinator.reconcile()
    }
}
