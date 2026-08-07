import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for the row context menu's Copy Name item. The parts that can go wrong are all in the
/// app target: which object the item carries, the plural title, and the pasteboard contract — an empty
/// result must leave the user's clipboard alone rather than clearing it to write nothing.
@MainActor
final class SidebarCopyNameTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!
    private var window: NSWindow!
    private var outline: SidebarOutlineView!
    private var coordinator: WorkspaceSidebar.Coordinator!
    private var savedPasteboard: String?

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-copy-name-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            actions = AppActions(library: library)
            savedPasteboard = NSPasteboard.general.string(forType: .string)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            if let savedPasteboard {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(savedPasteboard, forType: .string)
            }
            savedPasteboard = nil
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

    func testSingleSessionCopiesItsDisplayName() throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        store.renameSession(session.id, to: "🌱 feature-branch")
        buildSidebar(for: store)

        try invokeCopyName(onRowFor: session.id)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "🌱 feature-branch")
    }

    func testUnrenamedSessionCopiesTheDerivedNameNotAnEmptyCustomName() throws {
        let store = try XCTUnwrap(library.activeStore)
        let ws = try XCTUnwrap(store.workspaces.first)
        let session = try XCTUnwrap(store.addSession(toWorkspace: ws.id, cwd: "/tmp/beta"))
        buildSidebar(for: store)

        // the trap: customName is nil here, so copying it would put "" on the clipboard.
        try invokeCopyName(onRowFor: session.id)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "beta")
    }

    func testMultiSelectionIsPluralAndNewlineJoinedInSidebarOrder() throws {
        let store = try XCTUnwrap(library.activeStore)
        let ws = try XCTUnwrap(store.workspaces.first)
        let first = try XCTUnwrap(store.addSession(toWorkspace: ws.id, cwd: "/tmp/one"))
        let second = try XCTUnwrap(store.addSession(toWorkspace: ws.id, cwd: "/tmp/two"))
        store.selectSession(first.id)
        store.setSidebarSelection([first.id, second.id])
        buildSidebar(for: store)

        let item = try menuItem(titled: "Copy Names", onRowFor: first.id)
        coordinator.perform(item.action, with: item)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "one\ntwo")
    }

    func testWorkspaceRowCopiesTheWorkspaceName() throws {
        let store = try XCTUnwrap(library.activeStore)
        let ws = try XCTUnwrap(store.workspaces.first)
        store.renameWorkspace(ws.id, to: "Zumino")
        buildSidebar(for: store)

        let item = try menuItem(titled: "Copy Name", onWorkspaceRowFor: ws.id)
        coordinator.perform(item.action, with: item)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Zumino")
    }

    func testABlankWorkspaceNameLeavesTheClipboardAlone() throws {
        let store = try XCTUnwrap(library.activeStore)
        let ws = try XCTUnwrap(store.workspaces.first)
        buildSidebar(for: store)
        let item = try menuItem(titled: "Copy Name", onWorkspaceRowFor: ws.id)

        // renameWorkspace rejects blank, so reach past it — AppStore+PendingClose rebuilds a Workspace
        // from a snapshot with no such guard, which is how a blank name survives a restart.
        var blanked = store.workspaces[0]
        blanked.name = "   "
        store.workspaces[0] = blanked

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("keep me", forType: .string)
        coordinator.perform(item.action, with: item)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "keep me",
                       "a blank name must not clear the clipboard to write an empty string")
    }

    func testAVanishedSessionLeavesTheClipboardAlone() throws {
        let store = try XCTUnwrap(library.activeStore)
        let ws = try XCTUnwrap(store.workspaces.first)
        let doomed = try XCTUnwrap(store.addSession(toWorkspace: ws.id, cwd: "/tmp/doomed"))
        buildSidebar(for: store)
        // the menu is built while the row exists, then the row closes before the choice is made — the
        // item goes on holding the id, which is the state this guards.
        let item = try menuItem(titled: "Copy Name", onRowFor: doomed.id)
        store.closeSession(doomed.id)

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("keep me", forType: .string)
        coordinator.perform(item.action, with: item)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "keep me")
    }

    // MARK: - Helpers

    private func invokeCopyName(onRowFor sessionID: UUID) throws {
        let item = try menuItem(titled: "Copy Name", onRowFor: sessionID)
        coordinator.perform(item.action, with: item)
    }

    private func menuItem(titled title: String, onRowFor sessionID: UUID) throws -> NSMenuItem {
        let row = try XCTUnwrap(rowIndex { $0.kind == .session && $0.id == sessionID },
                                "no sidebar row for that session")
        let menu = try XCTUnwrap(coordinator.menu(forRow: row))
        return try XCTUnwrap(menu.items.first { $0.title == title },
                             "no '\(title)' item; menu had \(menu.items.map(\.title))")
    }

    private func menuItem(titled title: String, onWorkspaceRowFor workspaceID: UUID) throws -> NSMenuItem {
        let row = try XCTUnwrap(rowIndex { $0.kind == .workspace && $0.id == workspaceID },
                                "no sidebar row for that workspace")
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
        window.isReleasedWhenClosed = false
        window.contentView = scroll

        coordinator.outlineView = outline
        coordinator.renameController.outlineView = outline
        coordinator.seedExpansionFromModel()
        coordinator.reconcile()
    }
}
