import XCTest

/// End-to-end test for the one-level vertical split. The split panes are Metal
/// `GhosttySurfaceView`s with no readable accessibility text, so this uses the terminal
/// itself as the oracle: each pane's shell has a distinct `tty`, so typing `tty > file`
/// in the focused pane records which shell received the keystrokes. That verifies the
/// split opens a separate shell, that opening moves focus to the new right pane, that the
/// keyboard nav (⌘⌥←/→) moves focus between panes, and that closing keeps the focused pane.
@MainActor
final class SplitUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stateDir: URL!
    private var markerDir: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-uitest-\(UUID().uuidString)", isDirectory: true)
        markerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-split-\(UUID().uuidString)", isDirectory: true)
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

    func testSplitFocusKeyboardNavAndCollapse() throws {
        let row = app.staticTexts["session-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "seeded session should exist")
        // ensure the primary terminal holds focus before typing.
        row.click()
        usleep(800_000)

        // 1. record the primary shell's tty.
        let primaryTTY = ttyAfterCommand(named: "primary")
        XCTAssertNotNil(primaryTTY, "primary shell should write its tty (terminal must be focused)")

        // 2. open the split — focus MOVES to the new (right) pane, a separate shell.
        let splitButton = app.buttons["split-toggle"]
        XCTAssertTrue(splitButton.waitForExistence(timeout: 5), "split toolbar button should exist")
        splitButton.click()
        usleep(800_000)
        let rightTTY = ttyAfterCommand(named: "afteropen")
        XCTAssertNotNil(rightTTY, "right shell should write its tty")
        XCTAssertNotEqual(rightTTY, primaryTTY, "opening the split moves focus to the new (right) pane")

        // 3. Cmd+Opt+Left focuses the primary pane again.
        app.typeKey(.leftArrow, modifierFlags: [.command, .option])
        usleep(500_000)
        let leftTTY = ttyAfterCommand(named: "left")
        XCTAssertEqual(leftTTY, primaryTTY, "Cmd+Opt+Left focuses the primary shell")

        // 4. Cmd+Opt+Right focuses the right pane (the same separate shell) again.
        app.typeKey(.rightArrow, modifierFlags: [.command, .option])
        usleep(500_000)
        let rightAgainTTY = ttyAfterCommand(named: "right")
        XCTAssertEqual(rightAgainTTY, rightTTY, "Cmd+Opt+Right focuses the separate right shell")

        // 5. with focus on the right pane, close the split — the focused (right) pane is kept
        // maximized, its shell alive, not the primary.
        splitButton.click()
        usleep(800_000)
        let collapsedTTY = ttyAfterCommand(named: "collapsed")
        XCTAssertEqual(collapsedTTY, rightTTY, "closing the split keeps the focused (right) pane, not the primary")
    }

    // Ctrl-1 / Ctrl-2 focus the primary / split pane directly (a faster alias for ⌘⌥←/→). Verified
    // with the same tty oracle: the command lands in whichever pane the shortcut focused.
    func testCtrlNumberFocusesPaneDirectly() throws {
        let row = app.staticTexts["session-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "seeded session should exist")
        row.click()
        usleep(800_000)

        let primaryTTY = ttyAfterCommand(named: "primary")
        XCTAssertNotNil(primaryTTY, "primary shell should write its tty")

        // open the split — focus moves to the new (right) pane.
        let splitButton = app.buttons["split-toggle"]
        XCTAssertTrue(splitButton.waitForExistence(timeout: 5), "split toolbar button should exist")
        splitButton.click()
        usleep(800_000)
        let rightTTY = ttyAfterCommand(named: "right")
        XCTAssertNotNil(rightTTY, "right shell should write its tty")
        XCTAssertNotEqual(rightTTY, primaryTTY, "opening the split moves focus to the new (right) pane")

        // Ctrl-1 focuses the primary pane.
        app.typeKey("1", modifierFlags: .control)
        usleep(500_000)
        XCTAssertEqual(ttyAfterCommand(named: "ctrl1"), primaryTTY, "Ctrl-1 focuses the primary pane")

        // Ctrl-2 focuses the split (right) pane.
        app.typeKey("2", modifierFlags: .control)
        usleep(500_000)
        XCTAssertEqual(ttyAfterCommand(named: "ctrl2"), rightTTY, "Ctrl-2 focuses the split pane")
    }

    // Ctrl-1 / Ctrl-2 are reserved app shortcuts: in a non-split session they must be consumed (no-op),
    // never leaking a literal "1"/"2" into the shell. Verified by typing them, then running the tty
    // oracle on the SAME line — a leaked "1"/"2" would prefix the command ("12tty …"), so the command
    // fails and the marker file stays empty (ttyAfterCommand returns nil).
    func testCtrlNumberDoesNotLeakIntoNonSplitTerminal() throws {
        let row = app.staticTexts["session-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "seeded session should exist")
        row.click()
        usleep(800_000)

        app.typeKey("1", modifierFlags: .control)
        app.typeKey("2", modifierFlags: .control)
        usleep(300_000)
        XCTAssertNotNil(ttyAfterCommand(named: "nonsplit"),
                        "Ctrl-1/Ctrl-2 must not leak characters into a non-split shell")
    }

    // hiding the split (the toolbar toggle / ⌘D) keeps both shells alive, so re-showing must restore
    // the SAME panes — the re-parent that swaps the surface between the HSplitView and a standalone host
    // must never tear a surface down. Verified by tty identity across a full hide → show cycle: a
    // destroyed-and-recreated pane would report a different tty.
    func testSplitSurvivesHideShow() throws {
        let row = app.staticTexts["session-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "seeded session should exist")
        row.click()
        usleep(800_000)

        let splitButton = app.buttons["split-toggle"]
        XCTAssertTrue(splitButton.waitForExistence(timeout: 5), "split toolbar button should exist")

        // open the split and record the right pane's shell tty.
        splitButton.click()
        usleep(800_000)
        app.typeKey(.rightArrow, modifierFlags: [.command, .option])
        usleep(500_000)
        let rightTTY = ttyAfterCommand(named: "right-before")
        XCTAssertNotNil(rightTTY, "right shell should write its tty")

        // hide the split (keep-alive), then show it again.
        splitButton.click() // hide
        usleep(800_000)
        splitButton.click() // show
        usleep(800_000)

        // focus the right pane and re-record its tty — the same shell must have survived the cycle.
        app.typeKey(.rightArrow, modifierFlags: [.command, .option])
        usleep(500_000)
        let rightTTYAfter = ttyAfterCommand(named: "right-after")
        XCTAssertEqual(rightTTYAfter, rightTTY, "hiding then showing the split keeps the same right shell alive")
    }

    // pane navigation must keep working when the split is HIDDEN (maximized): with one pane shown,
    // ⌃1/⌃2 (and ⌘⌥←/→) swap WHICH pane is shown maximized — gated on hasSplit, not isSplit. Before
    // the fix these no-op'd while hidden. Verified with the tty oracle: after hiding, the focus
    // shortcut swaps which shell receives the keystrokes.
    func testHiddenSplitPaneNavigationSwapsShownPane() throws {
        let row = app.staticTexts["session-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "seeded session should exist")
        row.click()
        usleep(800_000)

        let primaryTTY = ttyAfterCommand(named: "primary")
        XCTAssertNotNil(primaryTTY, "primary shell should write its tty")

        // open the split — focus moves to the new (right) pane.
        let splitButton = app.buttons["split-toggle"]
        XCTAssertTrue(splitButton.waitForExistence(timeout: 5), "split toolbar button should exist")
        splitButton.click()
        usleep(800_000)
        let rightTTY = ttyAfterCommand(named: "right")
        XCTAssertNotNil(rightTTY, "right shell should write its tty")
        XCTAssertNotEqual(rightTTY, primaryTTY, "opening the split moves focus to the new (right) pane")

        // hide the split — the focused (right) pane stays shown maximized, both shells alive.
        splitButton.click()
        usleep(800_000)
        XCTAssertEqual(ttyAfterCommand(named: "hidden-right"), rightTTY, "the hidden split shows the focused (right) pane")

        // Ctrl-1 while hidden swaps the shown pane to the primary (the bug: it used to no-op when hidden).
        app.typeKey("1", modifierFlags: .control)
        usleep(800_000)
        XCTAssertEqual(ttyAfterCommand(named: "hidden-ctrl1"), primaryTTY,
                       "Ctrl-1 swaps the hidden split to the primary pane")

        // Ctrl-2 while hidden swaps the shown pane back to the right pane.
        app.typeKey("2", modifierFlags: .control)
        usleep(800_000)
        XCTAssertEqual(ttyAfterCommand(named: "hidden-ctrl2"), rightTTY,
                       "Ctrl-2 swaps the hidden split back to the right pane")
    }

    // exiting one pane of a split must keep the session alive (collapsed to the survivor) AND focus
    // the surviving pane, so typing reaches it without a click. Verified by exiting the primary, then
    // typing WITHOUT focusing and checking the command landed in the surviving right shell.
    func testExitPrimaryPaneKeepsSessionAndFocusesSurvivor() throws {
        let row = app.staticTexts["session-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "seeded session should exist")
        row.click()
        usleep(800_000)

        let splitButton = app.buttons["split-toggle"]
        XCTAssertTrue(splitButton.waitForExistence(timeout: 5), "split toolbar button should exist")

        // open the split, focus the right pane, record its tty (the survivor when the primary exits).
        splitButton.click()
        usleep(800_000)
        app.typeKey(.rightArrow, modifierFlags: [.command, .option])
        usleep(500_000)
        let rightTTY = ttyAfterCommand(named: "right")
        XCTAssertNotNil(rightTTY, "right shell should write its tty")

        // focus the primary (left) pane and exit its shell.
        app.typeKey(.leftArrow, modifierFlags: [.command, .option])
        usleep(500_000)
        app.typeText("exit")
        app.typeKey(.return, modifierFlags: [])
        usleep(1_500_000) // shell exit + collapse + auto-focus retry

        // the session survives (collapsed to the surviving right pane).
        XCTAssertTrue(row.waitForExistence(timeout: 5), "exiting the primary pane must keep the session")

        // type WITHOUT focusing — the survivor must already hold focus, so the command reaches its shell.
        let survivorTTY = ttyAfterCommand(named: "survivor")
        XCTAssertEqual(survivorTTY, rightTTY, "after exiting the primary, the surviving right pane is focused")
    }

    // mirror of the above for exiting the split (right) pane: the session survives, collapsed to the
    // primary, and the primary holds focus.
    func testExitSplitPaneKeepsSessionAndFocusesSurvivor() throws {
        let row = app.staticTexts["session-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "seeded session should exist")
        row.click()
        usleep(800_000)

        let splitButton = app.buttons["split-toggle"]
        XCTAssertTrue(splitButton.waitForExistence(timeout: 5), "split toolbar button should exist")

        // record the primary tty (the survivor when the split exits).
        let primaryTTY = ttyAfterCommand(named: "primary")
        XCTAssertNotNil(primaryTTY, "primary shell should write its tty")

        // open the split, focus the right pane, exit its shell.
        splitButton.click()
        usleep(800_000)
        app.typeKey(.rightArrow, modifierFlags: [.command, .option])
        usleep(500_000)
        app.typeText("exit")
        app.typeKey(.return, modifierFlags: [])
        usleep(1_500_000)

        XCTAssertTrue(row.waitForExistence(timeout: 5), "exiting the split pane must keep the session")

        let survivorTTY = ttyAfterCommand(named: "survivor")
        XCTAssertEqual(survivorTTY, primaryTTY, "after exiting the split, the surviving primary pane is focused")
    }

    // exiting a non-split session closes it: the only session disappears from the sidebar.
    func testExitNonSplitSessionClosesIt() throws {
        let row = app.staticTexts["session-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "seeded session should exist")
        row.click()
        usleep(800_000)

        app.typeText("exit")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["session-row"].waitForNonExistence(timeout: 8),
                      "exiting a non-split session closes it")
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
