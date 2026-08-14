import Foundation
import XCTest

// Pins the `CustomCommandRunner` pane derivation behind `{AGT_PANE}`/`$AGT_PANE`: the keybind path derives
// the pane from the focused SURFACE's identity (NOT the session's `splitFocused` flag), the palette path
// from the flag. The probe command writes `$AGT_PANE` to a marker file, which the test reads back.
@MainActor
final class CustomCommandPaneTokenUITests: ControlAPITestCase {
    // NOTE: this does NOT isolate "surface identity" from "the splitFocused flag" — in both fired states the
    // flag and the actual first responder AGREE, so a regression deriving the pane from splitFocused would
    // pass here too. A divergence isn't deterministically reproducible: only `session.split on` over the
    // socket sets the flag without a focus change, and the main surface is then re-hosted into the HSplitView
    // holding no reliable first responder, so the chord's first-responder gate can't be pinned.
    func testAgtPaneKeybindReflectsFiredFromPane() throws {
        let marker = markerDir.appendingPathComponent("agt-pane-keybind")
        // the runner already wraps the line in `/bin/sh -c`, so `$AGT_PANE` expands with no inner `sh -c`.
        try relaunch(withKeymap: "command \"Pane Probe\" cmd+shift+e printf %s \"$AGT_PANE\" > \"\(marker.path)\"\n")

        focusMainTerminal()
        XCTAssertEqual(firePaneProbe(marker) { self.app.typeKey("e", modifierFlags: [.command, .shift]) }, "left",
                       "a chord fired from the main pane should report $AGT_PANE=left")

        let split = try sendCommand(#"{"cmd":"session.split","target":"active","args":{"mode":"on"}}"#)
        XCTAssertEqual(split["ok"] as? Bool, true, "split on should succeed: \(split)")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the active session should report split:true")
        let activeID = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.focus","target":"\#(activeID)","args":{"pane":"right"}}"#)["ok"] as? Bool,
                       true, "focus right should succeed")
        app.activate()
        XCTAssertEqual(firePaneProbe(marker) { self.app.typeKey("e", modifierFlags: [.command, .shift]) }, "right",
                       "a chord fired from the split's right pane should report $AGT_PANE=right")
    }

