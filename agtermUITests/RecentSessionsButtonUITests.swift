import XCTest

/// End-to-end tests for the title-bar recent-sessions button — the mouse equivalent of the Ctrl-Tab
/// switcher. It opens a popover of the window's most-recently-used sessions; clicking a row commits the
/// switch. The button is disabled until there are at least two sessions to switch between.
///
/// SCOPE NOTE: the row CLICK → session switch cannot be driven from XCUITest — a synthesized click (element
/// OR coordinate) on a SwiftUI `Button` inside an `NSPopover` does not fire the button's action (confirmed
/// by instrumenting the row action: the marker never wrote), while a real mouse click does, because it makes
/// the popover key. So these tests cover the enable/disable state and that the popover OPENS and LISTS the
/// correct previous session; the click → `selectSession` glue is verified by hand (see ui-tests.md).
@MainActor
final class RecentSessionsButtonUITests: ControlAPITestCase {
    func testRecentButtonEnablesWithSecondSession() throws {
        let button = app.buttons["recent-sessions-button"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "the recent-sessions button should render in the title bar")
        XCTAssertFalse(button.isEnabled, "a single-session window should disable the recent-sessions button")

        _ = try sendCommand(#"{"cmd":"session.new"}"#)
        XCTAssertTrue(pollEnabled(button, true, timeout: 8), "a second session should enable the recent-sessions button")
    }

    // the previous session gets a unique rename so its jump row can be told apart by label.
    func testRecentButtonPopoverListsPreviousSession() throws {
        let seeded = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(seeded)","args":{"name":"prevsession"}}"#)["ok"] as? Bool,
                       true, "renaming the seeded session should succeed")

        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let newID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new should return the new id")
        XCTAssertTrue(pollActiveSessionID(try XCTUnwrap(UUID(uuidString: newID)), timeout: 8), "the new session should be selected")

        let button = app.buttons["recent-sessions-button"]
        XCTAssertTrue(pollEnabled(button, true, timeout: 8), "two sessions should enable the recent-sessions button")

        let jumpRow = openPopoverJumpRow(button: button, timeout: 10)
        XCTAssertTrue(jumpRow.exists, "clicking the button should open the popover with the previous session as a jump row")
        XCTAssertTrue(jumpRow.label.contains("prevsession"),
                      "the jump row should be the previously-selected (renamed) session, got label: \(jumpRow.label)")
        XCTAssertEqual(app.buttons.matching(identifier: "recent-session-row").count, 1,
                       "the popover should list only the single other session, not the current one")
    }

    func testPopoversNameACompanionAfterItsParent() throws {
        try relaunch(withSettings: #"{"attentionButtonEnabled":true}"#)
        let parent = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(parent)","args":{"name":"api"}}"#)["ok"] as? Bool, true)
        let row = app.staticTexts["session-row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.rightClick()
        let item = app.menuItems.matching(identifier: "New Companion").allElementsBoundByIndex.first { $0.isHittable }
        try XCTUnwrap(item, "the row menu should offer New Companion").click()
        let companion = try XCTUnwrap(pollSecondSessionID(timeout: 8), "New Companion should add a session")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(companion)","args":{"name":"logs"}}"#)["ok"] as? Bool, true)
        _ = try sendCommand(#"{"cmd":"session.status","target":"\#(companion)","args":{"status":"blocked"}}"#)
        _ = try sendCommand(#"{"cmd":"session.select","target":"\#(parent)"}"#)

        let recent = app.buttons["recent-sessions-button"]
        XCTAssertTrue(pollEnabled(recent, true, timeout: 8))
        let jumpRow = openPopoverJumpRow(button: recent, timeout: 10)
        XCTAssertTrue(jumpRow.label.contains("api › logs"), "clock popover row: \(jumpRow.label)")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

        let bell = app.buttons["attention-button"]
        let attentionRow = app.buttons["attention-session-row"]
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !attentionRow.exists {
            bell.click()
            _ = attentionRow.waitForExistence(timeout: 1)
        }
        XCTAssertTrue(attentionRow.label.contains("api › logs"), "bell popover row: \(attentionRow.label)")
    }

    private func pollSecondSessionID(timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let tree = (try? sendCommand(#"{"cmd":"tree"}"#))?["result"] as? [String: Any]
            let ws = ((tree?["tree"] as? [String: Any])?["workspaces"] as? [[String: Any]])?.first
            if let sessions = ws?["sessions"] as? [[String: Any]], sessions.count == 2 {
                return sessions[1]["id"] as? String
            }
            usleep(200_000)
        }
        return nil
    }

    /// (Re)opens the recent-sessions popover until its jump row appears, returning it (or a non-existent
    /// element on timeout). The transient popover can dismiss before the first snapshot, so retry the open;
    /// a click is only issued while no row is showing, so it never toggles an already-open popover shut.
    private func openPopoverJumpRow(button: XCUIElement, timeout: TimeInterval) -> XCUIElement {
        let row = app.buttons["recent-session-row"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if row.exists { return row }
            button.click()
            if row.waitForExistence(timeout: 1) { return row }
        }
        return row
    }

    /// Polls until `element`'s enabled state matches `expected` (the live observation lag after the session
    /// set changes over the socket), bounded by `timeout`.
    private func pollEnabled(_ element: XCUIElement, _ expected: Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.isEnabled == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return element.exists && element.isEnabled == expected
    }
}
