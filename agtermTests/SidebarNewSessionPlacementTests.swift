import AppKit
import XCTest
@testable import agterm
import agtermCore

/// The workspace row's New Session under "After the current session", in the sidebar's own store.
@MainActor
final class SidebarNewSessionPlacementTests: XCTestCase {
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
                .appendingPathComponent("agterm-sidebar-placement-tests-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
            library = WindowLibrary(directory: stateDir)
            actions = AppActions(library: library)
            let settings = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
            settings.setNewSessionPlacement(AppSettings.NewSessionPlacement.afterCurrent.rawValue)
            actions.settingsModel = settings
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

    func testWorkspaceRowNewSessionInsertsAfterTheSelectionInThatWorkspace() throws {
        let store = try XCTUnwrap(library.activeStore)
        let ws = try XCTUnwrap(store.workspaces.first)
        let first = try XCTUnwrap(store.activeSession)
        _ = try XCTUnwrap(store.addSession(toWorkspace: ws.id, cwd: "/tmp/second"))
        store.selectSession(first.id)
        buildSidebar(for: store)

        try invokeNewSession(onWorkspaceRowFor: ws.id)

        let sessions = try XCTUnwrap(store.workspaces.first { $0.id == ws.id }).sessions
        XCTAssertEqual(sessions.count, 3)
        XCTAssertEqual(sessions[1].id, store.selectedSessionID)
    }

    func testWorkspaceRowNewSessionAppendsWhenTheSelectionIsElsewhere() throws {
        let store = try XCTUnwrap(library.activeStore)
        let selected = try XCTUnwrap(store.activeSession)
        let other = store.addWorkspace(name: "other")
        for cwd in ["/tmp/a", "/tmp/b"] {
            _ = try XCTUnwrap(store.addSession(toWorkspace: other.id, cwd: cwd, select: false))
        }
        store.selectSession(selected.id)
        buildSidebar(for: store)

        try invokeNewSession(onWorkspaceRowFor: other.id)

        let sessions = try XCTUnwrap(store.workspaces.first { $0.id == other.id }).sessions
        XCTAssertEqual(sessions.count, 3)
        XCTAssertEqual(sessions.last?.id, store.selectedSessionID)
    }

    // MARK: - Helpers

    private func invokeNewSession(onWorkspaceRowFor workspaceID: UUID) throws {
        let row = try XCTUnwrap((0..<outline.numberOfRows).first { row in
            (outline.item(atRow: row) as? SidebarNode).map { $0.kind == .workspace && $0.id == workspaceID } ?? false
        }, "no sidebar row for that workspace")
        let menu = try XCTUnwrap(coordinator.menu(forRow: row))
        let item = try XCTUnwrap(menu.items.first { $0.title == "New Session" },
                                 "no 'New Session' item; menu had \(menu.items.map(\.title))")
        coordinator.perform(item.action, with: item)
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
