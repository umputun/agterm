import XCTest

/// Drives the command palettes (actions + sessions) and the menu-triggered inline rename. The
/// result list is SwiftUI, so these assert through observable side effects in the persisted
/// snapshot: running an action changes the workspace/session tree, choosing a session changes the
/// persisted selection, and a rename changes the persisted name. Also covers ↑/↓ navigation (the
/// part most likely to fight the text field) over the now-alphabetical list.
@MainActor
final class PaletteUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stateDir: URL!

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

    func testActionPaletteFiltersAndRunsTopMatch() throws {
        let before = sessionCount()
        openPalette("Command Palette")
        typeIntoPalette("New Session")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(poll { self.sessionCount() == before + 1 }, "running New Session should add a session")
    }

    func testActionPaletteArrowNavigationRunsSecondItem() throws {
        // "new" matches [New Session, New Window, New Workspace] alphabetically; ↓↓ selects New Workspace.
        let beforeWs = workspaceCount(), beforeSessions = sessionCount()
        openPalette("Command Palette")
        typeIntoPalette("new")
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(poll { self.workspaceCount() == beforeWs + 1 }, "↓↓ then Enter should run the third match (New Workspace)")
        XCTAssertEqual(sessionCount(), beforeSessions, "New Session should not have run")
    }

    func testRenameSessionFromMenuStartsInlineEdit() throws {
        renameActiveSession(to: "renamed-via-menu")
        XCTAssertTrue(poll { self.firstSessionName() == "renamed-via-menu" }, "menu rename should persist the new name")
    }

    func testSessionPaletteSelectsSession() throws {
        // rename the seeded session so the palette can target it unambiguously.
        renameActiveSession(to: "zeta")
        XCTAssertTrue(poll { self.firstSessionName() == "zeta" })
        let first = try XCTUnwrap(firstSessionID())

        // add a second session; it becomes selected.
        app.menuBars.menuBarItems["File"].click()
        app.menuItems["New Session"].click()
        XCTAssertTrue(poll { self.sessionCount() == 2 }, "a second session should be added")
        XCTAssertNotEqual(selectedID(), first, "the new session should be selected after add")

        openPalette("Go to Session")
        typeIntoPalette("zeta")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(poll { self.selectedID() == first }, "Go to Session → zeta should select the first session")
    }

    func testThemePickerCommitsOnEnterAndRevertsOnEsc() throws {
        // commit: open the picker, filter to a non-default theme, Enter persists it to settings.json
        // (the live color change is a Metal-surface visual, verified manually; the persistence is the
        // observable contract here). "Dracula" differs from the seeded agterm default, so it proves a change.
        openThemePicker()
        typeIntoPalette("Dracula")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(poll { self.settingsTheme() == "Dracula" }, "Enter on a theme should persist it to settings.json")

        // revert: open again, filter to a different theme (which previews it live), Esc. The preview is
        // never persisted, so settings.json keeps the previously committed theme.
        openThemePicker()
        typeIntoPalette("Nord")
        app.typeKey(.escape, modifierFlags: [])
        usleep(500_000) // the cancel-revert is synchronous; give any stray write a beat to disprove it
        XCTAssertEqual(settingsTheme(), "Dracula", "Esc discards the preview without persisting it")
    }

    func testThemePickerAutoFocusesFieldFromActionPaletteLauncher() throws {
        // open the picker the way a keyboard user does: the action palette → "Select Theme…" → Enter.
        // that path closes the action palette (whose close-restore re-grabs terminal focus) and opens the
        // .themes picker a tick later; the picker must AUTO-FOCUS its field so typing filters it.
        openPalette("Command Palette")
        typeIntoPalette("Select Theme") // clicking the ACTION-palette field is fine — not the focus under test
        app.typeKey(.return, modifierFlags: [])

        // the picker is open; type WITHOUT clicking its field. If focus stayed on the terminal behind it
        // (the bug), this text would reach the shell, the selection would stay on the current theme, and
        // Enter would commit the wrong one — so the commit assertion is the focus oracle.
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5), "the theme picker field should appear")
        app.typeText("agterm")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(poll { self.settingsTheme() == "agterm" },
                      "the auto-focused picker should filter on the typed text and commit that theme")
    }

    func testFreshLaunchAppliesAgtermDefaultThemeWithoutAnyChange() throws {
        // a fresh install must apply the seeded agterm default at LAUNCH, not only after a settings change
        // triggers a config rewrite. SettingsModel.init writes the ghostty config before GhosttyApp boots,
        // so <stateDir>/ghostty-settings.conf carries the theme with NO interaction.
        XCTAssertTrue(poll { self.appliedGhosttyTheme()?.contains("agterm") == true },
                      "a fresh launch should write the agterm default into the live ghostty config")
    }

    func testThemePickerPreviewsTopMatchOnFilterWithoutNavigating() throws {
        // typing to filter must preview the new top match live — even with no arrow navigation. The live
        // preview writes the applied theme into <stateDir>/ghostty-settings.conf, so that file is the
        // oracle (the Metal recolor itself isn't observable). No Enter, no arrows.
        openThemePicker()
        typeIntoPalette("Hot Dog") // top match: the vivid "Hot Dog Stand" theme
        XCTAssertTrue(poll { self.appliedGhosttyTheme()?.contains("Hot Dog Stand") == true },
                      "filtering should preview the top match live, before any navigation")
        app.typeKey(.escape, modifierFlags: []) // revert the preview
    }

    func testActionPaletteClearFlaggedVisibilityTracksFlagState() throws {
        openPalette("Command Palette")
        typeIntoPalette("Clear Flagged")
        XCTAssertFalse(app.staticTexts["Clear Flagged"].waitForExistence(timeout: 1),
                       "Clear Flagged should be omitted while no session is flagged")
        app.typeKey(.escape, modifierFlags: [])

        invokeViewMenuItem("Flag Session")
        openPalette("Command Palette")
        typeIntoPalette("Clear Flagged")
        XCTAssertTrue(app.staticTexts["Clear Flagged"].waitForExistence(timeout: 5),
                      "Clear Flagged should appear once a session is flagged")
    }

    func testActionPaletteHidesExpandCollapseInFlaggedView() throws {
        invokeViewMenuItem("Flag Session")

        openPalette("Command Palette")
        typeIntoPalette("Expand Workspaces")
        XCTAssertTrue(app.staticTexts["Expand Workspaces"].waitForExistence(timeout: 5),
                      "Expand Workspaces should appear in the normal workspace tree")
        app.typeKey(.escape, modifierFlags: [])

        invokeViewMenuItem("Show Flagged Sessions")
        openPalette("Command Palette")
        typeIntoPalette("Expand Workspaces")
        XCTAssertFalse(app.staticTexts["Expand Workspaces"].waitForExistence(timeout: 1),
                       "Expand Workspaces should be omitted in the flat flagged view")
        app.typeKey(.escape, modifierFlags: [])

        openPalette("Command Palette")
        typeIntoPalette("Collapse Workspaces")
        XCTAssertFalse(app.staticTexts["Collapse Workspaces"].waitForExistence(timeout: 1),
                       "Collapse Workspaces should be omitted in the flat flagged view")
    }

    // MARK: - Helpers

    /// The theme line the live config currently applies, read from <stateDir>/ghostty-settings.conf
    /// (the file the preview rewrites on every apply). nil when no theme line is present.
    private func appliedGhosttyTheme() -> String? {
        let file = stateDir.appendingPathComponent("ghostty-settings.conf")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").first { $0.hasPrefix("theme = ") }.map(String.init)
    }

    /// Open the live-preview theme picker via View ▸ Select Theme… It opens on the next runloop tick
    /// (async, so it survives the launching palette's close), so wait for the field to appear.
    private func openThemePicker() {
        app.menuBars.menuBarItems["View"].click()
        let item = app.menuItems["Select Theme…"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "View menu should offer Select Theme…")
        item.click()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5), "the theme picker field should appear")
    }

    private func settingsTheme() -> String? {
        let file = stateDir.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["theme"] as? String
    }

    private func openPalette(_ menuTitle: String) {
        app.menuBars.menuBarItems["Navigate"].click()
        let item = app.menuItems[menuTitle]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Navigate menu should offer \(menuTitle)")
        item.click()
    }

    private func invokeViewMenuItem(_ title: String) {
        app.menuBars.menuBarItems["View"].click()
        let item = app.menuItems[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "View menu should offer \(title)")
        item.click()
    }

    private func typeIntoPalette(_ text: String) {
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "palette search field should appear")
        field.click()
        field.typeText(text)
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

    private func poll(_ condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(150_000)
        }
        return false
    }

    private func snapshot() -> [String: Any]? {
        let file = stateDir.windowSnapshotFile()
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private func workspaces() -> [[String: Any]] { snapshot()?["workspaces"] as? [[String: Any]] ?? [] }
    private func workspaceCount() -> Int { workspaces().count }
    private func sessionCount() -> Int { workspaces().reduce(0) { $0 + (($1["sessions"] as? [[String: Any]])?.count ?? 0) } }
    private func selectedID() -> String? { snapshot()?["selectedSessionID"] as? String }
    private func firstSession() -> [String: Any]? { (workspaces().first?["sessions"] as? [[String: Any]])?.first }
    private func firstSessionID() -> String? { firstSession()?["id"] as? String }
    private func firstSessionName() -> String? { firstSession()?["customName"] as? String }
}
