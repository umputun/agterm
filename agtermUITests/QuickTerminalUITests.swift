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
        _ = try openQuickTerminalRecordingTTYs()
    }

    func testCloseSessionShortcutHidesQuickTerminalInsteadOfClosingSession() throws {
        let (mainTTY, _) = try openQuickTerminalRecordingTTYs()

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

    // ⌘W must dismiss the quick terminal even when the window has NO active session (the cover guard lives
    // in closeActiveSession, not the menu gate). Regression for the bug where the menu's old
    // `if activeSession != nil` gate fell through to performClose and closed the window with the cover up.
    func testCloseSessionShortcutWithNoSessionKeepsWindowAndDismissesQuickTerminal() throws {
        let row = app.staticTexts["session-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "seeded session should exist")
        row.click()
        usleep(500_000)

        // ⌘W with no cover closes the only session, emptying the window to zero sessions (no-cover fall-through).
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(row.waitForNonExistence(timeout: 10), "⌘W with no cover should close the only session")

        // open the quick terminal over the now session-less window; the cover element proves it is shown.
        let button = app.buttons["quick-terminal-toggle"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "quick-terminal toolbar button should exist")
        button.click()
        let cover = app.descendants(matching: .any).matching(identifier: "quick-terminal").firstMatch
        XCTAssertTrue(cover.waitForExistence(timeout: 5), "the quick terminal cover should be shown")

        // ⌘W must DISMISS the quick terminal (cover gone) and NOT close the (last) window (toolbar survives).
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(cover.waitForNonExistence(timeout: 10), "⌘W should dismiss the quick terminal cover")
        XCTAssertTrue(app.buttons["quick-terminal-toggle"].waitForExistence(timeout: 10),
                      "⌘W must not close the window when the quick terminal is the only cover and no session is active")
    }

    /// Selects the seeded session, records its tty, opens the quick terminal, records the quick terminal's
    /// tty, and asserts they are distinct shells (so the panel is a separate, focused shell on top). Returns
    /// (mainTTY, quickTTY).
    private func openQuickTerminalRecordingTTYs() throws -> (main: String, quick: String) {
        let row = app.staticTexts["session-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "seeded session should exist")
        row.click()
        usleep(800_000)

        let mainTTY = try XCTUnwrap(ttyAfterCommand(named: "main"),
                                    "main shell should write its tty (terminal must be focused)")

        let button = app.buttons["quick-terminal-toggle"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "quick-terminal toolbar button should exist")
        button.click()
        usleep(900_000)
        let quickTTY = try XCTUnwrap(ttyAfterCommand(named: "quick"),
                                     "quick terminal should write its tty (its panel must be focused)")
        XCTAssertNotEqual(mainTTY, quickTTY, "the quick terminal is a separate shell from the main session")
        return (mainTTY, quickTTY)
    }

    /// Types `tty > <markerDir>/<name>` into the focused terminal and returns the tty the shell wrote
    /// (trimmed), or nil if nothing was written within the timeout. Re-types each round: focus return after
    /// a cover hides is async (a bounded makeFirstResponder retry), so a single keystroke burst can land
    /// before the terminal is first responder and be dropped; re-typing `tty > file` is an idempotent overwrite.
    private func ttyAfterCommand(named name: String) -> String? {
        let file = markerDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: file)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            app.typeText("tty > '\(file.path)'")
            app.typeKey(.return, modifierFlags: [])
            let roundDeadline = Date().addingTimeInterval(1.0)
            while Date() < roundDeadline {
                if let contents = try? String(contentsOf: file, encoding: .utf8) {
                    let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
                usleep(100_000)
            }
        }
        return nil
    }
}
