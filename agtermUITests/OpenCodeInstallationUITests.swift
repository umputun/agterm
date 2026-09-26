import XCTest

@MainActor
final class OpenCodeInstallationUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stateDir: URL!
    private var home: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        let fm = FileManager.default
        stateDir = fm.temporaryDirectory.appendingPathComponent("opencode-ui-\(UUID().uuidString)")
        home = stateDir.appendingPathComponent("opencode-home")
        try fm.createDirectory(at: home.appendingPathComponent(".config/opencode"), withIntermediateDirectories: true)
        let host = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("OpenCodeInstallerTestHost.app")
        XCTAssertTrue(fm.fileExists(atPath: host.path), "installer test host should be built beside the UI runner")
        app = XCUIApplication(url: host)
        app.launchEnvironment["AGTERM_STATE_DIR"] = stateDir.path
    }

    override func tearDown() async throws {
        app?.terminate()
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
    }

    func testUnknownVersionInstallsV1() throws {
        try assertFallbackInstalls(button: "OpenCode v1", plugin: "agterm-status.js",
                                   marker: "// agterm-opencode-status-plugin", other: "agterm-v2/tui.js")
    }

    func testUnknownVersionInstallsV2() throws {
        try assertFallbackInstalls(button: "OpenCode v2", plugin: "agterm-v2/tui.js",
                                   marker: "// agterm-opencode-v2-status-plugin", other: "agterm-status.js")
    }

    func testSkipUnknownVersionDoesNotInstallPlugin() throws {
        openInstaller()
        let skip = app.dialogs.buttons["Skip OpenCode"]
        XCTAssertTrue(skip.waitForExistence(timeout: 10))
        skip.click()
        dismissResult(containing: "status plugin was skipped")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/opencode/plugins").path))
        assertOtherIntegrationsUntouched()
    }

    func testDetectedVersionInstallsWithoutSelection() throws {
        app.launchEnvironment["AGTERM_UITEST_OPENCODE_VERSION"] = "opencode v2.0.12"
        openInstaller()
        dismissResult(containing: "OpenCode v2 status plugin installed")
        XCTAssertFalse(app.dialogs.buttons["Skip OpenCode"].exists)
        let plugin = home.appendingPathComponent(".config/opencode/plugins/agterm-v2/tui.js")
        XCTAssertTrue(try String(contentsOf: plugin, encoding: .utf8).hasPrefix("// agterm-opencode-v2-status-plugin"))
        assertOtherIntegrationsUntouched()
    }

    private func openInstaller() {
        app.launchForUITest()
        XCTAssertTrue(app.windows["OpenCode installer UI test"].waitForExistence(timeout: 10))
        app.menuBars.menuBarItems["Help"].click()
        let install = app.menuItems["Install Agent Status Hooks…"]
        XCTAssertTrue(install.waitForExistence(timeout: 5))
        install.click()
    }

    private func assertFallbackInstalls(button: String, plugin: String, marker: String, other: String) throws {
        openInstaller()
        let choice = app.dialogs.buttons[button]
        XCTAssertTrue(choice.waitForExistence(timeout: 10))
        choice.click()
        dismissResult(containing: "\(button) status plugin installed")
        let installed = home.appendingPathComponent(".config/opencode/plugins/" + plugin)
        XCTAssertTrue(try String(contentsOf: installed, encoding: .utf8).hasPrefix(marker))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/opencode/plugins/" + other).path))
        assertOtherIntegrationsUntouched()
    }

    private func dismissResult(containing text: String) {
        let result = app.dialogs.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        app.dialogs.buttons["OK"].click()
    }

    private func assertOtherIntegrationsUntouched() {
        for path in [".claude", ".codex", ".pi", ".zshrc", ".bashrc", ".config/agterm"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(path).path), path)
        }
    }
}
