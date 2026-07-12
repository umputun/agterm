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

    // the split toolbar glyph encodes the split state via its accessibilityValue (the symbol name is not
    // observable): none for a non-split session, both while shown side-by-side, and left/right when
    // collapsed to a single pane — whichever pane is currently shown. Also pins the design choice that a
    // SHOWN split stays "both" regardless of which pane holds focus (only a collapsed split distinguishes
    // left vs right). Ctrl-1's effect is proven by the later "left" assertion: had it not registered,
    // focus would still be on the right pane and the hide would collapse to "right", failing that check.
    func testSplitButtonGlyphReflectsState() throws {
        let row = app.staticTexts["session-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "seeded session should exist")
        row.click()
        usleep(800_000)

        let splitButton = app.buttons["split-toggle"]
        XCTAssertTrue(splitButton.waitForExistence(timeout: 5), "split toolbar button should exist")

        // non-split session → outline glyph.
        XCTAssertTrue(waitSplitValue(splitButton, "none"), "a non-split session shows the outline glyph")

        // open the split (both panes shown) → both halves filled.
        splitButton.click()
        XCTAssertTrue(waitSplitValue(splitButton, "both"), "a shown split fills both panes")

        // a shown split stays "both" regardless of focus: focusing the primary must NOT flip the glyph.
        app.typeKey("1", modifierFlags: .control)
        usleep(500_000)
        XCTAssertTrue(waitSplitValue(splitButton, "both"), "a shown split ignores which pane is focused")

        // hide the split while the primary (left) pane is focused → collapsed to the left pane.
        splitButton.click()
        XCTAssertTrue(waitSplitValue(splitButton, "left"), "collapsed to the primary pane fills the left half")

        // Ctrl-2 swaps the shown pane to the right → right half filled.
        app.typeKey("2", modifierFlags: .control)
        XCTAssertTrue(waitSplitValue(splitButton, "right"), "collapsed to the split pane fills the right half")

        // re-showing the collapsed split fills both panes again (isSplit true).
        splitButton.click()
        XCTAssertTrue(waitSplitValue(splitButton, "both"), "re-showing a collapsed split fills both panes again")

        // closing the split (exit the right pane's shell) collapses to a single non-split session → outline.
        app.typeKey(.rightArrow, modifierFlags: [.command, .option]) // put terminal focus on the right pane
        usleep(500_000)
        app.typeText("exit")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitSplitValue(splitButton, "none"), "closing the split returns the glyph to the no-split outline")
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

    // promote → re-split → exit-main: the round-1 zombie scenario, driven through the REAL pane-exit
    // routing (typing `exit`, not calling closePrimaryPane directly like the host-free test). After the
    // primary exits, the right pane promotes into the sole/main slot; a fresh split then opens a new right
    // pane; exiting the promoted MAIN pane must route through closePrimaryPane (dispatched on the surface's
    // LIVE role, now primary) and collapse onto the FRESH right pane — not through the survivor's stale
    // split onExit, which would tear the fresh right down and strand the dead main. The tell: the final
    // command reaches the fresh right shell. This is the only test that guards the role-aware dispatch;
    // reverting it strands the session, failing the last assertion.
    func testPromoteThenResplitThenExitMainCollapsesToFreshSplit() throws {
        let row = app.staticTexts["session-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "seeded session should exist")
        row.click()
        usleep(800_000)

        let splitButton = app.buttons["split-toggle"]
        XCTAssertTrue(splitButton.waitForExistence(timeout: 5), "split toolbar button should exist")

        // open the split, focus the right pane, record its tty — this is the survivor that promotes.
        splitButton.click()
        usleep(800_000)
        app.typeKey(.rightArrow, modifierFlags: [.command, .option])
        usleep(500_000)
        let promotedTTY = ttyAfterCommand(named: "promoted")
        XCTAssertNotNil(promotedTTY, "right shell should write its tty")

        // exit the primary (left) shell → the right pane promotes into the sole/main pane and holds focus.
        app.typeKey(.leftArrow, modifierFlags: [.command, .option])
        usleep(500_000)
        app.typeText("exit")
        app.typeKey(.return, modifierFlags: [])
        usleep(1_500_000) // shell exit + promotion + auto-focus retry
        XCTAssertTrue(row.waitForExistence(timeout: 5), "exiting the primary must keep the session (promoted survivor)")
        XCTAssertEqual(ttyAfterCommand(named: "after-promote"), promotedTTY,
                       "the promoted survivor is the session's sole pane and holds focus")

        // split AGAIN → a fresh right pane opens and takes focus (a separate shell from the promoted main).
        splitButton.click()
        usleep(800_000)
        let freshRightTTY = ttyAfterCommand(named: "fresh-right")
        XCTAssertNotNil(freshRightTTY, "the re-split's fresh right shell should write its tty")
        XCTAssertNotEqual(freshRightTTY, promotedTTY, "re-split opens a fresh right pane, distinct from the promoted main")

        // focus the promoted MAIN (left) pane and exit its shell. Its exit must route through
        // closePrimaryPane (live role = primary after promotion) and collapse onto the FRESH right pane —
        // NOT closeSplitPane, which would tear the fresh right down and strand the dead main (round-1 bug).
        app.typeKey(.leftArrow, modifierFlags: [.command, .option])
        usleep(500_000)
        app.typeText("exit")
        app.typeKey(.return, modifierFlags: [])
        usleep(1_500_000)

        XCTAssertTrue(row.waitForExistence(timeout: 5), "exiting the promoted main pane must keep the session")
        // type WITHOUT focusing — the fresh right pane must be the survivor and hold focus, so the command
        // reaches its shell (a torn-down fresh right / stranded dead main would fail this).
        XCTAssertEqual(ttyAfterCommand(named: "final"), freshRightTTY,
                       "exiting the promoted main collapses onto the fresh right pane, not tears it down")
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

    /// Polls the split button's accessibilityValue (none/both/left/right) until it equals `value`,
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
