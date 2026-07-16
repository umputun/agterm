import XCTest

/// Reproduction for issue #219: `map <chord> <action>` reportedly does nothing when the target action
/// ships without a default chord. The four actions the report tested — `previous_session`,
/// `next_session`, `previous_attention_session`, `next_attention_session` — are all in the six-member
/// arrow-bound group (`defaultChord == nil`, a hardcoded arrow key-equivalent as the menu fallback via
/// `agtermApp.arrowShortcut(for:)`). Uses the control socket to read the selected session by id, which is
/// why it subclasses `ControlAPITestCase` (the `KeymapUITests` base can't reach the socket).
@MainActor
final class KeymapArrowRebindUITests: ControlAPITestCase {
    // map `next_session` (one of the four reported arrow-bound actions) to a parseable chord and prove the
    // chord actually navigates. two sessions so a single forward step never wraps to self, and the
    // selection starts on the first so the step lands on the second (forward, unambiguous).
    func testMapArrowNavActionFiresWhenSeededAtLaunch() throws {
        try relaunch(withKeymap: "map cmd+shift+a next_session\n")
        let sessionA = try activeSessionID()

        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let sessionB = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "new session id")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "should have two sessions")

        _ = try sendCommand(#"{"cmd":"session.select","target":"\#(sessionA)"}"#)
        XCTAssertTrue(pollSelectedSession(sessionA, timeout: 10), "A should be selected before the chord")

        // the mapped chord ⌘⇧A must fire next_session and move the selection A -> B.
        app.typeKey("a", modifierFlags: [.command, .shift])
        XCTAssertTrue(pollSelectedSession(sessionB, timeout: 10),
                      "the mapped chord ⌘⇧A should fire next_session and select B (issue #219)")

        // positive control: navigation itself works over the socket, so a chord failure above is a
        // keybinding failure, not dead navigation.
        _ = try sendCommand(#"{"cmd":"session.select","target":"\#(sessionA)"}"#)
        XCTAssertTrue(pollSelectedSession(sessionA, timeout: 10), "reselect A for the control")
        _ = try sendCommand(#"{"cmd":"session.go","args":{"to":"next"}}"#)
        XCTAssertTrue(pollSelectedSession(sessionB, timeout: 10),
                      "session.go next over the socket should select B (proves navigation is alive)")
    }

    // the same rebind but applied via a LIVE `keymap.reload` (the exact path issue #219 used —
    // `agtermctl keymap reload` while running), not seeded at launch. The menu items start with the
    // hardcoded arrow key-equivalents, and reload must RE-REGISTER the mapped chord onto them.
    func testMapArrowNavActionFiresAfterLiveReload() throws {
        let sessionA = try activeSessionID()
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let sessionB = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "new session id")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "should have two sessions")

        writeKeymapAndReload("map cmd+shift+a next_session\n")

        _ = try sendCommand(#"{"cmd":"session.select","target":"\#(sessionA)"}"#)
        XCTAssertTrue(pollSelectedSession(sessionA, timeout: 10), "A should be selected before the chord")

        app.typeKey("a", modifierFlags: [.command, .shift])
        XCTAssertTrue(pollSelectedSession(sessionB, timeout: 10),
                      "the live-reloaded chord ⌘⇧A should fire next_session and select B (issue #219)")

        _ = try sendCommand(#"{"cmd":"session.select","target":"\#(sessionA)"}"#)
        XCTAssertTrue(pollSelectedSession(sessionA, timeout: 10), "reselect A for the control")
        _ = try sendCommand(#"{"cmd":"session.go","args":{"to":"next"}}"#)
        XCTAssertTrue(pollSelectedSession(sessionB, timeout: 10),
                      "session.go next over the socket should select B (proves navigation is alive)")
    }

    // control for the live-reload path: a DEFAULT-chord action (new_session, ships ⌘N) rebound via the
    // SAME live reload. If this fires but the arrow action above does not, the failure is specific to the
    // arrow-bound actions' menu key-equivalent update; if both fail, live reload never re-registers a
    // built-in menu shortcut at all.
    func testRebindDefaultChordActionFiresAfterLiveReload() throws {
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "starts with the one seeded session")

        writeKeymapAndReload("map cmd+shift+y new_session\n")

        // ⌘⇧Y must now fire new_session (a second row appears).
        app.typeKey("y", modifierFlags: [.command, .shift])
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10),
                      "the live-reloaded chord ⌘⇧Y should fire new_session and add a session")
    }

    // MARK: - helpers

    /// Write `contents` to the isolated `<stateDir>/config/keymap.conf` (overwriting the comment-only
    /// starter) and reload it LIVE over the socket, asserting a clean (0-diagnostic) parse — the
    /// `agtermctl keymap reload` path, without relaunching.
    private func writeKeymapAndReload(_ contents: String) {
        let configDir = stateDir.appendingPathComponent("config", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: configDir.appendingPathComponent("keymap.conf"))
            let reloaded = try sendCommand(#"{"cmd":"keymap.reload"}"#)
            XCTAssertEqual((reloaded["result"] as? [String: Any])?["count"] as? Int, 0,
                           "keymap.reload should report 0 diagnostics: \(reloaded)")
        } catch {
            XCTFail("writing/reloading the keymap failed: \(error)")
        }
    }

    /// The currently selected (active-flagged) session id from the tree, or nil if not readable yet.
    private func selectedSessionID() -> String? {
        guard let tree = try? sendCommand(#"{"cmd":"tree"}"#),
              let result = tree["result"] as? [String: Any],
              let top = result["tree"] as? [String: Any],
              let workspaces = top["workspaces"] as? [[String: Any]] else { return nil }
        for workspace in workspaces {
            for session in (workspace["sessions"] as? [[String: Any]] ?? []) where session["active"] as? Bool == true {
                return session["id"] as? String
            }
        }
        return nil
    }

    private func pollSelectedSession(_ id: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if selectedSessionID()?.lowercased() == id.lowercased() { return true }
            usleep(200_000)
        }
        return selectedSessionID()?.lowercased() == id.lowercased()
    }
}
