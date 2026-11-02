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
    private var savedHiddenElements: Set<InterfaceElement> = []

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-row-views-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            actions = AppActions(library: library)
            savedHiddenElements = GhosttyApp.shared.hiddenInterfaceElements
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            GhosttyApp.shared.setHiddenInterfaceElements(savedHiddenElements)
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

    func testATitleTickRefreshesTheTooltipOnTheLiveCell() throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        buildSidebar(for: store)
        let cell = try renderedCell(forSession: session.id)
        let long = "PROJ-123 enforce the storage quota on the plan endpoint before the billing cutover"

        for (title, expected) in [("api", nil), (long, long), ("api", nil)] {
            session.oscTitle = title
            coordinator.reconcile()
            cell.layoutSubtreeIfNeeded()
            XCTAssertTrue(try renderedCell(forSession: session.id) === cell, "a title tick must keep the cell")
            XCTAssertEqual(cell.textField?.stringValue, title)
            XCTAssertEqual(cell.textField?.toolTip, expected, "the relabel must schedule the layout pass that owns the tooltip")
        }
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

    func testAFlaggedRemoteRowKeepsTheUnsplitWeight() throws {
        let store = try XCTUnwrap(library.activeStore)
        let remote = try XCTUnwrap(store.addSession(toWorkspace: store.workspaces[0].id, cwd: "/a", remoteHost: "buildbox"))
        remote.flagged = true
        buildSidebar(for: store)

        XCTAssertEqual(try renderedIcon(forSession: remote.id), coordinator.remoteSessionIcon,
                       "on a remote row the weight carries split, so flagging must not claim it")
    }

    func testHiddenSessionIconsGiveTheSlotToTheNameAndLeaveWorkspaceIcons() throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        GhosttyApp.shared.setHiddenInterfaceElements([.sessionIcons])
        buildSidebar(for: store)

        let cell = try renderedCell(forSession: session.id)
        cell.layoutSubtreeIfNeeded()
        let icon = try XCTUnwrap(cell.imageView)
        XCTAssertTrue(icon.isHidden)
        XCTAssertEqual(icon.frame.width, 0)
        let field = try XCTUnwrap(cell.textField)
        XCTAssertEqual(field.alignmentRect(forFrame: field.frame).minX, icon.frame.minX)
        XCTAssertEqual(try renderedWorkspaceCell(store.workspaces[0].id).imageView?.isHidden, false)
    }

    func testHiddenWorkspaceIconsLeaveSessionIcons() throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        GhosttyApp.shared.setHiddenInterfaceElements([.workspaceIcons])
        buildSidebar(for: store)

        XCTAssertEqual(try renderedWorkspaceCell(store.workspaces[0].id).imageView?.isHidden, true)
        XCTAssertEqual(try renderedCell(forSession: session.id).imageView?.isHidden, false)
    }

    func testAnAppearanceChangeReGatesTheOnScreenRowsBothWays() throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        buildSidebar(for: store)
        let cell = try renderedCell(forSession: session.id)
        let shownMinX = try renderedNameField(forSession: session.id).frame.minX

        GhosttyApp.shared.setHiddenInterfaceElements([.sessionIcons])
        NotificationCenter.default.post(name: .agtermAppearanceChanged, object: nil)
        XCTAssertTrue(try renderedCell(forSession: session.id) === cell, "the re-gate must reach the live cell")
        XCTAssertEqual(cell.imageView?.isHidden, true)
        XCTAssertLessThan(try renderedNameField(forSession: session.id).frame.minX, shownMinX)

        GhosttyApp.shared.setHiddenInterfaceElements([])
        NotificationCenter.default.post(name: .agtermAppearanceChanged, object: nil)
        XCTAssertEqual(cell.imageView?.isHidden, false)
        XCTAssertEqual(try renderedNameField(forSession: session.id).frame.minX, shownMinX)
    }

    func testADisconnectedNoticeMovesToTheNameWhileTheIconIsHidden() throws {
        let store = try XCTUnwrap(library.activeStore)
        let remote = try XCTUnwrap(store.addSession(toWorkspace: store.workspaces[0].id, cwd: "/a", remoteHost: "buildbox"))
        store.bindRemote(RemoteBinding(remoteSessionID: "s1", daemonsByLocalPane: [:], presentationVersion: 1),
                         forSession: remote.id)
        store.setRemoteConnection(.failed("exit 255"), forSession: remote.id)
        let notice = try XCTUnwrap(RemotePresentationConnection.failed("exit 255").rowNotice(host: "buildbox"))
        buildSidebar(for: store)
        store.renameSession(remote.id, to: "api")
        coordinator.reconcile()

        XCTAssertEqual(try renderedCell(forSession: remote.id).imageView?.toolTip, notice)
        XCTAssertNil(try renderedNameField(forSession: remote.id).toolTip)

        GhosttyApp.shared.setHiddenInterfaceElements([.sessionIcons])
        NotificationCenter.default.post(name: .agtermAppearanceChanged, object: nil)
        XCTAssertNil(try renderedCell(forSession: remote.id).imageView?.toolTip)
        XCTAssertEqual(try renderedNameField(forSession: remote.id).toolTip, notice)

        store.setRemoteConnection(.connected, forSession: remote.id)
        coordinator.reconcile()
        XCTAssertNil(try renderedNameField(forSession: remote.id).toolTip, "a reconnect must clear the notice")
    }

    func testFlaggedRenameRestoresTheLabelAfterAnUnchangedCustomName() async throws {
        try await checkFlaggedRename(customName: "api", edited: "api", expected: "api")
    }

    func testFlaggedRenameRestoresTheLabelAfterAcceptingTheAutomaticName() async throws {
        try await checkFlaggedRename(customName: nil, edited: "automatic", expected: "automatic")
    }

    func testFlaggedRenameRendersTheNormalizedCommittedName() async throws {
        try await checkFlaggedRename(customName: "api", edited: "  worker  ", expected: "worker")
    }

    func testFlaggedRenameCancellationRestoresTheLabel() async throws {
        try await checkFlaggedRename(customName: "api", edited: "discarded", expected: "api", cancelled: true)
    }

    func testRejectedBlankWorkspaceRenameRestoresTheLabel() async throws {
        let store = try XCTUnwrap(library.activeStore)
        buildSidebar(for: store)
        let workspace = store.workspaces[0]
        let node = try XCTUnwrap(coordinator.workspaceNode(forID: workspace.id))
        let field = try beginRename(node)
        field.stringValue = "   "
        try endRename(field)
        await drainRenameCallback()
        let row = outline.row(forItem: node)
        let cell = try XCTUnwrap(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)
        XCTAssertEqual(cell.textField?.stringValue, workspace.name)
        XCTAssertEqual(store.workspaces[0].name, workspace.name)
    }

    func testRenameCallbackDoesNotReloadAnEditStartedBeforeItRuns() async throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        buildSidebar(for: store)
        let node = try sessionNode(session.id)
        let field = try beginRename(node)
        try endRename(field)
        let nextField = try beginRename(node)
        nextField.stringValue = "unfinished"
        await drainRenameCallback()
        XCTAssertTrue(coordinator.renameController.isEditing)
        XCTAssertTrue(try renderedNameField(forSession: session.id) === nextField)
        XCTAssertEqual(nextField.stringValue, "unfinished")
        try endRename(nextField, cancelled: true)
        await drainRenameCallback()
    }

    private func checkFlaggedRename(customName: String?, edited: String, expected: String, cancelled: Bool = false) async throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        session.oscTitle = "automatic"
        session.customName = customName
        session.flagged = true
        store.sidebarMode = .flagged
        let other = try XCTUnwrap(store.addSession(toWorkspace: store.workspaces[0].id, cwd: "/other"))
        other.flagged = true
        buildSidebar(for: store)
        let field = try beginRename(sessionNode(session.id))
        XCTAssertEqual(field.stringValue, customName ?? "automatic")
        field.stringValue = edited
        try endRename(field, cancelled: cancelled)
        store.selectSession(other.id)
        await drainRenameCallback()
        let restored = try renderedNameField(forSession: session.id)
        XCTAssertEqual(restored.stringValue, "\(expected) : \(store.workspaces[0].name)")
        XCTAssertEqual(session.customName, expected)
        XCTAssertFalse(restored.isEditable)
        XCTAssertEqual(restored.accessibilityIdentifier(), "session-row")
    }

    private func sessionNode(_ id: UUID) throws -> SidebarNode {
        try XCTUnwrap((0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? SidebarNode }
            .first { $0.kind == .session && $0.id == id })
    }

    private func beginRename(_ node: SidebarNode) throws -> NSTextField {
        coordinator.renameController.beginEditing(node: node)
        let cell = try XCTUnwrap(outline.view(atColumn: 0, row: outline.row(forItem: node), makeIfNecessary: true) as? NSTableCellView)
        return try XCTUnwrap(cell.textField)
    }

    private func endRename(_ field: NSTextField, cancelled: Bool = false) throws {
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.string = field.stringValue
        if cancelled {
            XCTAssertTrue(coordinator.renameController.control(field, textView: editor,
                doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        } else {
            XCTAssertTrue(field.window?.makeFirstResponder(nil) == true)
        }
    }

    private func drainRenameCallback() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
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
        let cell = try renderedCell(forSession: id)
        cell.layoutSubtreeIfNeeded()
        return try XCTUnwrap(cell.textField)
    }

    private func renderedCell(forSession id: UUID) throws -> SidebarCellView {
        outline.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap((0..<outline.numberOfRows).first { index in
            guard let node = outline.item(atRow: index) as? SidebarNode else { return false }
            return node.kind == .session && node.id == id
        }, "the session row should be visible in the outline")
        return try XCTUnwrap(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCellView)
    }

    private func renderedWorkspaceCell(_ id: UUID) throws -> SidebarCellView {
        outline.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap((0..<outline.numberOfRows).first { index in
            guard let node = outline.item(atRow: index) as? SidebarNode else { return false }
            return node.kind == .workspace && node.id == id
        }, "the workspace row should be visible in the outline")
        return try XCTUnwrap(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCellView)
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
