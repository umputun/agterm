import Foundation
import XCTest

/// Control-channel e2e for pane-aware agent status: a `blocked` status tagged with the pane that set it
/// (`session.status --pane left|right|scratch`) must survive typing in a DIFFERENT pane, and every
/// user-initiated GUI selection must reveal the pane that actually blocked.
///
/// Reveal oracle: the reveal sets the MODEL flags `splitFocused` / `scratchActive` synchronously and
/// `Session.onScreenSurface` follows them, so `session.text` with NO `--pane` reflects the reveal
/// immediately, independent of the best-effort AppKit `makeFirstResponder` retry. Each pane carries a
/// distinct echo marker, so the no-pane read tells the panes apart. The control `session.go
/// next-attention` is reveal-free, so only a menu key-equivalent / click / palette pick exercises it.
///
/// Clear oracle: the keyboard-driven clear is wired off the real `keyDown`, so it MUST be driven by the
/// synthesized keyboard. `session.type` reaches the same pane-scoped clear through `injectAsUserInput`
/// rather than `keyDown`, so it clears its own pane too — but never on an empty payload, which queues no
/// keystrokes. The sidebar glyph (`agent-status`) is the observable.
@MainActor
final class PaneAwareStatusUITests: ControlAPITestCase {
    func testAttentionNavRevealsBlockedSplitPane() throws {
        let sessionA = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(sessionA)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "split on should succeed")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the session should report split:true")

