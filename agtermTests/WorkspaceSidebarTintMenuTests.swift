import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for the row menus' Tint submenu and the tinted row rendering.
@MainActor
final class WorkspaceSidebarTintMenuTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!
    private var window: NSWindow!
    private var outline: SidebarOutlineView!
    private var coordinator: WorkspaceSidebar.Coordinator!
    private var savedUserKeyEquivalents = true

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            savedUserKeyEquivalents = NSMenuItem.usesUserKeyEquivalents
            NSMenuItem.usesUserKeyEquivalents = false
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-tint-menu-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            actions = AppActions(library: library)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            NSMenuItem.usesUserKeyEquivalents = savedUserKeyEquivalents
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

    func testPickingAColorTintsTheClickedSession() throws {
        let store = try XCTUnwrap(library.activeStore)
        let (_, sessions) = try seed(store, tints: [nil])
        buildSidebar(for: store)

        try perform("Red", in: try tintMenu(onSession: sessions[0].id))

        XCTAssertEqual(sessions[0].tint, SidebarTint(color: .red))
    }

    func testABatchChecksOnlyWhatEveryTargetShares() throws {
        let store = try XCTUnwrap(library.activeStore)
        let (_, sessions) = try seed(store, tints: [SidebarTint(color: .red, parts: [.name]), SidebarTint(color: .green)])
        store.setSidebarSelection(sessions.map(\.id))
        buildSidebar(for: store)

        let menu = try tintMenu(onSession: sessions[0].id)

        XCTAssertTrue(menu.items.allSatisfy { $0.state == .off }, "mixed colors and placements must check nothing")
        try perform("Blue", in: menu)
        XCTAssertEqual(sessions.map(\.tint), [SidebarTint(color: .blue, parts: [.name]), SidebarTint(color: .blue)])
        let shared = try tintMenu(onSession: sessions[0].id)
        XCTAssertEqual(try item("Blue", in: shared).state, .on)
    }

    func testShowOnIsDisabledUnlessEveryTargetIsTinted() throws {
        let store = try XCTUnwrap(library.activeStore)
        let (_, sessions) = try seed(store, tints: [SidebarTint(color: .red), nil])
        store.setSidebarSelection(sessions.map(\.id))
        buildSidebar(for: store)

        let menu = try tintMenu(onSession: sessions[0].id)

        XCTAssertFalse(try item("Name", in: menu).isEnabled)
        XCTAssertFalse(try item("Icon and Name", in: menu).isEnabled)
    }

    func testShowOnMovesEachRowsOwnColor() throws {
        let store = try XCTUnwrap(library.activeStore)
        let (_, sessions) = try seed(store, tints: [SidebarTint(color: .red), SidebarTint(color: .green)])
        store.setSidebarSelection(sessions.map(\.id))
        buildSidebar(for: store)

        try perform("Icon and Name", in: try tintMenu(onSession: sessions[0].id))

        XCTAssertEqual(sessions.map(\.tint), [SidebarTint(color: .red, parts: [.icon, .name]),
                                              SidebarTint(color: .green, parts: [.icon, .name])])
    }

    func testNoneClearsTheTint() throws {
        let store = try XCTUnwrap(library.activeStore)
        let (_, sessions) = try seed(store, tints: [SidebarTint(color: .red)])
        buildSidebar(for: store)
        let menu = try tintMenu(onSession: sessions[0].id)
        XCTAssertEqual(try item("Red", in: menu).state, .on)

        try perform("None", in: menu)

        XCTAssertNil(sessions[0].tint)
    }

    func testWorkspaceMenuTintsTheWorkspaceRowAlone() throws {
        let store = try XCTUnwrap(library.activeStore)
        let (workspaceID, sessions) = try seed(store, tints: [nil])
        buildSidebar(for: store)

        try perform("Purple", in: try tintMenu(onWorkspace: workspaceID))

        XCTAssertEqual(store.workspaces.first { $0.id == workspaceID }?.tint, SidebarTint(color: .purple))
        XCTAssertNil(sessions[0].tint)
    }

    func testTintColorsTheIconOrNameAndSurvivesSelection() throws {
        let store = try XCTUnwrap(library.activeStore)
        let (_, sessions) = try seed(store, tints: [nil])
        buildSidebar(for: store)
        let plainIcon = try cell(forSession: sessions[0].id).imageView?.contentTintColor

        store.setTint(SidebarTint(color: .red, parts: [.icon]), forSession: sessions[0].id)
        coordinator.reconcile()
        var tinted = try cell(forSession: sessions[0].id)
        XCTAssertEqual(tinted.imageView?.contentTintColor, NSColor.systemRed)
        XCTAssertNotEqual(tinted.textField?.textColor, NSColor.systemRed)
        XCTAssertEqual(tinted.imageView?.accessibilityValue() as? String, "red tint")
        tinted.setColors(selected: true)
        XCTAssertEqual(tinted.imageView?.contentTintColor, NSColor.systemRed)

        store.setTint(SidebarTint(color: .green, parts: [.name]), forSession: sessions[0].id)
        coordinator.reconcile()
        tinted = try cell(forSession: sessions[0].id)
        XCTAssertEqual(tinted.textField?.textColor, NSColor.systemGreen)

        store.setTint(nil, forSession: sessions[0].id)
        coordinator.reconcile()
        let cleared = try cell(forSession: sessions[0].id)
        XCTAssertEqual(cleared.imageView?.contentTintColor, plainIcon)
        XCTAssertNil(cleared.imageView?.accessibilityValue())
    }

    // MARK: - Helpers

    private func seed(_ store: AppStore, tints: [SidebarTint?]) throws -> (UUID, [Session]) {
        let workspace = store.addWorkspace(name: "target")
        let sessions = try tints.enumerated().map { index, tint in
            let session = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp/t\(index)"))
            store.setTint(tint, forSession: session.id)
            return session
        }
        return (workspace.id, sessions)
    }

    private func tintMenu(onSession id: UUID) throws -> NSMenu {
        try tintMenu(row: try XCTUnwrap(rowIndex { $0.kind == .session && $0.id == id }))
    }

    private func tintMenu(onWorkspace id: UUID) throws -> NSMenu {
        try tintMenu(row: try XCTUnwrap(rowIndex { $0.kind == .workspace && $0.id == id }))
    }

    private func tintMenu(row: Int) throws -> NSMenu {
        let menu = try XCTUnwrap(coordinator.menu(forRow: row))
        return try XCTUnwrap(menu.items.first { $0.title == "Tint" }?.submenu, "menu had \(menu.items.map(\.title))")
    }

    private func item(_ title: String, in menu: NSMenu) throws -> NSMenuItem {
        try XCTUnwrap(menu.items.first { $0.title == title }, "no '\(title)'; submenu had \(menu.items.map(\.title))")
    }

    private func perform(_ title: String, in menu: NSMenu) throws {
        let item = try item(title, in: menu)
        XCTAssertTrue(item.isEnabled)
        coordinator.perform(item.action, with: item)
    }

    private func cell(forSession id: UUID) throws -> SidebarCellView {
        let row = try XCTUnwrap(rowIndex { $0.kind == .session && $0.id == id })
        return try XCTUnwrap(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCellView)
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
