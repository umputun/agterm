import XCTest

@MainActor
final class ControlSurfaceCursorUITests: ControlAPITestCase {
    // differential, not absolute: the host's prompt, font size and padding are unknown here
    func testSurfaceCursorColumnAdvancesByTheTypedTextLength() throws {
        let sessionID = try activeSessionID()
        try waitForPrompt(sessionID, marker: "cursor-ready")

        let atPrompt = try XCTUnwrap(settledCursorColumn(timeout: 10), "the column should settle at the prompt")
        let probe = "abcdefg"
        // no trailing newline: the payload must sit on the prompt line, not run
        XCTAssertEqual(try sendCommand(typeRequest(text: probe, target: sessionID, select: false))["ok"] as? Bool,
                       true, "typing the probe payload should succeed")
        XCTAssertTrue(pollCursorColumn(atPrompt + probe.count, timeout: 10),
                      "the column should advance by the payload length from \(atPrompt); got \(String(describing: cursorColumnOrNil()))")
    }

    func testSurfaceCursorReadsAnExplicitSplitPaneAndRejectsUnknownTargets() throws {
        let sessionID = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","args":{"mode":"on"}}"#)["ok"] as? Bool, true,
                       "split on should succeed")
        try waitForPrompt(sessionID, marker: "cursor-split-ready", pane: "right")

