import XCTest

/// End-to-end test for the in-terminal search bar. The terminal surface is a Metal
/// `GhosttySurfaceView` with no readable accessibility text, so the oracle is the bar's
/// `search-counter` StaticText, populated by the START_SEARCH/SEARCH_TOTAL callbacks — a non-empty
/// "N of M" / "M matches" counter is what confirms the libghostty binding-action strings fire.
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

    func testSearchBarOpensTypesAndCounts() throws {
        selectSeededSession()

        // the typed command line AND its echoed output both carry the token, so there are ≥2 matches.
        app.typeText("echo agtermFINDME agtermFINDME")
        app.typeKey(.return, modifierFlags: [])

        app.typeKey("f", modifierFlags: .command)
        let field = app.textFields["search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⌘F should open the search bar with a search-field")

        let label = waitForMatchLabel(field: field, needle: "agtermFINDME", timeout: 12)
        let resolved = try XCTUnwrap(label, "the search counter should report a match count (binding strings fired)")
        XCTAssertTrue(resolved.contains("of") || resolved.contains("matches"),
                      "counter should read 'N of M' or 'M matches', got '\(resolved)'")
    }

    func testSearchDoesNotOpenWhileQuickTerminalCovers() throws {
        selectSeededSession()

        let qtButton = app.buttons["quick-terminal-toggle"]
        XCTAssertTrue(qtButton.waitForExistence(timeout: 5), "quick-terminal toolbar button should exist")
        qtButton.click()
        // drain the run loop so the panel is up before ⌘F.
        RunLoop.current.run(until: Date().addingTimeInterval(0.9))

        app.typeKey("f", modifierFlags: .command)
        let field = app.textFields["search-field"]
        XCTAssertFalse(field.waitForExistence(timeout: 3),
                       "⌘F while the quick terminal covers the session must NOT open a hidden search bar")
    }

    func testSearchOpensOverScratch() throws {
        selectSeededSession()

        let scratchButton = app.buttons["scratch-toggle"]
        XCTAssertTrue(scratchButton.waitForExistence(timeout: 5), "scratch toolbar button should exist")
        scratchButton.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.9))

        // the scratch's autoFocus takes first responder, so this lands in the scratch shell; the typed line
        // and its echo both carry the token, so the scratch scrollback holds ≥2 matches.
        app.typeText("echo scratchFINDME scratchFINDME")
        app.typeKey(.return, modifierFlags: [])

        app.typeKey("f", modifierFlags: .command)
        let field = app.textFields["search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5),
                      "⌘F while the scratch terminal is shown SHOULD open the search bar over the scratch")

        let label = waitForMatchLabel(field: field, needle: "scratchFINDME", timeout: 12)
        let resolved = try XCTUnwrap(label, "the search counter should report a match against the scratch content")
        XCTAssertTrue(resolved.contains("of") || resolved.contains("matches"),
                      "counter should read 'N of M' or 'M matches', got '\(resolved)'")
    }

    // the END_SEARCH callback hides the bar, so the search-field leaves the accessibility tree.
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
                // typing the identical string over itself would not change the binding, so clear the
                // field first to make the re-typed needle re-fire search:<needle> after a late render.
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
