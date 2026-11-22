import agtermCore
import AppKit
import GhosttyKit
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

    private func fixture(fontSize: Float, wait: Bool = false, configure: (GhosttySurfaceView) -> Void) throws
        -> (settings: SettingsModel, view: GhosttySurfaceView) {
        let library = WindowLibrary(directory: stateDir)
        let settings = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory()))
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), fontSize: fontSize, command: "/bin/cat",
                                      waitAfterCommand: wait)
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

    // a fast command in a held zmx pane drew libghostty's "failed to launch" banner
    func testAZmxPaneHeldAfterItsCommandKeepsAZeroAbnormalExitRuntimeAcrossAReload() throws {
        let fix = try paneFixture(backedByZmx: true, wait: true)
        XCTAssertEqual(abnormalExitRuntime(fix.view), 0)
        XCTAssertEqual(waitsAfterCommand(fix.view), true)
        let created = fix.view.ownedConfigs.last

        fix.settings.reloadGhosttyConfig()

        XCTAssertNotEqual(fix.view.ownedConfigs.last, created)
        XCTAssertEqual(abnormalExitRuntime(fix.view), 0)
        XCTAssertEqual(waitsAfterCommand(fix.view), true)
    }

    // a per-surface config replaced the surface's wait_after_command, so a background set mid-run lost the hold
    func testAWaitPaneKeepsItsHoldThroughABackgroundAndAReload() throws {
        let fix = try paneFixture(backedByZmx: false, wait: true)
        fix.view.session?.backgroundWatermark = BackgroundWatermark(kind: .color, colorHex: "#203040")

        fix.view.applyWatermarkFromSession()
        XCTAssertEqual(waitsAfterCommand(fix.view), true)
        let colored = fix.view.ownedConfigs.last
        fix.settings.reloadGhosttyConfig()

        XCTAssertNotEqual(fix.view.ownedConfigs.last, colored)
        XCTAssertEqual(waitsAfterCommand(fix.view), true)
        XCTAssertNotEqual(abnormalExitRuntime(fix.view), 0)
    }

    func testAColoredWaitOverlayKeepsItsHoldAcrossAReload() throws {
        let fix = try fixture(fontSize: 9, wait: true) { $0.overlayBackgroundColorHex = "#202020" }
        XCTAssertEqual(waitsAfterCommand(fix.view), true)
        let created = fix.view.ownedConfigs.last

        fix.settings.reloadGhosttyConfig()

        XCTAssertNotEqual(fix.view.ownedConfigs.last, created)
        XCTAssertEqual(waitsAfterCommand(fix.view), true)
    }

    func testAPlainWaitOverlayKeepsItsHoldAcrossAReload() throws {
        let fix = try fixture(fontSize: 9, wait: true) { _ in }
        let created = fix.view.ownedConfigs.last

        fix.settings.reloadGhosttyConfig()

        XCTAssertNotEqual(fix.view.ownedConfigs.last, created)
        XCTAssertEqual(waitsAfterCommand(fix.view), true)
    }

    func testAPaneNotHeldOrNotBackedByZmxKeepsTheDefaultAbnormalExitRuntime() throws {
        for (zmx, wait) in [(true, false), (false, true), (false, false)] {
            let fix = try paneFixture(backedByZmx: zmx, wait: wait)
            fix.settings.reloadGhosttyConfig()
            XCTAssertNotEqual(abnormalExitRuntime(fix.view), 0, "backedByZmx \(zmx), wait \(wait)")
        }
    }

    private func paneFixture(backedByZmx: Bool, wait: Bool) throws -> (settings: SettingsModel, view: GhosttySurfaceView) {
        let library = WindowLibrary(directory: stateDir)
        let settings = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory()))
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), command: "/bin/cat", waitAfterCommand: wait,
                                      backedByZmx: backedByZmx)
        view.session = session
        session.surface = view
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 320), styleMask: [],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        addTeardownBlock { window.orderOut(nil) }
        XCTAssertTrue(view.isRealized)
        return (settings, view)
    }

    /// waitsAfterCommand reads the hold from the view's per-surface config, nil when it has none.
    private func waitsAfterCommand(_ view: GhosttySurfaceView) -> Bool? {
        guard let config = view.ownedConfigs.last else { return nil }
        var value = false
        let key = "wait-after-command"
        let read = key.withCString { ghostty_config_get(config, &value, $0, UInt(key.utf8.count)) }
        return read ? value : nil
    }

    /// abnormalExitRuntime reads the threshold from the view's per-surface config, nil when it has none.
    private func abnormalExitRuntime(_ view: GhosttySurfaceView) -> UInt32? {
        guard let config = view.ownedConfigs.last else { return nil }
        var value: UInt32 = 0
        let key = "abnormal-command-exit-runtime"
        let read = key.withCString { ghostty_config_get(config, &value, $0, UInt(key.utf8.count)) }
        return read ? value : nil
    }
}
