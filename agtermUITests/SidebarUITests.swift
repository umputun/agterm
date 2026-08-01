import XCTest

/// Real UI tests: launch the actual app and drive the sidebar through the
/// accessibility API. These exercise the SwiftUI wiring (rename focus, context
/// menus, move, close) the agtermCore unit tests cannot reach.
///
/// Accessibility-tree facts these queries rely on (verified via app.debugDescription):
/// - session rows expose their name as a StaticText `value` (not `label`);
/// - workspace headers expose their name as a StaticText `label`;
/// - the inline rename field is a StaticText with identifier `edit-field` and is
///   keyboard-focused on appear, so typing goes straight to it.
@MainActor
final class SidebarUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stateDir: URL!
    private var markerDir: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        // a fresh temp dir per test seeds exactly one "workspace 1" + one session.
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-uitest-\(UUID().uuidString)", isDirectory: true)
        markerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-sidebar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: markerDir, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchEnvironment["AGTERM_STATE_DIR"] = stateDir.path
        app.launchForUITest()
    }

    override func tearDown() async throws {
        app?.terminate()
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
        if let markerDir { try? FileManager.default.removeItem(at: markerDir) }
    }

    /// Focus oracle: types `tty > file` into whatever currently holds keyboard focus, then Return.
    /// The marker file gets written only if the keystrokes reached the session's shell — i.e. the
    /// terminal has focus. If the sidebar kept focus the text drives outline type-select instead and
    /// the file stays absent, so a nil return means "focus did NOT return to the terminal".
    private func terminalReceivedTyping(named name: String) -> Bool {
        let file = markerDir.appendingPathComponent(name)
        app.typeText("tty > '\(file.path)'")
        app.typeKey(.return, modifierFlags: [])
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let contents = try? String(contentsOf: file, encoding: .utf8),
               !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            usleep(150_000)
        }
        return false
    }

    /// The (single, seeded) session row, matched by its stable accessibility
    /// identifier — the displayed name lands in the StaticText `value`, which the
    /// usual identifier/label lookups don't match.
    private func sessionRow() -> XCUIElement { app.staticTexts["session-row"] }

    /// The on-screen (hittable) menu item with `title`. macOS always exposes the full menu-bar
    /// hierarchy to accessibility, so the File-menu items (New Session, Open Directory…, Close
    /// Session) collide by title with the same-named bottom-bar / context-menu items. The
    /// presented popup/context item is hittable; the closed menu-bar one is not — filter on that.
    private func presentedMenuItem(_ title: String, timeout: TimeInterval = 5) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let matches = app.menuItems.matching(identifier: title).allElementsBoundByIndex
            if let hit = matches.first(where: { $0.exists && $0.isHittable }) { return hit }
            usleep(150_000)
        }
        return app.menuItems[title].firstMatch
    }

    /// Polls until the number of visible `session-row` static texts equals `expected`. Used by the
    /// collapse-persistence test, where the observable is how many session rows show under the
    /// expanded-vs-collapsed workspaces.
    private func pollSessionRowCount(_ expected: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.staticTexts.matching(identifier: "session-row").count == expected { return true }
            usleep(150_000)
        }
        return app.staticTexts.matching(identifier: "session-row").count == expected
    }

    /// Polls an element's `value` until it equals `expected`.
    private func waitForValue(_ element: XCUIElement, _ expected: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (element.value as? String) == expected { return true }
            usleep(150_000)
        }
        return false
    }

    /// Enter rename via the row's context menu, type a new name, commit with Return.
    private func rename(_ row: XCUIElement, to newName: String) {
        XCTAssertTrue(row.waitForExistence(timeout: 20), "row to rename should exist")
        row.rightClick()
        let rename = app.menuItems["Rename"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5), "Rename menu item should appear")
        rename.click()
        // the field surfaces as a TextField (session rows) or StaticText (workspace headers),
        // so match by identifier across element types.
        let field = app.descendants(matching: .any).matching(identifier: "edit-field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "rename did not enter edit mode (field never appeared)")
        app.typeKey("a", modifierFlags: .command)
        app.typeText("\(newName)\r")
    }

    func testRenameSession() throws {
        let row = sessionRow()
        rename(row, to: "renamed-session")
        XCTAssertTrue(waitForValue(row, "renamed-session", timeout: 5),
                      "session row should show the new name after rename")
    }

    func testRenameWorkspace() throws {
        let ws = app.staticTexts["workspace 1"]
        rename(ws, to: "work")
        XCTAssertTrue(app.staticTexts["work"].waitForExistence(timeout: 5),
                      "workspace header should show the new name after rename")
    }

    // the toggle is deferred by the double-click interval (so a rename double-click can cancel it), so the
    // child session hides/returns a beat after the click rather than instantly.
    func testClickWorkspaceRowTogglesExpansion() throws {
        let ws = app.staticTexts["workspace 1"]
        XCTAssertTrue(ws.waitForExistence(timeout: 20), "workspace header should exist")
        let session = sessionRow()
        XCTAssertTrue(session.waitForExistence(timeout: 20), "seeded session row should be visible while expanded")

        ws.click()
        XCTAssertTrue(session.waitForNonExistence(timeout: 5), "collapsing the workspace should hide its session row")

        ws.click()
        XCTAssertTrue(session.waitForExistence(timeout: 5), "expanding the workspace should show its session row again")
    }

    // with `workspaceRowClickExpands` off, only the disclosure triangle stays a toggle.
    func testWorkspaceRowClickDoesNotToggleWhenSettingIsOff() throws {
        XCTAssertTrue(app.staticTexts["workspace 1"].waitForExistence(timeout: 20), "seeded workspace should exist")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "seeded session should be visible")

        app.terminate()
        let settings = try JSONSerialization.data(withJSONObject: ["workspaceRowClickExpands": false])
        try settings.write(to: stateDir.appendingPathComponent("settings.json"))
        app = XCUIApplication()
        app.launchEnvironment["AGTERM_STATE_DIR"] = stateDir.path
        app.launchForUITest()
        let ws = app.staticTexts["workspace 1"]
        XCTAssertTrue(ws.waitForExistence(timeout: 20), "workspace 1 should restore")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "the session row should be visible after relaunch")

        // the toggle would have been deferred by the double-click interval, so poll past it for a collapse
        // that must never come.
        ws.click()
        XCTAssertFalse(pollSessionRowCount(0, timeout: 3), "a row click must not collapse the workspace while the setting is off")

        let triangle = app.disclosureTriangles.firstMatch
        XCTAssertTrue(triangle.waitForExistence(timeout: 5), "the workspace row should expose its disclosure triangle")
        triangle.click()
        XCTAssertTrue(pollSessionRowCount(0, timeout: 8), "the disclosure triangle should collapse regardless of the setting")
    }

    // the `persistAndApply()` mirror leg: the seeded-file test above covers only the launch-time one, so
    // without this a missing live mirror would leave the toggle needing a relaunch and the suite green.
    func testWorkspaceRowClickStopsTogglingAfterLiveSettingsFlip() throws {
        let ws = app.staticTexts["workspace 1"]
        XCTAssertTrue(ws.waitForExistence(timeout: 20), "seeded workspace should exist")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "seeded session should be visible")

        settingsControl(tab: "General", control: "settings-workspace-row-click-expands").click() // default on
        XCTAssertTrue(pollSettingsFalse("workspaceRowClickExpands", timeout: 5),
                      "clicking the toggle should persist workspaceRowClickExpands=false")
        // close Settings by its own close button: ⌘W would reach the app's Close Session command and take
        // the seeded session with it, which reads as a collapse to the row-count oracle below.
        let settingsWindow = app.windows.containing(.any, identifier: "settings-workspace-row-click-expands").firstMatch
        settingsWindow.buttons[XCUIIdentifierCloseWindow].click()

        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "closing Settings must leave the seeded session in place")
        XCTAssertTrue(ws.waitForHittable(timeout: 10), "the sidebar row should be reachable after closing Settings")
        ws.click()
        XCTAssertFalse(pollSessionRowCount(0, timeout: 3),
                       "a row click must not collapse the workspace after the setting is flipped off live")
    }

    /// Polls the isolated `settings.json` until `key` is persisted as false.
    private func pollSettingsFalse(_ key: String, timeout: TimeInterval) -> Bool {
        let file = stateDir.appendingPathComponent("settings.json")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: file),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (object[key] as? NSNumber)?.boolValue == false { return true }
            usleep(150_000)
        }
        return false
    }

    /// The Settings control with `control`, opening Settings and switching to `tab` as needed — reopen can
    /// leave a non-key window that swallows the first tab click, so both steps retry until it is hittable.
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

    // collapses a workspace whose session is NOT the selected one, so the launch-time reveal of the
    // active session cannot re-expand it.
    func testWorkspaceCollapsePersistsAcrossRelaunch() throws {
        XCTAssertTrue(app.staticTexts["workspace 1"].waitForExistence(timeout: 20), "seeded workspace should exist")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "seeded session A should be visible")

        // session B goes in via the workspace-row menu so it lands in workspace 2 and becomes active.
        app.buttons["New Workspace"].click()
        let ws2 = app.staticTexts["workspace 2"]
        XCTAssertTrue(ws2.waitForExistence(timeout: 5), "second workspace should appear")
        ws2.rightClick()
        presentedMenuItem("New Session").click()
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "workspace 2 should now show its own session B")

        app.staticTexts["workspace 1"].click()
        XCTAssertTrue(pollSessionRowCount(1, timeout: 8), "collapsing workspace 1 should hide session A")
        XCTAssertTrue(stateDir.pollSnapshot(equals: true, timeout: 8) { snapshot in
            (snapshot["workspaces"] as? [[String: Any]])?
                .first(where: { $0["name"] as? String == "workspace 1" })?["collapsed"] as? Bool
        }, "collapsing workspace 1 should persist collapsed=true")

        // the active session B's workspace is revealed on launch, so exactly one row (B) shows; A stays
        // hidden under the restored-collapsed workspace 1.
        app.terminate()
        app = XCUIApplication()
        app.launchEnvironment["AGTERM_STATE_DIR"] = stateDir.path
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["workspace 1"].waitForExistence(timeout: 20), "workspace 1 should restore")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10),
                      "workspace 1 should restore collapsed (session A hidden); only the active session B shows")

        app.staticTexts["workspace 1"].click()
        XCTAssertTrue(pollSessionRowCount(2, timeout: 8), "expanding workspace 1 should reveal session A again")
    }

    // the relaunch force-reveal of the active session is a view action, so it must not re-persist that
    // session's workspace as expanded.
    func testActiveWorkspaceCollapsePersistsDespiteReveal() throws {
        XCTAssertTrue(app.staticTexts["workspace 1"].waitForExistence(timeout: 20), "seeded workspace should exist")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "seeded active session should be visible")

        app.staticTexts["workspace 1"].click()
        XCTAssertTrue(pollSessionRowCount(0, timeout: 8), "collapsing the active workspace should hide its session row")
        XCTAssertTrue(stateDir.pollSnapshot(equals: true, timeout: 8) { snapshot in
            (snapshot["workspaces"] as? [[String: Any]])?.first?["collapsed"] as? Bool
        }, "collapsing the active workspace should persist collapsed=true")

        app.terminate()
        app = XCUIApplication()
        app.launchEnvironment["AGTERM_STATE_DIR"] = stateDir.path
        app.launchForUITest()
        XCTAssertTrue(pollSessionRowCount(1, timeout: 20), "the active session should be force-revealed on relaunch")
        XCTAssertTrue(stateDir.pollSnapshot(equals: true, timeout: 8) { snapshot in
            (snapshot["workspaces"] as? [[String: Any]])?.first?["collapsed"] as? Bool
        }, "the launch reveal must not re-persist the workspace as expanded (still collapsed=true)")
    }

    // the focus filter hides workspace 1, so this only passes if Collapse Workspaces reaches past the
    // visible rows.
    func testCollapseWorkspacesWhileFocusedCollapsesHiddenWorkspaces() throws {
        XCTAssertTrue(app.staticTexts["workspace 1"].waitForExistence(timeout: 20), "seeded workspace should exist")
        // session B goes in via the workspace-row menu so workspace 2 becomes the active one.
        app.buttons["New Workspace"].click()
        let ws2 = app.staticTexts["workspace 2"]
        XCTAssertTrue(ws2.waitForExistence(timeout: 5), "second workspace should appear")
        ws2.rightClick()
        presentedMenuItem("New Session").click()
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "workspace 2 should show its own active session B")

        ws2.rightClick()
        presentedMenuItem("Focus").click()
        XCTAssertTrue(pollSessionRowCount(1, timeout: 8), "focusing workspace 2 should hide workspace 1's session")

        app.menuBars.menuBarItems["View"].click()
        let collapse = app.menuItems["Collapse Workspaces"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 5), "Collapse Workspaces menu item should appear")
        collapse.click()
        XCTAssertTrue(stateDir.pollSnapshot(equals: true, timeout: 8) { snapshot in
            (snapshot["workspaces"] as? [[String: Any]])?
                .first(where: { $0["name"] as? String == "workspace 1" })?["collapsed"] as? Bool
        }, "Collapse Workspaces must persist the focus-hidden workspace 1 as collapsed")
    }

    // the move does not change the selection, so nothing reveals workspace 2 — it renders open only from
    // the model's expanded-by-default state.
    func testMovingActiveSessionIntoNewWorkspaceKeepsItVisible() throws {
        let row = sessionRow()
        XCTAssertTrue(row.waitForExistence(timeout: 20), "seeded active session should exist")
        app.buttons["New Workspace"].click()
        XCTAssertTrue(app.staticTexts["workspace 2"].waitForExistence(timeout: 5), "second workspace should appear")

        row.rightClick()
        let moveTo = app.menuItems["Move to"]
        XCTAssertTrue(moveTo.waitForExistence(timeout: 5), "Move to submenu should appear")
        moveTo.hover()
        let target = app.menuItems["workspace 2"]
        XCTAssertTrue(target.waitForExistence(timeout: 5), "target workspace in submenu should appear")
        target.click()

        XCTAssertTrue(pollSessionRowCount(1, timeout: 8),
                      "the active session should stay visible in the new workspace (rendered expanded by default)")
    }

    // issue #41: Esc must cancel the inline rename — close edit mode and discard the typed change.
    func testRenameSessionEscCancels() throws {
        let row = sessionRow()
        XCTAssertTrue(row.waitForExistence(timeout: 20), "session row should exist")
        let original = row.value as? String
        row.rightClick()
        let rename = app.menuItems["Rename"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5), "Rename menu item should appear")
        rename.click()
        let field = app.descendants(matching: .any).matching(identifier: "edit-field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "rename did not enter edit mode (field never appeared)")
        app.typeKey("a", modifierFlags: .command)
        app.typeText("should-be-discarded")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        // on restore the field's identifier reverts from edit-field to session-row.
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "Esc should close rename edit mode")
        XCTAssertEqual(sessionRow().value as? String, original, "Esc should discard the rename")
        usleep(800_000)
        XCTAssertTrue(terminalReceivedTyping(named: "after-esc"),
                      "Esc should return focus to the session terminal, not keep it on the sidebar")
    }

    func testRenameSessionCommitReturnsFocus() throws {
        let row = sessionRow()
        rename(row, to: "renamed-focus")
        XCTAssertTrue(waitForValue(row, "renamed-focus", timeout: 5), "rename should commit")
        usleep(800_000)
        XCTAssertTrue(terminalReceivedTyping(named: "after-commit"),
                      "committing a rename should return focus to the session terminal")
    }

    func testCloseSession() throws {
        let row = sessionRow()
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.rightClick()
        let close = presentedMenuItem("Close Session")
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.click()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5),
                      "session row should disappear after close")
    }

    func testMoveSession() throws {
        let row = sessionRow()
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        app.buttons["New Workspace"].click()
        XCTAssertTrue(app.staticTexts["workspace 2"].waitForExistence(timeout: 5), "second workspace should appear")
        row.rightClick()
        let moveTo = app.menuItems["Move to"]
        XCTAssertTrue(moveTo.waitForExistence(timeout: 5), "Move to submenu should appear")
        moveTo.hover()
        let target = app.menuItems["workspace 2"]
        XCTAssertTrue(target.waitForExistence(timeout: 5), "target workspace in submenu should appear")
        target.click()
        XCTAssertTrue(pollSessionCount(workspace: "workspace 2", expected: 1, timeout: 5),
                      "session should be under workspace 2 in persisted state after move")
    }

    func testDragSessionToWorkspace() throws {
        let row = sessionRow()
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        app.buttons["New Workspace"].click()
        let ws2 = app.staticTexts["workspace 2"]
        XCTAssertTrue(ws2.waitForExistence(timeout: 5), "second workspace should appear")
        row.press(forDuration: 1.0, thenDragTo: ws2)
        XCTAssertTrue(pollSessionCount(workspace: "workspace 2", expected: 1, timeout: 5),
                      "session should move to workspace 2 via drag-and-drop")
    }

    func testDeleteWorkspace() throws {
        XCTAssertTrue(app.staticTexts["workspace 1"].waitForExistence(timeout: 20), "seeded workspace should exist")
        XCTAssertTrue(sessionRow().waitForExistence(timeout: 5), "seeded session should exist")

        // a second workspace is needed: the last remaining one can't be deleted.
        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.staticTexts["workspace 2"].waitForExistence(timeout: 5), "New Workspace should add workspace 2")

        app.staticTexts["workspace 1"].rightClick()
        let delete = presentedMenuItem("Delete Workspace")
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "Delete Workspace menu item should appear")
        delete.click()
        // scope the Delete button to the modal dialog — menu-bar items also surface in the app-wide
        // button query.
        let alert = app.dialogs.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "a non-empty workspace should prompt to confirm")
        alert.buttons["Delete"].firstMatch.click()

        XCTAssertTrue(app.staticTexts["workspace 1"].waitForNonExistence(timeout: 5), "workspace 1 should be gone")
        XCTAssertTrue(pollWorkspaceNames(["workspace 2"], timeout: 5), "only workspace 2 should remain")
    }

    func testRowsShowKindIcons() throws {
        XCTAssertTrue(sessionRow().waitForExistence(timeout: 20), "seeded session should exist")
        // the row icons carry their identifiers on image views, so match across element types.
        let workspaceIcon = app.descendants(matching: .any).matching(identifier: "workspace-icon").firstMatch
        XCTAssertTrue(workspaceIcon.waitForExistence(timeout: 5), "workspace row should show its folder icon")
        let sessionIcon = app.descendants(matching: .any).matching(identifier: "session-icon").firstMatch
        XCTAssertTrue(sessionIcon.waitForExistence(timeout: 5), "session row should show its terminal icon")
    }

    func testNewSessionButton() throws {
        XCTAssertTrue(sessionRow().waitForExistence(timeout: 20), "seeded session should exist")
        // a SwiftUI Menu may surface as a popup rather than a plain button, so match across element types.
        let add = app.descendants(matching: .any).matching(identifier: "add-session").firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5), "bottom-bar add-session menu should exist")
        add.click()
        let newItem = presentedMenuItem("New Session")
        XCTAssertTrue(newItem.waitForExistence(timeout: 5), "New Session menu item should appear")
        newItem.click()
        XCTAssertTrue(pollSessionCount(workspace: "workspace 1", expected: 2, timeout: 5),
                      "workspace 1 should have 2 sessions after add-session -> New Session")
    }

    // the "+" is hover-revealed (zero width on an idle row), so the row must be hovered to make it hittable.
    func testInlineAddSessionButtonCreatesSession() throws {
        XCTAssertTrue(sessionRow().waitForExistence(timeout: 20), "seeded session should exist")
        let ws = app.staticTexts["workspace 1"]
        XCTAssertTrue(ws.waitForExistence(timeout: 5), "seeded workspace should exist")
        let addBtn = app.descendants(matching: .any).matching(identifier: "workspace-add-session").firstMatch
        // retry the hover: the first synthesized move can land before the window is key, and
        // .activeInKeyWindow tracking swallows it.
        let deadline = Date().addingTimeInterval(8)
        while !addBtn.isHittable, Date() < deadline {
            ws.hover()
            usleep(200_000)
        }
        XCTAssertTrue(addBtn.isHittable, "hovering the workspace row should reveal the inline '+' button")
        addBtn.click()
        XCTAssertTrue(pollSessionCount(workspace: "workspace 1", expected: 2, timeout: 5),
                      "workspace 1 should have 2 sessions after clicking the inline '+' button")
    }

    // the picker is system UI, so only its presentation is checked here; the resulting addSession(cwd:)
    // is covered at the model level by AppStoreTests.
    func testOpenDirectoryShowsPicker() throws {
        let add = app.descendants(matching: .any).matching(identifier: "add-session").firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 20), "bottom-bar add-session menu should exist")
        add.click()
        let open = presentedMenuItem("Open Directory…")
        XCTAssertTrue(open.waitForExistence(timeout: 5), "Open Directory… menu item should appear")
        open.click()
        // more than one "Cancel" can exist in the tree, so dismiss with Escape rather than by label.
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 5),
                      "Open Directory… should present a folder picker")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    }

    /// Polls the hermetic snapshot file until the workspace names equal `expected`, in order.
    private func pollWorkspaceNames(_ expected: [String], timeout: TimeInterval) -> Bool {
        let file = stateDir.windowSnapshotFile()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: file),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let workspaces = obj["workspaces"] as? [[String: Any]],
               workspaces.compactMap({ $0["name"] as? String }) == expected {
                return true
            }
            usleep(200_000)
        }
        return false
    }

    /// Polls the hermetic snapshot file until the named workspace has `expected` sessions.
    private func pollSessionCount(workspace name: String, expected: Int, timeout: TimeInterval) -> Bool {
        let file = stateDir.windowSnapshotFile()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: file),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let workspaces = obj["workspaces"] as? [[String: Any]],
               let ws = workspaces.first(where: { ($0["name"] as? String) == name }),
               ((ws["sessions"] as? [[String: Any]])?.count ?? 0) == expected {
                return true
            }
            usleep(200_000)
        }
        return false
    }

    // width and split ratio have no AX value (the divider has no queryable element), so they stay on the
    // host-free AppStore round-trip tests; only visibility is observable here.
    func testSidebarVisibilityPersistsAcrossRelaunch() throws {
        XCTAssertTrue(sessionRow().firstMatch.waitForExistence(timeout: 20), "seeded session should exist")

        let toggle = app.buttons["sidebar-toggle-button"]
        XCTAssertTrue(toggle.waitForHittable(timeout: 8), "sidebar toggle should be hittable")
        toggle.click()
        XCTAssertTrue(stateDir.pollSnapshot(equals: false, timeout: 8) { $0["sidebarVisible"] as? Bool },
                      "hiding should persist sidebarVisible=false")

        // the toggle is present either way, so it only proves the window rendered; the absent rows are
        // the real signal.
        app.terminate()
        app = XCUIApplication()
        app.launchEnvironment["AGTERM_STATE_DIR"] = stateDir.path
        app.launchForUITest()
        let toggleAfter = app.buttons["sidebar-toggle-button"]
        XCTAssertTrue(toggleAfter.waitForHittable(timeout: 20), "window should render with the sidebar toggle")
        XCTAssertFalse(sessionRow().firstMatch.waitForExistence(timeout: 3),
                       "the sidebar should restore hidden (no session rows)")

        toggleAfter.click()
        XCTAssertTrue(sessionRow().firstMatch.waitForExistence(timeout: 8),
                      "the restored session appears when the sidebar is shown again")
        XCTAssertTrue(stateDir.pollSnapshot(equals: true, timeout: 8) { $0["sidebarVisible"] as? Bool },
                      "showing should persist sidebarVisible=true")
    }
}
