import XCTest

/// End-to-end coverage for the session second line (`Session.subtitleDetail`). A remote (SSH) host
/// sets the terminal title while the local OSC 7 cwd goes stale, so the second line must show that
/// title instead of the misleading local path. The title comes from real terminal output (a Metal
/// surface with no readable text), so these drive it by typing a `printf` that emits OSC 2 into the
/// focused shell — the shell's printf expands the `\033`/`\007` it is handed, so only printable
/// keystrokes are injected — then read the rendered palette subtitle through the accessibility tree.
///
/// The session palette, the Ctrl-Tab switcher, and the title bar all render the SAME `subtitleDetail`,
/// so the palette is the representative surface here (the property's branches are unit-tested in
/// `SessionTests`; the title-bar second line is hidden in the default compact toolbar).
@MainActor
final class SessionSubtitleUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stateDir: URL!
    /// The app's session cwd is its home directory, which on macOS lives under `/Users/`. Asserting on
    /// this marker (not the test runner's own home, which resolves differently across processes) tells a
    /// cwd second line apart from a title one.
    private let cwdMarker = "/Users/"

    override func setUp() async throws {
        continueAfterFailure = false
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-uitest-\(UUID().uuidString)", isDirectory: true)
        app = XCUIApplication()
        app.launchEnvironment["AGTERM_STATE_DIR"] = stateDir.path
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session should exist")
    }

    override func tearDown() async throws {
        app?.terminate()
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
    }

    func testNamedSessionShowsOscTitleOnSecondLine() throws {
        renameActiveSession(to: "demo-host")
        XCTAssertTrue(rowValueEquals("session-row", "demo-host"), "rename should pin the custom name on line 1")

        emitOscTitle("REMOTE-DEMO-TITLE")

        // the palette list is snapshotted on open, so reopen until the OSC title has landed; capture the
        // value that satisfied it for the negative assertion.
        var subtitle = ""
        XCTAssertTrue(poll(timeout: 10) {
            subtitle = self.currentPaletteSubtitle()
            self.closePalette()
            return subtitle.contains("REMOTE-DEMO-TITLE")
        }, "a named session's second line should show the OSC title; got \(subtitle)")
        XCTAssertFalse(subtitle.contains(cwdMarker), "the second line should drop the stale local path; got \(subtitle)")

        // line 1 stays the custom name — the title only ever changes the second line.
        XCTAssertTrue(rowValueEquals("session-row", "demo-host"), "the OSC title must not override the custom name")
    }

    func testUnnamedSessionKeepsCwdOnSecondLine() throws {
        emitOscTitle("UNNAMED-DEMO-TITLE")

        // unnamed → the OSC title drives the sidebar label (line 1); waiting on this also confirms the
        // title has been captured before the palette is opened.
        XCTAssertTrue(rowValueEquals("session-row", "UNNAMED-DEMO-TITLE", timeout: 10),
                      "an unnamed session's line 1 should become the OSC title")

        let subtitle = currentPaletteSubtitle()
        closePalette()
        XCTAssertTrue(subtitle.contains(cwdMarker), "an unnamed session's second line should still show the cwd; got \(subtitle)")
        XCTAssertFalse(subtitle.contains("UNNAMED-DEMO-TITLE"),
                       "the second line must not repeat the title already shown on line 1; got \(subtitle)")
    }

    // MARK: - Helpers

    /// Focuses the seeded session's terminal and emits an OSC 2 set-title for `title`, then blocks the
    /// shell with `cat`. The literal `\033`/`\007` are typed as keystrokes; the shell's printf expands
    /// them. The trailing `; cat` is load-bearing: a one-shot printf sets the title but the shell
    /// immediately returns to its prompt, where the local shell integration clears it again — exactly
    /// what a real remote does NOT do, because an `ssh` blocks the local shell at a foreground process.
    /// `cat` reproduces that hold, so the title persists for the assertions (verified: without it the
    /// title reverts and the sidebar name falls back to the cwd basename).
    private func emitOscTitle(_ title: String) {
        let row = app.staticTexts["session-row"].firstMatch
        row.click() // select the row so the primary terminal holds focus
        usleep(800_000)
        app.typeText("printf '\\033]2;\(title)\\007'; cat")
        app.typeKey(.return, modifierFlags: [])
        usleep(400_000)
    }

    /// Opens the Go to Session palette and returns the (single seeded) row's rendered subtitle, or ""
    /// if it never appears. The caller closes the palette.
    private func currentPaletteSubtitle() -> String {
        app.menuBars.menuBarItems["Navigate"].click()
        let item = app.menuItems["Go to Session"]
        guard item.waitForExistence(timeout: 5) else { return "" }
        item.click()
        let subtitle = app.staticTexts["palette-subtitle"].firstMatch
        guard subtitle.waitForExistence(timeout: 5) else { return "" }
        return subtitle.value as? String ?? ""
    }

    private func closePalette() {
        app.typeKey(.escape, modifierFlags: [])
        usleep(200_000)
    }

    /// Renames the active session via File ▸ Rename Session (the menu-triggered inline edit).
    private func renameActiveSession(to name: String) {
        app.menuBars.menuBarItems["File"].click()
        let item = app.menuItems["Rename Session"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "File menu should offer Rename Session")
        item.click()
        let field = app.descendants(matching: .any).matching(identifier: "edit-field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Rename Session should start the inline edit")
        app.typeKey("a", modifierFlags: .command)
        app.typeText("\(name)\r")
    }

    private func rowValueEquals(_ identifier: String, _ expected: String, timeout: TimeInterval = 5) -> Bool {
        let element = app.staticTexts[identifier].firstMatch
        return poll(timeout: timeout) { (element.value as? String) == expected }
    }

    private func poll(_ condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(150_000)
        }
        return false
    }

    private func poll(timeout: TimeInterval, _ condition: () -> Bool) -> Bool { poll(condition, timeout: timeout) }
}
