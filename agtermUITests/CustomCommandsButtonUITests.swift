import XCTest

/// End-to-end tests for the title-bar custom-commands button, the mouse form of ⌃⇧O (#570). It is off by
/// default and opts in through `shownInterfaceElements`; it enables only with parsed commands and an active
/// session; its popover lists every command with its chord, the most-run ones first once there are more
/// than five.
///
/// SCOPE NOTE: as for the recent-sessions button, a synthesized click on a row inside the `NSPopover` fires
/// nothing, so the row → run glue is verified by hand; the run counts are driven here through a chord.
@MainActor
final class CustomCommandsButtonUITests: ControlAPITestCase {
    override var seededSettings: [String: Any]? {
        name.contains("HiddenByDefault") ? nil : ["shownInterfaceElements": ["customCommands"]]
    }

    func testButtonIsHiddenByDefault() {
        XCTAssertTrue(app.buttons["dashboard-toggle-button"].waitForExistence(timeout: 10), "the title bar should render")
        XCTAssertFalse(app.buttons["custom-commands-button"].exists,
                       "the custom-commands button should stay off until Settings ▸ Interface opts in")
    }

    func testButtonEnablesWithCommandsAndListsThemWithChords() throws {
        let button = app.buttons["custom-commands-button"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "opting in should render the custom-commands button")
        XCTAssertFalse(button.isEnabled, "an empty keymap should disable the custom-commands button")

        try relaunch(withKeymap: """
        command "Touch One" cmd+shift+e touch '\(markerDir.path)/one'
        command "Touch Two" touch '\(markerDir.path)/two'

        """)
        XCTAssertTrue(pollEnabled(button, true, timeout: 10), "parsed commands should enable the button")

        let rows = app.buttons.matching(identifier: "custom-command-row")
        openPopover(button, until: rows.firstMatch, timeout: 10)
        XCTAssertEqual(rows.count, 2, "the popover should list both commands")
        let first = rows.element(boundBy: 0).label
        XCTAssertTrue(first.contains("Touch One"), "rows keep keymap order, got: \(first)")
        XCTAssertTrue(first.contains("cmd+shift+e"), "a bound command shows its chord, got: \(first)")
        XCTAssertEqual(app.buttons.matching(identifier: "custom-command-top-row").count, 0,
                       "the most-used section needs more than five commands")
    }

    func testMostRunCommandsLeadOncePastFive() throws {
        let marker = markerDir.appendingPathComponent("six")
        var keymap = ""
        for index in 1...5 { keymap += "command \"Cmd \(index)\" echo \(index)\n" }
        keymap += "command \"Touch Six\" cmd+shift+e touch '\(marker.path)'\n"
        try relaunch(withKeymap: keymap)
        focusTerminal()
        XCTAssertTrue(chordFiresMarker(marker) { app.typeKey("e", modifierFlags: [.command, .shift]) },
                      "⌘⇧E should run the sixth command and touch the marker file")

        let button = app.buttons["custom-commands-button"]
        XCTAssertTrue(pollEnabled(button, true, timeout: 10), "six parsed commands should enable the button")
        let top = app.buttons.matching(identifier: "custom-command-top-row")
        openPopover(button, until: top.firstMatch, timeout: 10)
        XCTAssertEqual(top.count, 1, "only the run command has a count, so the most-used section holds one row")
        XCTAssertTrue(top.firstMatch.label.contains("Touch Six"), "the run command should lead, got: \(top.firstMatch.label)")
        XCTAssertEqual(app.buttons.matching(identifier: "custom-command-row").count, 5, "the rest follow below the separator")
    }

    // counts seeded straight into the usage file: seven commands with counts rising in file order, so the
    // top group is the last five by count while still rendering in file order.
    func testMostRunGroupKeepsFileOrder() throws {
        var keymap = ""
        for name in ["A", "B", "C", "D", "E", "F", "G"] { keymap += "command \"Cmd \(name)\" true\n" }
        let counts = Dictionary(uniqueKeysWithValues: ["A", "B", "C", "D", "E", "F", "G"].enumerated()
            .map { ("Cmd \($0.element)", $0.offset + 1) })
        let usage = try JSONSerialization.data(withJSONObject: ["version": 1, "counts": counts])
        try usage.write(to: stateDir.appendingPathComponent("custom-command-usage.json"))
        try relaunch(withKeymap: keymap)

        let button = app.buttons["custom-commands-button"]
        XCTAssertTrue(pollEnabled(button, true, timeout: 10), "seven parsed commands should enable the button")
        let top = app.buttons.matching(identifier: "custom-command-top-row")
        openPopover(button, until: top.firstMatch, timeout: 10)
        let leading = top.allElementsBoundByIndex.map(\.label)
        XCTAssertEqual(leading.count, 5, "the five most-run commands lead, got: \(leading)")
        XCTAssertEqual(leading.map { String($0.prefix(5)) }, ["Cmd C", "Cmd D", "Cmd E", "Cmd F", "Cmd G"],
                       "the top group keeps file order rather than count order, got: \(leading)")
        let rest = app.buttons.matching(identifier: "custom-command-row").allElementsBoundByIndex.map(\.label)
        XCTAssertEqual(rest.map { String($0.prefix(5)) }, ["Cmd A", "Cmd B"], "the rest follow in file order, got: \(rest)")
    }

    /// (Re)opens the popover until `row` appears. The transient popover can dismiss before the first
    /// snapshot, so retry the open; a click is only issued while no row is showing, so it never toggles an
    /// already-open popover shut.
    private func openPopover(_ button: XCUIElement, until row: XCUIElement, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !row.exists {
            button.click()
            if row.waitForExistence(timeout: 1) { return }
        }
        XCTAssertTrue(row.exists, "clicking the button should open the popover with its rows")
    }

    /// Polls until `element`'s enabled state matches `expected` (the live observation lag after a relaunch
    /// or a keymap change), bounded by `timeout`.
    private func pollEnabled(_ element: XCUIElement, _ expected: Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.isEnabled == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return element.exists && element.isEnabled == expected
    }

    /// Click the seeded session row so the terminal surface takes first responder, then let the responder
    /// bounce settle, so the chord resolves from that surface.
    private func focusTerminal() {
        let row = app.staticTexts["session-row"].firstMatch
        XCTAssertTrue(row.waitForHittable(timeout: 20), "seeded session should be hittable")
        row.click()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, row.isSelected == false {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// Run `press` and poll for `marker`, retrying the press a few times: the first burst after
    /// `focusTerminal` can land before the surface is genuinely first responder and be dropped.
    private func chordFiresMarker(_ marker: URL, attempts: Int = 6, perAttempt: TimeInterval = 2.5,
                                  press: () -> Void) -> Bool {
        for _ in 0..<attempts {
            press()
            if poll(until: FileManager.default.fileExists(atPath: marker.path), timeout: perAttempt) { return true }
        }
        return false
    }
}
