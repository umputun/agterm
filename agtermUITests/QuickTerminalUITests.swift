import XCTest

/// End-to-end test for the floating quick terminal. The panel is a Metal `GhosttySurfaceView`
/// with no readable accessibility text, so this uses the terminal as the oracle: the quick
/// terminal's shell has a distinct `tty` from the main session's, so typing `tty > file` in
/// each records which shell received the keystrokes. That verifies the toolbar button opens a
/// separate, focused shell on top.
@MainActor
final class QuickTerminalUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stateDir: URL!
    private var markerDir: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-uitest-\(UUID().uuidString)", isDirectory: true)
        markerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-qt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: markerDir, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchEnvironment["AGTERM_STATE_DIR"] = stateDir.path
        app.launchForUITest()
    }

    override func tearDown() async throws {
        app?.terminate()
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
        if let markerDir { try? FileManager.default.removeItem(at: markerDir) }
    }

    func testQuickTerminalOpensSeparateFocusedShell() throws {
        let row = app.staticTexts["session-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "seeded session should exist")
        row.click()
        usleep(800_000)

        // the main session's shell.
        let mainTTY = ttyAfterCommand(named: "main")
        XCTAssertNotNil(mainTTY, "main shell should write its tty (terminal must be focused)")

        // open the quick terminal — focus should move to its (separate) shell on top.
        let button = app.buttons["quick-terminal-toggle"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "quick-terminal toolbar button should exist")
        button.click()
        usleep(900_000)
        let quickTTY = ttyAfterCommand(named: "quick")
        XCTAssertNotNil(quickTTY, "quick terminal should write its tty (its panel must be focused)")
        XCTAssertNotEqual(mainTTY, quickTTY, "the quick terminal is a separate shell from the main session")
    }

    func testCloseSessionShortcutHidesQuickTerminalInsteadOfClosingSession() throws {
        let row = app.staticTexts["session-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "seeded session should exist")
        row.click()
        usleep(800_000)

        // focus the main session and record its tty.
        let mainTTY = ttyAfterCommand(named: "main")
        XCTAssertNotNil(mainTTY, "main shell should write its tty (terminal must be focused)")

        // open the quick terminal — a separate shell on top of the session.
        let button = app.buttons["quick-terminal-toggle"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "quick-terminal toolbar button should exist")
        button.click()
        usleep(900_000)
        let quickTTY = ttyAfterCommand(named: "quick")
        XCTAssertNotNil(quickTTY, "quick terminal should be focused")
        XCTAssertNotEqual(mainTTY, quickTTY, "the quick terminal is a separate shell from the main session")

        // ⌘W with the quick terminal up must DISMISS it, NOT close the session underneath.
        app.typeKey("w", modifierFlags: .command)
        usleep(900_000)

        // the session survives (the bug closed the session behind the quick terminal instead).
        XCTAssertTrue(app.staticTexts["session-row"].exists, "⌘W must not close the session behind the quick terminal")
        XCTAssertEqual(app.staticTexts.matching(identifier: "session-row").count, 1, "no session should be closed")

        // focus returned to the original session (the quick terminal hid), so its tty matches the main shell.
        let afterTTY = ttyAfterCommand(named: "after")
        XCTAssertEqual(afterTTY, mainTTY, "⌘W hid the quick terminal and refocused the session")
    }

    /// Types `tty > <markerDir>/<name>` into the focused terminal and returns the tty the
    /// shell wrote (trimmed), or nil if nothing was written within the timeout.
    private func ttyAfterCommand(named name: String) -> String? {
        let file = markerDir.appendingPathComponent(name)
        app.typeText("tty > '\(file.path)'")
        app.typeKey(.return, modifierFlags: [])
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let contents = try? String(contentsOf: file, encoding: .utf8) {
                let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            usleep(150_000)
        }
        return nil
    }
}
