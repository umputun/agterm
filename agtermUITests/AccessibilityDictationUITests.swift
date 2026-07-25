import Foundation
import XCTest

/// e2e for the accessibility dictation bridge (`GhosttySurfaceView+Accessibility.swift`). Subclasses
/// `ControlAPITestCase` to reuse the isolated-state-dir + control-socket harness: sessions and the
/// dashboard are driven over the socket, while the AX exposure is observed through the XCUITest
/// accessibility tree — the surface advertises role `.textArea` (XCUITest element type `.textView`)
/// with label "Terminal".
///
/// These tests lock down the GATING the review asked for: the surface is exposed ONLY for the on-screen
/// deck pane(s) — one for a plain session, BOTH for a visible split (`deckVisible` is not focus-gated) —
/// never for the eagerly-realized background sessions (the deck mounts every session's surface at once)
/// nor for the view-only dashboard cells. The write path itself (single-line `insertText` vs multiline
/// `insertPasted`) is not reachable from XCUITest — there is no public API to call `setAccessibilityValue`
/// on another process's element — so its routing is covered by the manual dev-instance check, not here.
@MainActor
final class AccessibilityDictationUITests: ControlAPITestCase {
    // The single seeded, on-screen pane exposes exactly one AX text area, labelled "Terminal", of role
    // `.textArea` (XCUITest `.textView`), that reads back empty (we do not mirror the scrollback). A
    // single-session window must expose exactly ONE such element — not one per realized surface.
    // (Keyboard/AX focus is enforced by `isAccessibilityFocused`/`setAccessibilityValue` in code and
    // verified manually — macOS XCUITest exposes no keyboard-focus predicate to assert it here.)
    func testFocusedVisiblePaneExposesTerminalTextArea() throws {
        let terminal = terminalTextAreas().firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 15),
                      "the visible terminal pane should expose an AX text area labelled Terminal")
        XCTAssertEqual(terminal.elementType, .textView, "the exposed element is a text area (role .textArea)")
        // "reads back empty" = nil OR an empty string. Reject anything else outright (don't coerce with
        // `?? ""`): a future change that mirrored the scrollback would surface a non-empty / non-String
        // value, and this must FAIL then rather than pass vacuously.
        switch terminal.value {
        case nil:
            break // XCUITest surfaces an empty AXValue as nil — acceptable
        case let string as String:
            XCTAssertTrue(string.isEmpty, "the exposed text area reads back empty (scrollback is not mirrored)")
        default:
            XCTFail("the exposed text area must read back empty, got a non-empty/non-string value: \(String(describing: terminal.value))")
        }
        assertStableTerminalTextAreaCount(1, timeout: 10, hold: 2,
                                          "a single-session window exposes exactly one Terminal text area, not one per surface")
    }

    // The core regression guard for the "background sessions become writable AX targets" bug: with three
    // sessions realized, only the ON-SCREEN pane is an AX text area — the two background sessions are
    // excluded by the `deckVisible` gate. `realizeAllSurfaces` cycles focus through every session so all
    // three surfaces have entered the AX tree BEFORE the assertion, making the steady state deterministic:
    // under the un-fixed code (gating on `!viewOnly` only) the settled count is 3, so the poll for 1 times
    // out and the test fails; with the fix it is stably 1. This removes the timing race a first-match poll
    // (or a hold that starts before the background surfaces realize) would have.
    func testBackgroundSessionsAreNotAccessibleTargets() throws {
        let ids = try prepareSessions(extra: 2) // 3 sessions total
        try realizeAllSurfaces(ids)
        assertStableTerminalTextAreaCount(1, timeout: 15, hold: 2,
                                          "only the on-screen pane is an AX text area; realized background sessions are excluded")
    }

    // A visible split has BOTH panes on screen and `deckVisible` (the flag is deliberately not
    // split-focus-gated — the same one drag/cursor use), so both advertise a "Terminal" text area. This
    // pins that two-element contract: only the first-responder pane accepts a write, but a screen reader /
    // AX client sees both visible panes, and a future change that exposed N-per-surface or hid the
    // non-focused pane would move this count off 2.
    func testVisibleSplitExposesBothPanes() throws {
        assertStableTerminalTextAreaCount(1, timeout: 15, hold: 1, "one exposed pane before splitting")
        let split = try sendCommand(#"{"cmd":"session.split","target":"active","args":{"mode":"on"}}"#)
        XCTAssertEqual(split["ok"] as? Bool, true, "split on should succeed: \(split)")
        assertStableTerminalTextAreaCount(2, timeout: 15, hold: 2,
                                          "both visible split panes expose a Terminal text area")
    }

    // The dashboard mounts every member surface as a VIEW-ONLY cell and hides the deck panes, so nothing is
    // a live text destination: no Terminal text area is exposed while it is open. Closing it restores the
    // single on-screen exposure — proving the exclusion is driven by live `viewOnly`/`deckVisible` state,
    // not a one-way latch.
    func testDashboardCellsAreNotAccessibleTextAreas() throws {
        let ids = try prepareSessions(extra: 2)
        try realizeAllSurfaces(ids) // so a leaked background pane would settle at a WRONG count, not stay unrealized
        assertStableTerminalTextAreaCount(1, timeout: 15, hold: 1, "baseline: one exposed pane before opening the dashboard")

        try openDashboard(members: ids)
        // stable-hold, not a first-match poll: a lingering exposure passes through 0 transiently.
        assertStableTerminalTextAreaCount(0, timeout: 15, hold: 2,
                                          "view-only dashboard cells (and the hidden deck panes) expose no Terminal text area")

        try closeDashboard()
        XCTAssertTrue(dashboardOverlay.waitForNonExistence(timeout: 10), "the dashboard overlay should close")
        // the count climbs 0→1(→2 if a background pane leaks) on restore; only a stable hold rejects the leak.
        assertStableTerminalTextAreaCount(1, timeout: 15, hold: 2,
                                          "closing the dashboard restores exactly the single on-screen exposure")
    }

    // MARK: - AX queries

    /// Every AX text area the surface exposes, matched by our "Terminal" label (role `.textArea` →
    /// XCUITest `.textView`).
    private func terminalTextAreas() -> XCUIElementQuery {
        app.textViews.matching(NSPredicate(format: "label == %@", "Terminal"))
    }

    private func pollTerminalTextAreaCount(_ expected: Int, timeout: TimeInterval) -> Bool {
        let query = terminalTextAreas()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if query.count == expected { return true }
            usleep(200_000)
        }
        return query.count == expected
    }

    /// Assert the exposed-count reaches `expected` within `timeout` AND then STAYS there across a hold. The
    /// hold turns an at-some-instant reading into a steady-state invariant: a count that only transiently
    /// equals `expected` (e.g. staggered surface realization under a regression) drifts off during the hold
    /// and fails, where a plain first-match poll would false-pass. The hold runs for at least `hold` seconds
    /// AND at least `minSamples` re-reads — each `.count` is a full AX snapshot that can take ~1s under load,
    /// so a purely time-bounded loop could degrade to a single sample; the min-sample floor keeps it a real
    /// re-check even then.
    private func assertStableTerminalTextAreaCount(_ expected: Int, timeout: TimeInterval, hold: TimeInterval,
                                                   _ message: String, minSamples: Int = 3,
                                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(pollTerminalTextAreaCount(expected, timeout: timeout), message, file: file, line: line)
        let deadline = Date().addingTimeInterval(hold)
        var samples = 0
        while samples < minSamples || Date() < deadline {
            XCTAssertEqual(terminalTextAreas().count, expected, "\(message) (must stay stable)", file: file, line: line)
            samples += 1
            usleep(200_000)
        }
    }

    // MARK: - socket helpers (local copies — the DashboardUITests versions are private to that class)

    /// Create `extra` sessions, wait for them all in the sidebar, and return every session id in tree order.
    @discardableResult
    private func prepareSessions(extra: Int) throws -> [String] {
        for _ in 0..<extra {
            XCTAssertEqual(try sendCommand(#"{"cmd":"session.new"}"#)["ok"] as? Bool, true, "session.new should succeed")
        }
        XCTAssertTrue(pollSessionRowCount(extra + 1, timeout: 15), "all sessions should appear in the sidebar")
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let result = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let top = try XCTUnwrap(result["tree"] as? [String: Any], "result should carry a tree")
        let workspace = try XCTUnwrap((top["workspaces"] as? [[String: Any]])?.first, "a seeded workspace")
        let sessions = try XCTUnwrap(workspace["sessions"] as? [[String: Any]], "workspace sessions")
        return try sessions.map { try XCTUnwrap($0["id"] as? String, "session id") }
    }

    /// The id of the currently selected (active-flagged) session, or nil if the tree isn't readable yet.
    private func selectedSessionID() -> String? {
        guard let response = try? sendCommand(#"{"cmd":"tree"}"#),
              let result = response["result"] as? [String: Any],
              let top = result["tree"] as? [String: Any],
              let workspaces = top["workspaces"] as? [[String: Any]] else { return nil }
        for workspace in workspaces {
            for session in (workspace["sessions"] as? [[String: Any]] ?? []) where session["active"] as? Bool == true {
                return session["id"] as? String
            }
        }
        return nil
    }

    /// Select `id` and wait until the tree reports it active, so the caller knows the switch landed.
    private func selectSession(_ id: String, timeout: TimeInterval = 10) throws {
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(id)"}"#)["ok"] as? Bool, true,
                       "session.select \(id) should succeed")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if selectedSessionID()?.lowercased() == id.lowercased() { return }
            usleep(200_000)
        }
        XCTFail("selecting \(id) did not land within \(timeout)s")
    }

    /// Bring every session on screen once (then settle back on the first), so each surface has been the
    /// visible deck pane and is guaranteed into the AX tree — making the exposed-count assertion depend on
    /// the gating, not on eager-realization timing.
    private func realizeAllSurfaces(_ ids: [String]) throws {
        for id in ids { try selectSession(id) }
        if let first = ids.first { try selectSession(first) }
    }

    private var dashboardOverlay: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "dashboard").firstMatch
    }

    /// Open the dashboard over the socket with `members` (in order) and wait for the overlay to mount.
    private func openDashboard(members: [String]) throws {
        // establish XCUITest key routing before opening (the SplitUITests/DashboardUITests idiom): click the
        // first sidebar row so the key-catcher can grab first responder on mount. Row 0 is the default
        // selection, so this perturbs nothing.
        let routingRow = app.staticTexts.matching(identifier: "session-row").element(boundBy: 0)
        if routingRow.waitForExistence(timeout: 15) {
            routingRow.click()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        let data = try JSONSerialization.data(withJSONObject: ["cmd": "dashboard", "args": ["targets": members]])
        let line = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(try sendCommand(line)["ok"] as? Bool, true, "dashboard open should succeed")
        XCTAssertTrue(dashboardOverlay.waitForExistence(timeout: 15), "the dashboard overlay should appear")
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    }

    private func closeDashboard() throws {
        XCTAssertEqual(try sendCommand(#"{"cmd":"dashboard","args":{"close":true}}"#)["ok"] as? Bool, true,
                       "dashboard --close should succeed")
    }
}
