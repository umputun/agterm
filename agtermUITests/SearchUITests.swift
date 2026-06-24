import XCTest

/// End-to-end test for the in-terminal search bar. The terminal surface is a Metal
/// `GhosttySurfaceView` with no readable accessibility text, so the oracle is the bar's
/// `search-counter` StaticText: pressing ⌘F sends `start_search`, typing a needle sends
/// `search:<needle>`, and the START_SEARCH/SEARCH_TOTAL callbacks populate the counter. A
/// non-empty "N of M" / "M matches" counter therefore confirms the libghostty binding-action
/// strings actually fire end-to-end (the deferred empirical check Task 5 could not run headlessly).
@MainActor
final class SearchUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stateDir: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-uitest-\(UUID().uuidString)", isDirectory: true)
        app = XCUIApplication()
        app.launchEnvironment["AGTERM_STATE_DIR"] = stateDir.path
        app.launchForUITest()
    }

    override func tearDown() async throws {
        app?.terminate()
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
    }

    // ⌘F opens the bar; typing a needle that appears repeatedly on screen (the echoed command line
    // plus its output both carry the token) round-trips through start_search + search:<needle> and the
    // SEARCH_TOTAL callback, so the counter reports matches — which confirms the binding strings fire.
    func testSearchBarOpensTypesAndCounts() throws {
        selectSeededSession()

        // put a known, repeated token on screen: the typed command line AND its echoed output both
        // contain "agtermFINDME", guaranteeing at least two matches in the scrollback.
        app.typeText("echo agtermFINDME agtermFINDME")
        app.typeKey(.return, modifierFlags: [])

        // ⌘F opens the search bar over the focused pane.
        app.typeKey("f", modifierFlags: .command)
        let field = app.textFields["search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⌘F should open the search bar with a search-field")

        // type the needle; the bar's binding drives search:<needle> on each keystroke. the echoed line
        // render + the async SEARCH_TOTAL callback can lag, so re-send the needle until a real match
        // count settles (NOT "no matches", which the echo-not-yet-rendered case would briefly show). the
        // counter StaticText is empty (absent from the AX tree) until a count lands, so it's looked up
        // INSIDE the poll, only after the needle is sent.
        let label = waitForMatchLabel(field: field, needle: "agtermFINDME", timeout: 12)
        let resolved = try XCTUnwrap(label, "the search counter should report a match count (binding strings fired)")
        XCTAssertTrue(resolved.contains("of") || resolved.contains("matches"),
                      "counter should read 'N of M' or 'M matches', got '\(resolved)'")
    }

    // While the quick terminal covers the session, ⌘F must NOT open the search bar over the hidden pane
    // (a covered, focus-stealing bar). The OPEN is gated when a covering surface is up; the search-field
    // must NOT appear.
    func testSearchDoesNotOpenWhileQuickTerminalCovers() throws {
        selectSeededSession()

        // open the quick terminal — a window-level cover over the session.
        let qtButton = app.buttons["quick-terminal-toggle"]
        XCTAssertTrue(qtButton.waitForExistence(timeout: 5), "quick-terminal toolbar button should exist")
        qtButton.click()
        // drain the run loop so the panel is up before ⌘F.
        RunLoop.current.run(until: Date().addingTimeInterval(0.9))

        // ⌘F goes through the Find menu key-equivalent; it must no-op while the cover is up.
        app.typeKey("f", modifierFlags: .command)
        let field = app.textFields["search-field"]
        XCTAssertFalse(field.waitForExistence(timeout: 3),
                       "⌘F while the quick terminal covers the session must NOT open a hidden search bar")
    }

    // Search works IN the scratch terminal: with the scratch shown, ⌘F opens the bar over the scratch
    // surface (not the hidden pane underneath), and typing a needle that appears in the scratch's
    // scrollback round-trips through start_search + search:<needle> so the counter reports matches.
    func testSearchOpensOverScratch() throws {
        selectSeededSession()

        // open the scratch terminal — a full-coverage layer over the session; autoFocus puts first
        // responder in the scratch shell, so typeText goes to it.
        let scratchButton = app.buttons["scratch-toggle"]
        XCTAssertTrue(scratchButton.waitForExistence(timeout: 5), "scratch toolbar button should exist")
        scratchButton.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.9))

        // put a known, repeated token in the SCRATCH scrollback: the typed line and its echoed output
        // both carry "scratchFINDME", guaranteeing at least two matches.
        app.typeText("echo scratchFINDME scratchFINDME")
        app.typeKey(.return, modifierFlags: [])

        // ⌘F now opens the bar over the scratch (the cover gate no longer blocks it for the scratch).
        app.typeKey("f", modifierFlags: .command)
        let field = app.textFields["search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5),
                      "⌘F while the scratch terminal is shown SHOULD open the search bar over the scratch")

        // the needle matches against the SCRATCH content, confirming search targets the scratch surface.
        let label = waitForMatchLabel(field: field, needle: "scratchFINDME", timeout: 12)
        let resolved = try XCTUnwrap(label, "the search counter should report a match against the scratch content")
        XCTAssertTrue(resolved.contains("of") || resolved.contains("matches"),
                      "counter should read 'N of M' or 'M matches', got '\(resolved)'")
    }

    // Esc closes the bar: the close path sends end_search, the END_SEARCH callback clears the fields
    // and hides the bar, so the search-field leaves the accessibility tree. Fresh launch (one reliable
    // keyboard-driven interaction per launch is the norm for these tests).
    func testSearchBarCloses() throws {
        selectSeededSession()

        app.typeKey("f", modifierFlags: .command)
        let field = app.textFields["search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⌘F should open the search bar")

        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "Esc should close the search bar")
    }

    /// Click the seeded session row and drain the run loop until it reports selected, so the responder
    /// bounce (mouseDown → focusActiveTerminal) settles before a chord is pressed — a wait-for-condition
    /// rather than a fixed sleep (the KeymapUITests focusTerminal idiom).
    private func selectSeededSession() {
        let row = app.staticTexts["session-row"].firstMatch
        XCTAssertTrue(row.waitForHittable(timeout: 20), "seeded session should be hittable")
        row.click()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, row.isSelected == false {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// Types `needle` into the field and polls the counter until it reports a REAL match (an "N of M" /
    /// non-zero "M matches" string, NOT "no matches" — which the echo-not-yet-rendered case briefly
    /// shows). Returns the settled label, or nil on timeout. The render + the SEARCH_TOTAL callback are
    /// both async and the counter StaticText is empty (absent from the tree) until a count lands, so a
    /// one-shot type races them; re-seeding the needle (clear → retype, changing the binding) re-fires
    /// search:<needle> after a late render.
    private func waitForMatchLabel(field: XCUIElement, needle: String, timeout: TimeInterval) -> String? {
        let counter = app.staticTexts["search-counter"]
        let deadline = Date().addingTimeInterval(timeout)
        var first = true
        while Date() < deadline {
            if first {
                field.typeText(needle)
                first = false
            } else {
                // re-seed: clear the field to empty (sends search:"") then retype the needle, so the
                // binding genuinely changes value and re-fires search:<needle> after a late render — typing
                // the identical string over itself would not change the binding and would not re-evaluate.
                field.click()
                field.typeKey("a", modifierFlags: .command)
                field.typeKey(.delete, modifierFlags: [])
                field.typeText(needle)
            }
            let counterDeadline = Date().addingTimeInterval(2)
            while Date() < counterDeadline {
                guard counter.exists else { usleep(150_000); continue }
                let text = ((counter.value as? String) ?? counter.label)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty, text != "no matches" { return text }
                usleep(150_000)
            }
        }
        return nil
    }
}
