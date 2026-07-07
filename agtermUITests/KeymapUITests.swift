import XCTest

/// End-to-end tests for the user-editable keymap (`<stateDir>/config/keymap.conf`). Seeded via the
/// isolated `AGTERM_STATE_DIR` before launch so `SettingsModel` parses it at init. The palette case
/// asserts a custom command shows the `custom` badge in the action palette and runs from it, using
/// the branch's observable-side-effect pattern (the command `touch`es a tempfile that the test polls).
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
        // a palette-only custom command (no chord) that touches a marker file when run.
        let marker = markerDir.appendingPathComponent("touched")
        seedKeymap("command \"Touch File\" touch '\(marker.path)'\n")
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session should exist")

        openPalette("Command Palette")
        typeIntoPalette("Touch File")

        // the custom badge identifies the row as a keymap command; assert it surfaced.
        let badge = app.descendants(matching: .any).matching(identifier: "palette-badge").firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 5), "the custom command should show the `custom` badge in the palette")

        // run the selected (top) match and assert the command actually executed.
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(poll { FileManager.default.fileExists(atPath: marker.path) },
                      "running the custom command from the palette should touch the marker file")
    }

    // the Custom Commands palette (Navigate ▸ Custom Commands, ⌃⇧O) lists ONLY custom commands and drops
    // the `custom` badge — every row is already custom. Seed one custom command, open the palette, and
    // assert: the custom row appears, a built-in action (New Session) does NOT, no badge shows, and it runs.
    func testCustomCommandsPaletteShowsCustomOnlyWithoutBadge() throws {
        let marker = markerDir.appendingPathComponent("custom-only")
        seedKeymap("command \"Touch File\" touch '\(marker.path)'\n")
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session should exist")

        openPalette("Custom Commands")
        XCTAssertTrue(app.staticTexts["Touch File"].waitForExistence(timeout: 5),
                      "the custom command should appear in the Custom Commands palette")
        // built-in actions are excluded — this palette is custom-only.
        XCTAssertFalse(app.staticTexts["New Session"].exists, "built-in actions must not appear in the Custom Commands palette")
        // the `custom` badge is suppressed here (the whole list is custom).
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "palette-badge").firstMatch.exists,
                       "the Custom Commands palette should not show the `custom` badge")

        // filter to the command (also focuses the field), then run it and assert it executed.
        typeIntoPalette("Touch File")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(poll { FileManager.default.fileExists(atPath: marker.path) },
                      "running a custom command from the Custom Commands palette should touch the marker file")
    }

    // the Increase Font Size palette hint must NOT show the unparseable kitty string `cmd++` (its
    // default chord's key is `+`, a grammar separator, so `displayString` renders `cmd++`). The
    // palette-hint path falls back to a readable ⌘+ glyph for separator-key chords instead.
    func testIncreaseFontSizePaletteHintIsNotBroken() throws {
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session should exist")

        openPalette("Command Palette")
        typeIntoPalette("Increase Font Size")

        // the row appears (its title is the static text the palette renders)…
        XCTAssertTrue(app.staticTexts["Increase Font Size"].waitForExistence(timeout: 5),
                      "the Increase Font Size palette item should appear")
        // …and the broken `cmd++` hint must NOT be present anywhere in the palette.
        XCTAssertFalse(app.staticTexts["cmd++"].exists, "the palette hint must not render the unparseable `cmd++`")
    }

    // a `map` override moves a built-in's key: bind new_session to ⌘⇧Y. new_session is the most
    // reliably observable built-in — each new session is a countable `session-row` element. Pressing
    // the OVERRIDE chord adds a row; pressing the OLD default (⌘N) does NOT, proving the key moved.
    // (Built-ins fire via the menu key-equivalent, so no terminal focus is needed.)
    func testBuiltinOverrideMovesKey() throws {
        seedKeymap("map cmd+shift+y new_session\n")
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session should exist")
        XCTAssertTrue(poll { self.sessionRowCount() == 1 }, "should start with the one seeded session")

        // the override chord ⌘⇧Y now triggers new_session → a second row appears.
        app.typeKey("y", modifierFlags: [.command, .shift])
        XCTAssertTrue(poll { self.sessionRowCount() == 2 }, "the override chord ⌘⇧Y should create a new session")

        // the OLD default ⌘N must no longer trigger new_session (the key moved) → the count stays at 2.
        app.typeKey("n", modifierFlags: .command)
        XCTAssertFalse(poll { self.sessionRowCount() == 3 }, "the old default ⌘N must no longer create a session")
        XCTAssertEqual(sessionRowCount(), 2, "no extra session should have been created by the moved-away default")

        // positive control: the OVERRIDE chord ⌘⇧Y is still bound, so it MUST still create a session.
        // this makes the negative above meaningful — it distinguishes "⌘N is correctly inert" from
        // "key dispatch is dead/slow" (which would also make this still-bound chord fail).
        app.typeKey("y", modifierFlags: [.command, .shift])
        XCTAssertTrue(poll { self.sessionRowCount() == 3 }, "the still-bound override ⌘⇧Y should keep creating sessions")
    }

    // a custom command bound to a single chord fires from a focused terminal: bind ⌘⇧E to `touch
    // <file>`, focus the terminal, press the chord, assert the file appears (observable-side-effect).
    func testCustomCommandSingleChordFires() throws {
        let marker = markerDir.appendingPathComponent("single")
        seedKeymap("command \"Touch A\" cmd+shift+e touch '\(marker.path)'\n")
        app.launchForUITest()
        focusTerminal()

        XCTAssertTrue(chordFiresMarker(marker) { app.typeKey("e", modifierFlags: [.command, .shift]) },
                      "the custom single chord ⌘⇧E should run its command and touch the marker file")
    }

    // a custom command bound to a SHIFTED-SYMBOL key fires: bind `shift+/` (the `?` key) to `touch
    // <file>`, focus the terminal, press Shift+/ (which types `?`), assert the file appears. Regression
    // guard for the base-key derivation in `CustomCommandRunner.chord(from:)`: the runner must normalize
    // a shifted symbol to its BASE key (shift+/ → key "/", matching the `shift+/` binding), not to the
    // shifted glyph "?" — a parser↔runtime mismatch the host-free tests structurally can't reach.
    func testCustomCommandShiftedSymbolFires() throws {
        let marker = markerDir.appendingPathComponent("shifted")
        seedKeymap("command \"Touch Q\" shift+/ touch '\(marker.path)'\n")
        app.launchForUITest()
        focusTerminal()

        XCTAssertTrue(chordFiresMarker(marker) { app.typeKey("/", modifierFlags: .shift) },
                      "a custom command bound to shift+/ should fire when Shift+/ (the ? key) is pressed")
    }

    // a custom command bound to a LEADER sequence fires: bind `ctrl+a>g` to `touch <file>`, focus the
    // terminal, press ctrl+a then g (two key events), assert the file appears. ctrl+a normally moves to
    // the line start in the shell, but the runner arms on it and consumes the sequence.
    func testCustomCommandLeaderFires() throws {
        let marker = markerDir.appendingPathComponent("leader")
        seedKeymap("command \"Touch B\" ctrl+a>g touch '\(marker.path)'\n")
        app.launchForUITest()
        focusTerminal()

        // chordFiresMarker may press the ctrl+a>g burst several times before the marker appears. This is
        // safe only because the matcher re-arms on each fresh leader (ctrl+a): a dropped first burst
        // leaves the matcher in a clean state, so the next ctrl+a starts the sequence over rather than
        // the retry colliding with a half-consumed leader.
        XCTAssertTrue(chordFiresMarker(marker) {
            app.typeKey("a", modifierFlags: .control)
            app.typeKey("g", modifierFlags: [])
        }, "the custom leader ctrl+a>g should run its command and touch the marker file")
    }

    // "Reload Keymap" re-reads keymap.conf: launch with ⌘⇧J bound to touch fileC1, then rewrite the
    // file so ⌘⇧J touches fileC2 instead, invoke Reload Keymap (File menu), and assert the POST-reload
    // chord touches fileC2 — proving the reload picked up the rewritten file.
    func testReloadKeymapPicksUpRewrittenFile() throws {
        let before = markerDir.appendingPathComponent("reload-before")
        let after = markerDir.appendingPathComponent("reload-after")
        seedKeymap("command \"Touch C\" cmd+shift+j touch '\(before.path)'\n")
        app.launchForUITest()
        focusTerminal()

        // the pre-reload binding fires (sanity: the seeded file is in effect).
        XCTAssertTrue(chordFiresMarker(before) { app.typeKey("j", modifierFlags: [.command, .shift]) },
                      "the pre-reload binding ⌘⇧J should touch the first marker")

        // rewrite keymap.conf so the same chord now touches a DIFFERENT file.
        seedKeymap("command \"Touch C\" cmd+shift+j touch '\(after.path)'\n")

        // invoke Reload Keymap from the File menu.
        app.menuBars.menuBarItems["File"].click()
        let reload = app.menuItems["Reload Keymap"]
        XCTAssertTrue(reload.waitForExistence(timeout: 5), "File menu should offer Reload Keymap")
        reload.click()

        // after the reload the chord must touch the NEW file (the rewritten binding is in effect).
        focusTerminal()
        XCTAssertTrue(chordFiresMarker(after) { app.typeKey("j", modifierFlags: [.command, .shift]) },
                      "after Reload Keymap the rewritten binding should touch the second marker")
    }

    // the Key Mapping settings tab renders the parse diagnostics and its Reload button re-reads the
    // file: seed a broken line, open Settings ▸ Key Mapping, assert the diagnostic surfaces; then
    // rewrite the file clean, click the tab's Reload, assert the diagnostics clear to "No issues.".
    func testKeyMappingSettingsTabShowsDiagnosticsAndReloads() throws {
        seedKeymap("bogus line here\n")
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session should exist")

        // open the tab (retrying the click) and confirm the diagnostics list renders the broken line.
        // a SwiftUI container with an accessibilityIdentifier combines its child Texts into the
        // container's own label, so match the broken-line message anywhere in the diagnostics subtree
        // OR in the app's static texts.
        settingsControl(tab: "Key Mapping", control: "settings-keymap-diagnostics")
        XCTAssertTrue(poll { self.diagnosticsContain("unknown verb") },
                      "the diagnostics list should render the broken line")

        // rewrite the file clean, then Reload from the tab; the diagnostics must clear to "No issues.".
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

    /// Writes `keymap.conf` under the isolated state dir's `config` directory, before launch, so
    /// `SettingsModel.loadKeymap` reads it at init (and `ensureStarterKeymap` leaves it untouched).
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
    /// settles. The custom-command runner only fires when the key window's first responder is a terminal
    /// surface, so a chord test that didn't focus the terminal first would silently pass the chord through.
    private func focusTerminal() {
        let row = app.staticTexts["session-row"].firstMatch
        XCTAssertTrue(row.waitForHittable(timeout: 20), "seeded session should be hittable")
        row.click()
        // drain the run loop until the row reports selected, so the responder bounce
        // (mouseDown → focusActiveTerminal) settles before a chord is pressed — a wait-for-condition
        // rather than a fixed sleep. chordFiresMarker retries anyway, so a slow settle is not fatal.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, row.isSelected == false {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
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
