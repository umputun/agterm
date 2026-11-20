import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class WorkspaceSidebarTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!
    private var window: NSWindow!
    private var outline: RecordingOutlineView!
    private var coordinator: WorkspaceSidebar.Coordinator!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-sidebar-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            actions = AppActions(library: library)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            GhosttyApp.shared.setFlaggedViewLayout(.flat)
            window?.orderOut(nil)
            window = nil
            outline = nil
            coordinator = nil
            actions = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    func testRootSessionsRenderUnindentedAboveTheFirstWorkspaceRow() throws {
        let rows = try seed()
        buildSidebar(for: rows.store)

        XCTAssertEqual(visibleIDs(), [rows.top.id, rows.companion.id, rows.second.id, rows.workspace.id, rows.named.id])
        XCTAssertEqual(outline.level(forRow: try row(rows.top.id)), 0)
        XCTAssertEqual(outline.level(forRow: try row(rows.companion.id)), 1)
        XCTAssertEqual(outline.level(forRow: try row(rows.second.id)), 0)
        XCTAssertEqual(outline.level(forRow: try row(rows.workspace.id)), 0)
        XCTAssertEqual(try cell(rows.top.id).textField?.stringValue, rows.top.displayName)
    }

    func testAFoldedRootParentStaysFoldedAcrossARebuild() throws {
        let rows = try seed()
        rows.store.setSessionExpanded(rows.top.id, expanded: false)
        buildSidebar(for: rows.store)

        XCTAssertFalse(outline.isItemExpanded(try node(rows.top.id)))
        XCTAssertFalse(visibleIDs().contains(rows.companion.id))
    }

    func testTheFocusFilterHidesRootSessionsUnlessTheRootIsAMember() throws {
        let rows = try seed()
        rows.store.setFocusMembership(rows.workspace.id, member: true)
        rows.store.setFocusEnabled(true)
        buildSidebar(for: rows.store)
        XCTAssertFalse(visibleIDs().contains(rows.top.id))
        XCTAssertTrue(visibleIDs().contains(rows.workspace.id))

        rows.store.setFocusMembership(rows.root.id, member: true)
        coordinator.reconcile()

        XCTAssertEqual(try row(rows.top.id), 0)
    }

    func testTheFlaggedTreeListsFlaggedRootSessionsAboveItsWorkspaceRows() throws {
        let rows = try seed()
        rows.store.setFlag(true, forSessions: [rows.second.id, rows.named.id])
        rows.store.setSidebarMode(.flagged)
        GhosttyApp.shared.setFlaggedViewLayout(.tree)
        buildSidebar(for: rows.store)

        XCTAssertEqual(visibleIDs(), [rows.second.id, rows.workspace.id, rows.named.id])
        XCTAssertEqual(outline.level(forRow: 0), 0)
    }

    func testTheFlatFlaggedListLabelsARootSessionWithoutAWorkspaceSuffix() throws {
        let rows = try seed()
        rows.store.setFlag(true, forSessions: [rows.second.id, rows.named.id])
        rows.store.setSidebarMode(.flagged)
        buildSidebar(for: rows.store)

        XCTAssertEqual(try cell(rows.second.id).textField?.stringValue, rows.second.displayName)
        XCTAssertEqual(try cell(rows.named.id).textField?.stringValue, "\(rows.named.displayName) : \(rows.workspace.name)")
    }

    func testAWorkspaceDraggedToTheBottomHighlightsBelowTheRootBlockAndLandsLast() throws {
        let rows = try seed()
        let second = rows.store.addWorkspace(name: "second")
        let third = rows.store.addWorkspace(name: "third")
        buildSidebar(for: rows.store)
        let last = outline.rect(ofRow: outline.numberOfRows - 1)
        let info = workspaceDrag(rows.workspace.id, at: NSPoint(x: last.midX, y: last.maxY - 1))

        XCTAssertEqual(coordinator.outlineView(outline, validateDrop: info, proposedItem: nil, proposedChildIndex: -1), .move)
        XCTAssertNil(outline.dropItem)
        XCTAssertEqual(outline.dropChildIndex, outline.numberOfChildren(ofItem: nil))
        XCTAssertTrue(coordinator.outlineView(outline, acceptDrop: info, item: nil, childIndex: outline.dropChildIndex))
        XCTAssertEqual(rows.store.namedWorkspaces.map(\.id), [second.id, third.id, rows.workspace.id])
        XCTAssertEqual(rows.store.workspaces.last?.id, rows.root.id)
    }

    func testASessionDroppedInTheGapAboveTheFirstWorkspaceRowLandsLastInTheRoot() throws {
        let rows = try seed()
        buildSidebar(for: rows.store)
        let info = sessionDrag([rows.named.id])

        XCTAssertEqual(coordinator.outlineView(outline, validateDrop: info, proposedItem: nil, proposedChildIndex: 2), .move)
        XCTAssertNil(outline.dropItem)
        XCTAssertEqual(outline.dropChildIndex, 2)
        XCTAssertTrue(coordinator.outlineView(outline, acceptDrop: info, item: nil, childIndex: 2))
        XCTAssertEqual(rows.store.rootWorkspace?.sessions.map(\.id), [rows.top.id, rows.companion.id, rows.second.id, rows.named.id])
        XCTAssertFalse(rows.store.workspaces.first { $0.id == rows.workspace.id }?.sessions.contains { $0.id == rows.named.id } ?? true)
    }

    func testASessionDroppedOnARootRowJoinsTheRoot() throws {
        let rows = try seed()
        buildSidebar(for: rows.store)
        let info = sessionDrag([rows.named.id])

        XCTAssertEqual(coordinator.outlineView(outline, validateDrop: info, proposedItem: try node(rows.second.id),
                                               proposedChildIndex: SidebarDrop.onItemIndex), .move)
        XCTAssertTrue(coordinator.outlineView(outline, acceptDrop: info, item: outline.dropItem, childIndex: outline.dropChildIndex))
        XCTAssertEqual(rows.store.workspace(forSession: rows.named.id)?.id, rows.root.id)
    }

    func testARootParentDraggedToTheEndOfTheRootMovesWithItsCompanions() throws {
        let rows = try seed()
        buildSidebar(for: rows.store)
        let info = sessionDrag([rows.top.id])

        XCTAssertEqual(coordinator.outlineView(outline, validateDrop: info, proposedItem: nil, proposedChildIndex: 2), .move)
        XCTAssertTrue(coordinator.outlineView(outline, acceptDrop: info, item: nil, childIndex: 2))
        XCTAssertEqual(rows.store.rootWorkspace?.sessions.map(\.id), [rows.second.id, rows.top.id, rows.companion.id])
    }

    func testARootSessionDroppedIntoAWorkspaceLeavesTheRoot() throws {
        let rows = try seed()
        buildSidebar(for: rows.store)
        let info = sessionDrag([rows.second.id])

        XCTAssertEqual(coordinator.outlineView(outline, validateDrop: info, proposedItem: try node(rows.workspace.id),
                                               proposedChildIndex: 0), .move)
        XCTAssertTrue(coordinator.outlineView(outline, acceptDrop: info, item: outline.dropItem, childIndex: outline.dropChildIndex))
        XCTAssertEqual(rows.store.workspace(forSession: rows.second.id)?.id, rows.workspace.id)
    }

    func testTheTopLevelGapIsNoDropWhileTheFocusFilterHidesTheRoot() throws {
        let rows = try seed()
        rows.store.setFocusMembership(rows.workspace.id, member: true)
        rows.store.setFocusEnabled(true)
        buildSidebar(for: rows.store)

        XCTAssertEqual(coordinator.outlineView(outline, validateDrop: sessionDrag([rows.named.id]), proposedItem: nil,
                                               proposedChildIndex: 0), [])
    }

    func testAnEmptyRootTakesADropInTheGapAboveTheFirstWorkspaceRow() throws {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.namedWorkspaces.first)
        let session = try XCTUnwrap(workspace.sessions.first ?? store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        buildSidebar(for: store)
        let info = sessionDrag([session.id])

        XCTAssertEqual(coordinator.outlineView(outline, validateDrop: info, proposedItem: nil, proposedChildIndex: 0), .move)
        XCTAssertTrue(coordinator.outlineView(outline, acceptDrop: info, item: nil, childIndex: 0))
        XCTAssertEqual(store.rootWorkspace?.sessions.map(\.id), [session.id])
    }

    func testAFolderDroppedOnARootRowOpensInTheRootWhileANamedWorkspaceIsCurrent() throws {
        let rows = try seed()
        rows.store.selectSession(rows.named.id)
        buildSidebar(for: rows.store)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("agterm-sidebar-\(UUID().uuidString)"))
        addTeardownBlock { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([folder as NSURL])
        let info = SidebarDrag(pasteboard, over: outline)
        let before = rows.store.rootWorkspace?.sessions.count ?? 0

        XCTAssertEqual(coordinator.outlineView(outline, validateDrop: info, proposedItem: try node(rows.second.id),
                                               proposedChildIndex: SidebarDrop.onItemIndex), .copy)
        XCTAssertTrue(coordinator.outlineView(outline, acceptDrop: info, item: outline.dropItem, childIndex: outline.dropChildIndex))
        XCTAssertEqual(rows.store.rootWorkspace?.sessions.count, before + 1)
    }

    func testMoveToListsTopLevelSessionsFirstAndMovesANamedSessionIntoTheRoot() throws {
        let rows = try seed()
        buildSidebar(for: rows.store)
        rows.store.setSidebarSelection([rows.named.id])

        let submenu = try moveToMenu(rows.named.id)
        XCTAssertEqual(submenu.items.first?.title, ControlWorkspaceNode.rootLabel)
        let item = try XCTUnwrap(submenu.items.first)
        coordinator.perform(item.action, with: item)

        XCTAssertEqual(rows.store.workspace(forSession: rows.named.id)?.id, rows.root.id)
    }

    func testMoveToOnARootSessionOffersTheNamedWorkspacesOnly() throws {
        let rows = try seed()
        buildSidebar(for: rows.store)
        rows.store.setSidebarSelection([rows.second.id])

        XCTAssertEqual(try moveToMenu(rows.second.id).items.map(\.title), [rows.workspace.name])
    }

    func testTheCompanionMoveMenuHeadsTheRootsParentsTopLevelSessions() throws {
        let rows = try seed()
        let helper = try rows.store.addCompanion(to: rows.named.id).get()
        buildSidebar(for: rows.store)
        rows.store.setSidebarSelection([helper.id])

        let submenu = try moveToMenu(helper.id)
        XCTAssertEqual(Array(submenu.items.prefix(3).map(\.title)), [ControlWorkspaceNode.rootLabel, "top", "second"])
        XCTAssertTrue(submenu.items[0].isSectionHeader)
    }

    func testARootRowFocusesTheRootAndTogglesItsMembership() throws {
        let rows = try seed()
        buildSidebar(for: rows.store)
        rows.store.setSidebarSelection([rows.second.id])

        try perform("Focus Top-Level Sessions", onRow: rows.second.id)
        XCTAssertEqual(rows.store.focusedWorkspaceIDs, [rows.root.id])
        XCTAssertTrue(rows.store.focusEnabled)
        XCTAssertNotNil(try menuItem("Unfocus Top-Level Sessions", onRow: rows.second.id))
        try perform("Remove Top-Level Sessions from Focus", onRow: rows.second.id)
        XCTAssertTrue(rows.store.focusedWorkspaceIDs.isEmpty)
        try perform("Add Top-Level Sessions to Focus", onRow: rows.second.id)
        XCTAssertEqual(rows.store.focusedWorkspaceIDs, [rows.root.id])
        XCTAssertFalse(rows.store.focusEnabled)
    }

    func testANamedSessionRowOffersNoTopLevelSessionsFocusItems() throws {
        let rows = try seed()
        buildSidebar(for: rows.store)
        rows.store.setSidebarSelection([rows.named.id])

        let menu = try XCTUnwrap(coordinator.menu(forRow: try row(rows.named.id)))
        XCTAssertFalse(menu.items.contains { $0.title.contains(ControlWorkspaceNode.rootLabel) }, "\(menu.items.map(\.title))")
    }

    private func moveToMenu(_ id: UUID) throws -> NSMenu {
        let menu = try XCTUnwrap(coordinator.menu(forRow: try row(id)))
        return try XCTUnwrap(menu.items.first { $0.title == "Move to" }?.submenu, "\(menu.items.map(\.title))")
    }

    private func menuItem(_ title: String, onRow id: UUID) throws -> NSMenuItem? {
        try XCTUnwrap(coordinator.menu(forRow: try row(id))).items.first { $0.title == title }
    }

    private func perform(_ title: String, onRow id: UUID) throws {
        let item = try XCTUnwrap(try menuItem(title, onRow: id), title)
        coordinator.perform(item.action, with: item)
    }

    private func sessionDrag(_ ids: [UUID]) -> SidebarDrag {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("agterm-sidebar-\(UUID().uuidString)"))
        addTeardownBlock { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString(ids.map(\.uuidString).joined(separator: "\n"), forType: sessionPasteboardType)
        return SidebarDrag(pasteboard, over: outline)
    }

    private func workspaceDrag(_ id: UUID, at point: NSPoint) -> SidebarDrag {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("agterm-sidebar-\(UUID().uuidString)"))
        addTeardownBlock { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString(id.uuidString, forType: workspacePasteboardType)
        return SidebarDrag(pasteboard, over: outline, at: outline.convert(point, to: nil))
    }

    private func seed() throws -> RootRows {
        let store = try XCTUnwrap(library.activeStore)
        let root = try XCTUnwrap(store.rootWorkspace)
        let workspace = try XCTUnwrap(store.namedWorkspaces.first)
        let named = try XCTUnwrap(workspace.sessions.first ?? store.addSession(toWorkspace: workspace.id, cwd: "/tmp", name: "named"))
        let top = try XCTUnwrap(store.addSession(toWorkspace: root.id, cwd: "/tmp", name: "top"))
        let companion = try store.addCompanion(to: top.id, options: CompanionOptions(name: "helper")).get()
        let second = try XCTUnwrap(store.addSession(toWorkspace: root.id, cwd: "/tmp", name: "second"))
        return RootRows(store: store, root: root, workspace: workspace, named: named, top: top, companion: companion, second: second)
    }

    private func visibleIDs() -> [UUID] {
        (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? SidebarNode)?.id }
    }

    private func node(_ id: UUID) throws -> SidebarNode {
        try XCTUnwrap(outline.item(atRow: try row(id)) as? SidebarNode)
    }

    private func row(_ id: UUID) throws -> Int {
        try XCTUnwrap((0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarNode)?.id == id },
                      "no visible row for \(id)")
    }

    private func cell(_ id: UUID) throws -> SidebarCellView {
        try XCTUnwrap(outline.view(atColumn: 0, row: try row(id), makeIfNecessary: true) as? SidebarCellView)
    }

    private func buildSidebar(for store: AppStore) {
        outline = RecordingOutlineView()
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
        coordinator.rebuildAndReload()
    }
}

private struct RootRows {
    let store: AppStore
    let root: Workspace
    let workspace: Workspace
    let named: Session
    let top: Session
    let companion: Session
    let second: Session
}
