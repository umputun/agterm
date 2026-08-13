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
        row.click()
        usleep(800_000)

        let primaryTTY = ttyAfterCommand(named: "primary")
        XCTAssertNotNil(primaryTTY, "primary shell should write its tty (terminal must be focused)")

        let splitButton = app.buttons["split-toggle"]
        XCTAssertTrue(splitButton.waitForExistence(timeout: 5), "split toolbar button should exist")
        splitButton.click()
        usleep(800_000)
        let rightTTY = ttyAfterCommand(named: "afteropen")
        XCTAssertNotNil(rightTTY, "right shell should write its tty")
        XCTAssertNotEqual(rightTTY, primaryTTY, "opening the split moves focus to the new (right) pane")

        app.typeKey(.leftArrow, modifierFlags: [.command, .option])
        usleep(500_000)
        let leftTTY = ttyAfterCommand(named: "left")
        XCTAssertEqual(leftTTY, primaryTTY, "Cmd+Opt+Left focuses the primary shell")

        app.typeKey(.rightArrow, modifierFlags: [.command, .option])
        usleep(500_000)
        let rightAgainTTY = ttyAfterCommand(named: "right")
        XCTAssertEqual(rightAgainTTY, rightTTY, "Cmd+Opt+Right focuses the separate right shell")

        splitButton.click()
        usleep(800_000)
        let collapsedTTY = ttyAfterCommand(named: "collapsed")
        XCTAssertEqual(collapsedTTY, rightTTY, "closing the split keeps the focused (right) pane, not the primary")
    }

    func testHorizontalShortcutCreatesTransposesAndTogglesWithoutReplacingPanes() throws {
        let row = app.staticTexts["session-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "seeded session should exist")
        row.click()
        usleep(800_000)

        let primaryTTY = ttyAfterCommand(named: "horizontal-primary")
        XCTAssertNotNil(primaryTTY)
        let splitButton = app.buttons["split-toggle"]
        XCTAssertTrue(splitButton.waitForExistence(timeout: 5))

        app.typeKey("d", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitSplitValue(splitButton, "both-horizontal"), "⌘⇧D creates a top/bottom split")
        let splitTTY = ttyAfterCommand(named: "horizontal-split")
        XCTAssertNotNil(splitTTY)
        XCTAssertNotEqual(splitTTY, primaryTTY)

        app.typeKey("1", modifierFlags: .control)
        XCTAssertEqual(ttyAfterCommand(named: "horizontal-primary-before-transpose"), primaryTTY)
        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(waitSplitValue(splitButton, "both"), "⌘D transposes the shown split to left/right")
        XCTAssertEqual(ttyAfterCommand(named: "horizontal-primary-after-transpose"), primaryTTY,
                       "transposing preserves the focused primary terminal")

        app.typeKey("d", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitSplitValue(splitButton, "both-horizontal"), "⌘⇧D transposes it back to top/bottom")
        app.typeKey("2", modifierFlags: .control)
        XCTAssertEqual(ttyAfterCommand(named: "horizontal-split-after-transpose"), splitTTY,
                       "transposing preserves the split terminal")

        app.typeKey("d", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitSplitValue(splitButton, "bottom"), "same-axis shortcut hides onto the focused bottom pane")
        app.typeKey("d", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitSplitValue(splitButton, "both-horizontal"), "same-axis shortcut re-shows top/bottom")
    }

    func testCtrlNumberFocusesPaneDirectly() throws {
        let row = app.staticTexts["session-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "seeded session should exist")
        row.click()
        usleep(800_000)

        let primaryTTY = ttyAfterCommand(named: "primary")
        XCTAssertNotNil(primaryTTY, "primary shell should write its tty")

        let splitButton = app.buttons["split-toggle"]
        XCTAssertTrue(splitButton.waitForExistence(timeout: 5), "split toolbar button should exist")
        splitButton.click()
        usleep(800_000)
        let rightTTY = ttyAfterCommand(named: "right")
        XCTAssertNotNil(rightTTY, "right shell should write its tty")
        XCTAssertNotEqual(rightTTY, primaryTTY, "opening the split moves focus to the new (right) pane")

        app.typeKey("1", modifierFlags: .control)
        usleep(500_000)
        XCTAssertEqual(ttyAfterCommand(named: "ctrl1"), primaryTTY, "Ctrl-1 focuses the primary pane")

        app.typeKey("2", modifierFlags: .control)
        usleep(500_000)
        XCTAssertEqual(ttyAfterCommand(named: "ctrl2"), rightTTY, "Ctrl-2 focuses the split pane")
    }

    // a leaked "1"/"2" would prefix the tty command on the SAME line ("12tty …"), so it fails and the
    // marker file stays empty — which is why a non-nil read proves nothing leaked.
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

    // the re-parent between the HSplitView and a standalone host must never tear a surface down; a
    // destroyed-and-recreated pane would report a different tty across the hide → show cycle.
    func testSplitSurvivesHideShow() throws {
        let row = app.staticTexts["session-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "seeded session should exist")
        row.click()
        usleep(800_000)

        let splitButton = app.buttons["split-toggle"]
        XCTAssertTrue(splitButton.waitForExistence(timeout: 5), "split toolbar button should exist")

        splitButton.click()
        usleep(800_000)
        app.typeKey(.rightArrow, modifierFlags: [.command, .option])
        usleep(500_000)
        let rightTTY = ttyAfterCommand(named: "right-before")
        XCTAssertNotNil(rightTTY, "right shell should write its tty")

        splitButton.click() // hide
        usleep(800_000)
        splitButton.click() // show
        usleep(800_000)

        app.typeKey(.rightArrow, modifierFlags: [.command, .option])
        usleep(500_000)
        let rightTTYAfter = ttyAfterCommand(named: "right-after")
        XCTAssertEqual(rightTTYAfter, rightTTY, "hiding then showing the split keeps the same right shell alive")
    }

    // pane nav is gated on hasSplit, not isSplit: while the split is hidden, ⌃1/⌃2 (and ⌘⌥←/→) swap
    // WHICH pane is shown maximized.
    func testHiddenSplitPaneNavigationSwapsShownPane() throws {
        let row = app.staticTexts["session-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "seeded session should exist")
        row.click()
        usleep(800_000)

        let primaryTTY = ttyAfterCommand(named: "primary")
        XCTAssertNotNil(primaryTTY, "primary shell should write its tty")

        let splitButton = app.buttons["split-toggle"]
        XCTAssertTrue(splitButton.waitForExistence(timeout: 5), "split toolbar button should exist")
        splitButton.click()
        usleep(800_000)
        let rightTTY = ttyAfterCommand(named: "right")
        XCTAssertNotNil(rightTTY, "right shell should write its tty")
        XCTAssertNotEqual(rightTTY, primaryTTY, "opening the split moves focus to the new (right) pane")

        splitButton.click()
        usleep(800_000)
        XCTAssertEqual(ttyAfterCommand(named: "hidden-right"), rightTTY, "the hidden split shows the focused (right) pane")

        app.typeKey("1", modifierFlags: .control)
        usleep(800_000)
        XCTAssertEqual(ttyAfterCommand(named: "hidden-ctrl1"), primaryTTY,
                       "Ctrl-1 swaps the hidden split to the primary pane")

        app.typeKey("2", modifierFlags: .control)
        usleep(800_000)
        XCTAssertEqual(ttyAfterCommand(named: "hidden-ctrl2"), rightTTY,
                       "Ctrl-2 swaps the hidden split back to the right pane")
    }

    // the glyph's symbol name is not observable, so the state rides its accessibilityValue
    // (none/both/left/right). Ctrl-1's effect is proven by the later "left" assertion: had it not
    // registered, focus would still be on the right pane and the hide would collapse to "right".
    func testSplitButtonGlyphReflectsState() throws {
        let row = app.staticTexts["session-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "seeded session should exist")
        row.click()
        usleep(800_000)

        let splitButton = app.buttons["split-toggle"]
        XCTAssertTrue(splitButton.waitForExistence(timeout: 5), "split toolbar button should exist")

        XCTAssertTrue(waitSplitValue(splitButton, "none"), "a non-split session shows the outline glyph")

        splitButton.click()
        XCTAssertTrue(waitSplitValue(splitButton, "both"), "a shown split fills both panes")

        app.typeKey("1", modifierFlags: .control)
        usleep(500_000)
        XCTAssertTrue(waitSplitValue(splitButton, "both"), "a shown split ignores which pane is focused")

        splitButton.click()
        XCTAssertTrue(waitSplitValue(splitButton, "left"), "collapsed to the primary pane fills the left half")

        app.typeKey("2", modifierFlags: .control)
        XCTAssertTrue(waitSplitValue(splitButton, "right"), "collapsed to the split pane fills the right half")

        splitButton.click()
        XCTAssertTrue(waitSplitValue(splitButton, "both"), "re-showing a collapsed split fills both panes again")

        app.typeKey(.rightArrow, modifierFlags: [.command, .option])
        usleep(500_000)
        app.typeText("exit")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitSplitValue(splitButton, "none"), "closing the split returns the glyph to the no-split outline")
    }

    func testExitPrimaryPaneKeepsSessionAndFocusesSurvivor() throws {
        let row = app.staticTexts["session-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "seeded session should exist")
        row.click()
        usleep(800_000)

        let splitButton = app.buttons["split-toggle"]
        XCTAssertTrue(splitButton.waitForExistence(timeout: 5), "split toolbar button should exist")

        splitButton.click()
        usleep(800_000)
        app.typeKey(.rightArrow, modifierFlags: [.command, .option])
        usleep(500_000)
        let rightTTY = ttyAfterCommand(named: "right")
        XCTAssertNotNil(rightTTY, "right shell should write its tty")

        app.typeKey(.leftArrow, modifierFlags: [.command, .option])
        usleep(500_000)
        app.typeText("exit")
        app.typeKey(.return, modifierFlags: [])
        usleep(1_500_000) // shell exit + collapse + auto-focus retry

        XCTAssertTrue(row.waitForExistence(timeout: 5), "exiting the primary pane must keep the session")

        // typed WITHOUT focusing, so this only lands if the survivor already holds focus.
        let survivorTTY = ttyAfterCommand(named: "survivor")
        XCTAssertEqual(survivorTTY, rightTTY, "after exiting the primary, the surviving right pane is focused")
    }

    // Regression for #303: promotion into the primary slot does not change the surrounding SwiftUI
    // branch, so the terminal host must remount for the promoted surface or the visible pane stays the
    // dead primary while the live survivor is stranded off-screen.
    func testExitPrimaryPaneWhileSplitHiddenHostsAndFocusesSurvivor() throws {
        let row = app.staticTexts["session-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "seeded session should exist")
        row.click()
        usleep(800_000)

        let splitButton = app.buttons["split-toggle"]
        XCTAssertTrue(splitButton.waitForExistence(timeout: 5), "split toolbar button should exist")

        splitButton.click()
        usleep(800_000)
        let rightTTY = ttyAfterCommand(named: "hidden-survivor")
        XCTAssertNotNil(rightTTY, "right shell should write its tty")

        app.typeKey("1", modifierFlags: .control)
        usleep(500_000)
        splitButton.click()
        XCTAssertTrue(waitSplitValue(splitButton, "left"), "the hidden split should show the primary pane")

        app.typeText("exit")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitSplitValue(splitButton, "none"), "promotion should leave a regular non-split session")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "exiting the hidden primary must keep the session")

        // typed WITHOUT focusing — this fails if SwiftUI kept hosting the torn-down primary surface.
        XCTAssertEqual(ttyAfterCommand(named: "after-hidden-promotion"), rightTTY,
                       "the promoted hidden survivor should be visible and focused")
    }

    // exiting the promoted main pane must dispatch on the surface's LIVE role (primary after promotion)
    // and collapse onto the FRESH right pane; the survivor's stale split onExit would tear that pane
    // down and strand the dead main. The only test guarding the role-aware dispatch.
    func testPromoteThenResplitThenExitMainCollapsesToFreshSplit() throws {
        let row = app.staticTexts["session-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "seeded session should exist")
        row.click()
        usleep(800_000)

        let splitButton = app.buttons["split-toggle"]
        XCTAssertTrue(splitButton.waitForExistence(timeout: 5), "split toolbar button should exist")

        splitButton.click()
        usleep(800_000)
        app.typeKey(.rightArrow, modifierFlags: [.command, .option])
        usleep(500_000)
        let promotedTTY = ttyAfterCommand(named: "promoted")
        XCTAssertNotNil(promotedTTY, "right shell should write its tty")

        app.typeKey(.leftArrow, modifierFlags: [.command, .option])
        usleep(500_000)
        app.typeText("exit")
        app.typeKey(.return, modifierFlags: [])
        usleep(1_500_000) // shell exit + promotion + auto-focus retry
        XCTAssertTrue(row.waitForExistence(timeout: 5), "exiting the primary must keep the session (promoted survivor)")
        XCTAssertEqual(ttyAfterCommand(named: "after-promote"), promotedTTY,
                       "the promoted survivor is the session's sole pane and holds focus")

        splitButton.click()
        usleep(800_000)
        let freshRightTTY = ttyAfterCommand(named: "fresh-right")
        XCTAssertNotNil(freshRightTTY, "the re-split's fresh right shell should write its tty")
        XCTAssertNotEqual(freshRightTTY, promotedTTY, "re-split opens a fresh right pane, distinct from the promoted main")

        app.typeKey(.leftArrow, modifierFlags: [.command, .option])
        usleep(500_000)
        app.typeText("exit")
        app.typeKey(.return, modifierFlags: [])
        usleep(1_500_000)

        XCTAssertTrue(row.waitForExistence(timeout: 5), "exiting the promoted main pane must keep the session")
        // typed WITHOUT focusing — a torn-down fresh right or a stranded dead main fails here.
        XCTAssertEqual(ttyAfterCommand(named: "final"), freshRightTTY,
                       "exiting the promoted main collapses onto the fresh right pane, not tears it down")
    }

    func testExitSplitPaneKeepsSessionAndFocusesSurvivor() throws {
        let row = app.staticTexts["session-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "seeded session should exist")
        row.click()
        usleep(800_000)

        let splitButton = app.buttons["split-toggle"]
        XCTAssertTrue(splitButton.waitForExistence(timeout: 5), "split toolbar button should exist")

        let primaryTTY = ttyAfterCommand(named: "primary")
        XCTAssertNotNil(primaryTTY, "primary shell should write its tty")

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

    /// Polls the split button's accessibilityValue (none/both/left/right/both-horizontal/top/bottom),
    /// covering the observation lag between a state change and the title-bar re-render.
    private func waitSplitValue(_ button: XCUIElement, _ value: String, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (button.value as? String) == value { return true }
            usleep(150_000)
        }
        return false
    }
}
