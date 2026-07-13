import Foundation
import XCTest

// Verifies the `CustomCommandRunner` pane derivation that populates `{AGT_PANE}`/`$AGT_PANE`: a custom
// command reports the pane it fired FROM — "left" (main), "right" (split), or "scratch" (the session's
// scratch terminal). This is the only test that pins that logic. The keybind path derives the pane from
// the focused SURFACE's identity (NOT the session's `splitFocused` flag), and the palette path from the
// flag. The probe command writes `$AGT_PANE` to a marker file, which the test reads back. A
// `ControlAPITestCase` subclass so it can split/focus/scratch panes over the control socket while firing
// real keystrokes for the keybind path.
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

    // keybind path, SCRATCH: open the session's scratch terminal over the socket (it auto-focuses on
    // show), then fire the SAME chord from it → "scratch". This is the app-side proof of
    // `runFromSessionlessSurface`'s scratch branch: the scratch surface has no `view.session`, so the
    // runner identifies it as the ACTIVE session's `scratchSurface` and reports `.scratch`, the read leg
    // of the `$AGT_PANE` → `session type --pane scratch` round-trip. The host-free tests can't reach the
    // runner. The quick terminal and overlays deliberately have no pane value (their state is on `tree`).
    func testAgtPaneKeybindReportsScratch() throws {
        let marker = markerDir.appendingPathComponent("agt-pane-scratch")
        try relaunch(withKeymap: "command \"Pane Probe\" cmd+shift+e printf %s \"$AGT_PANE\" > \"\(marker.path)\"\n")

        focusMainTerminal()
        let scratch = try sendCommand(#"{"cmd":"session.scratch","target":"active","args":{"mode":"on"}}"#)
        XCTAssertEqual(scratch["ok"] as? Bool, true, "scratch on should succeed: \(scratch)")
        // wait for the scratch surface to realize (shell spawned, readable) so the focus it grabs is real.
        XCTAssertTrue(pollScratchRealized(timeout: 10), "the control-opened scratch should realize its surface")
        app.activate()

        // the scratch auto-focuses on show, but that focus is async — retry the chord until it reports the
        // scratch (a chord landing before the scratch grabs first responder reports the main pane).
        XCTAssertEqual(fireUntil("scratch", marker: marker) { self.app.typeKey("e", modifierFlags: [.command, .shift]) },
                       "scratch", "a chord fired from the scratch terminal should report $AGT_PANE=scratch")
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
    // promotes the survivor INTO the main slot (surface=survivor, splitSurface=nil, hasSplit=false,
    // splitFocused=false — a plain single pane). {AGT_PANE} must report "left": the survivor is now the
    // main pane, and `session.type --pane left` reaches it. Then prove the round-trip the token exists
    // for: `session.type --pane <reported>` lands in the promoted pane's own buffer.
    func testAgtPanePromotedSurvivorReportsLeft() throws {
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

        // palette path: the promoted survivor is now the main pane (splitSurface == nil, splitFocused ==
        // false), so run() reports left.
        try? FileManager.default.removeItem(at: marker)
        runFromCustomCommandsPalette("Pane Probe")
        let reported = pollMarker(marker, timeout: 5)
        XCTAssertEqual(reported, "left", "a promoted split survivor is the main pane, so $AGT_PANE=left")

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
