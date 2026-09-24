import agtermCore
import AppKit
import XCTest
@testable import agterm

@MainActor
final class GhosttySurfaceViewConfigTests: XCTestCase {
    private var stateDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-surface-config-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    private func fixture(fontSize: Float, configure: (GhosttySurfaceView) -> Void) throws
        -> (settings: SettingsModel, view: GhosttySurfaceView) {
        let library = WindowLibrary(directory: stateDir)
        let settings = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory()))
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), fontSize: fontSize, command: "/bin/cat")
        configure(view)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 320), styleMask: [],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        addTeardownBlock { window.orderOut(nil) }
        session.overlaySurface = view
        XCTAssertTrue(view.isRealized)
        return (settings, view)
    }

    func testTheBackgroundPaneFollowsTheViewsRoleAndPicksItsOverride() {
        let session = Session(initialCwd: "/tmp")
        session.backgroundWatermark = BackgroundWatermark(kind: .color, colorHex: "#201414")
        session.paneBackgrounds.right = BackgroundWatermark(kind: .text, text: "PEER")
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), fontSize: 12, command: "/bin/cat")
        XCTAssertNil(view.effectiveWatermark)

        view.session = session
        XCTAssertEqual(view.backgroundPane, .left)
        XCTAssertEqual(view.effectiveWatermark, session.backgroundWatermark)
        view.setPaneRole(.split)
        XCTAssertEqual(view.backgroundPane, .right)
        XCTAssertEqual(view.effectiveWatermark, session.paneBackgrounds.right)

        view.session = nil
        view.watermarkSession = session
        XCTAssertEqual(view.backgroundPane, .scratch)
        XCTAssertEqual(view.effectiveWatermark, session.backgroundWatermark)
    }

    // a config reload reset a hud to the default font while its measurement kept the creation size.
    func testAConfigReloadKeepsAHudsCreationFontSize() throws {
        let fix = try fixture(fontSize: 9) { $0.hudBodyFile = "/tmp/agterm-hud-config-\(UUID().uuidString)" }

        fix.settings.reloadGhosttyConfig()

        XCTAssertEqual(try XCTUnwrap(fix.view.currentFontSize()), 9, accuracy: 0.01)
    }

    func testAConfigReloadKeepsAColoredHudsCreationFontSize() throws {
        let fix = try fixture(fontSize: 9) {
            $0.hudBodyFile = "/tmp/agterm-hud-config-\(UUID().uuidString)"
            $0.overlayBackgroundColorHex = "#202020"
        }

        XCTAssertEqual(try XCTUnwrap(fix.view.currentFontSize()), 9, accuracy: 0.01)
        fix.settings.reloadGhosttyConfig()

        XCTAssertEqual(try XCTUnwrap(fix.view.currentFontSize()), 9, accuracy: 0.01)
    }

    func testAConfigReloadLeavesAProgramOverlayOnTheSharedFont() throws {
        let fix = try fixture(fontSize: 9) { _ in }

        fix.settings.reloadGhosttyConfig()

        XCTAssertNotEqual(try XCTUnwrap(fix.view.currentFontSize()), 9, accuracy: 0.01)
    }
}
