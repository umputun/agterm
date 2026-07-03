import Foundation
import XCTest

// Verifies the `CustomCommandRunner` pane derivation that populates `{AGT_PANE}`/`$AGT_PANE`: a custom
// command reports the pane it fired FROM — "left" (main) or "right" (split). This is the only test that
// pins that logic. The keybind path derives the pane from the focused SURFACE's identity (NOT the
// session's `splitFocused` flag), and the palette path from the flag. The probe command writes
// `$AGT_PANE` to a marker file, which the test reads back. A `ControlAPITestCase` subclass so it can
// split/focus panes over the control socket while firing real keystrokes for the keybind path.
@MainActor
final class CustomCommandPaneTokenUITests: ControlAPITestCase {
    // keybind path: fire the SAME chord from the main pane (no split) and then from the split's focused
    // right pane; $AGT_PANE must be "left" then "right", exercising both branches of `runFromKeybind`'s
    // surface-identity derivation end-to-end through the real NSEvent monitor.
    //
    // NOTE: this does NOT isolate "surface identity" from "the splitFocused flag" — in both fired states
    // the flag and the actual first responder AGREE (the surfaces' onFocusChange closures keep splitFocused
    // synced to real focus), so a regression deriving the pane from splitFocused would pass here too. A
    // flag-vs-focus divergence isn't deterministically reproducible: the only way to set the flag without a
    // focus change is `session.split on` over the socket, after which the main surface is re-hosted into the
    // HSplitView and holds no reliable first responder — so the chord's "a GhosttySurfaceView must hold
    // first responder" gate can't be pinned. The surface-identity choice itself is covered by inspection
    // (`CustomCommandRunner.runFromKeybind`) plus the promoted-survivor reasoning in keymap.md.
    func testAgtPaneKeybindReflectsFiredFromPane() throws {
        let marker = markerDir.appendingPathComponent("agt-pane-keybind")
        // ⌘⇧E → write $AGT_PANE to the marker. The runner already wraps the line in `/bin/sh -c`, so
        // `$AGT_PANE` expands from the exported env; no inner `sh -c` is needed.
        try relaunch(withKeymap: "command \"Pane Probe\" cmd+shift+e printf %s \"$AGT_PANE\" > \"\(marker.path)\"\n")

        // MAIN pane (no split yet): focus the seeded terminal, fire the chord → "left".
        focusMainTerminal()
        XCTAssertEqual(firePaneProbe(marker) { self.app.typeKey("e", modifierFlags: [.command, .shift]) }, "left",
                       "a chord fired from the main pane should report $AGT_PANE=left")

        // SPLIT right pane: split on, move keyboard focus to the right pane, fire the SAME chord → "right".
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

    // palette path: the runner's `run(_:)` (no fired-from surface to key off) derives the pane from the
    // active session's `splitFocused` flag. Split on + focus right, then run the command from the Custom
    // Commands palette; opening the menu doesn't touch `splitFocused`, so the flag stays true → "right".
    func testAgtPanePaletteUsesFocusedPane() throws {
        let marker = markerDir.appendingPathComponent("agt-pane-palette")
        // no chord → palette-only (the `printf` token is not a valid chord, so the whole remainder is the
        // shell line).
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

    // palette path, default (no split): the seeded session has no split, so `run(_:)`'s
    // `splitFocused ? .right : .left` takes the `.left` branch — the common case, and the half of that
    // ternary the split+focus-right test above never exercises through the real runner. Pins that a
    // swapped ternary or a hardcoded `.right` in the palette path would be caught.
    func testAgtPanePaletteDefaultsToLeftWithoutSplit() throws {
        let marker = markerDir.appendingPathComponent("agt-pane-palette-left")
        try relaunch(withKeymap: "command \"Pane Probe\" printf %s \"$AGT_PANE\" > \"\(marker.path)\"\n")

        // no split on the seeded session → the active pane is the main pane, so the palette path reports left.
        try? FileManager.default.removeItem(at: marker)
        runFromCustomCommandsPalette("Pane Probe")
        XCTAssertEqual(pollMarker(marker, timeout: 5), "left",
                       "a command run from the palette with no split should report $AGT_PANE=left")
    }

    // promoted single-pane: split on, then exit the PRIMARY (main/left) shell so `closePrimaryPane`
    // promotes the survivor into the `splitSurface` slot (hasSplit=false, splitFocused=true, surface=nil).
    // {AGT_PANE} must report "right": the survivor physically lives in splitSurface, so that's the pane
    // `session.type --pane` reaches — a "left" here would name the torn-down main surface. Then prove the
    // round-trip the token exists for: `session.type --pane <reported>` lands in the survivor's own buffer.
    // This is the edge the review went back and forth on (reword-not-gate).
    func testAgtPanePromotedSurvivorReportsRight() throws {
        let marker = markerDir.appendingPathComponent("agt-pane-promoted")
        try relaunch(withKeymap: "command \"Pane Probe\" printf %s \"$AGT_PANE\" > \"\(marker.path)\"\n")

        let split = try sendCommand(#"{"cmd":"session.split","target":"active","args":{"mode":"on"}}"#)
        XCTAssertEqual(split["ok"] as? Bool, true, "split on should succeed: \(split)")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the active session should report split:true")
        let activeID = try activeSessionID()

        // a no-pane session.type injects into the main (left) surface regardless of focus, so `exit` closes
        // the primary pane; with a live split pane, `closePrimaryPane` promotes the survivor rather than
        // closing the session. Retry the exit until the split flag drops (the shell may not be at a prompt
        // for the first keystrokes — the same readiness idiom the pane-text polls use).
        var promoted = false
        for _ in 0..<5 {
            _ = try sendCommand(typeRequest(text: "exit\n", target: activeID, select: false))
            if pollActiveSessionSplit(false, timeout: 4) { promoted = true; break }
        }
        XCTAssertTrue(promoted, "exiting the primary pane should promote the survivor to a single (non-split) pane")

        // palette path: the promoted survivor has splitFocused=true AND splitSurface != nil, so run() reports right.
        try? FileManager.default.removeItem(at: marker)
        runFromCustomCommandsPalette("Pane Probe")
        let reported = pollMarker(marker, timeout: 5)
        XCTAssertEqual(reported, "right", "a promoted split survivor should report $AGT_PANE=right")

        // round-trip: session.type --pane <reported> must reach THAT pane's buffer (the survivor). Typed as
        // `$((6*7))` arithmetic so a match proves the survivor's shell RAN the line, not merely echoed it.
        let pane = try XCTUnwrap(reported)
        let tag = "PROMO-\(UUID().uuidString.prefix(8))"
        let text = try pollPaneText(target: activeID, pane: pane, contains: "\(tag)-42", retype: {
            _ = try self.sendCommand(self.typeRequest(text: "echo \(tag)-$((6*7))\n", target: activeID,
                                                      select: false, pane: pane))
        })
        XCTAssertNotNil(text, "session.type --pane \(pane) should reach the promoted survivor")
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
}
