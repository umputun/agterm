import XCTest

/// End-to-end tests for Settings ▸ Agent Status ▸ Status reset: which keystroke clears a `completed` glyph.
/// The status is set and read over the socket and the typing goes through `session.type`, which fires the
/// same pane-scoped clear a keystroke does, so each mode is pinned without driving the keyboard.
@MainActor
final class StatusResetUITests: ControlAPITestCase {
    override var seededSettings: [String: Any]? {
        if name.contains("OnEnter") { return ["statusReset": "enter"] }
        if name.contains("Disabled") { return ["statusReset": "never"] }
        return nil
    }

    func testDefaultClearsCompletedOnTheFirstKey() throws {
        let sid = try markCompleted()
        try type("a", into: sid)
        XCTAssertTrue(pollStatus(sid, equals: nil, timeout: 8), "the first key should clear completed to idle by default")
    }

    func testOnEnterKeepsCompletedUntilReturn() throws {
        let sid = try markCompleted()
        try type("true", into: sid)
        XCTAssertTrue(statusHolds(sid, equals: "completed", for: 2), "typing without Return should keep completed under On Enter")
        try type("\n", into: sid)
        XCTAssertTrue(pollStatus(sid, equals: nil, timeout: 8), "Return should clear completed under On Enter")
    }

    // real keyboard events reach keyDown and its modifier mapping, which session.type bypasses.
    func testOnEnterRealKeysKeepCompletedUntilBareReturn() throws {
        let sid = try markCompleted()
        focusTerminal()
        app.typeText("true")
        app.typeKey(.return, modifierFlags: [.shift])
        XCTAssertTrue(statusHolds(sid, equals: "completed", for: 2), "typing and Shift-Return should keep completed under On Enter")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(pollStatus(sid, equals: nil, timeout: 8), "a bare Return should clear completed under On Enter")
    }

    func testDisabledKeepsCompletedThroughReturn() throws {
        let sid = try markCompleted()
        try type("true\n", into: sid)
        XCTAssertTrue(statusHolds(sid, equals: "completed", for: 2), "neither typing nor Return should clear completed when disabled")
    }

    /// Marks the seeded session completed over the socket and waits for the tree to report it.
    private func markCompleted() throws -> String {
        let sid = try activeSessionID()
        let set = try sendCommand(#"{"cmd":"session.status","target":"\#(sid)","args":{"status":"completed"}}"#)
        XCTAssertEqual(set["ok"] as? Bool, true, "session.status completed should succeed: \(set)")
        XCTAssertTrue(pollStatus(sid, equals: "completed", timeout: 8), "the tree should report completed before typing")
        return sid
    }

    private func type(_ text: String, into sid: String) throws {
        let payload: [String: Any] = ["cmd": "session.type", "target": sid, "args": ["text": text]]
        let typed = try sendCommand(String(decoding: JSONSerialization.data(withJSONObject: payload), as: UTF8.self))
        XCTAssertEqual(typed["ok"] as? Bool, true, "session.type should succeed: \(typed)")
    }

    /// Click the seeded session row so the terminal surface takes first responder, then let the responder
    /// bounce settle, so the keys reach that surface's keyDown.
    private func focusTerminal() {
        let row = app.staticTexts["session-row"].firstMatch
        XCTAssertTrue(row.waitForHittable(timeout: 20), "seeded session should be hittable")
        row.click()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, row.isSelected == false {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func currentStatus(_ sid: String) -> String? {
        (try? sessionNodeIfPresent(id: sid))??["status"] as? String
    }

    private func pollStatus(_ sid: String, equals expected: String?, timeout: TimeInterval) -> Bool {
        poll(until: currentStatus(sid) == expected, timeout: timeout)
    }

    /// True when the status reads `expected` on every sample across `seconds`; a clear that arrives late
    /// still fails it, which is the point of sampling rather than reading once.
    private func statusHolds(_ sid: String, equals expected: String, for seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if currentStatus(sid) != expected { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return currentStatus(sid) == expected
    }
}
