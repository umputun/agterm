import AppKit
import SwiftUI
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for the OS-title child view: a session or window rename reaches `NSWindow.title` through
/// its own body, with the root view left in place.
@MainActor
final class WindowContentViewTitlebarTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var window: NSWindow!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-titlebar-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
            // over-releases a window the registry may still hold, crashing the host at autorelease-pool pop
            window.isReleasedWhenClosed = false
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            window?.close()
            window = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    func testTheWindowTitleFollowsSessionAndWindowRenames() throws {
        let windowID = try XCTUnwrap(library.activeWindowID)
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        window.contentView = NSHostingView(rootView: WindowTitleSync(store: store, library: library,
                                                                    windowID: windowID, captureOnExit: nil))
        window.layoutIfNeeded()
        try waitForTitle(session.displayName)

        session.oscTitle = "spin 1"
        try waitForTitle("spin 1")

        store.renameSession(session.id, to: "api")
        try waitForTitle("api")

        library.renameWindow(windowID, to: "work")
        try waitForTitle("api — work")
    }

    private func waitForTitle(_ expected: String) throws {
        let deadline = Date().addingTimeInterval(2)
        while window.title != expected, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(window.title, expected)
    }

    func testRemoteTitlebarRendersAtNarrowAndWideWidths() throws {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        store.sidebarVisible = false
        for mode in [ToolbarMode.normal, .compact] {
            for width in [640.0, 1100.0] {
                for host in ["dev", "builder@very-long-host.internal.example.com"] {
                    let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: "/repo",
                                                                name: "build", remoteHost: host))
                    XCTAssertTrue(store.setContext("PR #517 " + String(repeating: "context ", count: 20), forSession: session.id))
                    let windowID = try XCTUnwrap(library.activeWindowID)
                    library.renameWindow(windowID, to: "work")
                    let visible = try renderTitlebar(mode: mode, width: width)
                    let hidden = try renderTitlebar(mode: mode, width: width, hidden: [.remoteHost])
                    let scale = Int(window.backingScaleFactor)
                    XCTAssertEqual(visible.pixelsWide, Int(width) * scale)
                    XCTAssertEqual(visible.pixelsHigh, (mode == .normal ? 48 : 30) * scale)
                    XCTAssertGreaterThan(differentPixels(visible, hidden, from: 110 * scale, to: (Int(width) - 270) * scale), 20)
                    let buttonsWidth = mode == .normal ? 250 : 225
                    XCTAssertEqual(differentPixels(visible, hidden, from: (Int(width) - buttonsWidth) * scale,
                                                   to: Int(width) * scale), 0)
                    attach(visible, name: "remote-\(mode.rawValue)-\(Int(width))-\(host == "dev" ? "short" : "long")")
                }
            }
        }
    }

    func testLongRemoteIdentityKeepsButtonsInPlaceWithSidebarVisible() throws {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        store.sidebarVisible = true
        store.sidebarWidth = 220
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: "/repo",
                                                    name: "a very long session name for the remote build",
                                                    remoteHost: "builder@very-long-host.internal.example.com"))
        XCTAssertTrue(store.setContext("PR #517 " + String(repeating: "context ", count: 20), forSession: session.id))
        for mode in [ToolbarMode.normal, .compact] {
            let visible = try renderTitlebar(mode: mode, width: 640)
            let hidden = try renderTitlebar(mode: mode, width: 640, hidden: [.remoteHost])
            let scale = Int(window.backingScaleFactor)
            let buttonsWidth = mode == .normal ? 250 : 225
            XCTAssertEqual(differentPixels(visible, hidden, from: (640 - buttonsWidth) * scale, to: 640 * scale), 0)
            attach(visible, name: "remote-\(mode.rawValue)-640-sidebar-long-identity")
        }
    }

    func testRemoteCloudSplitWeightRemainsVisibleAtSidebarSize() throws {
        let store = try XCTUnwrap(library.activeStore)
        let coordinator = WorkspaceSidebar.Coordinator(store: store, actions: AppActions(library: library))
        let regular = try renderCloud(XCTUnwrap(coordinator.remoteSessionIcon))
        let bold = try renderCloud(XCTUnwrap(coordinator.remoteSplitSessionIcon))
        XCTAssertGreaterThan(differentPixels(regular, bold, from: 0, to: 16), 15)
        attach(regular, name: "remote-cloud-sidebar-regular")
        attach(bold, name: "remote-cloud-sidebar-bold")
    }

    private func renderTitlebar(mode: ToolbarMode, width: Double,
                                hidden: Set<InterfaceElement> = []) throws -> NSBitmapImageRep {
        let store = try XCTUnwrap(library.activeStore)
        let content = WindowContentView(
            windowID: try XCTUnwrap(library.activeWindowID), store: store, library: library,
            makeSurface: { _ in fatalError("titlebar must not create surfaces") },
            makeSplitSurface: { _ in fatalError("titlebar must not create surfaces") },
            makeOverlaySurface: { _, _ in fatalError("titlebar must not create surfaces") },
            makeScratchSurface: { _ in fatalError("titlebar must not create surfaces") },
            captureOnExit: nil, actions: AppActions(library: library), palette: PaletteController(),
            sessionSwitcher: SessionSwitcher(library: library, canSwitch: { false }),
            toolbarMode: mode, chromeText: .black, attentionButtonEnabled: true, hiddenInterfaceElements: hidden
        )
        let view = content.customTitlebar.frame(width: width).background(.white).environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: view)
        window.setContentSize(NSSize(width: width, height: mode == .normal ? 48 : 30))
        window.contentView = host
        window.orderFront(nil)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func renderCloud(_ image: NSImage) throws -> NSBitmapImageRep {
        let view = Image(nsImage: image).frame(width: 16, height: 16).foregroundStyle(.black).background(.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let rendered = try XCTUnwrap(renderer.nsImage)
        return try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(rendered.tiffRepresentation)))
    }

    private func differentPixels(_ first: NSBitmapImageRep, _ second: NSBitmapImageRep,
                                 from start: Int, to end: Int) -> Int {
        (start..<end).reduce(0) { count, x in
            count + (0..<first.pixelsHigh).filter { y in
                first.colorAt(x: x, y: y) != second.colorAt(x: x, y: y)
            }.count
        }
    }

    private func attach(_ bitmap: NSBitmapImageRep, name: String) {
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
