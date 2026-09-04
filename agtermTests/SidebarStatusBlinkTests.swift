import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for the sidebar status glyph's blink lifecycle: it starts and stops with the indicator,
/// and survives a terminal title change, which relabels the row's cell in place through `displayName`.
@MainActor
final class SidebarStatusBlinkTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!
    private var window: NSWindow!
    private var outline: SidebarOutlineView!
    private var coordinator: WorkspaceSidebar.Coordinator!
    private var builds: CellBuildCounter!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-status-blink-tests-\(UUID().uuidString)", isDirectory: true)
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
            builds = nil
            actions = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    func testTitleChangeDoesNotRestartTheStatusBlink() throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                      "Reduce Motion suppresses the blink this test pins")
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        buildSidebar(for: store)

        session.agentIndicator = AgentIndicator(status: .active, blink: true)
        coordinator.reconcile()
        let (firstCell, firstBlink) = try renderedStatus(forSession: session.id)
        let built = builds.count

        session.oscTitle = "spin 1"
        coordinator.reconcile()
        let (secondCell, secondBlink) = try renderedStatus(forSession: session.id)

        XCTAssertEqual(builds.count, built, "a title tick must relabel the live cell, not rebuild it through reloadItem")
        XCTAssertTrue(firstCell === secondCell, "the relabel must land on the cell already on screen")
        XCTAssertEqual(secondCell.textField?.stringValue, "spin 1")
        XCTAssertTrue(firstBlink === secondBlink,
                      "the blink must ride through the relabel; a fresh animation restarts the fade at full opacity")
    }

    func testAFlagChangeStillRebuildsTheCell() throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        buildSidebar(for: store)
        _ = try renderedRow(forSession: session.id)
        let built = builds.count

        session.flagged = true
        coordinator.reconcile()
        _ = try renderedRow(forSession: session.id)

        XCTAssertGreaterThan(builds.count, built, "the counter must see a reload, or the zero above proves nothing")
    }

    func testStatusChangeStillStartsTheBlink() throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                      "Reduce Motion suppresses the blink this test pins")
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        buildSidebar(for: store)

        session.agentIndicator = AgentIndicator(status: .active, blink: false)
        coordinator.reconcile()
        let (_, cell) = try renderedRow(forSession: session.id)
        XCTAssertNil(cell.statusIcon.layer?.animation(forKey: Self.blinkKey),
                     "a non-blinking status must not animate")

        session.agentIndicator = AgentIndicator(status: .active, blink: true)
        coordinator.reconcile()
        _ = try renderedStatus(forSession: session.id)
    }

    func testClearingOnlyTheBlinkFlagStopsTheAnimation() throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                      "Reduce Motion suppresses the blink this test pins")
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        buildSidebar(for: store)

        session.agentIndicator = AgentIndicator(status: .active, blink: true)
        coordinator.reconcile()
        _ = try renderedStatus(forSession: session.id)

        session.agentIndicator = AgentIndicator(status: .active, blink: false)
        coordinator.reconcile()
        let (_, cell) = try renderedRow(forSession: session.id)

        XCTAssertNil(cell.statusIcon.layer?.animation(forKey: Self.blinkKey),
                     "dropping the blink flag must stop the animation, not only going idle")
        XCTAssertFalse(cell.statusIcon.isHidden, "a still-active status keeps its glyph on screen")
    }

    func testClearingBlinkStopsTheAnimation() throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                      "Reduce Motion suppresses the blink this test pins")
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        buildSidebar(for: store)

        session.agentIndicator = AgentIndicator(status: .active, blink: true)
        coordinator.reconcile()
        _ = try renderedStatus(forSession: session.id)

        session.agentIndicator = AgentIndicator(status: .idle)
        coordinator.reconcile()
        let (_, cell) = try renderedRow(forSession: session.id)

        XCTAssertNil(cell.statusIcon.layer?.animation(forKey: Self.blinkKey),
                     "going idle must remove the animation, not leave a hidden view pulsing")
    }

    /// Mirrors `StatusIconView.blinkKey`, which is private; the non-nil assertions below fail loudly if the
    /// two ever drift, so a renamed key cannot make these tests pass vacuously.
    private static let blinkKey = "agent-status-blink"

    private func buildSidebar(for store: AppStore) {
        outline = SidebarOutlineView()
        coordinator = WorkspaceSidebar.Coordinator(store: store, actions: actions)
        builds = CellBuildCounter(forwarding: coordinator)
        outline.dataSource = coordinator
        outline.delegate = builds
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
        // over-releases a window the registry may still hold, crashing the host at autorelease-pool pop
        window.isReleasedWhenClosed = false
        window.contentView = scroll

        coordinator.outlineView = outline
        coordinator.renameController.outlineView = outline
        coordinator.seedExpansionFromModel()
        coordinator.reconcile()
    }

    private func renderedRow(forSession id: UUID) throws -> (row: Int, cell: SidebarCellView) {
        outline.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap((0..<outline.numberOfRows).first { index in
            guard let node = outline.item(atRow: index) as? SidebarNode else { return false }
            return node.kind == .session && node.id == id
        }, "the session row should be visible in the outline")
        let cell = try XCTUnwrap(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCellView)
        return (row, cell)
    }

    private func renderedStatus(forSession id: UUID) throws -> (cell: SidebarCellView, blink: CAAnimation) {
        let (_, cell) = try renderedRow(forSession: id)
        let blink = try XCTUnwrap(cell.statusIcon.layer?.animation(forKey: Self.blinkKey),
                                  "a blinking status should have installed the opacity animation")
        return (cell, blink)
    }
}

/// Counts the outline's cell-builder calls and hands every other delegate message to the coordinator.
@MainActor
private final class CellBuildCounter: NSObject, NSOutlineViewDelegate {
    private(set) var count = 0
    private let coordinator: WorkspaceSidebar.Coordinator

    init(forwarding coordinator: WorkspaceSidebar.Coordinator) {
        self.coordinator = coordinator
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        count += 1
        return coordinator.outlineView(outlineView, viewFor: tableColumn, item: item)
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || coordinator.responds(to: aSelector)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        coordinator
    }
}
