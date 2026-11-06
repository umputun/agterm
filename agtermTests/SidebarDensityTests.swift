import AppKit
import SwiftUI
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class SidebarDensityTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!
    private var window: NSWindow!
    private var outline: SidebarOutlineView!
    private var savedDisplay = SessionInfoDisplay.always

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-sidebar-density-tests-\(UUID().uuidString)", isDirectory: true)
        library = WindowLibrary(directory: stateDir)
        actions = AppActions(library: library)
        savedDisplay = GhosttyApp.shared.sessionInfoDisplay
        GhosttyApp.shared.setSessionInfoDisplay(.always)
        GhosttyApp.shared.setSidebarDensity(.standard)
    }

    override func tearDown() async throws {
        GhosttyApp.shared.setSidebarDensity(.standard)
        GhosttyApp.shared.setSessionInfoDisplay(savedDisplay)
        window?.orderOut(nil)
        window = nil
        outline = nil
        actions = nil
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    func testSwitchingDensityOnAMountedSidebarReappliesEveryMetricBothWays() throws {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = store.addWorkspace(name: "target")
        let plain = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp/plain"))
        let infoRow = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp/info"))
        store.setInfo(try SessionInfo.make(source: "3 agents", markdown: false, hideAfter: 0).get(), forSession: infoRow.id)
        try mountSidebar(for: store)
        try assertMetrics(.standard, plain: plain.id, info: infoRow.id)

        switchDensity(to: .compact)
        try assertMetrics(.compact, plain: plain.id, info: infoRow.id)

        switchDensity(to: .standard)
        try assertMetrics(.standard, plain: plain.id, info: infoRow.id)
    }

    func testCompactRowsAreShorterThanDefaultAtEveryFontBound() {
        for size in [AppSettings.sidebarFontSizeRange.lowerBound, AppSettings.defaultSidebarFontSize,
                     AppSettings.sidebarFontSizeRange.upperBound] {
            XCTAssertEqual(AppSettings.sidebarRowHeight(fontSize: size, density: .standard)
                - AppSettings.sidebarRowHeight(fontSize: size, density: .compact), 5, "font \(size)")
            XCTAssertGreaterThanOrEqual(AppSettings.sidebarRowHeight(fontSize: size, density: .compact)
                - 2 * SidebarDensity.compact.selectionInset, 16, "font \(size): the 16pt row icon must fit the pill")
        }
    }

    private func switchDensity(to density: SidebarDensity) {
        GhosttyApp.shared.setSidebarDensity(density)
        NotificationCenter.default.post(name: .agtermAppearanceChanged, object: nil)
        outline.layoutSubtreeIfNeeded()
    }

    private func assertMetrics(_ density: SidebarDensity, plain: UUID, info: UUID,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let base = Double(GhosttyApp.shared.sidebarFontSize)
        let plainHeight = CGFloat(AppSettings.sidebarRowHeight(fontSize: base, density: density))
        XCTAssertEqual(outline.indentationPerLevel, CGFloat(density.indentPerLevel), "indent", file: file, line: line)
        XCTAssertEqual(outline.rect(ofRow: try row(of: plain)).height, plainHeight, "plain row", file: file, line: line)
        XCTAssertEqual(outline.rect(ofRow: try row(of: info)).height,
                       SidebarInfoMetrics.rowHeight(base: base, density: density), "info row", file: file, line: line)

        let plainCell = try XCTUnwrap(outline.view(atColumn: 0, row: try row(of: plain), makeIfNecessary: true) as? SidebarCellView)
        XCTAssertEqual(plainCell.titleCenter?.constant, CGFloat(-density.titleLift), "plain title lift", file: file, line: line)
        let infoCell = try XCTUnwrap(outline.view(atColumn: 0, row: try row(of: info), makeIfNecessary: true) as? SidebarInfoCellView)
        XCTAssertEqual(infoCell.titleCenter?.constant, CGFloat(-density.titleLift), "info title lift", file: file, line: line)
        XCTAssertEqual(infoCell.infoTop?.constant, CGFloat(-density.infoLineSpacing), "info line spacing", file: file, line: line)
        XCTAssertEqual(infoCell.titleBandHeight?.constant, plainHeight, "info title band", file: file, line: line)
    }

    private func row(of id: UUID) throws -> Int {
        try XCTUnwrap((0..<outline.numberOfRows).first { row in
            (outline.item(atRow: row) as? SidebarNode).map { $0.kind == .session && $0.id == id } ?? false
        })
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
}
