import XCTest

/// End-to-end tests for the user-editable keymap (`<stateDir>/config/keymap.conf`). Seeded via the
/// isolated `AGTERM_STATE_DIR` before launch so `SettingsModel` parses it at init. A custom command's
/// effect is observed as a side effect: it `touch`es a tempfile the test polls for.
@MainActor
final class KeymapUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stateDir: URL!
    private var markerDir: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-uitest-\(UUID().uuidString)", isDirectory: true)
        markerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-keymap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: markerDir, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchEnvironment["AGTERM_STATE_DIR"] = stateDir.path
    }

    override func tearDown() async throws {
        app?.terminate()
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
        if let markerDir { try? FileManager.default.removeItem(at: markerDir) }
    }

    func testCustomCommandShowsBadgeInPaletteAndRuns() throws {
        let marker = markerDir.appendingPathComponent("touched")
        seedKeymap("command \"Touch File\" touch '\(marker.path)'\n")
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session should exist")

        openPalette("Command Palette")
        typeIntoPalette("Touch File")

        let badge = app.descendants(matching: .any).matching(identifier: "palette-badge").firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 5), "the custom command should show the `custom` badge in the palette")

        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(poll { FileManager.default.fileExists(atPath: marker.path) },
                      "running the custom command from the palette should touch the marker file")
    }

    // the Custom Commands palette (Navigate ▸ Custom Commands, ⌃⇧O) drops the `custom` badge — every row
    // in it is already custom.
    func testCustomCommandsPaletteShowsCustomOnlyWithoutBadge() throws {
        let marker = markerDir.appendingPathComponent("custom-only")
        seedKeymap("command \"Touch File\" touch '\(marker.path)'\n")
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session should exist")

        openPalette("Custom Commands")
        XCTAssertTrue(app.staticTexts["Touch File"].waitForExistence(timeout: 5),
                      "the custom command should appear in the Custom Commands palette")
        XCTAssertFalse(app.staticTexts["New Session"].exists, "built-in actions must not appear in the Custom Commands palette")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "palette-badge").firstMatch.exists,
                       "the Custom Commands palette should not show the `custom` badge")

        typeIntoPalette("Touch File")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(poll { FileManager.default.fileExists(atPath: marker.path) },
                      "running a custom command from the Custom Commands palette should touch the marker file")
    }

    // the default chord's key is `+`, a grammar separator, so `displayString` renders the unparseable
    // `cmd++`; the palette hint falls back to a readable ⌘+ glyph for separator-key chords.
    func testIncreaseFontSizePaletteHintIsNotBroken() throws {
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session should exist")

        openPalette("Command Palette")
        typeIntoPalette("Increase Font Size")

        XCTAssertTrue(app.staticTexts["Increase Font Size"].waitForExistence(timeout: 5),
                      "the Increase Font Size palette item should appear")
        XCTAssertFalse(app.staticTexts["cmd++"].exists, "the palette hint must not render the unparseable `cmd++`")
    }

    // new_session is the most reliably observable built-in — each new session is a countable `session-row`
    // element. Built-ins fire via the menu key-equivalent, so no terminal focus is needed.
    func testBuiltinOverrideMovesKey() throws {
        seedKeymap("map cmd+shift+y new_session\n")
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session should exist")
        XCTAssertTrue(poll { self.sessionRowCount() == 1 }, "should start with the one seeded session")

        app.typeKey("y", modifierFlags: [.command, .shift])
        XCTAssertTrue(poll { self.sessionRowCount() == 2 }, "the override chord ⌘⇧Y should create a new session")

        app.typeKey("n", modifierFlags: .command)
        XCTAssertFalse(poll { self.sessionRowCount() == 3 }, "the old default ⌘N must no longer create a session")
        XCTAssertEqual(sessionRowCount(), 2, "no extra session should have been created by the moved-away default")

        // positive control: ⌘⇧Y is still bound, which distinguishes "⌘N is correctly inert" from "key
        // dispatch is dead/slow" — the latter would fail here too.
        app.typeKey("y", modifierFlags: [.command, .shift])
        XCTAssertTrue(poll { self.sessionRowCount() == 3 }, "the still-bound override ⌘⇧Y should keep creating sessions")
    }

    func testCustomCommandSingleChordFires() throws {
        let marker = markerDir.appendingPathComponent("single")
        seedKeymap("command \"Touch A\" cmd+shift+e touch '\(marker.path)'\n")
        app.launchForUITest()
        focusTerminal()

        XCTAssertTrue(chordFiresMarker(marker) { app.typeKey("e", modifierFlags: [.command, .shift]) },
                      "the custom single chord ⌘⇧E should run its command and touch the marker file")
    }

    // the SSH-disconnect state: every session's shell exited, so no terminal surface holds first responder
    // and the empty-window arm of `CustomCommandRunner.handleKeyDown` is the only path left.
    func testCustomCommandFiresWhenWindowHasNoSessions() throws {
        // the touched filename embeds {AGT_WINDOW_ID}: a `win-<uuid>` proves sessionlessContext() populated
        // the window id, a bare `win-` would mean a degenerate empty context.
        seedKeymap("command \"Touch E\" cmd+shift+e touch '\(markerDir.path)/win-{AGT_WINDOW_ID}'\n")
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session should exist")

        emptyTheOnlyWindow()

        let created = chordCreatesFile(prefix: "win-") { app.typeKey("e", modifierFlags: [.command, .shift]) }
        XCTAssertNotNil(created, "a custom command should fire from an empty window with no focused terminal surface")
        XCTAssertGreaterThan((created ?? "").count, "win-".count,
                             "sessionlessContext() should populate {AGT_WINDOW_ID}; got bare \"\(created ?? "nil")\"")
    }

    // the palette's search field is a text field hosted IN the agterm terminal window, so this proves the
    // runner's `responder is NSText` guard wins over its `WindowRegistry.contains` fire-anyway path.
    func testCustomCommandDoesNotFireWhileTextFieldFocused() throws {
        let marker = markerDir.appendingPathComponent("textfield-guard")
        seedKeymap("command \"Touch F\" cmd+shift+e touch '\(marker.path)'\n")
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session should exist")

        openPalette("Command Palette")
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "palette search field should appear")
        field.click()
        for _ in 0..<3 { app.typeKey("e", modifierFlags: [.command, .shift]) }
        XCTAssertFalse(poll({ FileManager.default.fileExists(atPath: marker.path) }, timeout: 3),
                       "a bound chord must not fire while a text field has focus")

        // positive control: the same chord must fire once the field yields focus, so the negative above
        // cannot pass on a dead binding.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(chordFiresMarker(marker) { app.typeKey("e", modifierFlags: [.command, .shift]) },
                      "after the palette closes, the same chord should fire (binding was live)")
    }

    // `CustomCommandRunner.chord(from:)` must normalize a shifted symbol to its BASE key (shift+/ → key
    // "/") rather than the shifted glyph "?" — a parser↔runtime mismatch the host-free tests can't reach.
    func testCustomCommandShiftedSymbolFires() throws {
        let marker = markerDir.appendingPathComponent("shifted")
        seedKeymap("command \"Touch Q\" shift+/ touch '\(marker.path)'\n")
        app.launchForUITest()
        focusTerminal()

        XCTAssertTrue(chordFiresMarker(marker) { app.typeKey("/", modifierFlags: .shift) },
                      "a custom command bound to shift+/ should fire when Shift+/ (the ? key) is pressed")
    }

    // the parser accepting `cmd+shift+left` means nothing unless the runner's NSEvent→Chord mapping yields
    // key "left" for keyCode 123: without that entry the event falls to the character branch and produces
    // the private-use arrow glyph — a valid Chord no keymap line can spell, so the binding never fires.
    func testCustomCommandArrowChordFires() throws {
        let marker = markerDir.appendingPathComponent("arrow")
        seedKeymap("command \"Touch Arrow\" cmd+shift+left touch '\(marker.path)'\n")
        app.launchForUITest()
        focusTerminal()

        XCTAssertTrue(chordFiresMarker(marker) { app.typeKey(.leftArrow, modifierFlags: [.command, .shift]) },
                      "a custom command bound to cmd+shift+left should fire when ⌘⇧← is pressed (issue #278)")
    }

    // ctrl+a normally moves to the shell's line start; the runner arms on it and consumes the sequence.
    func testCustomCommandLeaderFires() throws {
        let marker = markerDir.appendingPathComponent("leader")
        seedKeymap("command \"Touch B\" ctrl+a>g touch '\(marker.path)'\n")
        app.launchForUITest()
        focusTerminal()

        // chordFiresMarker's retried burst is safe only because the matcher re-arms on each fresh ctrl+a:
        // a dropped burst leaves a clean state instead of a half-consumed leader for the retry to collide with.
        XCTAssertTrue(chordFiresMarker(marker) {
            app.typeKey("a", modifierFlags: .control)
            app.typeKey("g", modifierFlags: [])
        }, "the custom leader ctrl+a>g should run its command and touch the marker file")
    }

    func testReloadKeymapPicksUpRewrittenFile() throws {
        let before = markerDir.appendingPathComponent("reload-before")
        let after = markerDir.appendingPathComponent("reload-after")
        seedKeymap("command \"Touch C\" cmd+shift+j touch '\(before.path)'\n")
        app.launchForUITest()
        focusTerminal()

        XCTAssertTrue(chordFiresMarker(before) { app.typeKey("j", modifierFlags: [.command, .shift]) },
                      "the pre-reload binding ⌘⇧J should touch the first marker")

        seedKeymap("command \"Touch C\" cmd+shift+j touch '\(after.path)'\n")

        app.menuBars.menuBarItems["File"].click()
        let reload = app.menuItems["Reload Keymap"]
        XCTAssertTrue(reload.waitForExistence(timeout: 5), "File menu should offer Reload Keymap")
        reload.click()

        focusTerminal()
        XCTAssertTrue(chordFiresMarker(after) { app.typeKey("j", modifierFlags: [.command, .shift]) },
                      "after Reload Keymap the rewritten binding should touch the second marker")
    }

    func testKeyMappingSettingsTabShowsDiagnosticsAndReloads() throws {
        seedKeymap("bogus line here\n")
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session should exist")

        settingsControl(tab: "Key Mapping", control: "settings-keymap-diagnostics")
        XCTAssertTrue(poll { self.diagnosticsContain("unknown verb") },
                      "the diagnostics list should render the broken line")

        seedKeymap("# all comments, nothing to parse\n")
        let reload = app.descendants(matching: .any).matching(identifier: "settings-keymap-reload").firstMatch
        XCTAssertTrue(reload.waitForHittable(timeout: 5), "the Reload button should be hittable")
        reload.click()
        XCTAssertTrue(poll { self.diagnosticsContain("No issues") },
                      "after Reload with a clean file the diagnostics should report no issues")
    }

    /// Whether the Key Mapping diagnostics area surfaces `needle`. The container carries the joined
    /// diagnostics as its accessibilityValue (so it is readable without scrolling each row into view);
    /// also falls back to the label and any matching static text.
    private func diagnosticsContain(_ needle: String) -> Bool {
        let container = app.descendants(matching: .any).matching(identifier: "settings-keymap-diagnostics").firstMatch
        guard container.exists else { return false }
        if (container.value as? String)?.contains(needle) == true { return true }
        if container.label.contains(needle) { return true }
        return app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", needle)).firstMatch.exists
    }

    // MARK: - Helpers

    /// Opens the Settings window (Cmd+,) if needed, switches to `tab`, and returns the control with
    /// `control` id once it is hittable — RETRYING the tab click each tick. A stale/half-open Settings
    /// window can silently drop the first tab click; retrying until the control is hittable is robust to
    /// that (mirrors SettingsUITests.settingsControl).
    @discardableResult
    private func settingsControl(tab: String, control: String, timeout: TimeInterval = 12,
                                 file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let target = app.descendants(matching: .any).matching(identifier: control).firstMatch
        let tabButton = app.buttons[tab].firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if target.exists, target.isHittable { return target }
            if tabButton.exists, tabButton.isHittable {
                tabButton.click()
            } else {
                app.typeKey(",", modifierFlags: .command) // settings not open yet (or lost) — (re)open
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTFail("Settings '\(tab)' control '\(control)' never became hittable", file: file, line: line)
        return target
    }

    // issue #296: moving close_session OFF ⌘W lets SwiftUI's stock File ▸ Close claim the chord, and
    // putting it BACK does not reclaim it — SwiftUI unbinds its own item instead. The sequence must run
    // through RELOAD, never a relaunch: seeding keymap.conf at LAUNCH does not exercise that path.
    func testCloseSessionReclaimsCommandWAfterReload() throws {
        seedKeymap("map cmd+e close_session\n")
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session should exist")
        XCTAssertTrue(poll { self.sessionRowCount() == 1 }, "should start with the one seeded session")

        // a second session, so closing one leaves the window populated — an emptied window legitimately
        // closes on ⌘W, which would make the assertion below ambiguous.
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(poll { self.sessionRowCount() == 2 }, "⌘N should add a second session")

        seedKeymap("")
        reloadKeymapFromMenu()

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(poll({ self.sessionRowCount() == 1 }, timeout: 10),
                      "⌘W should close a session once the override is gone; the stock File ▸ Close must not keep the chord")
        XCTAssertFalse(app.sheets.firstMatch.exists, "⌘W must not raise the close-window confirmation")
        XCTAssertEqual(app.state, .runningForeground, "the window must survive")
    }

    private func reloadKeymapFromMenu() {
        app.menuBars.menuBarItems["File"].click()
        let item = app.menuItems["Reload Keymap"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "File menu should offer Reload Keymap")
        item.click()
    }

    private func seedKeymap(_ contents: String) {
        let configDir = stateDir.appendingPathComponent("config", isDirectory: true)
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let url = configDir.appendingPathComponent("keymap.conf")
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The number of session rows currently in the sidebar.
    private func sessionRowCount() -> Int {
        app.staticTexts.matching(identifier: "session-row").count
    }

    /// Click the (single) seeded session row to put the terminal surface (a `GhosttySurfaceView`) at
    /// first responder, then drain the run loop so the responder bounce (mouseDown → focusActiveTerminal)
    /// settles. The runner fires from a focused terminal surface OR an empty/unfocused agterm terminal
    /// window; this helper focuses the terminal so a chord resolves context from THAT surface (the
    /// runFromKeybind path) rather than the frontmost active-session fallback.
    private func focusTerminal() {
        let row = app.staticTexts["session-row"].firstMatch
        XCTAssertTrue(row.waitForHittable(timeout: 20), "seeded session should be hittable")
        row.click()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, row.isSelected == false {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// Exit the single seeded session's shell so the window's tree goes empty (the SSH-disconnect
    /// state where every session closes). A login shell has no command, so on `exit` ghostty shows its
    /// "Process exited. Press any key to close" prompt instead of auto-closing; each poll tick types
    /// `exit`+Return, which runs `exit` at the prompt OR dismisses the press-any-key prompt afterwards,
    /// converging until no session rows remain. Idempotent, so retrying past the close is harmless.
    private func emptyTheOnlyWindow() {
        focusTerminal()
        let emptied = poll({
            if sessionRowCount() == 0 { return true }
            app.typeText("exit")
            app.typeKey(.return, modifierFlags: [])
            return false
        }, timeout: 25)
        XCTAssertTrue(emptied, "exiting the only session's shell should leave the window with no sessions")
    }

    /// Run `press` (a chord/leader keystroke burst) and poll for `marker` to appear, retrying the press
    /// a few times. Focus return / shell readiness is async, so the first burst after focusTerminal can
    /// land before the surface is genuinely first responder and be dropped — re-pressing is idempotent
    /// for a `touch <file>` command (mirrors ControlAPIUITests' keyboardTypeUntilMarker idiom).
    private func chordFiresMarker(_ marker: URL, attempts: Int = 6, perAttempt: TimeInterval = 2.5,
                                  press: () -> Void) -> Bool {
        for _ in 0..<attempts {
            press()
            if poll({ FileManager.default.fileExists(atPath: marker.path) }, timeout: perAttempt) { return true }
        }
        return false
    }

    /// Run `press` and poll `markerDir` for a file whose name starts with `prefix`, retrying the press a
    /// few times (focus/shell readiness is async). Returns the created filename (so the caller can check
    /// what a `{AGT_X}` token expanded to), or nil if none appeared.
    private func chordCreatesFile(prefix: String, attempts: Int = 6, perAttempt: TimeInterval = 2.5,
                                  press: () -> Void) -> String? {
        for _ in 0..<attempts {
            press()
            let deadline = Date().addingTimeInterval(perAttempt)
            while Date() < deadline {
                if let name = (try? FileManager.default.contentsOfDirectory(atPath: markerDir.path))?
                    .first(where: { $0.hasPrefix(prefix) }) { return name }
                usleep(150_000)
            }
        }
        return nil
    }

    private func openPalette(_ menuTitle: String) {
        app.menuBars.menuBarItems["Navigate"].click()
        let item = app.menuItems[menuTitle]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Navigate menu should offer \(menuTitle)")
        item.click()
    }

    private func typeIntoPalette(_ text: String) {
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "palette search field should appear")
        field.click()
        field.typeText(text)
    }

    private func poll(_ condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(150_000)
        }
        return false
    }
}
