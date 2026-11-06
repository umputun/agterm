import AppKit
import SwiftUI
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class SidebarInfoRowTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!
    private var window: NSWindow!
    private var outline: SidebarOutlineView!
    private var coordinator: WorkspaceSidebar.Coordinator!
    private var server: ControlServer?
    private var savedDisplay = SessionInfoDisplay.always

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-sidebar-info-tests-\(UUID().uuidString)", isDirectory: true)
        library = WindowLibrary(directory: stateDir)
        actions = AppActions(library: library)
        savedDisplay = GhosttyApp.shared.sessionInfoDisplay
        GhosttyApp.shared.setSessionInfoDisplay(.always)
    }

    override func tearDown() async throws {
        GhosttyApp.shared.setSessionInfoDisplay(savedDisplay)
        server?.stop()
        server = nil
        window?.orderOut(nil)
        window = nil
        outline = nil
        coordinator = nil
        actions = nil
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    func testARowGrowsWithInfoAndReturnsToPlainHeightOnClear() throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try seed(store)
        buildSidebar(for: store)
        XCTAssertEqual(try height(of: session.id), plainHeight)

        store.setInfo(try info("3 agents"), forSession: session.id)
        coordinator.reconcile()
        XCTAssertEqual(try height(of: session.id), infoHeight)

        store.setInfo(nil, forSession: session.id)
        coordinator.reconcile()
        XCTAssertEqual(try height(of: session.id), plainHeight)
    }

    func testOffDrawsNoLineButKeepsItAndItsTimer() throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try seed(store)
        store.setInfo(try SessionInfo.make(source: "3 agents", markdown: false, hideAfter: 30).get(), forSession: session.id)
        buildSidebar(for: store)
        XCTAssertEqual(try height(of: session.id), infoHeight)

        GhosttyApp.shared.setSessionInfoDisplay(.off)
        coordinator.reconcile()

        XCTAssertEqual(try height(of: session.id), plainHeight)
        XCTAssertEqual(session.info?.source, "3 agents")
        XCTAssertEqual(session.info?.hideAfter, 30)
    }

    func testFlaggedViewOnlyHidesTheLineInTheTreeAndShowsItInTheFlaggedView() throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try seed(store)
        store.setFlag(true, forSession: session.id)
        store.setInfo(try info("3 agents"), forSession: session.id)
        GhosttyApp.shared.setSessionInfoDisplay(.flagged)
        buildSidebar(for: store)
        XCTAssertEqual(try height(of: session.id), plainHeight)

        store.setSidebarMode(.flagged)
        coordinator.reconcile()
        XCTAssertEqual(try height(of: session.id), infoHeight)

        store.setSidebarMode(.tree)
        coordinator.reconcile()
        XCTAssertEqual(try height(of: session.id), plainHeight)
    }

    func testChangingTheDisplaySettingRedrawsThroughTheAppearanceBroadcast() throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try seed(store)
        store.setInfo(try info("3 agents"), forSession: session.id)
        buildSidebar(for: store)
        XCTAssertEqual(try height(of: session.id), infoHeight)

        GhosttyApp.shared.setSessionInfoDisplay(.off)
        NotificationCenter.default.post(name: .agtermAppearanceChanged, object: nil)

        XCTAssertEqual(try height(of: session.id), plainHeight)
    }

    func testASelectedRowKeepsColoredFragmentsAndFollowsTheSelectionForegroundElsewhere() throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try seed(store)
        store.setInfo(try info("^[ok](color: \"green\") plain", markdown: true), forSession: session.id)
        buildSidebar(for: store)
        let cell = try infoCell(forSession: session.id)

        cell.setColors(selected: true)

        let text = cell.infoField.attributedStringValue
        XCTAssertEqual(rgba(color(in: text, at: 0)), rgba(NSColor.tint(.green)))
        XCTAssertEqual(rgba(color(in: text, at: text.length - 1)),
                       rgba(cell.themeTextColor(selected: true).withAlphaComponent(0.85)))
    }

    func testARowTintNeverReachesTheInfoLine() throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try seed(store)
        store.setTint(SidebarTint(color: .orange, parts: [.icon, .name]), forSession: session.id)
        store.setInfo(try info("plain"), forSession: session.id)
        buildSidebar(for: store)
        let cell = try infoCell(forSession: session.id)

        for selected in [false, true] {
            cell.setColors(selected: selected)
            let expected = cell.themeTextColor(selected: selected).withAlphaComponent(selected ? 0.85 : 0.62)
            XCTAssertEqual(rgba(color(in: cell.infoField.attributedStringValue, at: 0)), rgba(expected), "selected: \(selected)")
            XCTAssertEqual(rgba(cell.textField?.textColor), rgba(NSColor.tint(.orange)), "the name keeps its tint")
        }
    }

    func testASessionInfoCommandRefreshesTheMountedSidebar() async throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try seed(store)
        let server = ControlServer(
            library: library, actions: actions,
            settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
            identity: AppIdentity(version: "9.9.9"), socketPath: "/tmp/agterm-info-row-\(UUID().uuidString.prefix(8)).sock")
        self.server = server
        try mountSidebar(for: store)
        let dispatcher = ControlDispatcher(actions: server)

        let set = await dispatcher.dispatch(ControlRequest(cmd: .sessionInfo, target: session.id.uuidString,
                                                           args: ControlArgs(text: "**3** agents", mode: "set", markdown: true)))
        XCTAssertEqual(set?.ok, true, set?.error ?? "")
        try await waitUntil { (try? self.height(of: session.id)) == self.infoHeight }
        XCTAssertEqual(try height(of: session.id), infoHeight)
        XCTAssertEqual(try infoCell(forSession: session.id).infoField.stringValue, "3 agents")

        let cleared = await dispatcher.dispatch(ControlRequest(cmd: .sessionInfo, target: session.id.uuidString,
                                                               args: ControlArgs(mode: "clear")))
        XCTAssertEqual(cleared?.ok, true, cleared?.error ?? "")
        try await waitUntil { (try? self.height(of: session.id)) == self.plainHeight }
        XCTAssertEqual(try height(of: session.id), plainHeight)
    }

    // regression: a line cleared while another row was being renamed stayed on screen after the rename ended
    func testAnInfoChangeDuringARenameCatchesUpWhenTheRenameEnds() async throws {
        let store = try XCTUnwrap(library.activeStore)
        let renamed = try seed(store)
        let other = try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.workspaces.last).id, cwd: "/tmp/other"))
        store.setInfo(try info("running"), forSession: other.id)
        try mountSidebar(for: store)
        try await waitUntil { (try? self.height(of: other.id)) == self.infoHeight }
        let coordinator = try XCTUnwrap(outline.delegate as? WorkspaceSidebar.Coordinator)
        let node = try XCTUnwrap(outline.item(atRow: try row(of: renamed.id)) as? SidebarNode)
        coordinator.renameController.beginEditing(node: node)
        let cell = try XCTUnwrap(outline.view(atColumn: 0, row: try row(of: renamed.id), makeIfNecessary: true) as? NSTableCellView)
        let field = try XCTUnwrap(cell.textField)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)

        store.setInfo(nil, forSession: other.id)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(try height(of: other.id), infoHeight)

        XCTAssertTrue(coordinator.renameController.control(field, textView: editor,
                                                           doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        try await waitUntil { (try? self.height(of: other.id)) == self.plainHeight }
        XCTAssertEqual(try height(of: other.id), plainHeight)
        XCTAssertFalse(coordinator.renameController.isEditing)
    }

    private var plainHeight: CGFloat { AppSettings.sidebarRowHeight(fontSize: GhosttyApp.shared.sidebarFontSize) }
    private var infoHeight: CGFloat {
        SidebarInfoMetrics.rowHeight(base: GhosttyApp.shared.sidebarFontSize, density: GhosttyApp.shared.sidebarDensity)
    }

    private func info(_ source: String, markdown: Bool = false) throws -> SessionInfo {
        try SessionInfo.make(source: source, markdown: markdown, hideAfter: 0).get()
    }

    private func seed(_ store: AppStore) throws -> Session {
        let workspace = store.addWorkspace(name: "target")
        return try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp/info"))
    }

    private func row(of id: UUID) throws -> Int {
        try XCTUnwrap((0..<outline.numberOfRows).first { row in
            (outline.item(atRow: row) as? SidebarNode).map { $0.kind == .session && $0.id == id } ?? false
        })
    }

    private func height(of id: UUID) throws -> CGFloat {
        outline.rect(ofRow: try row(of: id)).height
    }

    private func infoCell(forSession id: UUID) throws -> SidebarInfoCellView {
        try XCTUnwrap(outline.view(atColumn: 0, row: try row(of: id), makeIfNecessary: true) as? SidebarInfoCellView)
    }

    private func color(in text: NSAttributedString, at index: Int) -> NSColor? {
        text.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    private func rgba(_ color: NSColor?) -> [CGFloat] {
        guard let rgb = color?.usingColorSpace(.sRGB) else { return [] }
        return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent].map { ($0 * 1000).rounded() / 1000 }
    }

    private func mountSidebar(for store: AppStore) throws {
        let host = NSHostingView(rootView: WorkspaceSidebar(store: store, actions: actions).frame(width: 240, height: 400))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        outline = try XCTUnwrap(outlineView(in: host))
    }

    private func outlineView(in view: NSView) -> SidebarOutlineView? {
        if let outline = view as? SidebarOutlineView { return outline }
        return view.subviews.lazy.compactMap { self.outlineView(in: $0) }.first
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
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
