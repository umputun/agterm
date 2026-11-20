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
