import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for the sidebar row's name tooltip: it appears only while the label is too narrow to
/// show the whole name, and clears again once the name fits.
@MainActor
final class SidebarRowViewsTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!
    private var window: NSWindow!
    private var scroll: NSScrollView!
    private var outline: SidebarOutlineView!
    private var coordinator: WorkspaceSidebar.Coordinator!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-row-views-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            actions = AppActions(library: library)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            window?.orderOut(nil)
            window = nil
            scroll = nil
            outline = nil
            coordinator = nil
            actions = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    func testATruncatedNameGetsTheFullNameAsItsTooltip() throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        buildSidebar(for: store)

        let name = "PROJ-123 enforce the storage quota on the plan endpoint before the billing cutover"
        store.renameSession(session.id, to: name)
        coordinator.reconcile()

        let field = try renderedNameField(forSession: session.id)
        XCTAssertEqual(field.toolTip, name,
                       "a name the row cannot show needs a hover reveal; the label truncates with no other way to read it")
    }

    func testANameThatFitsGetsNoTooltip() throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        buildSidebar(for: store)

        store.renameSession(session.id, to: "api")
        coordinator.reconcile()

        let field = try renderedNameField(forSession: session.id)
        XCTAssertNil(field.toolTip, "a fully visible name needs no tooltip; repeating it on hover is noise")
    }

    func testWideningTheRowClearsAToolTipItNoLongerNeeds() throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        buildSidebar(for: store)

        store.renameSession(session.id, to: "PROJ-123 enforce the storage quota on the plan endpoint")
        coordinator.reconcile()
        let narrow = try renderedNameField(forSession: session.id)
        XCTAssertNotNil(narrow.toolTip, "the narrow sidebar should truncate this name")
        let narrowWidth = narrow.bounds.width

        setSidebarWidth(CGFloat(AppStore.sidebarWidthMax))

        let field = try renderedNameField(forSession: session.id)
        XCTAssertGreaterThan(field.bounds.width, narrowWidth,
                             "the row must widen here, or the tooltip assertion below proves nothing")
        XCTAssertNil(field.toolTip, "dragging the divider wider must re-evaluate, or a stale tooltip lingers")
    }

    func testARemoteSessionRowGetsItsOwnIcon() throws {
        let store = try XCTUnwrap(library.activeStore)
        let local = try XCTUnwrap(store.activeSession)
        let remote = try XCTUnwrap(store.addSession(toWorkspace: store.workspaces[0].id, cwd: "/a", remoteHost: "buildbox"))
        buildSidebar(for: store)

        let remoteIcon = try renderedIcon(forSession: remote.id)
        let localIcon = try renderedIcon(forSession: local.id)

        XCTAssertEqual(remoteIcon, coordinator.remoteSessionIcon)
        XCTAssertNotEqual(remoteIcon, localIcon, "a teleported row must be tellable from a local one at a glance")
    }

    func testARemoteRowStillShowsAHiddenSplit() throws {
        let store = try XCTUnwrap(library.activeStore)
        let remote = try XCTUnwrap(store.addSession(toWorkspace: store.workspaces[0].id, cwd: "/a", remoteHost: "buildbox"))
        store.toggleSplit(remote.id)
        store.toggleSplit(remote.id)
        buildSidebar(for: store)

        XCTAssertTrue(remote.hasSplit, "the pane is alive but hidden; the row is the only place this shows")
        XCTAssertEqual(try renderedIcon(forSession: remote.id), coordinator.remoteSplitSessionIcon)
    }

    func testAFlaggedRemoteRowKeepsTheUnsplitGlyph() throws {
        let store = try XCTUnwrap(library.activeStore)
        let remote = try XCTUnwrap(store.addSession(toWorkspace: store.workspaces[0].id, cwd: "/a", remoteHost: "buildbox"))
        remote.flagged = true
        buildSidebar(for: store)

        XCTAssertEqual(try renderedIcon(forSession: remote.id), coordinator.remoteSessionIcon,
                       "on a remote row the fill carries split, so flagging must not claim it")
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

        scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: Self.narrowSidebar, height: 400))
        scroll.documentView = outline
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.narrowSidebar, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
        // over-releases a window the registry may still hold, crashing the host at autorelease-pool pop
        window.isReleasedWhenClosed = false
        window.contentView = scroll

        coordinator.outlineView = outline
        coordinator.renameController.outlineView = outline
        coordinator.seedExpansionFromModel()
        coordinator.reconcile()
        setSidebarWidth(Self.narrowSidebar)
    }

    /// Both widths these tests use must stay inside the divider's own 160...560 range, or a truncation
    /// threshold that no drag can actually clear would still pass here.
    private static let narrowSidebar: CGFloat = 240

    /// Drives the width the way a divider drag does: the column tracks the outline, and the row views retile
    /// off that. Without it the column keeps its default width and every row measures the same regardless of
    /// the window, which makes a truncation assertion pass for the wrong reason.
    private func setSidebarWidth(_ width: CGFloat) {
        window.setContentSize(NSSize(width: width, height: 400))
        scroll.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        outline.frame = NSRect(x: 0, y: 0, width: width, height: outline.frame.height)
        outline.sizeLastColumnToFit()
        outline.layoutSubtreeIfNeeded()
    }

    private func renderedNameField(forSession id: UUID) throws -> NSTextField {
        outline.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap((0..<outline.numberOfRows).first { index in
            guard let node = outline.item(atRow: index) as? SidebarNode else { return false }
            return node.kind == .session && node.id == id
        }, "the session row should be visible in the outline")
        let cell = try XCTUnwrap(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCellView)
        cell.layoutSubtreeIfNeeded()
        return try XCTUnwrap(cell.textField)
    }

    private func renderedIcon(forSession id: UUID) throws -> NSImage? {
        outline.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap((0..<outline.numberOfRows).first { index in
            guard let node = outline.item(atRow: index) as? SidebarNode else { return false }
            return node.kind == .session && node.id == id
        }, "the session row should be visible in the outline")
        let cell = try XCTUnwrap(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCellView)
        return cell.imageView?.image
    }
}
