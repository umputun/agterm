import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for the row context menu's Copy Name item: which name each row kind resolves, and the
/// pasteboard contract — nothing to copy must leave the user's clipboard alone rather than clear it.
@MainActor
final class SidebarCopyNameTests: XCTestCase {
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
                .appendingPathComponent("agterm-copy-name-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            actions = AppActions(library: library)
            preservePasteboard()
        }
    }

    /// Restore the SYSTEM pasteboard's full prior contents after each test — the reasoning, and the
    /// deep-copy it requires, are documented on `ControlAPITestCase.seedPasteboard`. Not shared with it:
    /// that lives in the UI-test target. `addTeardownBlock` rather than `tearDown` so it also runs when an
    /// assertion fails.
    private func preservePasteboard() {
        let pasteboard = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        addTeardownBlock {
            let general = NSPasteboard.general
            general.clearContents()
            if !saved.isEmpty { general.writeObjects(saved) }
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

        try invokeCopyName(onRowFor: session.id)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "beta")
    }

    func testTheItemIsAbsentUnderAMultiSelection() throws {
        let store = try XCTUnwrap(library.activeStore)
        let ws = try XCTUnwrap(store.workspaces.first)
        let first = try XCTUnwrap(store.addSession(toWorkspace: ws.id, cwd: "/tmp/one"))
        let second = try XCTUnwrap(store.addSession(toWorkspace: ws.id, cwd: "/tmp/two"))
        store.selectSession(first.id)
        store.setSidebarSelection([first.id, second.id])
        buildSidebar(for: store)

        let row = try XCTUnwrap(rowIndex { $0.kind == .session && $0.id == first.id })
        let menu = try XCTUnwrap(coordinator.menu(forRow: row))
        // absence alone would also hold if the selection never formed, which is not what this pins.
        XCTAssertTrue(menu.items.contains { $0.title == "Close 2 Sessions" },
                      "the batch must have formed, or the absence below proves nothing")
        XCTAssertFalse(menu.items.contains { $0.title == "Copy Name" },
                       "single-target only, like Duplicate Session and Reveal in Finder")
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

        // set directly because renameWorkspace rejects blank; AppStore+PendingClose does not.
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
        // the menu must be built before the close, so the item is left holding a dead id.
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
        window.isReleasedWhenClosed = false // see SidebarStatusBlinkTests for why
        window.contentView = scroll

        coordinator.outlineView = outline
        coordinator.renameController.outlineView = outline
        coordinator.seedExpansionFromModel()
        coordinator.reconcile()
    }
}