    // the scratch surface has no `view.session`, so `runFromSessionlessSurface` must identify it as the ACTIVE
    // session's `scratchSurface` — the read leg of the `$AGT_PANE` → `session type --pane scratch` round-trip.
    func testAgtPaneKeybindReportsScratch() throws {
        let marker = markerDir.appendingPathComponent("agt-pane-scratch")
        try relaunch(withKeymap: "command \"Pane Probe\" cmd+shift+e printf %s \"$AGT_PANE\" > \"\(marker.path)\"\n")

        focusMainTerminal()
        let scratch = try sendCommand(#"{"cmd":"session.scratch","target":"active","args":{"mode":"on"}}"#)
        XCTAssertEqual(scratch["ok"] as? Bool, true, "scratch on should succeed: \(scratch)")
        XCTAssertTrue(pollScratchRealized(timeout: 10), "the control-opened scratch should realize its surface")
        app.activate()

        // the scratch's auto-focus on show is async, so a chord landing before it grabs first responder
        // reports the main pane — retry until it reports the scratch.
        XCTAssertEqual(fireUntil("scratch", marker: marker) { self.app.typeKey("e", modifierFlags: [.command, .shift]) },
                       "scratch", "a chord fired from the scratch terminal should report $AGT_PANE=scratch")
    }

    // `run(_:)` has no fired-from surface to key off, so it derives the pane from `splitFocused`; opening the
    // palette menu doesn't touch that flag, so it stays true across the run.
    func testAgtPanePaletteUsesFocusedPane() throws {
        let marker = markerDir.appendingPathComponent("agt-pane-palette")
        // no chord, so the `printf` token is not read as one and the whole remainder is the shell line.
        try relaunch(withKeymap: "command \"Pane Probe\" printf %s \"$AGT_PANE\" > \"\(marker.path)\"\n")

        let split = try sendCommand(#"{"cmd":"session.split","target":"active","args":{"mode":"on"}}"#)
        XCTAssertEqual(split["ok"] as? Bool, true, "split on should succeed: \(split)")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the active session should report split:true")
        let activeID = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.focus","target":"\#(activeID)","args":{"pane":"right"}}"#)["ok"] as? Bool,
                       true, "focus right should succeed")

        try? FileManager.default.removeItem(at: marker)
        runFromCustomCommandsPalette("Pane Probe")
        XCTAssertEqual(pollMarker(marker, timeout: 5), "right",
                       "a command run from the palette while the right pane is focused should report $AGT_PANE=right")
    }

    // the `.left` half of `run(_:)`'s `splitFocused ? .right : .left`, which the split+focus-right test above
    // never exercises — without it a swapped ternary or a hardcoded `.right` would go unnoticed.
    func testAgtPanePaletteDefaultsToLeftWithoutSplit() throws {
        let marker = markerDir.appendingPathComponent("agt-pane-palette-left")
        try relaunch(withKeymap: "command \"Pane Probe\" printf %s \"$AGT_PANE\" > \"\(marker.path)\"\n")

        try? FileManager.default.removeItem(at: marker)
        runFromCustomCommandsPalette("Pane Probe")
        XCTAssertEqual(pollMarker(marker, timeout: 5), "left",
                       "a command run from the palette with no split should report $AGT_PANE=left")
    }

    // exiting the PRIMARY shell makes `closePrimaryPane` promote the survivor INTO the main slot
    // (splitSurface=nil, hasSplit=false, splitFocused=false), so the survivor must report "left" and
    // `session.type --pane left` must reach it.
    func testAgtPanePromotedSurvivorReportsLeft() throws {
        let marker = markerDir.appendingPathComponent("agt-pane-promoted")
        try relaunch(withKeymap: "command \"Pane Probe\" printf %s \"$AGT_PANE\" > \"\(marker.path)\"\n")

        let split = try sendCommand(#"{"cmd":"session.split","target":"active","args":{"mode":"on"}}"#)
        XCTAssertEqual(split["ok"] as? Bool, true, "split on should succeed: \(split)")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the active session should report split:true")
        let activeID = try activeSessionID()

        // a no-pane session.type injects into the main surface regardless of focus, so this `exit` closes the
        // primary pane. Retry it: the shell may not be at a prompt yet for the first keystrokes.
        var promoted = false
        for _ in 0..<5 {
            _ = try sendCommand(typeRequest(text: "exit\n", target: activeID, select: false))
            if pollActiveSessionSplit(false, timeout: 4) { promoted = true; break }
        }
        XCTAssertTrue(promoted, "exiting the primary pane should promote the survivor to a single (non-split) pane")

        try? FileManager.default.removeItem(at: marker)
        runFromCustomCommandsPalette("Pane Probe")
        let reported = pollMarker(marker, timeout: 5)
        XCTAssertEqual(reported, "left", "a promoted split survivor is the main pane, so $AGT_PANE=left")

        // typed as `$((6*7))` arithmetic so a match proves the survivor's shell RAN the line, not echoed it.
        let pane = try XCTUnwrap(reported)
        let tag = "PROMO-\(UUID().uuidString.prefix(8))"
        let text = try pollPaneText(target: activeID, pane: pane, contains: "\(tag)-42", retype: {
            _ = try self.sendCommand(self.typeRequest(text: "echo \(tag)-$((6*7))\n", target: activeID,
                                                      select: false, pane: pane))
        })
        XCTAssertNotNil(text, "session.type --pane \(pane) should reach the promoted survivor")
    }

    // #434: an overlay view is sessionless, so the chord took the palette path and read the pane UNDER the
    // overlay. DISCRIMINATING on both tokens at once — the selection proves which surface was read, and the
    // pane proves the reply still routes to the one the user returns to.
    func testAgtSelectionAndPaneInsideAnOverlay() throws {
        let marker = markerDir.appendingPathComponent("agt-overlay-selection")
        try relaunch(withKeymap:
            "command \"Sel Probe\" cmd+shift+e printf %s \"$AGT_PANE|$AGT_SELECTION\" > \"\(marker.path)\"\n")

        focusMainTerminal()
        let id = try activeSessionID()
        let ovlJSON = try! JSONSerialization.data(withJSONObject:
            ["cmd": "session.overlay.open", "target": id, "args": ["command": "sh -c 'echo OVLPICK; cat'"]])
        XCTAssertEqual(try sendCommand(String(data: ovlJSON, encoding: .utf8)!)["ok"] as? Bool, true,
                       "overlay open should succeed")
        // wait on the overlay's own buffer rather than the model flag, which is set before the surface
        // realizes: the chord below needs a terminal that exists and a shell that has already printed.
        var drawn = false
        let deadline = Date().addingTimeInterval(15)
        while !drawn, Date() < deadline {
            let read = try sendCommand(#"{"cmd":"session.overlay.text","target":"\#(id)"}"#)
            drawn = (((read["result"] as? [String: Any])?["text"] as? String) ?? "").contains("OVLPICK")
            if !drawn { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        }
        XCTAssertTrue(drawn, "the overlay's program should have drawn before the chord fires")

        // Select All reaches the first responder, so it selects the OVERLAY's buffer once that has focus.
        // Both it and the chord ride the same async focus grab, so retry the pair until the selection lands.
        app.activate()
        var reported: String?
        for _ in 0..<12 {
            try? FileManager.default.removeItem(at: marker)
            app.typeKey("a", modifierFlags: .command)
            app.typeKey("e", modifierFlags: [.command, .shift])
            if let seen = pollMarker(marker, timeout: 2) {
                reported = seen
                if seen.contains("OVLPICK") { break }
            }
        }
        let value = try XCTUnwrap(reported, "the chord should fire while the overlay holds focus")
        let parts = value.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        XCTAssertEqual(parts.first.map(String.init), "left",
                       "an overlay names the pane underneath it, so the reply routes back there")
        XCTAssertTrue(parts.count == 2 && parts[1].contains("OVLPICK"),
                      "$AGT_SELECTION must come from the overlay, not the pane it covers: \(value)")
    }

    // MARK: - Helpers

    /// Click the seeded session row so the main terminal surface is first responder (the custom-command
    /// monitor only fires when a `GhosttySurfaceView` holds first responder). Drains until the row reports
    /// selected so the responder bounce settles before a chord is pressed.
    private func focusMainTerminal() {
        let row = app.staticTexts["session-row"].firstMatch
        XCTAssertTrue(row.waitForHittable(timeout: 20), "seeded session should be hittable")
        row.click()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, row.isSelected == false {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// Fire `press` and read the marker back, retrying: a chord can land before the surface is genuinely
    /// first responder (focus return is async) and be dropped. Clears the marker before each attempt so a
    /// prior attempt's write can't be misread. Returns the trimmed value, or nil on timeout.
    private func firePaneProbe(_ marker: URL, attempts: Int = 8, perAttempt: TimeInterval = 2,
                               press: () -> Void) -> String? {
        for _ in 0..<attempts {
            try? FileManager.default.removeItem(at: marker)
            press()
            if let value = pollMarker(marker, timeout: perAttempt) { return value }
        }
        return nil
    }

    /// Open Navigate ▸ Custom Commands, filter to `name`, and run the top match (Return).
    private func runFromCustomCommandsPalette(_ name: String) {
        app.menuBars.menuBarItems["Navigate"].click()
        let item = app.menuItems["Custom Commands"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Navigate menu should offer Custom Commands")
        item.click()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "palette search field should appear")
        field.click()
        field.typeText(name)
        app.typeKey(.return, modifierFlags: [])
    }

    /// Poll `session.text --pane scratch` until it returns ok, proving the scratch surface has realized
    /// (shell spawned, surface mounted) so the first responder it grabs on show is real.
    private func pollScratchRealized(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let response = try? sendCommand(#"{"cmd":"session.text","target":"active","args":{"pane":"scratch"}}"#),
               response["ok"] as? Bool == true { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    /// Fire `press` repeatedly, clearing the marker each attempt, until it reads `expected` — tolerating
    /// intermediate values while an async focus change settles. Returns the last value seen, or nil on
    /// timeout, so a failed assertion shows what it actually reported.
    private func fireUntil(_ expected: String, marker: URL, attempts: Int = 12, perAttempt: TimeInterval = 2,
                           press: () -> Void) -> String? {
        var last: String?
        for _ in 0..<attempts {
            try? FileManager.default.removeItem(at: marker)
            press()
            if let value = pollMarker(marker, timeout: perAttempt) {
                last = value
                if value == expected { return value }
            }
        }
        return last
    }
}
