import XCTest

/// The KEYBOARD half of the narrowing reselect: when applying the workspace filter hides the active
/// session, the user's keystrokes must follow the selection to the visible one.
///
/// Only a real keystroke names the surface that received it, so the oracle is the `tty > <file>` marker
/// idiom the split/overlay focus suites use. The narrowing is driven by CLICKING the bottom-bar toggle,
/// so a chrome button holds first responder when it fires.
@MainActor
final class FocusReselectFocusUITests: ControlAPITestCase {
    func testApplyingTheFilterMovesKeyboardFocusToTheVisibleSession() throws {
        let hidden = try activeSessionID()
        let hiddenTTY = markerDir.appendingPathComponent("hidden-tty")
        let hiddenTTYValue = try XCTUnwrap(
            typeUntilMarker("tty > '\(hiddenTTY.path)'\n", target: hidden, file: hiddenTTY, select: false),
            "the seeded session's shell should report its tty")

        let madeWs = try sendCommand(#"{"cmd":"workspace.new","args":{"name":"visible"}}"#)
        let wsResult = try XCTUnwrap(madeWs["result"] as? [String: Any], "workspace.new should carry a result")
        let visibleWs = try XCTUnwrap(wsResult["id"] as? String, "workspace.new should return the new id")
        let madeSession = try sendCommand(#"{"cmd":"session.new","args":{"workspace":"\#(visibleWs)"}}"#)
        let sessionResult = try XCTUnwrap(madeSession["result"] as? [String: Any], "session.new should carry a result")
        let visible = try XCTUnwrap(sessionResult["id"] as? String, "session.new should return the new id")
        let visibleTTY = markerDir.appendingPathComponent("visible-tty")
        let visibleTTYValue = try XCTUnwrap(
            typeUntilMarker("tty > '\(visibleTTY.path)'\n", target: visible, file: visibleTTY, select: false),
            "the second workspace's session should report its tty")
        XCTAssertNotEqual(hiddenTTYValue, visibleTTYValue, "the two sessions must be distinct shells")

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(hidden)"}"#)["ok"] as? Bool, true)
        XCTAssertTrue(poll(until: self.activeSessionInTree() == hidden, timeout: 10),
                      "the session the filter will hide should be active before the narrowing")

        let marked = try sendCommand(#"{"cmd":"workspace.focus","target":"\#(visibleWs)","args":{"mode":"add"}}"#)
        XCTAssertEqual(marked["ok"] as? Bool, true, "workspace.focus add should succeed: \(marked)")
        XCTAssertEqual(activeSessionInTree(), hidden, "marking alone must not move the selection")

        let toggle = app.buttons["focus-filter-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "the bottom-bar filter toggle should exist")
        XCTAssertTrue(poll(until: toggle.isEnabled, timeout: 10), "the toggle enables once something is marked")
        toggle.click()

        XCTAssertTrue(poll(until: self.activeSessionInTree() == visible, timeout: 10),
                      "applying the filter should move the selection into the marked workspace")

        let afterTTY = markerDir.appendingPathComponent("after-narrowing-tty")
        let afterValue = keyboardTypeUntilMarker("tty > '\(afterTTY.path)'", file: afterTTY)
        XCTAssertNotNil(afterValue, "keyboard focus should land on a terminal after the narrowing")
        XCTAssertEqual(afterValue, visibleTTYValue,
                       "keystrokes must reach the session the sidebar now shows, not the one the filter hid")
        XCTAssertNotEqual(afterValue, hiddenTTYValue,
                          "keystrokes reaching the hidden session is the regression this guards")
    }

    /// A visible quick terminal OWNS first responder, so a narrowing behind it must not pull focus into the
    /// covered deck. Driven over the socket, since the bottom-bar toggle is under the cover.
    func testNarrowingBehindTheQuickTerminalLeavesItsFocusAlone() throws {
        let hidden = try activeSessionID()
        let hiddenTTY = markerDir.appendingPathComponent("qt-hidden-tty")
        let hiddenTTYValue = try XCTUnwrap(
            typeUntilMarker("tty > '\(hiddenTTY.path)'\n", target: hidden, file: hiddenTTY, select: false),
            "the seeded session's shell should report its tty")

        let madeWs = try sendCommand(#"{"cmd":"workspace.new","args":{"name":"visible"}}"#)
        let wsResult = try XCTUnwrap(madeWs["result"] as? [String: Any], "workspace.new should carry a result")
        let visibleWs = try XCTUnwrap(wsResult["id"] as? String, "workspace.new should return the new id")
        let madeSession = try sendCommand(#"{"cmd":"session.new","args":{"workspace":"\#(visibleWs)"}}"#)
        let sessionResult = try XCTUnwrap(madeSession["result"] as? [String: Any], "session.new should carry a result")
        let visible = try XCTUnwrap(sessionResult["id"] as? String, "session.new should return the new id")
        let visibleTTY = markerDir.appendingPathComponent("qt-visible-tty")
        let visibleTTYValue = try XCTUnwrap(
            typeUntilMarker("tty > '\(visibleTTY.path)'\n", target: visible, file: visibleTTY, select: false),
            "the second workspace's session should report its tty")

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(hidden)"}"#)["ok"] as? Bool, true)
        XCTAssertTrue(poll(until: self.activeSessionInTree() == hidden, timeout: 10),
                      "the session the filter will hide should be active before the narrowing")

        XCTAssertEqual(try sendCommand(#"{"cmd":"quick","args":{"mode":"show"}}"#)["ok"] as? Bool, true,
                       "the quick terminal should show")
        let quickTTY = markerDir.appendingPathComponent("qt-quick-tty")
        let quickTTYValue = try XCTUnwrap(keyboardTypeUntilMarker("tty > '\(quickTTY.path)'", file: quickTTY),
                                          "the quick terminal should hold focus once shown")
        XCTAssertNotEqual(quickTTYValue, hiddenTTYValue, "the quick terminal is its own shell")
        XCTAssertNotEqual(quickTTYValue, visibleTTYValue, "the quick terminal is its own shell")

        let marked = try sendCommand(#"{"cmd":"workspace.focus","target":"\#(visibleWs)","args":{"mode":"add"}}"#)
        XCTAssertEqual(marked["ok"] as? Bool, true, "workspace.focus add should succeed: \(marked)")
        XCTAssertEqual(try sendCommand(#"{"cmd":"workspace.filter","args":{"mode":"on"}}"#)["ok"] as? Bool, true,
                       "applying the filter should succeed")
        XCTAssertTrue(poll(until: self.activeSessionInTree() == visible, timeout: 10),
                      "the narrowing should still move the selection behind the cover")

        let afterTTY = markerDir.appendingPathComponent("qt-after-tty")
        let afterValue = keyboardTypeUntilMarker("tty > '\(afterTTY.path)'", file: afterTTY)
        XCTAssertEqual(afterValue, quickTTYValue,
                       "keystrokes must stay in the quick terminal, not follow the reselect behind it")
        XCTAssertNotEqual(afterValue, visibleTTYValue,
                          "focus reaching the newly selected covered session is the regression this guards")
    }

    /// The active session id from `tree`, or nil — the seeded-row helper cannot serve, since the selection
    /// moves across workspaces here.
    private func activeSessionInTree() -> String? {
        guard let tree = try? sendCommand(#"{"cmd":"tree"}"#),
              let result = tree["result"] as? [String: Any],
              let t = result["tree"] as? [String: Any],
              let workspaces = t["workspaces"] as? [[String: Any]] else { return nil }
        for ws in workspaces {
            for session in ws["sessions"] as? [[String: Any]] ?? [] where session["active"] as? Bool == true {
                return session["id"] as? String
            }
        }
        return nil
    }
}
