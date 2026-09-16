import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for the row indent: macOS 27 reserves more leading room for the disclosure triangle than
/// it draws, and `SidebarOutlineView.frameOfCell` trims the surplus. The tight-gap cases only hold on that
/// version; the indent, the trailing edge, and the no-change promise below the gate hold everywhere.
@MainActor
final class SidebarRowIndentTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!
    private var window: NSWindow!
    private var scroll: NSScrollView!
    private var outline: SidebarOutlineView!
    private var coordinator: WorkspaceSidebar.Coordinator!
    private var stub: StubOutlineData!
    private var pairWindow: NSWindow!

    private static let sidebarWidth: CGFloat = 240
    private static let indentationPerLevel: CGFloat = 14

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-row-indent-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            actions = AppActions(library: library)
            stub = StubOutlineData()
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            window?.orderOut(nil)
            pairWindow?.orderOut(nil)
            window = nil
            pairWindow = nil
            scroll = nil
            outline = nil
            coordinator = nil
            actions = nil
            library = nil
            stub = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    func testWorkspaceRowStartsWhereTheDisclosureTriangleEnds() throws {
        try XCTSkipUnless(trimApplies)
        try buildSidebar()

        let row = try workspaceRow()
        XCTAssertEqual(outline.frameOfCell(atColumn: 0, row: row).minX, outline.frameOfOutlineCell(atRow: row).maxX,
                       "a row icon stranded past the triangle is the gap this trim exists to close")
    }

    func testRowIconClearsTheTriangleByTheCellInset() throws {
        try XCTSkipUnless(trimApplies)
        try buildSidebar()

        let row = try workspaceRow()
        let cell = try XCTUnwrap(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCellView)
        cell.layoutSubtreeIfNeeded()
        let icon = try XCTUnwrap(cell.imageView)
        XCTAssertEqual(icon.convert(icon.bounds, to: outline).minX, outline.frameOfOutlineCell(atRow: row).maxX + 2,
                       "the gap after the triangle should match the inset before it")
    }

    func testFlatLeafRowStartsWhereAParentRowDoes() throws {
        try XCTSkipUnless(trimApplies)
        let pair = buildPair()

        XCTAssertEqual(pair.trimmed.frameOfCell(atColumn: 0, row: StubOutlineData.leafRow).minX,
                       pair.trimmed.frameOfCell(atColumn: 0, row: StubOutlineData.parentRow).minX,
                       "flagged mode is all level-0 leaves, and they must not be left behind at the old offset")
    }

    func testSessionRowKeepsItsPerLevelIndent() throws {
        try buildSidebar()

        let workspace = outline.frameOfCell(atColumn: 0, row: try workspaceRow())
        let session = outline.frameOfCell(atColumn: 0, row: try sessionRow())
        XCTAssertEqual(session.minX - workspace.minX, Self.indentationPerLevel,
                       "the trim is the same at every level, so the outline's own indent has to survive it")
    }

    func testTrimLeavesTheTrailingEdgeAlone() {
        let pair = buildPair()

        for row in 0..<pair.plain.numberOfRows {
            XCTAssertEqual(pair.trimmed.frameOfCell(atColumn: 0, row: row).maxX,
                           pair.plain.frameOfCell(atColumn: 0, row: row).maxX,
                           "the status glyph and badge hang off the trailing edge and must not move")
        }
    }

    func testBelowTheGateFramesMatchAPlainOutline() throws {
        try XCTSkipIf(trimApplies)
        let pair = buildPair()

        for row in 0..<pair.plain.numberOfRows {
            XCTAssertEqual(pair.trimmed.frameOfCell(atColumn: 0, row: row),
                           pair.plain.frameOfCell(atColumn: 0, row: row),
                           "an earlier macOS lays the row out tightly already, and the override promises to keep that")
        }
    }

    private var trimApplies: Bool {
        if #available(macOS 27.0, *) { return true }
        return false
    }

    private func workspaceRow() throws -> Int {
        try row(ofKind: .workspace)
    }

    private func sessionRow() throws -> Int {
        try row(ofKind: .session)
    }

    private func row(ofKind kind: SidebarNode.Kind) throws -> Int {
        outline.layoutSubtreeIfNeeded()
        return try XCTUnwrap((0..<outline.numberOfRows).first { index in
            (outline.item(atRow: index) as? SidebarNode)?.kind == kind
        }, "the outline should show a \(kind) row")
    }

    /// Mirrors `WorkspaceSidebar.makeNSView`: the reserved leading strip depends on the outline's style and
    /// indentation, so a default-configured outline would measure something the app never renders.
    private func buildSidebar() throws {
        let store = try XCTUnwrap(library.activeStore)
        outline = SidebarOutlineView()
        coordinator = WorkspaceSidebar.Coordinator(store: store, actions: actions)
        outline.dataSource = coordinator
        outline.delegate = coordinator
        configure(outline)

        scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: Self.sidebarWidth, height: 400))
        scroll.documentView = outline
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.sidebarWidth, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll

        coordinator.outlineView = outline
        coordinator.renameController.outlineView = outline
        coordinator.seedExpansionFromModel()
        coordinator.rebuildAndReload()
        outline.expandItem(nil, expandChildren: true)
        outline.sizeLastColumnToFit()
        outline.layoutSubtreeIfNeeded()
    }

    /// The same rows in a `SidebarOutlineView` and a stock `NSOutlineView`, so AppKit's own layout is the
    /// oracle for what the override is supposed to leave alone.
    private func buildPair() -> (trimmed: SidebarOutlineView, plain: NSOutlineView) {
        let trimmed = SidebarOutlineView()
        let plain = NSOutlineView()
        pairWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.sidebarWidth * 2, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        pairWindow.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.sidebarWidth * 2, height: 400))
        pairWindow.contentView = container
        for (index, outline) in [trimmed, plain].enumerated() {
            outline.dataSource = stub
            container.addSubview(outline)
            outline.frame = NSRect(x: CGFloat(index) * Self.sidebarWidth, y: 0, width: Self.sidebarWidth, height: 400)
            configure(outline)
            outline.reloadData()
            outline.expandItem(nil, expandChildren: true)
            outline.sizeLastColumnToFit()
            outline.layoutSubtreeIfNeeded()
        }
        return (trimmed, plain)
    }

    private func configure(_ outline: NSOutlineView) {
        outline.headerView = nil
        outline.rowSizeStyle = .custom
        outline.rowHeight = AppSettings.sidebarRowHeight(fontSize: GhosttyApp.shared.sidebarFontSize)
        outline.indentationPerLevel = Self.indentationPerLevel
        outline.style = .plain
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
    }
}

/// Outline content for the paired comparison: an expandable parent with one child, then a level-0 leaf
/// standing in for a flagged-mode row.
private final class StubOutlineData: NSObject, NSOutlineViewDataSource {
    final class Node: NSObject {
        let children: [Node]
        init(children: [Node] = []) { self.children = children }
    }

    static let parentRow = 0
    static let leafRow = 2

    let roots = [Node(children: [Node()]), Node()]

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Node)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, objectValueFor tableColumn: NSTableColumn?, byItem item: Any?) -> Any? {
        ""
    }
}
