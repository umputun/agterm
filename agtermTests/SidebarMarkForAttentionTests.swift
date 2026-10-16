import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for the row context menu's Mark for Attention item: which rows offer it beside Clear
/// Status, and that it marks only the idle targets of a batch.
@MainActor
final class SidebarMarkForAttentionTests: XCTestCase {
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
                .appendingPathComponent("agterm-mark-attention-tests-\(UUID().uuidString)", isDirectory: true)
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

    func testIdleRowMarksTheSessionCompleted() throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        buildSidebar(for: store)

        let titles = try menuTitles(onRowFor: session.id)
        XCTAssertFalse(titles.contains("Clear Status"))
        let item = try menuItem(titled: "Mark for Attention", onRowFor: session.id)
        coordinator.perform(item.action, with: item)

        XCTAssertEqual(session.agentIndicator, AgentIndicator(status: .completed))
    }

    func testRowWithAStatusOffersOnlyClearStatus() throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        store.setAgentIndicator(AgentIndicator(status: .completed), forSession: session.id)
        buildSidebar(for: store)

        let titles = try menuTitles(onRowFor: session.id)
        XCTAssertTrue(titles.contains("Clear Status"))
        XCTAssertFalse(titles.contains("Mark for Attention"))
    }

    func testMixedSelectionOffersBothAndMarksOnlyTheIdleSession() throws {
        let store = try XCTUnwrap(library.activeStore)
        let ws = try XCTUnwrap(store.workspaces.first)
        let idle = try XCTUnwrap(store.addSession(toWorkspace: ws.id, cwd: "/tmp/idle"))
        let blocked = try XCTUnwrap(store.addSession(toWorkspace: ws.id, cwd: "/tmp/blocked"))
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: blocked.id)
        store.selectSession(idle.id)
        store.setSidebarSelection([idle.id, blocked.id])
        buildSidebar(for: store)

        let titles = try menuTitles(onRowFor: idle.id)
        XCTAssertTrue(titles.contains("Close 2 Sessions"), "the batch must have formed")
        XCTAssertTrue(titles.contains("Clear Statuses"))
        let item = try menuItem(titled: "Mark for Attention", onRowFor: idle.id)
        coordinator.perform(item.action, with: item)

        XCTAssertEqual(idle.agentIndicator.status, .completed)
        XCTAssertEqual(blocked.agentIndicator.status, .blocked)
    }

    // MARK: - Helpers

    private func menuTitles(onRowFor sessionID: UUID) throws -> [String] {
        let row = try XCTUnwrap(rowIndex { $0.kind == .session && $0.id == sessionID },
                                "no sidebar row for that session")
        return try XCTUnwrap(coordinator.menu(forRow: row)).items.map(\.title)
    }

    private func menuItem(titled title: String, onRowFor sessionID: UUID) throws -> NSMenuItem {
        let row = try XCTUnwrap(rowIndex { $0.kind == .session && $0.id == sessionID },
                                "no sidebar row for that session")
        let menu = try XCTUnwrap(coordinator.menu(forRow: row))
        return try XCTUnwrap(menu.items.first { $0.title == title },
                             "no '\(title)' item; menu had \(menu.items.map(\.title))")
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
        window.isReleasedWhenClosed = false // see SidebarStatusBlinkTests for why
        window.contentView = scroll

        coordinator.outlineView = outline
        coordinator.renameController.outlineView = outline
        coordinator.seedExpansionFromModel()
        coordinator.reconcile()
    }
}
