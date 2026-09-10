import XCTest

/// End-to-end tests for the title-bar custom-commands button, the mouse form of ⌃⇧O (#570). It is off by
/// default and opts in through `shownInterfaceElements`; it enables only with parsed commands and an active
/// session; its popover lists every command with its chord in keymap order.
///
/// SCOPE NOTE: as for the recent-sessions button, a synthesized click on a row inside the `NSPopover` fires
/// nothing, so the row → run glue is verified by hand.
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
        XCTAssertTrue(rows.element(boundBy: 1).label.contains("Touch Two"), "an unbound command lists too")
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
}
