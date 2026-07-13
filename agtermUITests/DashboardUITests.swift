import XCTest

/// End-to-end tests for the dashboard grid overlay (Task 11). Subclasses `ControlAPITestCase` to reuse the
/// isolated-state-dir + control-socket harness: the dashboard is OPENED/CLOSED over the socket
/// (`{"cmd":"dashboard",…}`) and its live state is read back through `tree`
/// (`dashboardMembers`/`dashboardHighlighted`/`dashboardFontSize`/`dashboardFontMode`), while the overlay,
/// its cells, and the keyboard highlight are observed through the accessibility ids `dashboard`,
/// `dashboard-cell`, and `dashboard-highlighted`.
///
/// What XCUITest can and cannot see is called out at each assertion: the member terminals are Metal-backed
/// `GhosttySurfaceView`s with no readable a11y text, so "view-only" is proven through observable side effects
/// (a leaked keystroke would echo into the surface buffer, read via `session.text`) rather than a pixel read,
/// and the font PIXEL size / the visual restore-on-close are covered by the manual dev-instance check in the
/// plan's Post-Completion, not here.
@MainActor
final class DashboardUITests: ControlAPITestCase {
    // MARK: - open / cell count / read-back

    // opening a 3-session dashboard renders exactly three member cells and reports the members on `tree`;
    // closing removes the overlay and clears every dashboard read-back.
    func testDashboardOpensWithMemberCellsAndClosesClean() throws {
        let ids = try prepareSessions(extra: 2) // 3 sessions → a 2x2 grid with three real cells + one filler
        XCTAssertEqual(ids.count, 3, "the seeded session plus two new ones")

        XCTAssertFalse(dashboardOverlay.exists, "no dashboard overlay before opening")
        XCTAssertNil(dashMembers(), "tree carries no dashboard read-back before opening")

        try openDashboard(members: ids)
        XCTAssertTrue(pollCellCount(3, timeout: 15), "a 3-member dashboard renders exactly three member cells")
        XCTAssertEqual(dashMembers()?.count, 3, "tree.dashboardMembers matches the member count")

        try closeDashboard()
        XCTAssertTrue(dashboardOverlay.waitForNonExistence(timeout: 10), "close removes the overlay")
        XCTAssertNil(dashMembers(), "tree.dashboardMembers clears on close")
        XCTAssertNil(dashHighlighted(), "tree.dashboardHighlighted clears on close")
    }

    // `dashboard --mru` populates the grid from the window's most-recently-used sessions (no explicit ids):
    // a KNOWN recency order is seeded via explicit `session.select`s (the LAST selected is most-recent), then
    // the mru members are asserted to equal that order exactly (recency is deterministic — the RecencyStack is
    // pushed on every select), one cell per session (fewer than the 9-cell cap). Asserts ORDER, not just the
    // set, since the switcher/recency behavior is deterministic.
    func testDashboardMruOpensRecentSessions() throws {
        let ids = try prepareSessions(extra: 3) // 4 sessions total (seeded + three new)
        XCTAssertEqual(ids.count, 4)

        // seed recency by selecting each session in a known sequence; most-recent-first is its reverse.
        let selectOrder = [ids[1], ids[3], ids[0], ids[2]]
        for id in selectOrder {
            XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(id)"}"#)["ok"] as? Bool, true,
                           "selecting \(id) should succeed")
            XCTAssertTrue(pollSelectedSession(id, timeout: 10), "the select should land before the next")
        }
        let expected = Array(selectOrder.reversed()) // [ids[2], ids[0], ids[3], ids[1]]

        let response = try sendCommand(#"{"cmd":"dashboard","args":{"mru":true}}"#)
        XCTAssertEqual(response["ok"] as? Bool, true, "dashboard --mru should succeed: \(response)")
        XCTAssertTrue(dashboardOverlay.waitForExistence(timeout: 15), "the mru dashboard overlay should appear")

        XCTAssertTrue(pollCellCount(4, timeout: 15), "mru renders one cell per recent session (≤9, fewer if fewer)")
        let members = try XCTUnwrap(dashMembers(), "tree carries the mru members while open")
        // the sessions have no split, so each is a single primary-pane cell (`<id>:left`), in mru order.
        XCTAssertEqual(members.map { $0.lowercased() }, expected.map { "\($0.lowercased()):left" },
                       "mru members are the window's sessions in most-recent-first order (each a primary pane cell)")

        try closeDashboard()
        XCTAssertTrue(dashboardOverlay.waitForNonExistence(timeout: 10), "close removes the mru overlay")
        XCTAssertNil(dashMembers(), "the mru members read-back clears on close")
    }