        let response = try sendCommand(#"{"cmd":"surface.cursor","target":"surface:\#(sessionID):right"}"#)
        XCTAssertEqual(response["ok"] as? Bool, true, "reading the split pane's cursor should succeed: \(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any], "a cursor read should carry a result")
        XCTAssertEqual(result["id"] as? String, "surface:\(sessionID):right",
                       "the result should echo the surface it read")
        // pins the nested shape: a future row joins `cursor`, never a second top-level key
        let cursor = try XCTUnwrap(result["cursor"] as? [String: Any], "the result should nest a cursor object")
        XCTAssertNotNil(cursor["column"] as? Int, "the cursor should carry an Int column: \(cursor)")
        XCTAssertNil(cursor["row"], "row is deliberately absent, the pinned libghostty cannot recover it")

        let unknown = try sendCommand(#"{"cmd":"surface.cursor","target":"not-a-surface"}"#)
        XCTAssertEqual(unknown["ok"] as? Bool, false, "an unparsable target should be refused: \(unknown)")
        XCTAssertEqual(unknown["error"] as? String, "invalid surface: not-a-surface")

        let empty = try sendCommand(#"{"cmd":"surface.cursor","target":"surface:\#(sessionID):scratch"}"#)
        XCTAssertEqual(empty["ok"] as? Bool, false, "an empty slot should be refused: \(empty)")
        XCTAssertEqual(empty["error"] as? String, "surface not available: surface:\(sessionID):scratch")
    }

    // zooming a NONFOCUSED pane leaves `splitFocused` alone, so resolving `active` from the store's focus
    // instead of the window's zoom controller silently read the hidden pane.
    func testSurfaceCursorActiveFollowsAnExplicitZoomOfTheNonFocusedPane() throws {
        let sessionID = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","args":{"mode":"on"}}"#)["ok"] as? Bool, true,
                       "split on should succeed")
        try waitForPrompt(sessionID, marker: "zoom-left-ready", pane: "left")
        try waitForPrompt(sessionID, marker: "zoom-right-ready", pane: "right")

        // distinct payloads so the two panes' columns cannot coincide
        try type("ab", into: sessionID, pane: "left")
        try type("abcdefghij", into: sessionID, pane: "right")
        let left = try XCTUnwrap(settledCursorColumn(target: "surface:\(sessionID):left", timeout: 10))
        let right = try XCTUnwrap(settledCursorColumn(target: "surface:\(sessionID):right", timeout: 10))
        XCTAssertNotEqual(left, right, "the panes must differ for `active` to be a real discriminator")

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.focus","args":{"pane":"left"}}"#)["ok"] as? Bool, true,
                       "focusing the left pane should succeed")
        XCTAssertTrue(pollCursorColumn(left, timeout: 10), "unzoomed, `active` should read the focused left pane")

        let zoom = try sendCommand(#"{"cmd":"surface.zoom","target":"surface:\#(sessionID):right","args":{"mode":"show"}}"#)
        XCTAssertEqual(zoom["ok"] as? Bool, true, "zooming the right pane should succeed: \(zoom)")
        XCTAssertTrue(pollCursorColumn(right, timeout: 10),
                      "`active` should follow the zoom to the right pane, not stay on the focused left one")

        XCTAssertEqual(try sendCommand(#"{"cmd":"surface.zoom","target":"surface:\#(sessionID):right","args":{"mode":"hide"}}"#)["ok"] as? Bool,
                       true, "unzooming should succeed")
        XCTAssertTrue(pollCursorColumn(left, timeout: 10), "`active` should return to the focused pane after unzoom")
    }

    // `QuickTerminalController.hide()` keeps its surface alive, so a panel shown once stayed readable —
    // the never-shown case is the false green here.
    func testSurfaceCursorRefusesAHiddenQuickTerminalAfterItHasBeenShown() throws {
        let before = try sendCommand(#"{"cmd":"surface.cursor","target":"quick"}"#)
        XCTAssertEqual(before["ok"] as? Bool, false, "a never-shown quick terminal should be refused: \(before)")

        XCTAssertEqual(try sendCommand(#"{"cmd":"quick","args":{"mode":"show"}}"#)["ok"] as? Bool, true,
                       "showing the quick terminal should succeed")
        XCTAssertNotNil(settledCursorColumn(target: "quick", timeout: 10),
                        "a shown quick terminal should report a column")

        XCTAssertEqual(try sendCommand(#"{"cmd":"quick","args":{"mode":"hide"}}"#)["ok"] as? Bool, true,
                       "hiding the quick terminal should succeed")
        let after = try sendCommand(#"{"cmd":"surface.cursor","target":"quick"}"#)
        XCTAssertEqual(after["ok"] as? Bool, false, "a hidden quick terminal should be refused again: \(after)")
        XCTAssertEqual(after["error"] as? String, "surface not available: quick")
    }

    // a HUD fills `overlaySurface` while `tree` omits the overlay surface and zoom rejects it, so a guessed
    // id read the app's own message painter. The program overlay proves the refusal is the gate, not a dead path.
    func testSurfaceCursorRefusesAHudInTheOverlaySlotButReadsAProgramOverlay() throws {
        let sessionID = try activeSessionID()
        let overlayID = "surface:\(sessionID):overlay"

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.hud.open","args":{"message":"cursor hud"}}"#)["ok"] as? Bool,
                       true, "opening a hud should succeed")
        let hud = try sendCommand(#"{"cmd":"surface.cursor","target":"\#(overlayID)"}"#)
        XCTAssertEqual(hud["ok"] as? Bool, false, "a hud must not be readable through the overlay id: \(hud)")
        XCTAssertEqual(hud["error"] as? String, "surface not available: \(overlayID)")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.hud.close"}"#)["ok"] as? Bool, true,
                       "closing the hud should succeed")

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.overlay.open","args":{"command":"sleep 300"}}"#)["ok"] as? Bool,
                       true, "opening a program overlay should succeed")
        XCTAssertNotNil(settledCursorColumn(target: overlayID, timeout: 15),
                        "a program overlay in the same slot should report a column")
    }

    // MARK: - Helpers

    /// A single cursor read, nil on any refusal. Silent because the pollers below run it while a surface is
    /// still coming up: `quick show` and `overlay.open` both answer `surface not realized` for a moment, the
    /// same readiness gap `quick.type`/`quick.text` poll through.
    private func cursorColumnOrNil(target: String? = nil) -> Int? {
        let response = try? sendCommand(target.map { #"{"cmd":"surface.cursor","target":"\#($0)"}"# }
            ?? #"{"cmd":"surface.cursor"}"#)
        guard let result = response?["result"] as? [String: Any],
              let cursor = result["cursor"] as? [String: Any] else { return nil }
        return cursor["column"] as? Int
    }

    /// A column read twice in a row with the same value. The marker file proves the command RAN, not that the
    /// shell has finished redrawing its next prompt, so a bare single read can sample the executing command's
    /// caret and every later expectation is then off by the prompt width.
    private func settledCursorColumn(target: String? = nil, timeout: TimeInterval) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        var previous: Int?
        while Date() < deadline {
            let current = cursorColumnOrNil(target: target)
            if let current, current == previous { return current }
            previous = current
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return nil
    }

    private func pollCursorColumn(_ expected: Int, target: String? = nil, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cursorColumnOrNil(target: target) == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    private func waitForPrompt(_ sessionID: String, marker: String, pane: String? = nil) throws {
        let file = markerDir.appendingPathComponent(marker)
        let value = try typeUntilMarker("printf READY > '\(file.path)'\n",
                                        target: sessionID, file: file, select: false, pane: pane)
        XCTAssertEqual(value, "READY", "the \(pane ?? "left") pane's shell should be reading commands")
    }

    private func type(_ text: String, into sessionID: String, pane: String?) throws {
        XCTAssertEqual(try sendCommand(typeRequest(text: text, target: sessionID, select: false, pane: pane))["ok"] as? Bool,
                       true, "typing into the \(pane ?? "left") pane should succeed")
    }
}
