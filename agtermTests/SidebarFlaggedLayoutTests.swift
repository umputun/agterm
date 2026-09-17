import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class SidebarFlaggedLayoutTests: XCTestCase {
    /// Counts full reloads, the only outward sign of a rebuild: node identity and expansion survive one.
    private final class CountingOutlineView: NSOutlineView {
        var reloads = 0

        override func reloadData() {
            reloads += 1
            super.reloadData()
        }
    }

    @MainActor
    private struct Sidebar {
        let window: NSWindow
        let outline: CountingOutlineView
        let coordinator: WorkspaceSidebar.Coordinator

        /// What `updateNSView` does on every observed store change.
        func update() {
            coordinator.reconcile()
            coordinator.syncSelection()
        }

        func badge(ofWorkspace id: UUID) -> Int? {
            let row = (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarNode)?.id == id }
            return row.flatMap { outline.view(atColumn: 0, row: $0, makeIfNecessary: true) as? SidebarCellView }?.badge.count
        }

        var rows: [String] {
            (0..<outline.numberOfRows).map { row in
                let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCellView
                let kind = (outline.item(atRow: row) as? SidebarNode)?.kind == .workspace ? "ws" : "s"
                return "\(kind):\(cell?.textField?.stringValue ?? "")"
            }
        }
    }

    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!
    private var model: SettingsModel!
    private var sidebars: [Sidebar] = []

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-flagged-layout-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            actions = AppActions(library: library)
            model = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            for sidebar in sidebars { sidebar.window.orderOut(nil) }
            sidebars = []
            GhosttyApp.shared.setFlaggedViewLayout(.flat)
            model = nil
            actions = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    func testTreeLayoutNestsFlaggedSessionsUnderTheirWorkspaces() throws {
        let store = try seededStore()
        store.setSidebarMode(.flagged)
        model.setFlaggedViewLayout(.tree)

        let sidebar = mount(store)

        XCTAssertEqual(sidebar.rows, ["ws:Alpha", "s:a1", "ws:Gamma", "s:c1"])
    }

    func testFlatLayoutKeepsTheWorkspaceSuffix() throws {
        let store = try seededStore()
        store.setSidebarMode(.flagged)

        let sidebar = mount(store)

        XCTAssertEqual(sidebar.rows, ["s:a1 : Alpha", "s:c1 : Gamma"])
    }

    func testTreeLayoutIgnoresTheFocusFilter() throws {
        let store = try seededStore()
        let beta = try XCTUnwrap(store.workspaces.first { $0.name == "Beta" })
        store.setFocusMembership(beta.id, member: true)
        store.setFocusEnabled(true)
        store.setSidebarMode(.flagged)
        model.setFlaggedViewLayout(.tree)

        let sidebar = mount(store)

        XCTAssertEqual(sidebar.rows, ["ws:Alpha", "s:a1", "ws:Gamma", "s:c1"])
    }

    func testLayoutChangeRebuildsAMountedFlaggedSidebar() throws {
        let store = try seededStore()
        store.setSidebarMode(.flagged)
        let sidebar = mount(store)

        model.setFlaggedViewLayout(.tree)

        XCTAssertEqual(sidebar.rows, ["ws:Alpha", "s:a1", "ws:Gamma", "s:c1"])

        model.setFlaggedViewLayout(.flat)

        XCTAssertEqual(sidebar.rows, ["s:a1 : Alpha", "s:c1 : Gamma"])
    }

    func testLayoutChangeLeavesAnOrdinaryTreeSidebarAlone() throws {
        let store = try seededStore()
        let sidebar = mount(store)
        let reloads = sidebar.outline.reloads

        model.setFlaggedViewLayout(.tree)

        XCTAssertEqual(sidebar.outline.reloads, reloads)
    }

    func testEnteringFlaggedModeReadsALayoutSetUnderTheOrdinaryTree() throws {
        let store = try seededStore()
        let sidebar = mount(store)
        model.setFlaggedViewLayout(.tree)

        store.setSidebarMode(.flagged)
        sidebar.update()

        XCTAssertEqual(sidebar.rows, ["ws:Alpha", "s:a1", "ws:Gamma", "s:c1"])
    }

    func testGroupLeavesWithItsLastFlagAndReturnsWhenReflagged() throws {
        let store = try seededStore()
        let c1 = try XCTUnwrap(store.flaggedSessions.last)
        store.setSidebarMode(.flagged)
        model.setFlaggedViewLayout(.tree)
        let sidebar = mount(store)

        store.setFlag(false, forSession: c1.id)
        sidebar.update()

        XCTAssertEqual(sidebar.rows, ["ws:Alpha", "s:a1"])

        store.setFlag(true, forSession: c1.id)
        sidebar.update()

        XCTAssertEqual(sidebar.rows, ["ws:Alpha", "s:a1", "ws:Gamma", "s:c1"])
    }

    func testTreeLayoutHeaderBadgeCountsOnlyFlaggedChildren() throws {
        let store = try seededStore()
        let alpha = try XCTUnwrap(store.workspaces.first)
        alpha.sessions[0].unseenCount = 2
        alpha.sessions[1].unseenCount = 5
        store.setSidebarMode(.flagged)
        model.setFlaggedViewLayout(.tree)

        let sidebar = mount(store)

        XCTAssertEqual(sidebar.badge(ofWorkspace: alpha.id), 2)
    }

    func testOrdinaryTreeHeaderBadgeStillCountsEverySession() throws {
        let store = try seededStore()
        let alpha = try XCTUnwrap(store.workspaces.first)
        alpha.sessions[0].unseenCount = 2
        alpha.sessions[1].unseenCount = 5
        model.setFlaggedViewLayout(.tree)

        let sidebar = mount(store)

        XCTAssertEqual(sidebar.badge(ofWorkspace: alpha.id), 7)
    }

    func testFlagFlipUpdatesTheTreeLayoutHeaderBadge() throws {
        let store = try seededStore()
        let alpha = try XCTUnwrap(store.workspaces.first)
        alpha.sessions[0].unseenCount = 2
        alpha.sessions[1].unseenCount = 5
        store.setSidebarMode(.flagged)
        model.setFlaggedViewLayout(.tree)
        let sidebar = mount(store)

        store.setFlag(true, forSession: alpha.sessions[1].id)
        sidebar.update()

        XCTAssertEqual(sidebar.badge(ofWorkspace: alpha.id), 7)
    }

    func testUnseenChangeUpdatesTheTreeLayoutHeaderBadgeWithoutARebuild() throws {
        let store = try seededStore()
        let alpha = try XCTUnwrap(store.workspaces.first)
        store.setSidebarMode(.flagged)
        model.setFlaggedViewLayout(.tree)
        let sidebar = mount(store)
        let reloads = sidebar.outline.reloads

        alpha.sessions[0].unseenCount = 3
        alpha.sessions[1].unseenCount = 9
        sidebar.update()

        XCTAssertEqual(sidebar.badge(ofWorkspace: alpha.id), 3)
        XCTAssertEqual(sidebar.outline.reloads, reloads)
    }

    /// Alpha [a1 flagged, a2], Beta [b1], Gamma [c1 flagged], with a1 selected.
    private func seededStore() throws -> AppStore {
        let store = try XCTUnwrap(library.activeStore)
        let alpha = try XCTUnwrap(store.workspaces.first)
        store.renameWorkspace(alpha.id, to: "Alpha")
        let a1 = try XCTUnwrap(alpha.sessions.first)
        store.renameSession(a1.id, to: "a1")
        let a2 = try XCTUnwrap(store.addSession(toWorkspace: alpha.id, cwd: "/tmp"))
        store.renameSession(a2.id, to: "a2")
        let beta = store.addWorkspace(name: "Beta")
        let b1 = try XCTUnwrap(store.addSession(toWorkspace: beta.id, cwd: "/tmp"))
        store.renameSession(b1.id, to: "b1")
        let gamma = store.addWorkspace(name: "Gamma")
        let c1 = try XCTUnwrap(store.addSession(toWorkspace: gamma.id, cwd: "/tmp"))
        store.renameSession(c1.id, to: "c1")
        store.setFlag(true, forSession: a1.id)
        store.setFlag(true, forSession: c1.id)
        store.selectSession(a1.id)
        return store
    }

    /// Mounts a real outline + Coordinator with the same first-build sequence as `makeNSView`.
    private func mount(_ store: AppStore) -> Sidebar {
        let outline = CountingOutlineView()
        let coordinator = WorkspaceSidebar.Coordinator(store: store, actions: actions)
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false // see SidebarStatusBlinkTests for why
        window.contentView = scroll

        coordinator.outlineView = outline
        coordinator.renameController.outlineView = outline
        coordinator.seedExpansionFromModel()
        coordinator.rebuildAndReload()
        coordinator.syncSelection()
        let sidebar = Sidebar(window: window, outline: outline, coordinator: coordinator)
        sidebars.append(sidebar)
        return sidebar
    }
}