    // a SPLIT session opens as TWO cells — its primary AND its split pane — so tree.dashboardMembers carries
    // BOTH `<id>:left` and `<id>:right`. Highlighting the split (right) cell and pressing Enter focuses the
    // RIGHT pane, asserted via the tree `splitFocused` read-back (flips false → true). The focus routing is
    // real behavior, not a weaker proxy: `splitFocused` is the same field `session.focus` reads back.
    func testSplitSessionOpensTwoCellsAndEnterFocusesSplitPane() throws {
        let ids = try prepareSessions(extra: 0) // just the seeded session
        let id = ids[0]
        // give the session a split pane (both shells alive). `session.split on` shows it and focuses the new
        // RIGHT pane, so move focus back to the LEFT pane first — that makes the split-cell Enter below flip
        // splitFocused false → true, a real (non-vacuous) effect to assert.
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(id)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "session.split on should succeed")
        XCTAssertTrue(pollSplit(id, timeout: 10), "the session should report a split")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.focus","target":"\#(id)","args":{"pane":"left"}}"#)["ok"] as? Bool,
                       true, "session.focus left should succeed")
        XCTAssertTrue(pollSplitFocused(id, expected: false, timeout: 10), "focus the left pane before opening")

        try openDashboard(members: [id])
        XCTAssertTrue(pollCellCount(2, timeout: 15), "a split session opens as two pane cells")
        let members = try XCTUnwrap(dashMembers(), "tree carries the pane-ref members while open")
        XCTAssertEqual(Set(members.map { $0.lowercased() }),
                       Set(["\(id.lowercased()):left", "\(id.lowercased()):right"]),
                       "the two cells are the session's left and right panes")

        // highlight the split (right) cell (right arrow: primary[0] → split[1]), then Enter.
        settle(0.5)
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(pollDashHighlightedRef("\(id):right", timeout: 8), "right arrow highlights the split pane cell")

        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(dashboardOverlay.waitForNonExistence(timeout: 10), "Enter closes the dashboard")
        XCTAssertTrue(pollSelectedSession(id, timeout: 10), "Enter selects the session")
        XCTAssertTrue(pollSplitFocused(id, expected: true, timeout: 10),
                      "Enter on the split cell focuses the RIGHT pane (splitFocused flips to true)")
    }

    // regression: opening the dashboard over a session whose FOCUSED split pane holds first responder must
    // hand the keyboard to the dashboard's key-catcher, not leave it with the reparented pane surface. The
    // focused split surface carries first responder ACROSS the reparent into the view-only cell
    // (`acceptsFirstResponder=false` blocks only NEW grabs, never a HELD one), so without the viewOnly resign
    // it keeps the keyboard — a bare arrow goes to that pane (invisible) instead of walking the highlight.
    // Deliberately does NOT use the `openDashboard` helper: its post-open cell click forces a key-catcher
    // re-grab that would MASK this exact race (the test would then pass even on the broken code). Routing is
    // established by the pre-open `row.click()` + `splitButton.click()` (the SplitUITests idiom) and persists
    // into the socket-opened dashboard, so the bare arrow below is the real discriminator.
    func testDashboardOverFocusedSplitPaneGivesKeyboardToKeyCatcher() throws {
        let ids = try prepareSessions(extra: 0) // just the seeded session
        let id = ids[0]

        // GUI click establishes XCUITest key routing AND focuses the seeded terminal; the split button then
        // moves focus to the NEW right pane, so its surface holds first responder (SplitUITests idiom).
        let row = app.staticTexts["session-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the seeded row should exist")
        row.click()
        settle(0.6)
        let splitButton = app.buttons["split-toggle"]
        XCTAssertTrue(splitButton.waitForExistence(timeout: 5), "split toolbar button should exist")
        splitButton.click()
        XCTAssertTrue(pollSplit(id, timeout: 10), "the session should report a split")
        XCTAssertTrue(pollSplitFocused(id, expected: true, timeout: 10), "opening the split focuses the right pane")

        // open the dashboard over the split session via the SOCKET, WITHOUT the masking cell click.
        let response = try sendCommand(#"{"cmd":"dashboard","args":{"targets":["\#(id)"]}}"#)
        XCTAssertEqual(response["ok"] as? Bool, true, "dashboard open should succeed: \(response)")
        XCTAssertTrue(dashboardOverlay.waitForExistence(timeout: 15), "the dashboard overlay should appear")
        XCTAssertTrue(pollCellCount(2, timeout: 15), "the split session opens as two pane cells")
        XCTAssertTrue(pollDashHighlightedRef("\(id):left", timeout: 8), "the highlight starts on the primary pane cell")

        // a bare right arrow must WALK the highlight to the split cell — proving the key-catcher owns the
        // keyboard. Without the viewOnly resign, the carried-in split surface swallows the arrow and the
        // highlight never leaves the primary cell.
        settle(0.5)
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(pollDashHighlightedRef("\(id):right", timeout: 8),
                      "a bare arrow walks the highlight — the key-catcher, not the reparented split pane, owns keys")
    }

    // arrow keys walk the highlight between cells (observed via tree.dashboardHighlighted and the
    // `dashboard-highlighted` marker), and Enter jumps into the highlighted session — closing the overlay AND
    // moving the selection to that session.
    func testArrowMovesHighlightAndEnterSelectsClosingDashboard() throws {
        let ids = try prepareSessions(extra: 1) // [seeded, new1] → a 1x2 grid
        try openDashboard(members: ids)

        let initial = try XCTUnwrap(dashHighlighted(), "the highlight is set while open")
        XCTAssertEqual(refSession(initial), ids[0].lowercased(), "the highlight starts on the first member")
        XCTAssertTrue(highlightedMarker.waitForExistence(timeout: 10), "the highlighted cell renders its marker")

        // give the AppKit key-catcher a beat to own first responder, then move the highlight right.
        settle(0.5)
        app.typeKey(.rightArrow, modifierFlags: [])
        let moved = pollDashHighlighted(changedFrom: ids[0], timeout: 8)
        XCTAssertEqual(moved.map(refSession), ids[1].lowercased(), "right arrow moves the highlight to the next cell")

        // Enter selects the highlighted session and closes the dashboard.
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(dashboardOverlay.waitForNonExistence(timeout: 10), "Enter closes the dashboard")
        XCTAssertNil(dashMembers(), "the dashboard read-backs clear once it closes")
        XCTAssertTrue(pollSelectedSession(ids[1], timeout: 10), "Enter selects the highlighted session")
    }

    // Esc dismisses the dashboard WITHOUT jumping in: the selection is whatever it was before opening, even
    // though the highlight was moved onto a different session.
    func testEscapeClosesDashboardWithoutChangingSelection() throws {
        let ids = try prepareSessions(extra: 1)
        // pin a known baseline selection distinct from the cell we will highlight (so a wrongly-selecting Esc
        // would be observable as a change to ids[1]).
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(ids[0])"}"#)["ok"] as? Bool, true,
                       "selecting the seeded session should succeed")
        XCTAssertTrue(pollSelectedSession(ids[0], timeout: 10), "the seeded session is selected before opening")

        try openDashboard(members: ids)
        settle(0.5)
        app.typeKey(.rightArrow, modifierFlags: []) // highlight → ids[1]
        _ = pollDashHighlighted(changedFrom: ids[0], timeout: 8)

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(dashboardOverlay.waitForNonExistence(timeout: 10), "Esc closes the dashboard")
        // give any (wrongly) armed selection change time to LAND and assert it never does — polling for the
        // WRONG state's absence, rather than a fixed settle before one read that could pass vacuously.
        XCTAssertFalse(pollSelectedSession(ids[1], timeout: 3), "Esc must not select the highlighted session")
        XCTAssertEqual(selectedSessionID()?.lowercased(), ids[0].lowercased(),
                       "Esc leaves the pre-open selection in place")
    }

    // while the view-only dashboard is open the full titlebar is swapped for a stripped bar (mirroring
    // terminal zoom): its interactive session controls are GONE, so a stray click on one can no longer steal
    // the key-catcher's first responder (which stranded Esc) or drive an action behind the grid. Only an exit
    // button remains, and clicking it closes the dashboard.
    func testDashboardTitlebarStripsInteractiveButtonsAndExitCloses() throws {
        let ids = try prepareSessions(extra: 1)

        // baseline: the full titlebar's session controls exist before opening.
        XCTAssertTrue(app.buttons["split-toggle"].waitForExistence(timeout: 15),
                      "the split button renders in the normal titlebar")

        try openDashboard(members: ids)

        // opening swaps in the stripped titlebar: every interactive session control is gone...
        for control in ["split-toggle", "sidebar-toggle-button", "scratch-toggle", "quick-terminal-toggle"] {
            XCTAssertTrue(app.buttons[control].waitForNonExistence(timeout: 10),
                          "\(control) must not render while the dashboard is open")
        }
        // ...and only the exit button remains (the counterpart of terminal-zoom-exit).
        let exit = app.buttons["dashboard-exit"]
        XCTAssertTrue(exit.waitForExistence(timeout: 10), "the stripped dashboard titlebar shows an exit button")

        // the exit button closes the dashboard (same close-and-refocus path as Esc)...
        exit.click()
        XCTAssertTrue(dashboardOverlay.waitForNonExistence(timeout: 10), "the exit button closes the dashboard")
        // ...and the full titlebar returns once it is closed.
        XCTAssertTrue(app.buttons["split-toggle"].waitForExistence(timeout: 10),
                      "the full titlebar returns once the dashboard closes")
    }

    // the correctness crux: while the dashboard is open it is VIEW-ONLY — neither a typed keystroke nor a
    // mouse click reaches any terminal. Proven with a three-phase probe so the negative is not vacuous:
    //   1. before opening, GUI typing DOES reach the focused terminal (a marker file is written);
    //   2. while open, a typed sentinel is swallowed (it never echoes into the surface buffer) and a cell
    //      click is consumed by the dashboard (it moves the highlight) rather than the terminal beneath it;
    //   3. after closing, GUI typing reaches the terminal again — so the block in phase 2 was the dashboard,
    //      not a dead terminal.
    func testDashboardIsViewOnlyKeystrokesAndClickDoNotReachTerminal() throws {
        let ids = try prepareSessions(extra: 1) // [seeded, new1]

        // focus the seeded terminal via its sidebar row (row click → select + focus, the SplitUITests idiom).
        let seededRow = app.staticTexts.matching(identifier: "session-row").element(boundBy: 0)
        XCTAssertTrue(seededRow.waitForExistence(timeout: 15), "the seeded row should exist")
        seededRow.click()
        settle(0.8)

        // PHASE 1 — GUI keystrokes reach the focused terminal (baseline that typing works at all). Retry the
        // GUI type until the marker lands: a freshly focused terminal's pty may not be ready to read when the
        // first keystrokes arrive (especially under full-suite CPU load), so a single type can be dropped —
        // the GUI-input twin of the base typeUntilMarker readiness wait.
        let beforeFile = markerDir.appendingPathComponent("before")
        XCTAssertNotNil(typeShellMarkerUntilFile(token: "DASHBEFORE7788", file: beforeFile),
                        "GUI keystrokes should reach the terminal before the dashboard opens")

        try openDashboard(members: ids)
        settle(0.6)

        // PHASE 2 — typing while open is swallowed by the key-catcher, so nothing echoes into the surface.
        // No Return: a Return would be consumed as Enter=select and close the overlay, so a leak is detected
        // by the sentinel appearing in the buffer, not by a marker file.
        app.typeText("LEAKSENTINEL9911")
        // a single click on the OTHER cell must reach the dashboard hit target (moving the highlight), never
        // the terminal below it (the member terminal is allowsHitTesting(false)).
        let secondCell = dashboardCells().element(boundBy: 1)
        XCTAssertTrue(secondCell.waitForExistence(timeout: 10), "the second member cell should exist")
        secondCell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        // poll for the highlight to move to the clicked cell FIRST — a POSITIVE precondition proving the
        // input pipeline drained PAST the typed sentinel, so a leaked keystroke would already be in the
        // buffer below (a fixed settle before the negative buffer read could pass vacuously, hiding a late leak).
        let moved = pollDashHighlighted(changedFrom: ids[0], timeout: 8)
        XCTAssertEqual(moved.map(refSession), ids[1].lowercased(),
                       "a cell click highlights that cell (dashboard input), proving it never reached the terminal")

        XCTAssertTrue(dashboardOverlay.exists, "typing and clicking must not dismiss the view-only dashboard")
        let buffer = try readSessionText(ids[0])
        XCTAssertFalse(buffer.isEmpty, "the member surface buffer should be readable (its shell prompt)")
        XCTAssertFalse(buffer.contains("LEAKSENTINEL9911"),
                       "no typed keystroke may reach a terminal while the dashboard is open")

        // PHASE 3 — closing restores terminal focus, and GUI typing lands again.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(dashboardOverlay.waitForNonExistence(timeout: 10), "Esc closes the dashboard")
        settle(0.8)
        let afterFile = markerDir.appendingPathComponent("after")
        typeShellMarker(token: "DASHAFTER7788", file: afterFile)
        XCTAssertNotNil(pollMarker(afterFile, timeout: 10),
                        "closing the dashboard restores terminal focus so GUI typing lands again")
    }

    // opening with --auto-size records a positive applied font size and fontMode=auto on `tree` while open,
    // and both clear on close. The font PIXEL size and the visual "restored" state are NOT a11y-observable —
    // this asserts the observable read-back proxies only (the pixel-level restore is covered by the manual
    // dev-instance check in the plan's Post-Completion; do NOT fake a pixel assertion here). Also opens while
    // a member is running a command, to sanity-check the reparent doesn't crash on a busy surface.
    func testAutoSizeFontReadsBackWhileOpenAndClearsOnClose() throws {
        let ids = try prepareSessions(extra: 1)
        // start light output in a member so the open path reparents a BUSY surface (a no-crash sanity check).
        startFlow(in: ids[0])
        settle(1.0)

        try openDashboard(members: ids, autoSize: true)

        XCTAssertEqual(dashMembers()?.count, 2, "the dashboard reports its members while open")
        XCTAssertEqual(dashFontMode(), "auto", "--auto-size reports fontMode=auto")
        let size = try XCTUnwrap(pollDashFontSize(timeout: 10), "--auto-size sets an applied font size for read-back")
        XCTAssertGreaterThan(size, 0, "the applied dashboard font size should be a positive point value")

        // an explicit config reload while the dashboard is open must not STRAND it: the overlay stays up and
        // the applied-font read-back survives (app-side, `reapplySessionConfigIfNeeded` reasserts the transient
        // surface override across the reload). The PIXEL-level "font correctly restored" check is not
        // a11y-observable and stays the manual dev-instance verification in the plan's Post-Completion.
        XCTAssertEqual(try sendCommand(#"{"cmd":"config.reload"}"#)["ok"] as? Bool, true, "config.reload should succeed")
        settle(0.6)
        XCTAssertTrue(dashboardOverlay.exists, "a config reload while open must not tear down the dashboard")
        XCTAssertEqual(dashFontMode(), "auto", "the dashboard font mode survives a config reload")
        XCTAssertNotNil(dashFontSize(), "the applied dashboard font read-back survives a config reload")

        try closeDashboard()
        XCTAssertTrue(dashboardOverlay.waitForNonExistence(timeout: 10), "close removes the overlay")
        XCTAssertNil(dashMembers(), "the members read-back clears on close")
        XCTAssertNil(dashFontSize(), "the font-size read-back clears on close")
        XCTAssertNil(dashFontMode(), "the font-mode read-back clears on close")
    }

    // a busy multi-cell dashboard survives a live window resize: the cells stay present (count unchanged) and
    // the app stays responsive (tree keeps answering — no crash/hang). True "no blank cell" is a pixel
    // property not observable from XCUITest; this asserts the observable parts only.
    func testDashboardResizeWhileBusyKeepsCellsAndResponsive() throws {
        let ids = try prepareSessions(extra: 3) // 4 sessions → a full 2x2 grid (no filler)
        XCTAssertEqual(ids.count, 4)
        for id in ids { startFlow(in: id) } // best-effort: exercise the busy path (assertions are structural)
        settle(1.0)

        try openDashboard(members: ids)
        XCTAssertTrue(pollCellCount(4, timeout: 15), "the 2x2 grid renders four member cells")

        resizeWindow(width: 1200, height: 900)
        settle(0.8)
        XCTAssertTrue(pollCellCount(4, timeout: 10), "the cells survive a window grow")
        XCTAssertEqual(dashMembers()?.count, 4, "the dashboard stays open and responsive after the grow")

        resizeWindow(width: 720, height: 540)
        settle(0.8)
        XCTAssertTrue(pollCellCount(4, timeout: 10), "the cells survive a window shrink")
        XCTAssertEqual(dashMembers()?.count, 4, "the dashboard stays open and responsive after the shrink")

        try closeDashboard()
        XCTAssertTrue(dashboardOverlay.waitForNonExistence(timeout: 10), "close removes the overlay after the resize")
    }

    // the Navigate ▸ Dashboard menu item (⌘⇧D) is the GUI opener for the MRU dashboard grid — it TOGGLES:
    // opening the window's most-recently-used sessions when closed, closing when open. Seeds a known recency
    // via explicit selects, opens via the menu item, asserts the overlay renders one cell per recent session
    // (the mru members), then toggles it closed via the same menu item and asserts the overlay is gone.
    func testNavigateDashboardMenuTogglesMruGrid() throws {
        let ids = try prepareSessions(extra: 2) // 3 sessions total
        XCTAssertEqual(ids.count, 3)
        // seed a deterministic recency so the mru open has members (each select pushes MRU front).
        for id in ids {
            XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(id)"}"#)["ok"] as? Bool, true,
                           "selecting \(id) should succeed")
            XCTAssertTrue(pollSelectedSession(id, timeout: 10), "the select should land before the next")
        }

        XCTAssertFalse(dashboardOverlay.exists, "no dashboard overlay before opening")
        openDashboardViaMenu()
        XCTAssertTrue(dashboardOverlay.waitForExistence(timeout: 15), "the Navigate ▸ Dashboard item opens the grid")
        XCTAssertTrue(pollCellCount(3, timeout: 15), "the mru grid renders one cell per recent session")
        XCTAssertEqual(dashMembers()?.count, 3, "tree.dashboardMembers matches the mru member count")
        XCTAssertEqual(dashFontMode(), "auto", "the menu opener is the --auto-size equivalent")

        // toggling the same menu item again closes it.
        openDashboardViaMenu()
        XCTAssertTrue(dashboardOverlay.waitForNonExistence(timeout: 10), "the menu item toggles the dashboard closed")
        XCTAssertNil(dashMembers(), "tree.dashboardMembers clears on the toggle-close")
    }

    // while the dashboard is open the UI is modal: session-mutating menu key-equivalents are gated the same
    // way terminal zoom gates them. ⌘N (new_session) routes through the menu (performKeyEquivalent, PAST the
    // grid's keyDown-only key-catcher), but the New Session item is .disabled while the dashboard is open AND
    // AppActions.newSession guards on uiActionsEnabled, so it neither creates a session nor dismisses the grid.
    // The Dashboard toggle stays enabled so ⌘⇧D still closes the grid — the user is never trapped.
    func testDashboardGatesSessionShortcutsWhileOpen() throws {
        let ids = try prepareSessions(extra: 1) // [seeded, new1] → two sessions
        XCTAssertEqual(ids.count, 2)
        XCTAssertTrue(pollSessionCount(2, timeout: 10), "two sessions before opening the dashboard")

        try openDashboard(members: ids)
        XCTAssertTrue(pollCellCount(2, timeout: 15), "the dashboard opens over both sessions")

        // ⌘N is a session-mutating menu key-equivalent; while the dashboard is open it must be a no-op. Poll
        // for the WRONG state (a third session) never landing rather than a single settled read.
        app.typeKey("n", modifierFlags: .command)
        settle(0.8)
        XCTAssertTrue(dashboardOverlay.exists, "a gated shortcut must not dismiss the view-only dashboard")
        XCTAssertEqual(dashMembers()?.count, 2, "the gated shortcut leaves the dashboard members unchanged")
        XCTAssertFalse(pollSessionCount(3, timeout: 3), "⌘N must not create a session while the dashboard is open")

        // the Dashboard toggle stays enabled (the escape hatch): ⌘⇧D closes the grid cleanly.
        app.typeKey("d", modifierFlags: [.command, .shift])
        XCTAssertTrue(dashboardOverlay.waitForNonExistence(timeout: 10), "⌘⇧D closes the open dashboard")
        XCTAssertNil(dashMembers(), "the dashboard read-backs clear on the toggle-close")
        XCTAssertTrue(pollSessionCount(2, timeout: 5), "the session set is unchanged after gating + close")
    }

    // ⌘W (close_session) DISMISSES the open dashboard like it dismisses terminal zoom — it must NOT close a
    // session behind the grid. Distinct from the ⌘N gating above: ⌘N stays gated (grid stays OPEN, no new
    // session), while ⌘W dismisses the grid (and closes no session). The Close Session menu item stays enabled
    // while modal (so ⌘W can dismiss the cover); its key-equivalent routes through the menu, PAST the grid's
    // keyDown-only key-catcher, into closeActiveSession, whose dashboard branch closes the grid and refocuses
    // the session before ever reaching the session-close path.
    func testCloseSessionShortcutDismissesDashboardWithoutClosingSession() throws {
        let ids = try prepareSessions(extra: 1) // [seeded, new1] → two sessions
        XCTAssertEqual(ids.count, 2)
        XCTAssertTrue(pollSessionCount(2, timeout: 10), "two sessions before opening the dashboard")

        try openDashboard(members: ids)
        XCTAssertTrue(pollCellCount(2, timeout: 15), "the dashboard opens over both sessions")

        // ⌘W while the dashboard is open closes the GRID, not a session.
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(dashboardOverlay.waitForNonExistence(timeout: 10), "⌘W dismisses the open dashboard")
        XCTAssertNil(dashMembers(), "the dashboard read-backs clear on the ⌘W dismiss")
        // poll for the WRONG state (a session closed → count 1) never landing rather than a single settled read,
        // then assert the full count held — a ⌘W that leaked to close-session would drop a session here.
        XCTAssertFalse(pollSessionCount(1, timeout: 3), "⌘W must not close a session while the dashboard is open")
        XCTAssertTrue(pollSessionCount(2, timeout: 5), "the session set is unchanged after the ⌘W dismiss")
    }

    /// Click Navigate ▸ Dashboard in the menu bar.
    private func openDashboardViaMenu() {
        app.menuBars.menuBarItems["Navigate"].click()
        let item = app.menuItems["Dashboard"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the Navigate menu should offer a Dashboard item")
        item.click()
    }

    // MARK: - element queries

    private var dashboardOverlay: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "dashboard").firstMatch
    }

    private func dashboardCells() -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "dashboard-cell")
    }

    private var highlightedMarker: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "dashboard-highlighted").firstMatch
    }

    // MARK: - socket helpers

    /// Create `extra` sessions (each `session.new`), wait for them all in the sidebar, and return every
    /// session id (seeded first) in tree order — the order the dashboard uses for member/grid placement.
    @discardableResult
    private func prepareSessions(extra: Int) throws -> [String] {
        for _ in 0..<extra {
            XCTAssertEqual(try sendCommand(#"{"cmd":"session.new"}"#)["ok"] as? Bool, true, "session.new should succeed")
        }
        XCTAssertTrue(pollSessionRowCount(extra + 1, timeout: 15), "all sessions should appear in the sidebar")
        return try allSessionIDs()
    }

    /// Open the dashboard over the socket with `members` (in order) and wait for the overlay to mount.
    private func openDashboard(members: [String], autoSize: Bool = false) throws {
        var args: [String: Any] = ["targets": members]
        if autoSize { args["autoSize"] = true }
        let data = try JSONSerialization.data(withJSONObject: ["cmd": "dashboard", "args": args])
        let line = try XCTUnwrap(String(data: data, encoding: .utf8))
        let response = try sendCommand(line)
        XCTAssertEqual(response["ok"] as? Bool, true, "dashboard open should succeed: \(response)")
        XCTAssertTrue(dashboardOverlay.waitForExistence(timeout: 15), "the dashboard overlay should appear")
        // the dashboard was opened over the SOCKET with no GUI interaction. A bare arrow is delivered to the
        // key window's first responder (unlike SplitUITests' MODIFIED arrows, which the menu dispatches), and
        // XCUITest only routes synthesized keystrokes into the app after a real click establishes it as the
        // event target. Click the highlighted marker (it fills the highlighted cell, so the click re-selects
        // the SAME cell — no highlight change) to establish that routing and settle the key-catcher's first
        // responder before any keystroke.
        if highlightedMarker.waitForExistence(timeout: 10) {
            highlightedMarker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            settle(0.5)
        }
    }

    private func closeDashboard() throws {
        let response = try sendCommand(#"{"cmd":"dashboard","args":{"close":true}}"#)
        XCTAssertEqual(response["ok"] as? Bool, true, "dashboard --close should succeed: \(response)")
    }

    /// Fire-and-forget a light flowing-output loop into a session's main surface (best-effort — a not-yet-
    /// realized surface errors, which we ignore since the busy path is a sanity exercise, not an assertion).
    private func startFlow(in id: String) {
        _ = try? sendCommand(
            #"{"cmd":"session.type","target":"\#(id)","args":{"text":"while true; do date; sleep 0.05; done\n","select":false}}"#)
    }

    private func resizeWindow(width: Int, height: Int) {
        XCTAssertEqual(
            try? sendCommand(#"{"cmd":"window.resize","args":{"width":\#(width),"height":\#(height)}}"#)["ok"] as? Bool,
            true, "window.resize should succeed")
    }

    private func readSessionText(_ id: String) throws -> String {
        let response = try sendCommand(#"{"cmd":"session.text","target":"\#(id)"}"#)
        return (response["result"] as? [String: Any])?["text"] as? String ?? ""
    }

    /// Type `echo <token> > '<file>'` + Return into whatever terminal currently holds first responder.
    private func typeShellMarker(token: String, file: URL) {
        app.typeText("echo \(token) > '\(file.path)'")
        app.typeKey(.return, modifierFlags: [])
    }

    /// Type the shell marker via the GUI keyboard, retrying until the marker file appears (or attempts are
    /// exhausted). The GUI-input twin of the base `typeUntilMarker` (which drives the control socket): phase 1
    /// of the view-only test must prove GUI keystrokes reach the terminal, so it cannot use the socket-driven
    /// helper. A freshly focused terminal's shell/pty may not be ready to read when the first keystrokes land,
    /// so a single type can be dropped — re-typing once the shell has had a beat is the deterministic readiness
    /// wait. The `echo` line is idempotent, so re-typing is safe. Returns the marker contents, or nil if it
    /// never appeared across all attempts.
    @discardableResult
    private func typeShellMarkerUntilFile(token: String, file: URL, attempts: Int = 4,
                                          perAttempt: TimeInterval = 4) -> String? {
        for _ in 0..<attempts {
            // clear any marker a prior attempt's late write may have left, so a stale value isn't read as success.
            try? FileManager.default.removeItem(at: file)
            typeShellMarker(token: token, file: file)
            if let value = pollMarker(file, timeout: perAttempt) { return value }
        }
        return nil
    }

    // MARK: - tree read-back

    private func treeTop() throws -> [String: Any] {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let result = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        return try XCTUnwrap(result["tree"] as? [String: Any], "result should carry a tree")
    }

    private func allSessionIDs() throws -> [String] {
        let workspace = try XCTUnwrap((treeTop()["workspaces"] as? [[String: Any]])?.first, "a seeded workspace")
        let sessions = try XCTUnwrap(workspace["sessions"] as? [[String: Any]], "workspace sessions")
        return try sessions.map { try XCTUnwrap($0["id"] as? String, "session id") }
    }

    /// The currently selected (active-flagged) session id, or nil if the tree isn't readable yet. Distinct
    /// from the base `activeSessionID()`, which returns the FIRST session rather than the selected one.
    private func selectedSessionID() -> String? {
        guard let workspaces = (try? treeTop())?["workspaces"] as? [[String: Any]] else { return nil }
        for workspace in workspaces {
            for session in (workspace["sessions"] as? [[String: Any]] ?? []) where session["active"] as? Bool == true {
                return session["id"] as? String
            }
        }
        return nil
    }

    private func dashMembers() -> [String]? { (try? treeTop())?["dashboardMembers"] as? [String] }
    private func dashHighlighted() -> String? { (try? treeTop())?["dashboardHighlighted"] as? String }
    private func dashFontSize() -> Double? { (try? treeTop())?["dashboardFontSize"] as? Double }
    private func dashFontMode() -> String? { (try? treeTop())?["dashboardFontMode"] as? String }

    // MARK: - polling

    private func pollCellCount(_ expected: Int, timeout: TimeInterval) -> Bool {
        let cells = dashboardCells()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cells.count == expected { return true }
            usleep(200_000)
        }
        return cells.count == expected
    }

    /// The session part of a dashboard pane ref (`<uuid>:left`/`:right` → `<uuid>`), lowercased.
    private func refSession(_ ref: String) -> String { String(ref.split(separator: ":").first ?? "").lowercased() }

    /// Polls `tree.dashboardHighlighted` until its SESSION part differs from the `old` session id
    /// (case-insensitive), returning the new pane ref, or the last-read value on timeout.
    private func pollDashHighlighted(changedFrom old: String, timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let current = dashHighlighted(), refSession(current) != old.lowercased() { return current }
            usleep(200_000)
        }
        return dashHighlighted()
    }

    /// Polls `tree.dashboardHighlighted` until it equals `ref` exactly (case-insensitive pane ref), for the
    /// split test where the two cells share a session and only the pane part distinguishes them.
    private func pollDashHighlightedRef(_ ref: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if dashHighlighted()?.lowercased() == ref.lowercased() { return true }
            usleep(200_000)
        }
        return dashHighlighted()?.lowercased() == ref.lowercased()
    }

    /// The `tree` session node for `id`, or nil if not readable yet.
    private func sessionNode(_ id: String) -> [String: Any]? {
        guard let workspaces = (try? treeTop())?["workspaces"] as? [[String: Any]] else { return nil }
        for workspace in workspaces {
            for session in (workspace["sessions"] as? [[String: Any]] ?? [])
            where (session["id"] as? String)?.lowercased() == id.lowercased() {
                return session
            }
        }
        return nil
    }

    /// Polls the session node's `split` (isSplit) flag until true.
    private func pollSplit(_ id: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sessionNode(id)?["split"] as? Bool == true { return true }
            usleep(200_000)
        }
        return sessionNode(id)?["split"] as? Bool == true
    }

    /// Polls the session node's `splitFocused` read-back until it equals `expected`.
    private func pollSplitFocused(_ id: String, expected: Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sessionNode(id)?["splitFocused"] as? Bool == expected { return true }
            usleep(200_000)
        }
        return sessionNode(id)?["splitFocused"] as? Bool == expected
    }

    private func pollDashFontSize(timeout: TimeInterval) -> Double? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let size = dashFontSize() { return size }
            usleep(200_000)
        }
        return dashFontSize()
    }

    private func pollSelectedSession(_ id: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if selectedSessionID()?.lowercased() == id.lowercased() { return true }
            usleep(200_000)
        }
        return selectedSessionID()?.lowercased() == id.lowercased()
    }

    /// Drain the run loop for `seconds` — the async-settle idiom the control suites use, so an @Observable
    /// mutation (highlight move, member-change font apply, reparent) has landed before the next read.
    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
