import AppKit
import XCTest
@testable import agterm
import agtermCore

/// The transient dashboard font override is swept per-window over that window's OWN store, so a session
/// that leaves before the sweep runs would keep the grid font forever in its new window.
@MainActor
final class AdoptedSurfaceRebindTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var window: NSWindow!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-adopt-rebind-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            window.orderOut(nil)
            window = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    /// Both surfaces stay at their zero init frame, so `viewDidMoveToWindow` parks in
    /// `pendingSurfaceCreation` instead of spawning a libghostty surface and a shell.
    private func makeSurface() -> GhosttySurfaceView {
        let surface = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        window.contentView?.addSubview(surface)
        return surface
    }

    func testRebindClearsTheDashboardFontOverrideOnBothPanes() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        let main = makeSurface()
        let split = makeSurface()
        split.isSplitPane = true
        session.surface = main
        session.splitSurface = split
        main.dashboardFontOverride = 9
        split.dashboardFontOverride = 9

        agtermApp.rebindSurfaces(of: session, to: store, library: library)

        XCTAssertNil(main.dashboardFontOverride)
        XCTAssertNil(split.dashboardFontOverride)
    }
}
