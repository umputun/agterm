import XCTest

/// End-to-end tests for the title-bar recent-sessions button — the mouse equivalent of the Ctrl-Tab
/// switcher. It opens a popover of the window's most-recently-used sessions; clicking a row commits the
/// switch. The button is disabled until there are at least two sessions to switch between. Subclasses the
/// shared control harness for the isolated launch + socket (`session.new`/`session.rename`) and the
/// `selectedSessionID` snapshot oracle.
///
/// SCOPE NOTE: the row CLICK → session switch cannot be driven from XCUITest — a synthesized click (element
/// OR coordinate) on a SwiftUI `Button` inside an `NSPopover` does not fire the button's action (confirmed
/// by instrumenting the row action: the marker never wrote). A real mouse click works because it makes the
/// popover key. So these tests cover the button's enable/disable and that the popover OPENS and LISTS the
/// correct previous session; the click → `selectSession` glue (already unit-tested in agtermCore) is verified
/// by hand in the app, like other non-AX-observable behaviors (see ui-tests.md).
@MainActor
final class RecentSessionsButtonUITests: ControlAPITestCase {
    // one session at launch → the button is present but disabled; adding a second session enables it live.
    func testRecentButtonEnablesWithSecondSession() throws {
        let button = app.buttons["recent-sessions-button"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "the recent-sessions button should render in the title bar")
        XCTAssertFalse(button.isEnabled, "a single-session window should disable the recent-sessions button")

        _ = try sendCommand(#"{"cmd":"session.new"}"#)
        XCTAssertTrue(pollEnabled(button, true, timeout: 8), "a second session should enable the recent-sessions button")
    }

    // with two sessions, clicking the button opens the popover; it lists the previously-selected session as
    // the clickable jump row (identified by a unique rename). The current session is omitted (not a jump target).
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
        // the current (new) session is NOT listed — it isn't a jump target, so the only row is the previous one.
        XCTAssertEqual(app.buttons.matching(identifier: "recent-session-row").count, 1,
                       "the popover should list only the single other session, not the current one")
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
