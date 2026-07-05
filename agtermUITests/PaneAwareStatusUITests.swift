import Foundation
import XCTest

/// Control-channel e2e for pane-aware agent status: a `blocked` status tagged with the pane that set it
/// (`session.status --pane left|right|scratch`) must (1) survive foreground typing in a DIFFERENT pane and
/// (2) make every user-initiated GUI selection (attention navigation, a sidebar row click, the attention
/// command palette) reveal and land on the pane that actually blocked — a split (right) pane, a hidden
/// split, or a scratch terminal — instead of the session's plain focused pane. Subclass of
/// `ControlAPITestCase` for the socket harness (isolated `AGTERM_STATE_DIR` + short socket path).
///
/// Reveal oracle (deterministic, race-free): the reveal step (`AppActions.revealActiveBlockedPane`) sets the
/// MODEL flags `splitFocused` / `scratchActive` synchronously, and `Session.onScreenSurface` follows those
/// flags — so `session.text` with NO `--pane` (the on-screen surface) reflects the reveal immediately,
/// independent of the best-effort AppKit `makeFirstResponder` retry the reveal also fires. Each pane is
/// pre-seeded with a distinct echo marker; after nav, the no-pane read returns the REVEALED pane's marker
/// and not the other's. The primary trigger is the GUI attention-nav shortcut ⌃⌥↓ (Navigate ▸ Next
/// Attention Session → `AppActions.selectNextAttentionSession` → `revealActiveBlockedPane`); the SAME reveal
/// also fires on a plain GUI selection — a sidebar row click (`outlineViewSelectionDidChange`) and the
/// ⌃P/attention command palette's run closure, each covered below — since the reveal now runs on every
/// user-initiated selection. Only the control `session.go next-attention` stays reveal-free (it drives
/// `AppStore.navigateSession` directly), so a menu key-equivalent / click / palette pick is the way to
/// exercise it (as `SessionNavUITests` drives ⌥⌘↓).
///
/// Clear oracle (survival / self-clear): the pane-scoped keystroke-clear is wired off the real `keyDown`
/// (each surface factory owns the decision for its own pane), so it MUST be driven by the synthesized
/// keyboard — `session.type` injects via `ghostty_surface_key` and bypasses `keyDown`. The sidebar glyph
/// (`agent-status`) is the observable, as in `ControlSidebarStatusUITests.testTypingClearsBlockedOrCompletedStatus`.
@MainActor
final class PaneAwareStatusUITests: ControlAPITestCase {
    // a `right`-tagged block on a SHOWN split: parked on another session, ⌃⌥↓ jumps to the blocked session
    // AND flips the on-screen pane from the main (left) pane — where focus was parked — to the split (right)
    // pane that set the status. Without the pane tag, nav would keep focus on the main pane.
    func testAttentionNavRevealsBlockedSplitPane() throws {
        let sessionA = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(sessionA)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "split on should succeed")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the session should report split:true")

        let leftTag = "PAWL-\(UUID().uuidString.prefix(8))"
        let rightTag = "PAWR-\(UUID().uuidString.prefix(8))"
        try seedPaneMarker(target: sessionA, pane: "left", tag: leftTag)
        try seedPaneMarker(target: sessionA, pane: "right", tag: rightTag)

