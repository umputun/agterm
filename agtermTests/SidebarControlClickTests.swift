import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for Control-click as the secondary click on sidebar rows (issue #668). CI does not run
/// the UI tests that drive a real Control-click, so this sends the event straight to `mouseDown`.
@MainActor
final class SidebarControlClickTests: XCTestCase {
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
                .appendingPathComponent("agterm-control-click-tests-\(UUID().uuidString)", isDirectory: true)
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
            actions = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    func testControlClickOnSessionRowOpensMenuAndNarrowsSelection() throws {
        let store = try XCTUnwrap(library.activeStore)
        let first = try XCTUnwrap(store.activeSession)
        let ws = try XCTUnwrap(store.workspaces.first)
        let second = try XCTUnwrap(store.addSession(toWorkspace: ws.id, cwd: "/tmp/second"))
        store.selectSession(first.id)
        buildSidebar(for: store)
        let row = try XCTUnwrap(rowIndex { $0.kind == .session && $0.id == second.id })
        XCTAssertFalse(outline.selectedRowIndexes.contains(row))

        XCTAssertEqual(try controlClick(row: row), 1, "Control-click should open the row's context menu")
        XCTAssertEqual(outline.selectedRowIndexes, IndexSet(integer: row), "Control-click should narrow like a right-click")
    }

    func testControlClickOnWorkspaceRowOpensMenuWithoutTogglingExpansion() throws {
        let store = try XCTUnwrap(library.activeStore)
        let ws = try XCTUnwrap(store.workspaces.first)
        buildSidebar(for: store)
        let row = try XCTUnwrap(rowIndex { $0.kind == .workspace && $0.id == ws.id })
        let node = try XCTUnwrap(outline.item(atRow: row))
        XCTAssertTrue(outline.isItemExpanded(node))

        XCTAssertEqual(try controlClick(row: row), 1, "Control-click should open the workspace row's context menu")
        RunLoop.main.run(until: Date().addingTimeInterval(NSEvent.doubleClickInterval + 0.2))
        XCTAssertTrue(outline.isItemExpanded(node), "Control-click must not schedule the row-click expansion toggle")
    }

    private final class MenuTrackingRecorder: @unchecked Sendable {
        var count = 0
    }

    /// Returns how many menus began tracking. The popped-up menu runs a modal loop, so it is dismissed from
    /// inside that loop; the posted mouse-up lets NSTableView's own click tracking return instead.
    private func controlClick(row: Int) throws -> Int {
        let recorder = MenuTrackingRecorder()
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                              object: nil, queue: .main) { note in
            recorder.count += 1
            (note.object as? NSMenu)?.perform(#selector(NSMenu.cancelTracking), with: nil, afterDelay: 0,
                                              inModes: [.eventTracking, .default])
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let rect = outline.rect(ofRow: row)
        let point = outline.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let down = try mouseEvent(.leftMouseDown, at: point)
        NSApp.postEvent(try mouseEvent(.leftMouseUp, at: point), atStart: false)
        outline.mouseDown(with: down)
        _ = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true)
        return recorder.count
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: .control,
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                         clickCount: 1, pressure: 1))
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
        outline.allowsMultipleSelection = true
        outline.action = #selector(WorkspaceSidebar.Coordinator.handleSingleClick(_:))
        outline.target = coordinator

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        scroll.documentView = outline
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false // see SidebarStatusBlinkTests for why
        window.contentView = scroll

        coordinator.outlineView = outline
        coordinator.renameController.outlineView = outline
        coordinator.seedExpansionFromModel()
        coordinator.reconcile()
    }
}
