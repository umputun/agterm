import XCTest

/// The first-launch welcome alert. Every UI test launches on a fresh isolated state directory, so the
/// alert is suppressed under XCUITest unless `AGTERM_UITEST_SHOW_WELCOME` opts back in, which is what
/// this class does.
@MainActor
final class WelcomeUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stateDir: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-uitest-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        app?.terminate()
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
    }

    private func launch(showWelcome: Bool) {
        app = XCUIApplication()
        app.launchEnvironment["AGTERM_STATE_DIR"] = stateDir.path
        if showWelcome { app.launchEnvironment["AGTERM_UITEST_SHOW_WELCOME"] = "1" }
        app.launchForUITest()
    }

    func testWelcomeShowsOnFirstLaunchAndNotOnTheNextOne() throws {
        launch(showWelcome: true)
        let later = app.buttons["welcome-later"]
        XCTAssertTrue(later.waitForExistence(timeout: 20), "first launch should show the welcome alert")
        let skill = app.checkBoxes["welcome-skill-checkbox"]
        let hooks = app.checkBoxes["welcome-hooks-checkbox"]
        XCTAssertTrue(skill.exists, "the skill option should be offered")
        XCTAssertTrue(hooks.exists, "the status hooks option should be offered")
        XCTAssertEqual(skill.value as? Int, 1, "the skill option should start checked")
        XCTAssertEqual(hooks.value as? Int, 1, "the status hooks option should start checked")
        // Later, never Install: clicking Install here would really install into the running user's config
        later.click()
        XCTAssertTrue(app.staticTexts["session-row"].waitForExistence(timeout: 20),
                      "dismissing the welcome should leave a usable window")
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 20), "app should quit before the relaunch")

        launch(showWelcome: true)
        XCTAssertTrue(app.staticTexts["session-row"].waitForExistence(timeout: 20), "relaunch should reach the window")
        XCTAssertFalse(app.buttons["welcome-later"].exists, "the welcome must not return on a later launch")
    }

    func testWelcomeIsSuppressedForOrdinaryUITestLaunches() throws {
        launch(showWelcome: false)
        XCTAssertTrue(app.staticTexts["session-row"].waitForExistence(timeout: 20), "launch should reach the window")
        XCTAssertFalse(app.buttons["welcome-later"].exists, "a UI test launch without the opt-in must see no alert")
    }
}
