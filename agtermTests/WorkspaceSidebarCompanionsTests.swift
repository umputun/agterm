import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class WorkspaceSidebarCompanionsTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!
    private var window: NSWindow!
    private var outline: RecordingOutlineView!
    private var coordinator: WorkspaceSidebar.Coordinator!
    private var savedUserKeyEquivalents = true

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            savedUserKeyEquivalents = NSMenuItem.usesUserKeyEquivalents
            NSMenuItem.usesUserKeyEquivalents = false
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-companions-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            actions = AppActions(library: library)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            NSMenuItem.usesUserKeyEquivalents = savedUserKeyEquivalents
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

    func testCompanionRowsNestUnderTheirParent() throws {
        let group = try seed()
        buildSidebar(for: group.store)

        let parentNode = try node(group.parent.id)
        XCTAssertEqual(parentNode.children.map(\.id), [group.first.id, group.second.id])
        XCTAssertEqual(try node(group.work.id).children.map(\.id), [group.parent.id, group.after.id])
        XCTAssertTrue(outline.isExpandable(parentNode))
        XCTAssertEqual(outline.level(forRow: try row(group.first.id)), outline.level(forRow: try row(group.parent.id)) + 1)
        XCTAssertEqual(try cell(group.first.id).textField?.accessibilityLabel(), "companion")
        XCTAssertNil(try cell(group.parent.id).textField?.accessibilityLabel())
    }

    func testFlaggedLayoutsListCompanionsAtTheirParentsLevel() throws {
        let group = try seed()
        group.store.setFlag(true, forSessions: [group.parent.id, group.first.id])
        group.store.setSidebarMode(.flagged)
        buildSidebar(for: group.store)

        XCTAssertTrue(try node(group.parent.id).children.isEmpty)
        XCTAssertEqual(outline.level(forRow: try row(group.first.id)), outline.level(forRow: try row(group.parent.id)))
    }

    func testFoldingAParentPersistsAndShowsTheCompanionsThatNeedAttention() throws {
        let group = try seed()
        group.store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: group.first.id)
        buildSidebar(for: group.store)
        XCTAssertTrue(try XCTUnwrap(cell(group.parent.id).companionMarker).isHidden, "an open parent shows its companions")

        outline.collapseItem(try node(group.parent.id))

        XCTAssertFalse(group.parent.isExpanded)
        let marker = try XCTUnwrap(cell(group.parent.id).companionMarker)
        XCTAssertFalse(marker.isHidden)
        XCTAssertEqual(marker.accessibilityLabel(), "companions need attention: \(group.first.displayName)")

        outline.expandItem(try node(group.parent.id))

        XCTAssertTrue(group.parent.isExpanded)
        XCTAssertTrue(try XCTUnwrap(cell(group.parent.id).companionMarker).isHidden)
    }

    func testAFoldedParentStaysFoldedAcrossARebuild() throws {
        let group = try seed()
        group.store.setSessionExpanded(group.parent.id, expanded: false)
        buildSidebar(for: group.store)

        XCTAssertFalse(outline.isItemExpanded(try node(group.parent.id)))
        coordinator.rebuildAndReload()
        XCTAssertFalse(outline.isItemExpanded(try node(group.parent.id)))
    }

    func testSelectingACompanionOfAFoldedParentRevealsItWithoutPersisting() throws {
        let group = try seed()
        group.store.setSessionExpanded(group.parent.id, expanded: false)
        group.store.setWorkspaceExpanded(group.work.id, expanded: false)
        buildSidebar(for: group.store)

        group.store.selectSession(group.second.id)
        coordinator.syncSelection()

        XCTAssertEqual(outline.selectedRow, try row(group.second.id))
        XCTAssertFalse(group.parent.isExpanded, "a reveal is a view action")
        XCTAssertEqual(group.store.selectedSessionID, group.second.id)
    }

    func testFoldingAParentKeepsTheActiveCompanion() throws {
        let group = try seed()
        buildSidebar(for: group.store)
        group.store.selectSession(group.first.id)
        coordinator.syncSelection()

        outline.collapseItem(try node(group.parent.id))

        XCTAssertEqual(group.store.selectedSessionID, group.first.id)
    }

    func testRowMenuNewCompanionAddsASiblingUnderTheParent() throws {
        let group = try seed()
        buildSidebar(for: group.store)

        let menu = try XCTUnwrap(coordinator.menu(forRow: try row(group.first.id)))
        let item = try XCTUnwrap(menu.items.first { $0.title == "New Companion" }, "menu had \(menu.items.map(\.title))")
        coordinator.perform(item.action, with: item)

        let companions = group.store.companions(of: group.parent.id)
        XCTAssertEqual(companions.count, 3)
        XCTAssertEqual(group.store.selectedSessionID, companions.last?.id)
    }

    // a cached parent node kept its nested rows into the flat flagged list
    func testSwitchingToAFlatFlaggedLayoutDropsTheParentsNestedRows() throws {
        let group = try seed()
        group.store.setFlag(true, forSession: group.parent.id)
        buildSidebar(for: group.store)
        XCTAssertFalse(try node(group.parent.id).children.isEmpty)

        for layout in [FlaggedViewLayout.flat, .plain] {
            GhosttyApp.shared.setFlaggedViewLayout(layout)
            group.store.setSidebarMode(.flagged)
            coordinator.reconcile()

            XCTAssertTrue(try node(group.parent.id).children.isEmpty, "\(layout)")
            XCTAssertFalse(outline.isExpandable(try node(group.parent.id)), "\(layout)")
            XCTAssertEqual(outline.numberOfRows, 1, "\(layout)")
            group.store.setSidebarMode(.tree)
            coordinator.reconcile()
        }
    }

    // an on-row drop was retargeted to a flat workspace index that acceptDrop could not read back
    func testASiblingDroppedOnItsSiblingRowReordersTheGroup() throws {
        let group = try seed()
        buildSidebar(for: group.store)

        XCTAssertTrue(try drop([group.first.id], onRow: group.second.id))

        XCTAssertEqual(group.store.workspaces.first { $0.id == group.work.id }?.sessions.map(\.id),
                       [group.parent.id, group.second.id, group.first.id, group.after.id])
    }

    func testATopLevelSessionDroppedOnARowBelowAGroupLandsRightAfterThatRow() throws {
        let group = try seed()
        let middle = try XCTUnwrap(group.store.addSession(toWorkspace: group.work.id, cwd: "/tmp", name: "middle"))
        let last = try XCTUnwrap(group.store.addSession(toWorkspace: group.work.id, cwd: "/tmp", name: "last"))
        buildSidebar(for: group.store)

        XCTAssertTrue(try drop([last.id], onRow: group.after.id))

        XCTAssertEqual(group.store.workspaces.first { $0.id == group.work.id }?.sessions.map(\.id),
                       [group.parent.id, group.first.id, group.second.id, group.after.id, last.id, middle.id])
    }

    func testAParentDraggedWithItsCompanionMovesTheGroupToAnotherWorkspace() throws {
        let group = try seed()
        let other = group.store.addWorkspace(name: "other")
        buildSidebar(for: group.store)

        XCTAssertTrue(try drop([group.parent.id, group.first.id], onRow: other.id))

        XCTAssertEqual(group.store.workspaces.first { $0.id == other.id }?.sessions.map(\.id),
                       [group.parent.id, group.first.id, group.second.id])
    }

    func testMoveToIsOfferedForAParentAndNotForACompanion() throws {
        let group = try seed()
        _ = group.store.addWorkspace(name: "other")
        buildSidebar(for: group.store)

        let parentMenu = try XCTUnwrap(coordinator.menu(forRow: try row(group.parent.id)))
        XCTAssertNotNil(parentMenu.items.first { $0.title == "Move to" })
        group.store.setSidebarSelection([group.first.id])
        let companionMenu = try XCTUnwrap(coordinator.menu(forRow: try row(group.first.id)))
        XCTAssertNil(companionMenu.items.first { $0.title == "Move to" }, "\(companionMenu.items.map(\.title))")
    }

    private func drop(_ ids: [UUID], onRow target: UUID) throws -> Bool {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("agterm-companions-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString(ids.map(\.uuidString).joined(separator: "\n"), forType: sessionPasteboardType)
        let info = FakeDrag(pasteboard, over: outline)
        let operation = coordinator.outlineView(outline, validateDrop: info, proposedItem: try node(target),
                                                proposedChildIndex: SidebarDrop.onItemIndex)
        guard operation == .move else { return false }
        return coordinator.outlineView(outline, acceptDrop: info, item: outline.dropItem,
                                       childIndex: outline.dropChildIndex)
    }

    func testAPageCompanionRowShowsThePageIconFilledWhenFlagged() throws {
        let group = try seed()
        let page = try group.store.addPageCompanion(to: group.parent.id,
                                                    overlay: HtmlOverlay(source: .file(path: "/tmp/p.html", grantRoot: nil)),
                                                    select: false).get()
        buildSidebar(for: group.store)
        XCTAssertTrue(try cell(page.id).imageView?.image === coordinator.pageSessionIcon)

        group.store.setFlag(true, forSession: page.id)
        coordinator.reconcile()

        XCTAssertTrue(try cell(page.id).imageView?.image === coordinator.flaggedPageSessionIcon)
    }

    private func seed() throws -> CompanionRows {
        let store = try XCTUnwrap(library.activeStore)
        let work = store.addWorkspace(name: "work")
        let parent = try XCTUnwrap(store.addSession(toWorkspace: work.id, cwd: "/tmp", name: "parent"))
        let after = try XCTUnwrap(store.addSession(toWorkspace: work.id, cwd: "/tmp", name: "after"))
        let first = try store.addCompanion(to: parent.id, options: CompanionOptions(name: "first")).get()
        let second = try store.addCompanion(to: parent.id, options: CompanionOptions(name: "second")).get()
        return CompanionRows(store: store, work: work, parent: parent, first: first, second: second, after: after)
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

private struct CompanionRows {
    let store: AppStore
    let work: Workspace
    let parent: Session
    let first: Session
    let second: Session
    let after: Session
}

private final class RecordingOutlineView: NSOutlineView {
    private(set) var dropItem: Any?
    private(set) var dropChildIndex = SidebarDrop.onItemIndex

    override func setDropItem(_ item: Any?, dropChildIndex index: Int) {
        dropItem = item
        dropChildIndex = index
        super.setDropItem(item, dropChildIndex: index)
    }
}

@MainActor
private final class FakeDrag: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow?
    let draggingLocation: NSPoint

    init(_ pasteboard: NSPasteboard, over view: NSView) {
        draggingPasteboard = pasteboard
        draggingDestinationWindow = view.window
        draggingLocation = .zero
    }

    var draggingSourceOperationMask: NSDragOperation { .every }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to _: NSPoint) {}
    func enumerateDraggingItems(options _: NSDraggingItemEnumerationOptions = [], for _: NSView?, classes _: [AnyClass],
                                searchOptions _: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using _: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
