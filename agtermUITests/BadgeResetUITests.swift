import XCTest

@MainActor
final class BadgeResetUITests: ControlAPITestCase {
    override var seededSettings: [String: Any]? {
        if name.contains("OnEnter") { return ["badgeReset": "enter"] }
        if name.contains("Disabled") { return ["badgeReset": "never"] }
        return nil
    }

    func testDefaultClearsBadgeOnTheFirstRealKeyButNotOnSessionType() throws {
        let sid = try badgeFocusedSession()
        try type("x", into: sid)
        XCTAssertTrue(badgeHolds(sid, for: 2), "session.type input must not clear the badge")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(pollUnseen(sid, equals: nil, timeout: 8), "the first real key should clear the badge by default")
    }

    func testOnEnterRealKeysKeepBadgeUntilBareReturn() throws {
        let sid = try badgeFocusedSession()
        try type("true\n", into: sid)
        app.typeKey(.escape, modifierFlags: [])
        typeKeys("true")
        app.typeKey(.return, modifierFlags: [.shift])
        XCTAssertTrue(badgeHolds(sid, for: 2), "typing, Escape, Shift-Return and injected Return should keep the badge under On Enter")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(pollUnseen(sid, equals: nil, timeout: 8), "a bare Return should clear the badge under On Enter")
    }

    func testDisabledKeepsBadgeThroughTypingAndReturn() throws {
        let sid = try badgeFocusedSession()
        typeKeys("true")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(badgeHolds(sid, for: 2), "neither typing nor Return should clear the badge when disabled")
    }

    private func badgeFocusedSession() throws -> String {
        let sid = try activeSessionID()
        focusTerminal()
        let sent = try sendCommand(#"{"cmd":"notify","target":"\#(sid)","args":{"body":"hi"}}"#)
        XCTAssertEqual(sent["ok"] as? Bool, true, "notify should succeed: \(sent)")
        XCTAssertTrue(pollUnseen(sid, equals: 1, timeout: 12), "notify should badge the focused session")
        return sid
    }

    private func type(_ text: String, into sid: String) throws {
        let payload: [String: Any] = ["cmd": "session.type", "target": sid, "args": ["text": text]]
        let typed = try sendCommand(String(decoding: JSONSerialization.data(withJSONObject: payload), as: UTF8.self))
        XCTAssertEqual(typed["ok"] as? Bool, true, "session.type should succeed: \(typed)")
    }

    private func typeKeys(_ text: String) {
        for char in text { app.typeKey(String(char), modifierFlags: []) }
    }

    private func focusTerminal() {
        let row = app.staticTexts["session-row"].firstMatch
        XCTAssertTrue(row.waitForHittable(timeout: 20), "seeded session should be hittable")
        row.click()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, row.isSelected == false {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func unseenCount(_ sid: String) -> Int? {
        (try? sessionNodeIfPresent(id: sid))??["unseen"] as? Int
    }

    private func pollUnseen(_ sid: String, equals expected: Int?, timeout: TimeInterval) -> Bool {
        poll(until: unseenCount(sid) == expected, timeout: timeout)
    }

    private func badgeHolds(_ sid: String, for seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if unseenCount(sid) != 1 { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return unseenCount(sid) == 1
    }
}
