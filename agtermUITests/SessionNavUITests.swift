import XCTest

/// End-to-end test for keyboard navigation between sessions (⌥⌘↑ previous, ⌥⌘↓ next — ⌥⌘ avoids the
/// text-field caret shadowing bare ⌘+arrows would cause; First/Last have no hotkey, covered by the
/// agtermCore unit tests). Sessions are Metal `GhosttySurfaceView`s with no readable accessibility
/// text, so this uses the terminal itself as the oracle: each session's shell has a distinct `tty`,
/// so typing `tty > file` in the focused session records which shell received the keystrokes. That
/// proves keyboard focus follows the selection as prev/next step between sessions.
@MainActor
final class SessionNavUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stateDir: URL!
    private var markerDir: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-uitest-\(UUID().uuidString)", isDirectory: true)
        markerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-sessionnav-\(UUID().uuidString)", isDirectory: true)
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

    func testSessionNavigationFollowsFocus() throws {
        let firstRow = app.staticTexts["session-row"]
        XCTAssertTrue(firstRow.waitForExistence(timeout: 20), "seeded session should exist")
        // the row click bounces first responder into the surface, which the tty oracle needs.
        firstRow.click()
        usleep(800_000)
        let firstTTY = ttyAfterCommand(named: "first")
        XCTAssertNotNil(firstTTY, "first session shell should write its tty (terminal must be focused)")

        let add = app.descendants(matching: .any).matching(identifier: "add-session").firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5), "bottom-bar add-session menu should exist")
        add.click()
        let newItem = presentedMenuItem("New Session")
        XCTAssertTrue(newItem.waitForExistence(timeout: 5), "New Session menu item should appear")
        newItem.click()

        // the menu interaction can leave focus off the surface, so a row click re-establishes it.
        let rows = app.staticTexts.matching(identifier: "session-row")
        XCTAssertTrue(waitForCount(rows, 2, timeout: 8), "a second session row should appear")
        let secondRow = rows.element(boundBy: 1)
        secondRow.click()
        usleep(800_000)
        let secondTTY = ttyAfterCommand(named: "second")
        XCTAssertNotNil(secondTTY, "second session shell should write its tty")
        XCTAssertNotEqual(secondTTY, firstTTY, "the second session is a separate shell")

        app.typeKey(.upArrow, modifierFlags: [.command, .option])
        usleep(500_000)
        XCTAssertEqual(ttyAfterCommand(named: "prev"), firstTTY, "Opt+Cmd+Up selects the previous session")

        app.typeKey(.downArrow, modifierFlags: [.command, .option])
        usleep(500_000)
        XCTAssertEqual(ttyAfterCommand(named: "next"), secondTTY, "Opt+Cmd+Down selects the next session")
    }

    /// Polls until a query resolves to `expected` matching elements.
    private func waitForCount(_ query: XCUIElementQuery, _ expected: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if query.count == expected { return true }
            usleep(150_000)
        }
        return false
    }

    /// Finds the presented (hittable) menu item by title. The menu-bar copy of the same title is not
    /// hittable while closed, so filter for the popup/context one.
    private func presentedMenuItem(_ title: String, timeout: TimeInterval = 5) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let matches = app.menuItems.matching(identifier: title).allElementsBoundByIndex
            if let hit = matches.first(where: { $0.exists && $0.isHittable }) { return hit }
            usleep(150_000)
        }
        return app.menuItems[title].firstMatch
    }

    /// Types `tty > <markerDir>/<name>` into the focused session and returns the tty the shell wrote
    /// (trimmed), or nil if nothing was written within the timeout.
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