        let leftTag = "PAWL-\(UUID().uuidString.prefix(8))"
        let rightTag = "PAWR-\(UUID().uuidString.prefix(8))"
        try seedPaneMarker(target: sessionA, pane: "left", tag: leftTag)
        try seedPaneMarker(target: sessionA, pane: "right", tag: rightTag)

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.focus","target":"\#(sessionA)","args":{"pane":"left"}}"#)["ok"] as? Bool,
                       true, "focusing the left pane should succeed")
        XCTAssertTrue(try pollOnScreen(target: sessionA, contains: "\(leftTag)-42"),
                      "with the left pane focused, the on-screen surface should be the main pane")

        try blockPane("right", target: sessionA)
        XCTAssertEqual(try statusPane(of: sessionA), "right", "the block should be tagged right")
        let sessionB = try parkOnNewSession()

        attentionNavDown()

        XCTAssertTrue(try pollActiveNode(equals: sessionA, timeout: 12), "attention-nav should land on the blocked session")
        XCTAssertTrue(try pollOnScreen(target: sessionA, contains: "\(rightTag)-42"),
                      "the reveal should make the split (right) pane the on-screen surface")
        let onScreen = try XCTUnwrap(onScreenText(sessionA), "the on-screen read should return text")
        XCTAssertFalse(onScreen.contains("\(leftTag)-42"), "the revealed right pane must not carry the main pane's marker")
        XCTAssertNotEqual(sessionB, sessionA, "sanity: the parked session is distinct")
    }

    // both directions are selection no-ops here — `navigateSession` returns nil after wrapping back onto the
    // current row — so the reveal has to come from the live indicator instead.
    func testAttentionNavRevealsTaggedPaneWhenSoleAttentionSessionIsAlreadySelected() throws {
        let sessionA = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(sessionA)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "split on should succeed")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the session should report split:true")

        let leftTag = "PAWNL-\(UUID().uuidString.prefix(8))"
        let rightTag = "PAWNR-\(UUID().uuidString.prefix(8))"
        try seedPaneMarker(target: sessionA, pane: "left", tag: leftTag)
        try seedPaneMarker(target: sessionA, pane: "right", tag: rightTag)

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.focus","target":"\#(sessionA)","args":{"pane":"left"}}"#)["ok"] as? Bool,
                       true, "focusing the left pane should succeed")
        XCTAssertTrue(try pollOnScreen(target: sessionA, contains: "\(leftTag)-42"),
                      "the selected session should start with its primary pane on-screen")
        try blockPane("right", target: sessionA)

        attentionNavDown()

        XCTAssertTrue(try pollActiveNode(equals: sessionA, timeout: 12),
                      "next-attention should keep the sole attention session selected")
        XCTAssertTrue(try pollOnScreen(target: sessionA, contains: "\(rightTag)-42"),
                      "next-attention should reveal the selected session's tagged right pane")

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.focus","target":"\#(sessionA)","args":{"pane":"left"}}"#)["ok"] as? Bool,
                       true, "focusing the left pane again should succeed")
        XCTAssertTrue(try pollOnScreen(target: sessionA, contains: "\(leftTag)-42"),
                      "the primary pane should be on-screen again before previous-attention")

        attentionNavUp()

        XCTAssertTrue(try pollActiveNode(equals: sessionA, timeout: 12),
                      "previous-attention should keep the sole attention session selected")
        XCTAssertTrue(try pollOnScreen(target: sessionA, contains: "\(rightTag)-42"),
                      "previous-attention should reveal the selected session's tagged right pane")
    }

    // the inverse of the test above: `selectSession` does not short-circuit a same-target select, so a plain
    // nav that moved nothing still hands back an indicator — revealing on it would clear `splitFocused`.
    func testPlainNavNoOpKeepsTheFocusedSplitPane() throws {
        let sessionA = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(sessionA)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "split on should succeed")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the session should report split:true")

        let leftTag = "PNOL-\(UUID().uuidString.prefix(8))"
        let rightTag = "PNOR-\(UUID().uuidString.prefix(8))"
        try seedPaneMarker(target: sessionA, pane: "left", tag: leftTag)
        try seedPaneMarker(target: sessionA, pane: "right", tag: rightTag)

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.focus","target":"\#(sessionA)","args":{"pane":"right"}}"#)["ok"] as? Bool,
                       true, "focusing the right pane should succeed")
        XCTAssertTrue(try pollOnScreen(target: sessionA, contains: "\(rightTag)-42"),
                      "the split pane should be the on-screen surface before nav")
        // an UNTAGGED block (what a plain `agtermctl session status blocked` sends) is treated as `left`, so
        // it survives the user working in the right pane.
        try blockPane("blocked", pane: nil, target: sessionA)

        // narrow the navigable set to this one session so ⌥⌘↓ wraps onto it instead of moving elsewhere.
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.flag","target":"\#(sessionA)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "flagging the session should succeed")
        XCTAssertEqual(try sendCommand(#"{"cmd":"sidebar.mode","args":{"mode":"flagged"}}"#)["ok"] as? Bool,
                       true, "switching to flagged mode should succeed")

        app.typeKey(.downArrow, modifierFlags: [.command, .option])

        XCTAssertTrue(try pollActiveNode(equals: sessionA, timeout: 12),
                      "the wrapping step should keep the same session selected")
        XCTAssertFalse(try pollOnScreen(target: sessionA, contains: "\(leftTag)-42", timeout: 3),
                       "a plain nav that moved nothing must not pull the on-screen surface onto the primary pane")
        XCTAssertTrue(try pollOnScreen(target: sessionA, contains: "\(rightTag)-42"),
                      "the split pane the user was working in should still be the on-screen surface")
    }

    func testAttentionNavRevealsHiddenSplit() throws {
        let sessionA = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(sessionA)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "split on should succeed")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the session should report split:true")

        let leftTag = "PAWHL-\(UUID().uuidString.prefix(8))"
        let rightTag = "PAWHR-\(UUID().uuidString.prefix(8))"
        try seedPaneMarker(target: sessionA, pane: "left", tag: leftTag)
        try seedPaneMarker(target: sessionA, pane: "right", tag: rightTag)

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.focus","target":"\#(sessionA)","args":{"pane":"left"}}"#)["ok"] as? Bool,
                       true, "focusing the left pane should succeed")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(sessionA)","args":{"mode":"off"}}"#)["ok"] as? Bool,
                       true, "split off (hide) should succeed")
        XCTAssertTrue(pollActiveSessionSplit(false, timeout: 10), "the split should be hidden (split:false)")
        XCTAssertTrue(try pollOnScreen(target: sessionA, contains: "\(leftTag)-42"),
                      "the hidden split should show the focused main pane maximized")

        try blockPane("right", target: sessionA)
        _ = try parkOnNewSession()

        attentionNavDown()

        XCTAssertTrue(try pollActiveNode(equals: sessionA, timeout: 12), "attention-nav should land on the blocked session")
        XCTAssertTrue(try pollOnScreen(target: sessionA, contains: "\(rightTag)-42"),
                      "the reveal should swap the hidden split to show the right pane maximized")
        XCTAssertEqual(try sessionNode(id: sessionA)["split"] as? Bool, false,
                       "the split stays hidden after the reveal — the right pane is shown maximized, not side-by-side")
    }

    func testAttentionNavRevealsHiddenScratch() throws {
        let sessionA = try activeSessionID()
        let mainTag = "PAWSM-\(UUID().uuidString.prefix(8))"
        let scratchTag = "PAWSS-\(UUID().uuidString.prefix(8))"
        try seedPaneMarker(target: sessionA, pane: "left", tag: mainTag)

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.scratch","target":"\#(sessionA)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "scratch on should succeed")
        XCTAssertTrue(try pollScratch(id: sessionA, equals: true, timeout: 10), "the scratch should be shown")
        try seedPaneMarker(target: sessionA, pane: "scratch", tag: scratchTag)
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.scratch","target":"\#(sessionA)","args":{"mode":"off"}}"#)["ok"] as? Bool,
                       true, "scratch off (hide) should succeed")
        XCTAssertTrue(try pollScratch(id: sessionA, equals: false, timeout: 10), "the scratch should be hidden")
        XCTAssertTrue(try pollOnScreen(target: sessionA, contains: "\(mainTag)-42"),
                      "with the scratch hidden, the main pane should be on-screen")

        try blockPane("scratch", target: sessionA)
        XCTAssertEqual(try statusPane(of: sessionA), "scratch", "the block should be tagged scratch")
        _ = try parkOnNewSession()

        attentionNavDown()

        XCTAssertTrue(try pollActiveNode(equals: sessionA, timeout: 12), "attention-nav should land on the blocked session")
        XCTAssertTrue(try pollScratch(id: sessionA, equals: true, timeout: 12), "the reveal should show the hidden scratch")
        XCTAssertTrue(try pollOnScreen(target: sessionA, contains: "\(scratchTag)-42"),
                      "the revealed scratch should be the on-screen surface")
        let onScreen = try XCTUnwrap(onScreenText(sessionA), "the on-screen read should return text")
        XCTAssertFalse(onScreen.contains("\(mainTag)-42"), "the revealed scratch must not carry the main pane's marker")
    }

    // with the scratch covering the panes both focus paths resolve to it, so the reveal has to HIDE the
    // covering scratch before the blocked right pane can surface.
    func testAttentionNavRevealsSplitBehindShownScratch() throws {
        let sessionA = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(sessionA)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "split on should succeed")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the session should report split:true")

        let leftTag = "PAWCL-\(UUID().uuidString.prefix(8))"
        let rightTag = "PAWCR-\(UUID().uuidString.prefix(8))"
        try seedPaneMarker(target: sessionA, pane: "left", tag: leftTag)
        try seedPaneMarker(target: sessionA, pane: "right", tag: rightTag)

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.focus","target":"\#(sessionA)","args":{"pane":"left"}}"#)["ok"] as? Bool,
                       true, "focusing the left pane should succeed")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.scratch","target":"\#(sessionA)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "scratch on should succeed")
        XCTAssertTrue(try pollScratch(id: sessionA, equals: true, timeout: 10), "the scratch should cover the panes")

        try blockPane("right", target: sessionA)
        XCTAssertEqual(try statusPane(of: sessionA), "right", "the block should be tagged right")
        _ = try parkOnNewSession()

        attentionNavDown()

        XCTAssertTrue(try pollActiveNode(equals: sessionA, timeout: 12), "attention-nav should land on the blocked session")
        XCTAssertTrue(try pollScratch(id: sessionA, equals: false, timeout: 12),
                      "the reveal should hide the covering scratch to expose the blocked pane")
        XCTAssertTrue(try pollOnScreen(target: sessionA, contains: "\(rightTag)-42"),
                      "with the scratch hidden, the split (right) pane should be the on-screen surface")
        let onScreen = try XCTUnwrap(onScreenText(sessionA), "the on-screen read should return text")
        XCTAssertFalse(onScreen.contains("\(leftTag)-42"), "the revealed right pane must not carry the main pane's marker")
    }

    func testMainPaneTypingSurvivesBackgroundPaneBlock() throws {
        let sessionA = try activeSessionID()
        // put first responder in the main pane so the synthesized Escape reaches its keyDown.
        app.staticTexts["session-row"].firstMatch.click()
        usleep(800_000)

        // the `right` case needs a LIVE split: without one `setAgentIndicator` coerces a `.right` tag to
        // `.left`, handing the block to the very pane this test types into, and the Escape would clear it.
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(sessionA)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "session.split on should succeed")
        XCTAssertTrue(try pollSplit(sessionA, timeout: 10), "the split should be live before tagging the right pane")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.focus","target":"\#(sessionA)","args":{"pane":"left"}}"#)["ok"] as? Bool,
                       true, "session.focus left should succeed")
        XCTAssertTrue(try pollSplitFocused(sessionA, expected: false, timeout: 10),
                      "focus should be back on the main pane before typing")
        usleep(800_000)

        for tag in ["right", "scratch"] {
            try blockPane("blocked", pane: tag, target: sessionA)
            XCTAssertTrue(app.staticTexts["agent-status"].waitForExistence(timeout: 12),
                          "a \(tag)-tagged block should show the glyph")
            for _ in 0..<3 { app.typeKey(.escape, modifierFlags: []); usleep(250_000) }
            usleep(600_000)
            XCTAssertTrue(app.staticTexts["agent-status"].exists,
                          "typing in the main pane must NOT clear a \(tag)-tagged block")
            XCTAssertEqual(try sessionNode(id: sessionA)["status"] as? String, "blocked",
                           "the \(tag)-tagged block should still read blocked after main-pane typing")
            // the idle carries the owning pane: an untagged one reads as `left` and the precedence rule
            // refuses it, exactly as it refuses the sibling agent's hook-sent idle.
            try blockPane("idle", pane: tag, target: sessionA)
            XCTAssertTrue(app.staticTexts["agent-status"].waitForNonExistence(timeout: 12), "idle should hide the glyph")
        }

        // positive control: the same Escape DOES clear a left-tagged block, so the survivals above are real
        // pane-scoping and not lost keystrokes.
        try blockPane("blocked", pane: "left", target: sessionA)
        XCTAssertTrue(app.staticTexts["agent-status"].waitForExistence(timeout: 12), "a left-tagged block should show the glyph")
        XCTAssertTrue(typeUntilGlyphCleared(), "typing in the main pane SHOULD clear a left-tagged block (its own pane)")
    }

    func testScratchTypingClearsScratchBlock() throws {
        let sessionA = try activeSessionID()
        try blockPane("scratch", target: sessionA)
        XCTAssertTrue(app.staticTexts["agent-status"].waitForExistence(timeout: 12), "a scratch-tagged block should show the glyph")

        // the scratch's autoFocus grabs first responder, so synthesized keys reach the scratch's keyDown.
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.scratch","target":"\#(sessionA)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "scratch on should succeed")
        XCTAssertTrue(try pollScratch(id: sessionA, equals: true, timeout: 10), "the scratch should be shown")
        usleep(800_000)

        XCTAssertTrue(typeUntilGlyphCleared(), "typing in the scratch SHOULD clear its own scratch-tagged block")
    }

    func testSidebarClickRevealsBlockedSplitPane() throws {
        let sessionA = try activeSessionID()
        // rename the blocked session so its sidebar row is matchable by value, distinct from the parked one.
        let rowName = "PAWCLICK-\(UUID().uuidString.prefix(8))"
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(sessionA)","args":{"name":"\#(rowName)"}}"#)["ok"] as? Bool,
                       true, "renaming the blocked session should succeed")

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(sessionA)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "split on should succeed")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the session should report split:true")

        let leftTag = "PAWKL-\(UUID().uuidString.prefix(8))"
        let rightTag = "PAWKR-\(UUID().uuidString.prefix(8))"
        try seedPaneMarker(target: sessionA, pane: "left", tag: leftTag)
        try seedPaneMarker(target: sessionA, pane: "right", tag: rightTag)

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.focus","target":"\#(sessionA)","args":{"pane":"left"}}"#)["ok"] as? Bool,
                       true, "focusing the left pane should succeed")
        XCTAssertTrue(try pollOnScreen(target: sessionA, contains: "\(leftTag)-42"),
                      "with the left pane focused, the on-screen surface should be the main pane")

        try blockPane("right", target: sessionA)
        XCTAssertEqual(try statusPane(of: sessionA), "right", "the block should be tagged right")
        _ = try parkOnNewSession()

        clickSessionRow(named: rowName)

        XCTAssertTrue(try pollActiveNode(equals: sessionA, timeout: 12), "clicking the row should select the blocked session")
        XCTAssertTrue(try pollOnScreen(target: sessionA, contains: "\(rightTag)-42"),
                      "the reveal should make the split (right) pane the on-screen surface")
        let onScreen = try XCTUnwrap(onScreenText(sessionA), "the on-screen read should return text")
        XCTAssertFalse(onScreen.contains("\(leftTag)-42"), "the revealed right pane must not carry the main pane's marker")
    }

    // the palette-run reveal is dispatched async, after the palette closes and its own focus-restore.
    func testAttentionPaletteRevealsBlockedSplitPane() throws {
        let sessionA = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(sessionA)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "split on should succeed")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the session should report split:true")

        let leftTag = "PAWPL-\(UUID().uuidString.prefix(8))"
        let rightTag = "PAWPR-\(UUID().uuidString.prefix(8))"
        try seedPaneMarker(target: sessionA, pane: "left", tag: leftTag)
        try seedPaneMarker(target: sessionA, pane: "right", tag: rightTag)

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.focus","target":"\#(sessionA)","args":{"pane":"left"}}"#)["ok"] as? Bool,
                       true, "focusing the left pane should succeed")
        XCTAssertTrue(try pollOnScreen(target: sessionA, contains: "\(leftTag)-42"),
                      "with the left pane focused, the on-screen surface should be the main pane")

        // park on a fresh IDLE session so the blocked A is the ONLY attention row and Return picks it.
        try blockPane("right", target: sessionA)
        XCTAssertEqual(try statusPane(of: sessionA), "right", "the block should be tagged right")
        _ = try parkOnNewSession()

        openAttentionPalette()
        XCTAssertTrue(try pollReturnSelects(sessionA, timeout: 12), "choosing the attention row should select the blocked session")

        XCTAssertTrue(try pollOnScreen(target: sessionA, contains: "\(rightTag)-42"),
                      "the palette reveal should make the split (right) pane the on-screen surface")
        let onScreen = try XCTUnwrap(onScreenText(sessionA), "the on-screen read should return text")
        XCTAssertFalse(onScreen.contains("\(leftTag)-42"), "the revealed right pane must not carry the main pane's marker")
    }

    func testSelectingIdleSessionKeepsShownScratch() throws {
        let sessionA = try activeSessionID()
        let rowName = "PAWIDLE-\(UUID().uuidString.prefix(8))"
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(sessionA)","args":{"name":"\#(rowName)"}}"#)["ok"] as? Bool,
                       true, "renaming the session should succeed")

        let mainTag = "PAWIM-\(UUID().uuidString.prefix(8))"
        let scratchTag = "PAWIS-\(UUID().uuidString.prefix(8))"
        try seedPaneMarker(target: sessionA, pane: "left", tag: mainTag)

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.scratch","target":"\#(sessionA)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "scratch on should succeed")
        XCTAssertTrue(try pollScratch(id: sessionA, equals: true, timeout: 10), "the scratch should be shown")
        try seedPaneMarker(target: sessionA, pane: "scratch", tag: scratchTag)
        XCTAssertNil(try statusPane(of: sessionA), "sanity: an idle session carries no status pane")

        _ = try parkOnNewSession()
        clickSessionRow(named: rowName)
        XCTAssertTrue(try pollActiveNode(equals: sessionA, timeout: 12), "clicking the row should select the idle session")

        // the reveal is async, so require the scratch stays shown on EVERY tick — a single read could sample
        // before a wrongly-firing reveal hid it.
        var stayedShown = true
        for _ in 0..<8 {
            usleep(250_000)
            if try sessionNode(id: sessionA)["scratch"] as? Bool != true { stayedShown = false; break }
        }
        XCTAssertTrue(stayedShown, "the shown scratch must stay shown after selecting the idle session (reveal is a no-op)")
        XCTAssertTrue(try pollOnScreen(target: sessionA, contains: "\(scratchTag)-42"),
                      "the scratch must remain the on-screen surface")
        let onScreen = try XCTUnwrap(onScreenText(sessionA), "the on-screen read should return text")
        XCTAssertFalse(onScreen.contains("\(mainTag)-42"), "the idle-session selection must not dismiss the scratch to the main pane")
    }

    // #199: the token read from the MAIN pane's shell is paired with the WRONG role (--pane right) — the
    // promoted-survivor shape — so `left` in the read-back can only come from the token winning.
    func testPaneIDOverridesStaleRoleThenFallsBack() throws {
        let sessionA = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(sessionA)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "split on should succeed")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the session should report split:true")

        let mainToken = try readPaneToken(target: sessionA, pane: "left")
        XCTAssertFalse(mainToken.isEmpty, "the main pane's shell should expose a non-empty AGTERM_PANE_ID")

        XCTAssertEqual(try sendStatus(target: sessionA, pane: "right", paneID: mainToken)["ok"] as? Bool, true,
                       "session.status with --pane-id should succeed")
        XCTAssertEqual(try statusPane(of: sessionA), "left",
                       "a main-slot --pane-id must override the stale --pane right (#199)")

        XCTAssertEqual(try sendStatus(target: sessionA, pane: "right", paneID: "not-a-real-token")["ok"] as? Bool, true,
                       "session.status with a bogus --pane-id should still succeed")
        XCTAssertEqual(try statusPane(of: sessionA), "right",
                       "an unknown --pane-id falls back to the baked --pane right")
    }

    func testStatusFromTheOtherPaneCannotReplaceABlock() throws {
        let sessionA = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(sessionA)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "split on should succeed")
        XCTAssertTrue(try pollSplit(sessionA, timeout: 10), "the split should be live before tagging the right pane")

        try blockPane("blocked", pane: "right", target: sessionA)

        let refused = try sendCommand(#"{"cmd":"session.status","target":"\#(sessionA)","args":{"status":"active","pane":"left"}}"#)
        XCTAssertEqual(refused["ok"] as? Bool, false, "a left-pane active must not replace the right pane's block: \(refused)")
        XCTAssertEqual(refused["error"] as? String,
                       "blocked status owned by pane right (write from that pane to change it)")
        let node = try sessionNode(id: sessionA)
        XCTAssertEqual(node["status"] as? String, "blocked", "the block should stand after the refused write")
        XCTAssertEqual(node["statusPane"] as? String, "right", "the refused write must not retag the status")

        // the shape the bundled hooks produce: Codex's session-start and the shell integration's
        // post-command hook both send `idle` from their own pane, which must not clear the sibling's block.
        let refusedIdle = try sendCommand(#"{"cmd":"session.status","target":"\#(sessionA)","args":{"status":"idle","pane":"left"}}"#)
        XCTAssertEqual(refusedIdle["ok"] as? Bool, false, "a left-pane idle must not clear the right pane's block: \(refusedIdle)")
        XCTAssertEqual(try sessionNode(id: sessionA)["status"] as? String, "blocked",
                       "the block should stand after the refused idle")

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.status","target":"\#(sessionA)","args":{"status":"active","pane":"right"}}"#)["ok"] as? Bool,
                       true, "the owning pane's own active should still apply")
        XCTAssertEqual(try sessionNode(id: sessionA)["status"] as? String, "active",
                       "the owning pane's write should land")
    }

    func testControlTypingClearsOnlyItsOwnPanesStatus() throws {
        let sessionA = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(sessionA)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "split on should succeed")
        XCTAssertTrue(try pollSplit(sessionA, timeout: 10), "the split should be live before tagging the right pane")

        try blockPane("blocked", pane: "left", target: sessionA)
        XCTAssertTrue(app.staticTexts["agent-status"].waitForExistence(timeout: 12), "a left-tagged block should show the glyph")
        try typeInto(pane: "left", target: sessionA, text: "\n")
        XCTAssertTrue(app.staticTexts["agent-status"].waitForNonExistence(timeout: 12),
                      "typing into the left pane SHOULD clear its own block")

        try blockPane("blocked", pane: "right", target: sessionA)
        XCTAssertTrue(app.staticTexts["agent-status"].waitForExistence(timeout: 12), "a right-tagged block should show the glyph")
        try typeInto(pane: "left", target: sessionA, text: "\n")
        XCTAssertEqual(try sessionNode(id: sessionA)["status"] as? String, "blocked",
                       "typing into the left pane must NOT clear the right pane's block")

        try blockPane("blocked", pane: "right", target: sessionA)
        try typeInto(pane: "right", target: sessionA, text: "")
        XCTAssertEqual(try sessionNode(id: sessionA)["status"] as? String, "blocked",
                       "an empty payload queues no keystrokes, so it must clear nothing")

        try blockPane("active", pane: "right", target: sessionA)
        try typeInto(pane: "right", target: sessionA, text: "\n")
        XCTAssertEqual(try sessionNode(id: sessionA)["status"] as? String, "active",
                       "injected text is not an interrupt, so it must leave an active glyph alone")
    }

    // MARK: - Helpers

    /// `session.type` into one pane, asserting ok.
    private func typeInto(pane: String, target: String, text: String) throws {
        XCTAssertEqual(try sendCommand(typeRequest(text: text, target: target, select: false, pane: pane))["ok"] as? Bool,
                       true, "session.type into the \(pane) pane should succeed")
    }

    /// Type Escape into the focused surface until the agent-status glyph clears (retrying rides out a
    /// still-settling keyboard focus). Mirrors `ControlSidebarStatusUITests`'s typeUntilGlyphCleared idiom.
    private func typeUntilGlyphCleared() -> Bool {
        for _ in 0..<8 {
            app.typeKey(.escape, modifierFlags: [])
            if app.staticTexts["agent-status"].waitForNonExistence(timeout: 2) { return true }
        }
        return false
    }

    /// Set `session.status blocked --pane <pane>` on `target`, asserting ok. Convenience for the blocked case.
    private func blockPane(_ pane: String, target: String) throws {
        try blockPane("blocked", pane: pane, target: target)
    }

    /// Set `session.status <status> --pane <pane>` on `target`, asserting ok. A nil pane omits `--pane`.
    private func blockPane(_ status: String, pane: String?, target: String) throws {
        var args: [String: Any] = ["status": status]
        if let pane { args["pane"] = pane }
        let obj: [String: Any] = ["cmd": "session.status", "target": target, "args": args]
        let line = String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
        XCTAssertEqual(try sendCommand(line)["ok"] as? Bool, true, "session.status \(status) --pane \(pane ?? "-") should succeed")
    }

    /// Seed a pane's shell with `printf '<tag>-%s\n' 42`, polling until the pane's own buffer carries `<tag>-42`
    /// (the input contains `<tag>-%s`, so only executed output contains the marker). Reuses the base
    /// `pollPaneText` readiness-retry so a freshly-spawned pane's dropped first keystrokes are re-injected.
    private func seedPaneMarker(target: String, pane: String, tag: String) throws {
        let seeded = try pollPaneText(target: target, pane: pane, contains: "\(tag)-42", retype: {
            _ = try self.sendCommand(self.typeRequest(text: "printf '\(tag)-%s\\n' 42\n",
                                                      target: target, select: false, pane: pane))
        })
        XCTAssertNotNil(seeded, "seeding the \(pane) pane marker should land in its buffer")
    }

    /// Send `session.status blocked --pane <pane> --pane-id <paneID>` on `target`, returning the raw response.
    private func sendStatus(target: String, pane: String, paneID: String) throws -> [String: Any] {
        let args: [String: Any] = ["status": "blocked", "pane": pane, "paneID": paneID]
        let obj: [String: Any] = ["cmd": "session.status", "target": target, "args": args]
        let line = String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
        return try sendCommand(line)
    }

    /// Read a pane's stable spawn token straight from its shell's `$AGTERM_PANE_ID` — the exact value the
    /// agent-status hook forwards as `--pane-id`. Echoes `<tag>-42[<token>]`, where the arithmetic 42 (from
    /// `$((6*7))`) proves the shell RAN the line (the typed command shows `$((6*7))`, only the output shows
    /// `42`), then extracts the token between the brackets. Reuses `pollPaneText`'s readiness-retry.
    private func readPaneToken(target: String, pane: String) throws -> String {
        let tag = "PIDR-\(UUID().uuidString.prefix(8))"
        let needle = "\(tag)-42["
        let buffer = try pollPaneText(target: target, pane: pane, contains: needle, retype: {
            _ = try self.sendCommand(self.typeRequest(
                text: "printf '\(tag)-%s[%s]\\n' \"$((6*7))\" \"$AGTERM_PANE_ID\"\n",
                target: target, select: false, pane: pane))
        })
        let text = try XCTUnwrap(buffer, "reading the \(pane) pane's AGTERM_PANE_ID should land in its buffer")
        let pattern = NSRegularExpression.escapedPattern(for: needle) + "([-0-9A-Fa-f]+)\\]"
        let regex = try NSRegularExpression(pattern: pattern)
        let match = try XCTUnwrap(regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                                  "the \(pane) pane should echo a non-empty AGTERM_PANE_ID")
        let tokenRange = try XCTUnwrap(Range(match.range(at: 1), in: text))
        return String(text[tokenRange])
    }

    /// Add a fresh session (which takes the selection) and wait for it to become the parked selection, so the
    /// following attention-nav has somewhere to jump FROM. Returns the new session id.
    private func parkOnNewSession() throws -> String {
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let id = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new should return an id")
        XCTAssertTrue(pollSessionCount(2, timeout: 10), "the parked second session should land")
        XCTAssertTrue(try pollActiveNode(equals: id, timeout: 10), "the new session should be the parked selection")
        return id
    }

    /// Fire the GUI attention-nav shortcut ⌃⌥↓ (Navigate ▸ Next Attention Session). A menu key-equivalent,
    /// so it dispatches regardless of which surface holds first responder (as `SessionNavUITests` drives ⌥⌘↓).
    private func attentionNavDown() {
        app.typeKey(.downArrow, modifierFlags: [.control, .option])
    }

    /// Fire the GUI previous-attention shortcut ⌃⌥↑.
    private func attentionNavUp() {
        app.typeKey(.upArrow, modifierFlags: [.control, .option])
    }

    /// Click the `session-row` whose displayed name (its accessibility VALUE) equals `name`. A renamed
    /// session's row is matched unambiguously by value (mirrors `FlaggedViewUITests`/`FocusWorkspaceUITests`).
    private func clickSessionRow(named name: String) {
        let row = app.staticTexts
            .matching(NSPredicate(format: "identifier == %@ AND value == %@", "session-row", name))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the '\(name)' session row should exist in the sidebar")
        row.click()
    }

    /// Open the attention command palette via Navigate ▸ Go to Attention… (a menu key-equivalent is the
    /// deterministic opener — mirrors `PaletteUITests.openPalette`), waiting for its field to appear.
    private func openAttentionPalette() {
        app.menuBars.menuBarItems["Navigate"].click()
        let item = app.menuItems["Go to Attention…"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Navigate menu should offer Go to Attention…")
        item.click()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5), "the attention palette field should appear")
    }

    /// Re-send Return each tick (the blocked session is the only attention row, so Return on the top match
    /// selects it) until the tree's active session equals `expected`, or the timeout elapses. A just-opened
    /// palette can settle field focus a beat after it mounts, so a single Return can race the focus and
    /// no-op; re-sending makes the selection deterministic (the `AttentionButtonUITests` idiom).
    private func pollReturnSelects(_ expected: String, timeout: TimeInterval) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            app.typeKey(.return, modifierFlags: [])
            if try pollActiveNode(equals: expected, timeout: 0.4) { return true }
        }
        return try activeNodeID() == expected.lowercased()
    }

    /// The on-screen surface's full buffer (`session.text` with NO `--pane`, `all:true`) for `target`, or nil.
    private func onScreenText(_ target: String) throws -> String? {
        let resp = try sendCommand(#"{"cmd":"session.text","target":"\#(target)","args":{"all":true}}"#)
        return (resp["result"] as? [String: Any])?["text"] as? String
    }

    /// Polls the on-screen buffer of `target` until it contains `needle`, or times out.
    private func pollOnScreen(target: String, contains needle: String, timeout: TimeInterval = 12) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try onScreenText(target), text.contains(needle) { return true }
            usleep(300_000)
        }
        return try onScreenText(target)?.contains(needle) ?? false
    }

    /// The `statusPane` read-back of `target` from the tree (nil when idle/unspecified).
    private func statusPane(of target: String) throws -> String? {
        try sessionNode(id: target)["statusPane"] as? String
    }

    /// The id (lowercased) of the tree's `active` (= selected) session, or nil.
    private func activeNodeID() throws -> String? {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        guard let result = tree["result"] as? [String: Any],
              let t = result["tree"] as? [String: Any],
              let workspaces = t["workspaces"] as? [[String: Any]] else { return nil }
        let sessions = workspaces.flatMap { ($0["sessions"] as? [[String: Any]]) ?? [] }
        return (sessions.first { ($0["active"] as? Bool) == true }?["id"] as? String)?.lowercased()
    }

    /// Polls the tree until the `active` session equals `expected` (case-insensitive), or times out.
    private func pollActiveNode(equals expected: String, timeout: TimeInterval) throws -> Bool {
        let want = expected.lowercased()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try activeNodeID() == want { return true }
            usleep(250_000)
        }
        return try activeNodeID() == want
    }

    /// Polls the tree until `target`'s `scratch` flag equals `expected`, or times out.
    private func pollScratch(id target: String, equals expected: Bool, timeout: TimeInterval) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try sessionNodeIfPresent(id: target)?["scratch"] as? Bool == expected { return true }
            usleep(250_000)
        }
        return try sessionNodeIfPresent(id: target)?["scratch"] as? Bool == expected
    }
}
