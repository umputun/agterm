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
        // hermetic state: a fresh temp dir per test so the app seeds exactly one
        // "workspace 1" + one session, and we never touch the real workspaces.json.
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
        // the field appears keyboard-focused (the rename fix); type into it. it
        // surfaces as a TextField (session rows) or StaticText (workspace headers),
        // so match by identifier across element types.
        let field = app.descendants(matching: .any).matching(identifier: "edit-field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "rename did not enter edit mode (field never appeared)")
        app.typeKey("a", modifierFlags: .command)
        app.typeText("\(newName)\r")
    }

    // The reported bug: renaming a session did nothing.
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

    // clicking anywhere on a workspace row (not just the disclosure triangle) toggles its expansion.
    // the toggle is deferred by the double-click interval so a rename double-click can cancel it, so the
    // child session hides/returns a beat after the click rather than instantly.
    func testClickWorkspaceRowTogglesExpansion() throws {
        let ws = app.staticTexts["workspace 1"]
        XCTAssertTrue(ws.waitForExistence(timeout: 20), "workspace header should exist")
        let session = sessionRow()
        XCTAssertTrue(session.waitForExistence(timeout: 20), "seeded session row should be visible while expanded")

        // click the row body → collapse → the child session row disappears.
        ws.click()
        XCTAssertTrue(session.waitForNonExistence(timeout: 5), "collapsing the workspace should hide its session row")

        // click again → expand → the session row comes back.
        ws.click()
        XCTAssertTrue(session.waitForExistence(timeout: 5), "expanding the workspace should show its session row again")
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
        // edit mode closes: on restore the field's identifier reverts from edit-field to session-row.
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "Esc should close rename edit mode")
        // and the name is unchanged: the rename was discarded, not committed.
        XCTAssertEqual(sessionRow().value as? String, original, "Esc should discard the rename")
        // focus returns to the terminal: the sidebar must not keep focus after the rename ends.
        usleep(800_000)
        XCTAssertTrue(terminalReceivedTyping(named: "after-esc"),
                      "Esc should return focus to the session terminal, not keep it on the sidebar")
    }

    // ending a rename with Return must also hand focus back to the terminal (not keep it on the sidebar).
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

        // delete workspace 1 — it still holds the seeded session, so a confirm alert appears.
        app.staticTexts["workspace 1"].rightClick()
        let delete = presentedMenuItem("Delete Workspace")
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "Delete Workspace menu item should appear")
        delete.click()
        // the confirm alert is an app-modal dialog; scope the Delete button to it (menu-bar items
        // also surface in the app-wide button query).
        let alert = app.dialogs.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "a non-empty workspace should prompt to confirm")
        alert.buttons["Delete"].firstMatch.click()

        XCTAssertTrue(app.staticTexts["workspace 1"].waitForNonExistence(timeout: 5), "workspace 1 should be gone")
        XCTAssertTrue(pollWorkspaceNames(["workspace 2"], timeout: 5), "only workspace 2 should remain")
    }

    func testRowsShowKindIcons() throws {
        XCTAssertTrue(sessionRow().waitForExistence(timeout: 20), "seeded session should exist")
        // the leading row icons (folder for a workspace, terminal for a session) carry stable
        // identifiers on their image views; match across element types like the other rows do.
        let workspaceIcon = app.descendants(matching: .any).matching(identifier: "workspace-icon").firstMatch
        XCTAssertTrue(workspaceIcon.waitForExistence(timeout: 5), "workspace row should show its folder icon")
        let sessionIcon = app.descendants(matching: .any).matching(identifier: "session-icon").firstMatch
        XCTAssertTrue(sessionIcon.waitForExistence(timeout: 5), "session row should show its terminal icon")
    }

    func testNewSessionButton() throws {
        XCTAssertTrue(sessionRow().waitForExistence(timeout: 20), "seeded session should exist")
        // bottom-bar add-session menu (a SwiftUI Menu may surface as a popup, not a
        // plain button), matched by identifier across element types.
        let add = app.descendants(matching: .any).matching(identifier: "add-session").firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5), "bottom-bar add-session menu should exist")
        add.click()
        let newItem = presentedMenuItem("New Session")
        XCTAssertTrue(newItem.waitForExistence(timeout: 5), "New Session menu item should appear")
        newItem.click()
        XCTAssertTrue(pollSessionCount(workspace: "workspace 1", expected: 2, timeout: 5),
                      "workspace 1 should have 2 sessions after add-session -> New Session")
    }

    // Verifies the "Open Directory…" wiring: the menu item presents the native
    // folder picker. (The picker is system UI; choosing a directory and the
    // resulting addSession(cwd:) are covered at the model level by AppStoreTests.)
    func testOpenDirectoryShowsPicker() throws {
        let add = app.descendants(matching: .any).matching(identifier: "add-session").firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 20), "bottom-bar add-session menu should exist")
        add.click()
        let open = presentedMenuItem("Open Directory…")
        XCTAssertTrue(open.waitForExistence(timeout: 5), "Open Directory… menu item should appear")
        open.click()
        // the native folder picker appears (app-modal); confirm via its Cancel button, then
        // dismiss with Escape (there can be more than one "Cancel" in the tree, so don't click by label).
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

    /// Sidebar visibility persists per-window: hiding it records `sidebarVisible=false` in the snapshot,
    /// it survives a relaunch (the sidebar restores hidden, so no `session-row`s show), and showing it
    /// again records `true` and reveals the restored session. Width and split ratio are geometric (no AX
    /// value, the divider has no queryable element), so those stay on the host-free `AppStore` round-trip
    /// tests; visibility is observable here in both the snapshot file and the rows' presence.
    func testSidebarVisibilityPersistsAcrossRelaunch() throws {
        XCTAssertTrue(sessionRow().firstMatch.waitForExistence(timeout: 20), "seeded session should exist")

        // hide via the title-bar toggle; the toggle's save() must record sidebarVisible=false.
        let toggle = app.buttons["sidebar-toggle-button"]
        XCTAssertTrue(toggle.waitForHittable(timeout: 8), "sidebar toggle should be hittable")
        toggle.click()
        XCTAssertTrue(stateDir.pollSnapshot(equals: false, timeout: 8) { $0["sidebarVisible"] as? Bool },
                      "hiding should persist sidebarVisible=false")

        // relaunch with the same state dir; the sidebar must restore HIDDEN. The toggle is present either
        // way (proves the window rendered); the rows stay absent because the sidebar is hidden.
        app.terminate()
        app = XCUIApplication()
        app.launchEnvironment["AGTERM_STATE_DIR"] = stateDir.path
        app.launchForUITest()
        let toggleAfter = app.buttons["sidebar-toggle-button"]
        XCTAssertTrue(toggleAfter.waitForHittable(timeout: 20), "window should render with the sidebar toggle")
        XCTAssertFalse(sessionRow().firstMatch.waitForExistence(timeout: 3),
                       "the sidebar should restore hidden (no session rows)")

        // showing it again reveals the restored session and persists sidebarVisible=true.
        toggleAfter.click()
        XCTAssertTrue(sessionRow().firstMatch.waitForExistence(timeout: 8),
                      "the restored session appears when the sidebar is shown again")
        XCTAssertTrue(stateDir.pollSnapshot(equals: true, timeout: 8) { $0["sidebarVisible"] as? Bool },
                      "showing should persist sidebarVisible=true")
    }
}
