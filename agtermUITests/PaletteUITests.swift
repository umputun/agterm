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

    func testActionPaletteControlJMovesDownLikeTheArrow() throws {
        let beforeWs = workspaceCount(), beforeSessions = sessionCount()
        openPalette("Command Palette")
        typeIntoPalette("new")
        app.typeKey("j", modifierFlags: [.control])
        app.typeKey("j", modifierFlags: [.control])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(poll { self.workspaceCount() == beforeWs + 1 }, "⌃J⌃J then Enter should run the third match (New Workspace)")
        XCTAssertEqual(sessionCount(), beforeSessions, "New Session should not have run")
    }

    func testActionPaletteControlKMovesUpLikeTheArrow() throws {
        let beforeWs = workspaceCount(), beforeSessions = sessionCount()
        openPalette("Command Palette")
        typeIntoPalette("new")
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey("k", modifierFlags: [.control])
        app.typeKey("k", modifierFlags: [.control])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(poll { self.sessionCount() == beforeSessions + 1 }, "↓↓⌃K⌃K then Enter should run the first match (New Session)")
        XCTAssertEqual(workspaceCount(), beforeWs, "New Workspace should not have run")
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

        app.menuBars.menuBarItems["File"].click()
        app.menuItems["New Session"].click()
        XCTAssertTrue(poll { self.sessionCount() == 2 }, "a second session should be added")
        XCTAssertNotEqual(selectedID(), first, "the new session should be selected after add")

        openPalette("Go to Session")
        typeIntoPalette("zeta")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(poll { self.selectedID() == first }, "Go to Session → zeta should select the first session")
    }

    /// Pins the half of `paletteSearchKeys` a caller-supplied picker gives up: a built-in palette still
    /// matches its "<workspace> · <detail>" subtitle, the only place the owning workspace is searchable.
    func testSessionPaletteMatchesItsSubtitleNotOnlyTheLabel() throws {
        renameActiveSession(to: "zeta")
        XCTAssertTrue(poll { self.firstSessionName() == "zeta" })
        let first = try XCTUnwrap(firstSessionID())

        openPalette("Go to Session")
        typeIntoPalette("workspace") // leads the subtitle, "workspace 1 · …", and is absent from the label

        XCTAssertTrue(app.paletteRow(first).waitForExistence(timeout: 5),
                      "a built-in palette row must survive a query that only its subtitle matches")
    }

    func testSessionPaletteListsAlphabeticallyOnAnEmptyQuery() throws {
        renameActiveSession(to: "zulu")
        XCTAssertTrue(poll { self.firstSessionName() == "zulu" })
        addSession(named: "mike")
        addSession(named: "yankee")
        let ids = sessionIDs()
        XCTAssertEqual(sessionNames(), ["zulu", "mike", "yankee"],
                       "the three renamed sessions should persist in creation order")
        XCTAssertEqual(ids.count, 3, "every persisted session should carry an id")
        XCTAssertEqual(selectedID(), ids.last, "the last created session should be selected")

        openPalette("Go to Session")
        XCTAssertTrue(app.paletteRow(ids[1]).waitForExistence(timeout: 5), "every session should be listed")
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(poll { self.selectedID() == ids[1] },
                      "an empty query must still sort a built-in palette A→Z, so Return runs mike, not zulu")
    }

    func testThemePickerCommitsOnEnterAndRevertsOnEsc() throws {
        // the live recolor is a Metal-surface visual, so settings.json is the oracle; "Dracula" differs
        // from the seeded agterm default, so persisting it proves a change.
        openThemePicker()
        typeIntoPalette("Dracula")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(poll { self.settingsTheme() == "Dracula" }, "Enter on a theme should persist it to settings.json")

        openThemePicker()
        typeIntoPalette("Nord")
        app.typeKey(.escape, modifierFlags: [])
        usleep(500_000) // the cancel-revert is synchronous; give any stray write a beat to disprove it
        XCTAssertEqual(settingsTheme(), "Dracula", "Esc discards the preview without persisting it")
    }

    func testThemePickerAutoFocusesFieldFromActionPaletteLauncher() throws {
        // the action-palette launcher closes that palette (whose close-restore re-grabs terminal focus)
        // and opens the picker a tick later, so the picker has to auto-focus its own field.
        openPalette("Command Palette")
        typeIntoPalette("Select Theme") // clicking the ACTION-palette field is fine — not the focus under test
        app.typeKey(.return, modifierFlags: [])

        // typing WITHOUT clicking the field is the point: had focus stayed on the terminal behind it, the
        // text would reach the shell and Enter would commit the unfiltered theme, so the commit is the oracle.
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5), "the theme picker field should appear")
        app.typeText("agterm")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(poll { self.settingsTheme() == "agterm" },
                      "the auto-focused picker should filter on the typed text and commit that theme")
    }

    func testFreshLaunchAppliesAgtermDefaultThemeWithoutAnyChange() throws {
        // SettingsModel.init writes the ghostty config before GhosttyApp boots, so the theme must be in
        // <stateDir>/ghostty-settings.conf with NO interaction at all.
        XCTAssertTrue(poll { self.appliedGhosttyTheme()?.contains("agterm") == true },
                      "a fresh launch should write the agterm default into the live ghostty config")
    }

    func testThemePickerPreviewsTopMatchOnFilterWithoutNavigating() throws {
        // the Metal recolor isn't observable, so the applied theme in <stateDir>/ghostty-settings.conf is
        // the oracle. No Enter, no arrows.
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

    func testFlaggedEditorTogglesInPlaceAndStaysOpen() throws {
        addSession(named: "mike")
        let mike = try XCTUnwrap(sessionIDs().last)

        openEditor("Edit Flagged Sessions")
        XCTAssertTrue(app.paletteRow(mike).waitForExistence(timeout: 5), "the editor should list every session")
        typeIntoPalette("mike")
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(poll { self.flaggedIDs() == [mike] }, "Return should flag the highlighted row")
        XCTAssertEqual(markValue(mike), "flagged")
        XCTAssertEqual(app.textFields.firstMatch.value as? String, "mike", "the editor stays open on the same query")

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(poll { !self.app.paletteRow(mike).exists }, "Esc should close the editor")
        invokeViewMenuItem("Show Flagged Sessions")
        XCTAssertTrue(poll { self.app.staticTexts.matching(identifier: "session-row").count == 1 },
                      "the flagged view should show the one flagged session")
    }

    func testFocusEditorTogglesMembershipInPlace() throws {
        let workspace = try XCTUnwrap(workspaces().first?["id"] as? String)

        openEditor("Edit Focused Workspaces")
        XCTAssertTrue(app.paletteRow(workspace).waitForExistence(timeout: 5), "the editor should list the workspace")
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(poll { self.focusedIDs() == [workspace] }, "Return should mark the highlighted workspace")
        XCTAssertEqual(markValue(workspace), "focused")
        XCTAssertNil(snapshot()?["focusEnabled"], "marking never turns the filter on")
        XCTAssertTrue(app.paletteRow(workspace).exists, "the editor stays open")

        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(poll { self.focusedIDs().isEmpty }, "a second Return should unmark it")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(poll { !self.app.paletteRow(workspace).exists }, "Esc should close the editor")
    }

    // regression: a click ran a row without moving the highlight, so the next return toggled another row.
    func testEditorClickThenReturnBothHitTheClickedRow() throws {
        addSession(named: "mike")
        addSession(named: "yankee")
        let ids = sessionIDs()
        XCTAssertEqual(ids.count, 3)

        openEditor("Edit Flagged Sessions")
        XCTAssertTrue(app.paletteRow(ids[2]).waitForExistence(timeout: 5))
        clickPaletteRow(ids[2])
        XCTAssertTrue(poll { self.flaggedIDs() == [ids[2]] }, "the click should flag the clicked row")

        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(poll { self.flaggedIDs().isEmpty }, "Return should unflag that same row, not the first one")
        XCTAssertEqual(markValue(ids[2]), "unflagged")
    }

    func testUnflaggingTheActiveSessionKeepsTheEditorWorking() throws {
        invokeViewMenuItem("Flag Session")
        addSession(named: "mike")
        invokeViewMenuItem("Flag Session")
        let ids = sessionIDs()
        XCTAssertTrue(poll { self.flaggedIDs() == ids }, "both sessions start flagged")
        let mike = ids[1]
        XCTAssertEqual(selectedID(), mike)
        invokeViewMenuItem("Show Flagged Sessions")

        openEditor("Edit Flagged Sessions")
        XCTAssertTrue(app.paletteRow(mike).waitForExistence(timeout: 5))
        typeIntoPalette("mike")
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(poll { self.flaggedIDs() == [ids[0]] }, "Return should unflag the active session")
        XCTAssertTrue(poll { self.selectedID() == ids[0] }, "the selection moves to the flagged survivor")
        XCTAssertTrue(app.paletteRow(mike).exists, "the editor stays open behind the reselection")

        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(poll { self.flaggedIDs() == ids }, "the next Return acts on the highlighted row again")
        app.typeKey("x", modifierFlags: [])
        XCTAssertEqual(app.textFields.firstMatch.value as? String, "x",
                       "typing still reaches the search field, replacing the query Return leaves selected")
    }

    // MARK: - Helpers

    private func openEditor(_ title: String) {
        openPalette("Command Palette")
        typeIntoPalette(title)
        app.typeKey(.return, modifierFlags: [])
    }

    private func markValue(_ id: String) -> String? {
        let states: Set<String> = ["flagged", "unflagged", "focused", "unfocused"]
        let tagged = app.descendants(matching: .any).matching(identifier: "palette-item-\(id)")
        let inside = app.paletteRow(id).descendants(matching: .any)
        return (tagged.allElementsBoundByIndex + inside.allElementsBoundByIndex)
            .compactMap { $0.value as? String }
            .first { states.contains($0) }
    }

    private func clickPaletteRow(_ id: String) {
        let matches = app.descendants(matching: .any).matching(identifier: "palette-item-\(id)")
        (matches.allElementsBoundByIndex.first { $0.isHittable } ?? matches.firstMatch).click()
    }

    private func flaggedIDs() -> [String] {
        sessions().filter { $0["flagged"] as? Bool == true }.compactMap { $0["id"] as? String }
    }

    private func focusedIDs() -> [String] { snapshot()?["focusedWorkspaceIDs"] as? [String] ?? [] }

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

    /// Adds a session through File ▸ New Session and renames the (now selected) row.
    private func addSession(named name: String) {
        let before = sessionCount()
        app.menuBars.menuBarItems["File"].click()
        app.menuItems["New Session"].click()
        XCTAssertTrue(poll { self.sessionCount() == before + 1 }, "New Session should add a session")
        renameActiveSession(to: name)
        XCTAssertTrue(poll { self.sessionNames().contains(name) }, "the new session should take the name \(name)")
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
    private func sessionCount() -> Int { sessions().count }
    private func selectedID() -> String? { snapshot()?["selectedSessionID"] as? String }
    private func sessions() -> [[String: Any]] { workspaces().flatMap { ($0["sessions"] as? [[String: Any]]) ?? [] } }
    private func sessionIDs() -> [String] { sessions().compactMap { $0["id"] as? String } }
    private func sessionNames() -> [String] { sessions().compactMap { $0["customName"] as? String } }
    private func firstSession() -> [String: Any]? { (workspaces().first?["sessions"] as? [[String: Any]])?.first }
    private func firstSessionID() -> String? { firstSession()?["id"] as? String }
    private func firstSessionName() -> String? { firstSession()?["customName"] as? String }
}