        // move focus to the main (left) pane so the split (right) pane is NOT the on-screen one — the state a
        // background pane block starts from.
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.focus","target":"\#(sessionA)","args":{"pane":"left"}}"#)["ok"] as? Bool,
                       true, "focusing the left pane should succeed")
        XCTAssertTrue(try pollOnScreen(target: sessionA, contains: "\(leftTag)-42"),
                      "with the left pane focused, the on-screen surface should be the main pane")

        // the split (right) pane's agent blocks; park the selection on a fresh non-blocked session.
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

    // a `right`-tagged block on a HIDDEN split: nav reveals it by swapping which pane shows MAXIMIZED (the
    // split stays hidden — split:false — but the right pane is now the on-screen one), not by re-showing the
    // two panes side-by-side.
    func testAttentionNavRevealsHiddenSplit() throws {
        let sessionA = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(sessionA)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "split on should succeed")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the session should report split:true")

        let leftTag = "PAWHL-\(UUID().uuidString.prefix(8))"
        let rightTag = "PAWHR-\(UUID().uuidString.prefix(8))"
        try seedPaneMarker(target: sessionA, pane: "left", tag: leftTag)
        try seedPaneMarker(target: sessionA, pane: "right", tag: rightTag)

        // focus the main pane, then HIDE the split (keep-alive) — the main pane shows maximized.
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
        XCTAssertEqual(try sessionNode(id: sessionA)?["split"] as? Bool, false,
                       "the split stays hidden after the reveal — the right pane is shown maximized, not side-by-side")
    }

    // a `scratch`-tagged block with the scratch HIDDEN: nav shows the scratch (the toggleScratch reveal path,
    // which has no notification PaneRole) and makes it the on-screen surface.
    func testAttentionNavRevealsHiddenScratch() throws {
        let sessionA = try activeSessionID()
        let mainTag = "PAWSM-\(UUID().uuidString.prefix(8))"
        let scratchTag = "PAWSS-\(UUID().uuidString.prefix(8))"
        try seedPaneMarker(target: sessionA, pane: "left", tag: mainTag)

        // open the scratch, seed its buffer, then HIDE it (keep-alive) — the main pane is on-screen again.
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

    // the inverse of the hidden-scratch reveal: a `right`-tagged block on the split with the scratch ALREADY
    // SHOWN (covering the panes). Without hiding the cover, both focus paths resolve to the scratch and nav
    // never reaches the blocked pane; the reveal must HIDE the covering scratch first, then surface the right
    // pane. The scratch is a background cover here — the block was set by the split behind it.
    func testAttentionNavRevealsSplitBehindShownScratch() throws {
        let sessionA = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(sessionA)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "split on should succeed")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the session should report split:true")

        let leftTag = "PAWCL-\(UUID().uuidString.prefix(8))"
        let rightTag = "PAWCR-\(UUID().uuidString.prefix(8))"
        try seedPaneMarker(target: sessionA, pane: "left", tag: leftTag)
        try seedPaneMarker(target: sessionA, pane: "right", tag: rightTag)

        // focus the main (left) pane, then SHOW the scratch so it covers both panes.
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.focus","target":"\#(sessionA)","args":{"pane":"left"}}"#)["ok"] as? Bool,
                       true, "focusing the left pane should succeed")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.scratch","target":"\#(sessionA)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "scratch on should succeed")
        XCTAssertTrue(try pollScratch(id: sessionA, equals: true, timeout: 10), "the scratch should cover the panes")

        // the split (right) pane's agent blocks behind the covering scratch; park on a fresh session.
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

    // the core fix: typing in the MAIN pane must NOT clear a block tagged `right` or `scratch` (a background
    // pane set it). The positive control at the end proves the SAME keystrokes DO reach the main pane's
    // keyDown and clear a `left`-tagged block — so the survivals above are real pane-scoping, not lost keys.
    func testMainPaneTypingSurvivesBackgroundPaneBlock() throws {
        let sessionA = try activeSessionID()
        // put first responder in the main pane so the synthesized Escape reaches its keyDown.
        app.staticTexts["session-row"].firstMatch.click()
        usleep(800_000)

        // a right- or scratch-tagged block survives Escape typed into the main pane.
        for tag in ["right", "scratch"] {
            try blockPane("blocked", pane: tag, target: sessionA)
            XCTAssertTrue(app.staticTexts["agent-status"].waitForExistence(timeout: 12),
                          "a \(tag)-tagged block should show the glyph")
            for _ in 0..<3 { app.typeKey(.escape, modifierFlags: []); usleep(250_000) }
            usleep(600_000)
            XCTAssertTrue(app.staticTexts["agent-status"].exists,
                          "typing in the main pane must NOT clear a \(tag)-tagged block")
            XCTAssertEqual(try sessionNode(id: sessionA)?["status"] as? String, "blocked",
                           "the \(tag)-tagged block should still read blocked after main-pane typing")
            XCTAssertEqual(try sendCommand(#"{"cmd":"session.status","target":"\#(sessionA)","args":{"status":"idle"}}"#)["ok"] as? Bool,
                           true, "clearing to idle should succeed")
            XCTAssertTrue(app.staticTexts["agent-status"].waitForNonExistence(timeout: 12), "idle should hide the glyph")
        }

        // positive control: a left-tagged block IS cleared by the same Escape in the main pane, proving the
        // keystrokes actually reach the main pane's keyDown (so the survivals above weren't false passes).
        try blockPane("blocked", pane: "left", target: sessionA)
        XCTAssertTrue(app.staticTexts["agent-status"].waitForExistence(timeout: 12), "a left-tagged block should show the glyph")
        XCTAssertTrue(typeUntilGlyphCleared(), "typing in the main pane SHOULD clear a left-tagged block (its own pane)")
    }

    // self-clear parity (the Task 8 scratch-factory closure): typing in the SCRATCH clears a `scratch`-tagged
    // block — the scratch surface owns its own pane-scoped keystroke-clear, so its own keystrokes clear its
    // own block, mirroring the main/split panes.
    func testScratchTypingClearsScratchBlock() throws {
        let sessionA = try activeSessionID()
        try blockPane("scratch", target: sessionA)
        XCTAssertTrue(app.staticTexts["agent-status"].waitForExistence(timeout: 12), "a scratch-tagged block should show the glyph")

        // show the scratch — its autoFocus grabs first responder, so synthesized keys reach the scratch's keyDown.
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.scratch","target":"\#(sessionA)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "scratch on should succeed")
        XCTAssertTrue(try pollScratch(id: sessionA, equals: true, timeout: 10), "the scratch should be shown")
        usleep(800_000) // let the scratch's autoFocus settle first responder onto it

        XCTAssertTrue(typeUntilGlyphCleared(), "typing in the scratch SHOULD clear its own scratch-tagged block")
    }

    // a `right`-tagged block revealed by a SIDEBAR ROW CLICK: with the selection parked on another session,
    // clicking the blocked session's row selects it AND flips the on-screen pane from the main (left) pane —
    // where focus was parked — to the split (right) pane that set the status. The reveal now fires on a plain
    // GUI selection, not only attention-nav; without the pane tag the click would keep focus on the main pane.
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

        // focus the main (left) pane so the split (right) pane is NOT the on-screen one.
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.focus","target":"\#(sessionA)","args":{"pane":"left"}}"#)["ok"] as? Bool,
                       true, "focusing the left pane should succeed")
        XCTAssertTrue(try pollOnScreen(target: sessionA, contains: "\(leftTag)-42"),
                      "with the left pane focused, the on-screen surface should be the main pane")

        // the split (right) pane's agent blocks; park the selection on a fresh session so A is NOT selected.
        try blockPane("right", target: sessionA)
        XCTAssertEqual(try statusPane(of: sessionA), "right", "the block should be tagged right")
        _ = try parkOnNewSession()

        // click the blocked session's row: selecting it should reveal its blocked (right) pane.
        clickSessionRow(named: rowName)

        XCTAssertTrue(try pollActiveNode(equals: sessionA, timeout: 12), "clicking the row should select the blocked session")
        XCTAssertTrue(try pollOnScreen(target: sessionA, contains: "\(rightTag)-42"),
                      "the reveal should make the split (right) pane the on-screen surface")
        let onScreen = try XCTUnwrap(onScreenText(sessionA), "the on-screen read should return text")
        XCTAssertFalse(onScreen.contains("\(leftTag)-42"), "the revealed right pane must not carry the main pane's marker")
    }

    // a `right`-tagged block revealed by the ATTENTION COMMAND PALETTE: opening Navigate ▸ Go to Attention…
    // and choosing the blocked session selects it AND flips the on-screen pane to the split (right) pane that
    // set the status. The palette-run reveal is dispatched async (after the palette closes and its own
    // focus-restore), so it lands on the waiting pane, mirroring attention-nav and the sidebar click.
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

        // block the right pane, then park on a fresh IDLE session so the blocked A is the ONLY attention row.
        try blockPane("right", target: sessionA)
        XCTAssertEqual(try statusPane(of: sessionA), "right", "the block should be tagged right")
        _ = try parkOnNewSession()

        openAttentionPalette()
        // A is the only non-idle session, so Return on the top match selects it; re-send Return each tick
        // since a menu-opened palette can settle field focus a beat after it mounts (the pollReturnSelects
        // idiom from AttentionButtonUITests).
        XCTAssertTrue(try pollReturnSelects(sessionA, timeout: 12), "choosing the attention row should select the blocked session")

        XCTAssertTrue(try pollOnScreen(target: sessionA, contains: "\(rightTag)-42"),
                      "the palette reveal should make the split (right) pane the on-screen surface")
        let onScreen = try XCTUnwrap(onScreenText(sessionA), "the on-screen read should return text")
        XCTAssertFalse(onScreen.contains("\(leftTag)-42"), "the revealed right pane must not carry the main pane's marker")
    }

    // regression: selecting a session that merely has its scratch SHOWN — with NO agent status (idle) — must
    // LEAVE the scratch shown. Before the idle-gate, `revealActiveBlockedPane` hid the scratch whenever
    // `statusPane` was nil (`nil != .scratch` is true) on EVERY selection, so a plain sidebar click to an idle
    // session dismissed its scratch. Now an idle session is a pure no-op. A stay-shown poll (not a single
    // read) is used so the async reveal can't false-pass by hiding the scratch a beat after the first check.
    func testSelectingIdleSessionKeepsShownScratch() throws {
        let sessionA = try activeSessionID()
        let rowName = "PAWIDLE-\(UUID().uuidString.prefix(8))"
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(sessionA)","args":{"name":"\#(rowName)"}}"#)["ok"] as? Bool,
                       true, "renaming the session should succeed")

        let mainTag = "PAWIM-\(UUID().uuidString.prefix(8))"
        let scratchTag = "PAWIS-\(UUID().uuidString.prefix(8))"
        try seedPaneMarker(target: sessionA, pane: "left", tag: mainTag)

        // show the scratch and seed it; leave it SHOWN. the session stays IDLE (no session.status at all).
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.scratch","target":"\#(sessionA)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "scratch on should succeed")
        XCTAssertTrue(try pollScratch(id: sessionA, equals: true, timeout: 10), "the scratch should be shown")
        try seedPaneMarker(target: sessionA, pane: "scratch", tag: scratchTag)
        XCTAssertNil(try statusPane(of: sessionA), "sanity: an idle session carries no status pane")

        // park the selection on a fresh session, then click BACK to the idle session's row — a GUI selection
        // that runs the reveal, which must be a no-op for the idle session and NOT hide its scratch.
        _ = try parkOnNewSession()
        clickSessionRow(named: rowName)
        XCTAssertTrue(try pollActiveNode(equals: sessionA, timeout: 12), "clicking the row should select the idle session")

        // the sidebar-click reveal is dispatched async; poll across its window and require the scratch stays
        // shown on EVERY tick (a single read could catch it before the pre-fix reveal hid it).
        var stayedShown = true
        for _ in 0..<8 {
            usleep(250_000)
            if try sessionNode(id: sessionA)?["scratch"] as? Bool != true { stayedShown = false; break }
        }
        XCTAssertTrue(stayedShown, "the shown scratch must stay shown after selecting the idle session (reveal is a no-op)")
        XCTAssertTrue(try pollOnScreen(target: sessionA, contains: "\(scratchTag)-42"),
                      "the scratch must remain the on-screen surface")
        let onScreen = try XCTUnwrap(onScreenText(sessionA), "the on-screen read should return text")
        XCTAssertFalse(onScreen.contains("\(mainTag)-42"), "the idle-session selection must not dismiss the scratch to the main pane")
    }

    // MARK: - Helpers

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

    /// Seed a pane's shell with `echo <tag>-$((6*7))`, polling until the pane's own buffer carries `<tag>-42`
    /// (the arithmetic result proves the shell RAN the line, not merely echoed it). Reuses the base
    /// `pollPaneText` readiness-retry so a freshly-spawned pane's dropped first keystrokes are re-injected.
    private func seedPaneMarker(target: String, pane: String, tag: String) throws {
        let seeded = try pollPaneText(target: target, pane: pane, contains: "\(tag)-42", retype: {
            _ = try self.sendCommand(self.typeRequest(text: "echo \(tag)-$((6*7))\n", target: target, select: false, pane: pane))
        })
        XCTAssertNotNil(seeded, "seeding the \(pane) pane marker should land in its buffer")
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

    /// The session node (case-insensitive id) from a fresh `tree`, across all workspaces, or nil.
    private func sessionNode(id: String) throws -> [String: Any]? {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        guard let result = tree["result"] as? [String: Any],
              let t = result["tree"] as? [String: Any],
              let workspaces = t["workspaces"] as? [[String: Any]] else { return nil }
        let sessions = workspaces.flatMap { ($0["sessions"] as? [[String: Any]]) ?? [] }
        return sessions.first { ($0["id"] as? String)?.lowercased() == id.lowercased() }
    }

    /// The `statusPane` read-back of `target` from the tree (nil when idle/unspecified).
    private func statusPane(of target: String) throws -> String? {
        try sessionNode(id: target)?["statusPane"] as? String
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
            if try sessionNode(id: target)?["scratch"] as? Bool == expected { return true }
            usleep(250_000)
        }
        return try sessionNode(id: target)?["scratch"] as? Bool == expected
    }
}
