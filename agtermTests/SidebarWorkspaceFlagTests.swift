import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for the workspace row's Flag All Sessions / Unflag All Sessions item.
@MainActor
final class SidebarWorkspaceFlagTests: XCTestCase {
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
                .appendingPathComponent("agterm-workspace-flag-tests-\(UUID().uuidString)", isDirectory: true)
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
            GhosttyApp.shared.setFlaggedViewLayout(.flat)
            actions = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    func testMixedWorkspaceOffersFlagAllAndFlagsEverySession() throws {
        let store = try XCTUnwrap(library.activeStore)
        let (workspaceID, sessions) = try seed(store, flagged: [true, false])
        buildSidebar(for: store)

        try perform("Flag All Sessions", onWorkspace: workspaceID)

        XCTAssertEqual(sessions.map(\.flagged), [true, true])
    }

    func testAllFlaggedWorkspaceOffersUnflagAll() throws {
        let store = try XCTUnwrap(library.activeStore)
        let (workspaceID, sessions) = try seed(store, flagged: [true, true])
        buildSidebar(for: store)

        try perform("Unflag All Sessions", onWorkspace: workspaceID)

        XCTAssertEqual(sessions.map(\.flagged), [false, false])
    }

    func testEmptyWorkspaceDisablesTheItem() throws {
        let store = try XCTUnwrap(library.activeStore)
        let empty = store.addWorkspace(name: "empty")
        buildSidebar(for: store)

        let item = try menuItem(titled: "Flag All Sessions", onWorkspace: empty.id)

        XCTAssertFalse(item.isEnabled)
    }

    func testFlaggedTreeLayoutFlagsTheSessionsItHides() throws {
        let store = try XCTUnwrap(library.activeStore)
        let (workspaceID, sessions) = try seed(store, flagged: [true, false])
        store.setSidebarMode(.flagged)
        GhosttyApp.shared.setFlaggedViewLayout(.tree)
        buildSidebar(for: store)
        XCTAssertNil(rowIndex { $0.kind == .session && $0.id == sessions[1].id }, "the unflagged session must be hidden")

        try perform("Flag All Sessions", onWorkspace: workspaceID)

        XCTAssertEqual(sessions.map(\.flagged), [true, true])
    }

    func testBackgroundWindowMenuFlagsItsOwnStore() throws {
        let frontID = try XCTUnwrap(library.activeWindowID)
        let frontStore = try XCTUnwrap(library.activeStore)
        let backStore = try XCTUnwrap(library.loadStore(for: library.newWindow(name: "back").id))
        library.frontmostWindowID = frontID
        let (frontWorkspaceID, frontSessions) = try seed(frontStore, flagged: [false])
        let (backWorkspaceID, backSessions) = try seed(backStore, flagged: [false, false])
        XCTAssertNotEqual(frontWorkspaceID, backWorkspaceID)
        buildSidebar(for: backStore)

        try perform("Flag All Sessions", onWorkspace: backWorkspaceID)

        XCTAssertEqual(backSessions.map(\.flagged), [true, true])
        XCTAssertEqual(frontSessions.map(\.flagged), [false])
    }

    // MARK: - Helpers

    private func seed(_ store: AppStore, flagged: [Bool]) throws -> (UUID, [Session]) {
        let workspace = store.addWorkspace(name: "target")
        let sessions = try flagged.enumerated().map { index, isFlagged in
            let session = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp/s\(index)"))
            store.setFlag(isFlagged, forSession: session.id)
            return session
        }
        return (workspace.id, sessions)
    }

    private func perform(_ title: String, onWorkspace id: UUID) throws {
        let item = try menuItem(titled: title, onWorkspace: id)
        XCTAssertTrue(item.isEnabled)
        coordinator.perform(item.action, with: item)
    }

    private func menuItem(titled title: String, onWorkspace id: UUID) throws -> NSMenuItem {
        let row = try XCTUnwrap(rowIndex { $0.kind == .workspace && $0.id == id }, "no sidebar row for that workspace")
        let menu = try XCTUnwrap(coordinator.menu(forRow: row))
        return try XCTUnwrap(menu.items.first { $0.title == title }, "no '\(title)' item; menu had \(menu.items.map(\.title))")
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
