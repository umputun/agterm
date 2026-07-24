import XCTest

// `notify` with the "Show notification banners" toggle OFF. The command still succeeds and the unseen
// badge still tracks, but nothing is handed to macOS — so it answers `ok` WITH an advisory note in
// `result.text` rather than a bare `ok`, which would be indistinguishable from a broken notification
// path (issue #286: a user read the bare `ok` plus a silent log as "notify never delivers").
// Launches with `notificationsEnabled: false` pre-seeded, since there is no `settings.*` control command.
final class NotifyBannersOffUITests: ControlAPITestCase {
    override var seededSettings: [String: Any]? { ["notificationsEnabled": false] }

    func testNotifyWithBannersOffReturnsOkWithNote() throws {
        let seeded = try seededSessionID()

        let notified = try sendCommand(#"{"cmd":"notify","target":"\#(seeded)","args":{"body":"hi"}}"#)
        XCTAssertEqual(notified["ok"] as? Bool, true, "notify should still succeed with banners off: \(notified)")

        let result = try XCTUnwrap(notified["result"] as? [String: Any], "notify should carry a result")
        XCTAssertEqual(result["text"] as? String,
                       "badge updated, but \"Show notification banners\" is off, so no banner was posted",
                       "banners-off notify should explain why no banner appeared: \(result)")

        // the badge is independent of the banner toggle, so the unseen count still rises.
        XCTAssertTrue(poll(timeout: 10) { try self.unseen(ofSession: seeded) == 1 },
                      "the unseen badge should still track with banners off")
    }
}

// The same command with banners ON (stock defaults) — the note must be ABSENT, so a caller can treat
// its presence as "no banner was posted" rather than boilerplate on every call.
final class NotifyBannersOnUITests: ControlAPITestCase {
    func testNotifyWithBannersOnReturnsNoNote() throws {
        let seeded = try seededSessionID()

        let notified = try sendCommand(#"{"cmd":"notify","target":"\#(seeded)","args":{"body":"hi"}}"#)
        XCTAssertEqual(notified["ok"] as? Bool, true, "notify should succeed: \(notified)")

        let result = try XCTUnwrap(notified["result"] as? [String: Any], "notify should carry a result")
        XCTAssertNil(result["text"], "a delivered notify should carry no advisory note: \(result)")
    }
}

// fileprivate so these don't reach the other ControlAPITestCase subclasses, several of which define
// their own `poll` with a different shape.
fileprivate extension ControlAPITestCase {
    /// The id of the session seeded at launch (the first session of the first workspace).
    func seededSessionID() throws -> String {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let treeResult = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let root = try XCTUnwrap(treeResult["tree"] as? [String: Any], "result should carry a tree")
        let workspaces = try XCTUnwrap(root["workspaces"] as? [[String: Any]], "tree should list workspaces")
        let sessions = try XCTUnwrap(workspaces.first?["sessions"] as? [[String: Any]], "workspace should list sessions")
        return try XCTUnwrap(sessions.first?["id"] as? String, "should have a seeded session id")
    }

    /// The session's `unseen` read-back off `tree` (omitted, hence nil, when the count is zero).
    func unseen(ofSession id: String) throws -> Int? {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let treeResult = tree["result"] as? [String: Any]
        let root = treeResult?["tree"] as? [String: Any]
        let workspaces = root?["workspaces"] as? [[String: Any]] ?? []
        let sessions = workspaces.flatMap { $0["sessions"] as? [[String: Any]] ?? [] }
        return sessions.first { $0["id"] as? String == id }?["unseen"] as? Int
    }

    /// Re-evaluates `condition` until it holds or `timeout` elapses.
    func poll(timeout: TimeInterval, _ condition: () throws -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? condition()) == true { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return (try? condition()) == true
    }
}
