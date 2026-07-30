import XCTest

/// Rebinding the six arrow-bound built-ins (`previous_session`, `next_session`, `focus_left_pane`,
/// `focus_right_pane`, and the two attention-nav actions) — the group issue #219 reported as dead. They
/// are ordinary `defaultChord`-driven actions now, rebindable to any chord including another arrow
/// (issue #278). Uses the control socket to read the selected session by id, which is why it subclasses
/// `ControlAPITestCase` (the `KeymapUITests` base can't reach the socket).
@MainActor
final class KeymapArrowRebindUITests: ControlAPITestCase {
    // two sessions so a single forward step never wraps to self, and the selection starts on the first so
    // the step lands on the second.
    func testMapArrowNavActionFiresWhenSeededAtLaunch() throws {
        try relaunch(withKeymap: "map cmd+shift+a next_session\n")
        let sessionA = try activeSessionID()

        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let sessionB = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "new session id")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "should have two sessions")

        _ = try sendCommand(#"{"cmd":"session.select","target":"\#(sessionA)"}"#)
        XCTAssertTrue(pollSelectedSession(sessionA, timeout: 10), "A should be selected before the chord")

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

    // issue #278: the MENU half of arrow support (Chord "left" -> KeyEquivalent.leftArrow in `toShortcut`);
    // the runner half is `KeymapUITests.testCustomCommandArrowChordFires`.
    func testMapToAnArrowChordFires() throws {
        try relaunch(withKeymap: "map cmd+shift+left next_session\n")
        let sessionA = try activeSessionID()

        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let sessionB = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "new session id")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "should have two sessions")

        _ = try sendCommand(#"{"cmd":"session.select","target":"\#(sessionA)"}"#)
        XCTAssertTrue(pollSelectedSession(sessionA, timeout: 10), "A should be selected before the chord")

        app.typeKey(.leftArrow, modifierFlags: [.command, .shift])
        XCTAssertTrue(pollSelectedSession(sessionB, timeout: 10),
                      "the mapped arrow chord ⌘⇧← should fire next_session and select B (issue #278)")
    }

    // `UndoCloseShortcut` is the other app-side NSEvent→Chord site and the only KEYBOARD path to undo_close
    // — File ▸ Reopen Closed Item ships no key equivalent. Two constraints: a SINGLE-target control close
    // takes the hard path and never arms the grace window, so TWO sessions are closed in one command; and
    // the grace is 3 s (`AppStore.pendingCloseGraceInterval`), so nothing may poll or wait between the
    // close and the chord.
    func testMapToAnArrowChordFiresUndoClose() throws {
        try relaunch(withKeymap: "map cmd+shift+up undo_close\n")

        let first = try sendCommand(#"{"cmd":"session.new"}"#)
        let idA = try XCTUnwrap((first["result"] as? [String: Any])?["id"] as? String, "session A id")
        let second = try sendCommand(#"{"cmd":"session.new"}"#)
        let idB = try XCTUnwrap((second["result"] as? [String: Any])?["id"] as? String, "session B id")
        XCTAssertTrue(pollSessionRowCount(3, timeout: 10), "should have three sessions before the close")

        _ = try sendCommand(#"{"cmd":"session.close","args":{"targets":["\#(idA)","\#(idB)"]}}"#)
        app.typeKey(.upArrow, modifierFlags: [.command, .shift])

        XCTAssertTrue(pollSessionRowCount(3, timeout: 10),
                      "the mapped arrow chord ⌘⇧↑ should fire undo_close and restore the closed group")
    }

    // the live `keymap.reload` path issue #219 used, not a launch seed: the menu items start with their
    // shipped arrow defaults, and the reload must RE-REGISTER the mapped chord onto them.
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

    // control for the live-reload path: if this fires but the arrow action above does not, the failure is
    // specific to the arrow-bound actions' menu key-equivalent update; if both fail, live reload never
    // re-registers a built-in menu shortcut at all.
    func testRebindDefaultChordActionFiresAfterLiveReload() throws {
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "starts with the one seeded session")

        writeKeymapAndReload("map cmd+shift+y new_session\n")

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
