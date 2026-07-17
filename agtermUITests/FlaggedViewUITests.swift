import XCTest

/// Real UI tests for the flagged working-set view. These launch the actual app and drive the
/// sidebar through the accessibility API — the behavioral coverage the host-free `agtermCore`
/// unit tests can't reach (the flagged-mode data source + the bottom-bar toggle live in
/// `WorkspaceSidebar.Coordinator` / `ContentView`).
///
/// Accessibility-tree facts these queries rely on (shared with SidebarUITests/ReorderUITests):
/// - a session row exposes its name as a StaticText `value` under the `session-row` identifier;
///   in flagged mode that value is the `session : workspace` label;
/// - the inline rename field is a StaticText/TextField with identifier `edit-field`;
/// - the bottom-bar mode toggle is a button with identifier `flagged-view-toggle`.
@MainActor
final class FlaggedViewUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stateDir: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        // hermetic state: a fresh temp dir per test so the app seeds exactly one "workspace 1" + one
        // session, and we never touch the real workspaces.json.
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

    /// End-to-end flagged view: seed three sessions across two workspaces, flag one in each, flip to
    /// the flat flagged list (exactly the two flagged rows, labeled `session : workspace`, the unflagged
    /// row absent), confirm a flagged-row click selects that session and toggling back restores the tree,
    /// then Clear Flagged empties the view back to the empty-state hint.
    func testFlaggedViewToggleSelectAndClear() throws {
        // workspace 1: alpha (flagged), beta (unflagged); workspace 2: gamma (flagged).
        seedThreeSessions()
        // flag while both are still in workspace 1 (visible) — the flag survives the move to workspace 2.
        flagRow(named: "alpha")
        flagRow(named: "gamma")
        XCTAssertTrue(pollFlagged("alpha", timeout: 8), "alpha should persist flagged == true")
        XCTAssertTrue(pollFlagged("gamma", timeout: 8), "gamma should persist flagged == true")

        addWorkspace() // workspace 2
        XCTAssertTrue(app.staticTexts["workspace 2"].waitForExistence(timeout: 5), "second workspace should appear")
        moveSession(named: "gamma", toWorkspace: "workspace 2")
        XCTAssertTrue(pollSessionCount(workspace: "workspace 2", expected: 1, timeout: 8),
                      "gamma should land under workspace 2 (keeping its flag)")

        // flip to the flat flagged list via the bottom-bar toggle.
        let toggle = app.buttons["flagged-view-toggle"]
        XCTAssertTrue(toggle.waitForHittable(timeout: 8), "flagged-view toggle should be hittable")
        toggle.click()

        // exactly the two flagged rows, each labeled `session : workspace`; the unflagged row is absent.
        XCTAssertTrue(sessionRow(named: "alpha : workspace 1").waitForExistence(timeout: 8),
                      "the flagged list should show alpha labeled with its workspace")
        XCTAssertTrue(sessionRow(named: "gamma : workspace 2").waitForExistence(timeout: 8),
                      "the flagged list should show gamma labeled with its (moved-to) workspace")
        XCTAssertTrue(sessionRow(named: "beta").waitForNonExistence(timeout: 5),
                      "the unflagged session should not appear in the flagged list")
        XCTAssertTrue(pollRowCount(2, timeout: 8),
                      "the flagged list should show exactly the two flagged rows")

        // clicking a flagged row selects that session (observable side effect: the persisted selection).
        clickFlaggedRowSelectsItsSession()

        // toggling back restores the full tree: the unflagged session returns and the `: workspace` label
        // is gone.
        toggle.click()
        XCTAssertTrue(sessionRow(named: "beta").waitForExistence(timeout: 8),
                      "toggling back to tree mode should restore the unflagged session row")
        XCTAssertTrue(sessionRow(named: "alpha : workspace 1").waitForNonExistence(timeout: 5),
                      "the flagged `session : workspace` label is flagged-mode only")
        XCTAssertTrue(app.staticTexts["workspace 1"].waitForExistence(timeout: 5), "the workspace tree should be back")
        XCTAssertTrue(app.staticTexts["workspace 2"].waitForExistence(timeout: 5), "both workspaces should be back")

        // Clear Flagged empties the flagged view back to the empty-state hint.
        toggle.click() // back to flagged mode
        XCTAssertTrue(sessionRow(named: "alpha : workspace 1").waitForExistence(timeout: 8),
                      "flagged mode should again show the flagged rows before clearing")
        invokeViewMenuItem("Clear Flagged")
        XCTAssertTrue(sessionRow().firstMatch.waitForNonExistence(timeout: 8),
                      "Clear Flagged should empty the flagged list (no session rows)")
        let hint = app.staticTexts
            .matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "No flagged sessions", "No flagged sessions"))
            .firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 8), "the empty-state hint should appear after Clear Flagged")
    }

    /// Issue #242: in the flagged view a row is labeled `session : workspace`. Entering inline rename must
    /// seed the editor with the BARE session name, not that decorated label — otherwise editing without
    /// deleting the ` : <workspace>` tail bakes the suffix into the stored custom name, and the flagged
    /// view re-appends it (visibly duplicating, e.g. `alpha-x : workspace 1 : workspace 1`).
    func testRenameInFlaggedViewSeedsBareName() throws {
        XCTAssertTrue(sessionRow().waitForExistence(timeout: 20), "seeded session should exist")
        let defaultName = (sessionRow().value as? String) ?? ""
        XCTAssertFalse(defaultName.isEmpty, "seeded session should expose a default name")
        rename(rowNamed: defaultName, to: "alpha")
        flagRow(named: "alpha")
        XCTAssertTrue(pollFlagged("alpha", timeout: 8), "alpha should persist flagged == true")

        // flip to the flat flagged view: the row now shows the decorated `alpha : workspace 1` label.
        let toggle = app.buttons["flagged-view-toggle"]
        XCTAssertTrue(toggle.waitForHittable(timeout: 8), "flagged-view toggle should be hittable")
        toggle.click()
        let decorated = sessionRow(named: "alpha : workspace 1")
        XCTAssertTrue(decorated.waitForHittable(timeout: 8), "the flagged row should show the decorated label")

        // enter inline rename via double-click.
        let field = app.descendants(matching: .any).matching(identifier: "edit-field").firstMatch
        var editing = false
        for _ in 0..<5 {
            decorated.doubleClick()
            if field.waitForExistence(timeout: 2) { editing = true; break }
        }
        XCTAssertTrue(editing, "rename did not enter edit mode in the flagged view (field never appeared)")

        // the reporter's flow: edit WITHOUT clearing the seed. collapse the selection to the end of the
        // pre-filled text (right arrow), append, and commit. the stored custom name must be the bare
        // `alpha-x` — if the editor was seeded with the decorated label, it would bake in ` : workspace 1`.
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeText("-x\r")
        XCTAssertTrue(stateDir.pollSnapshot(equals: "alpha-x", timeout: 8) { obj in
            guard let workspaces = obj["workspaces"] as? [[String: Any]],
                  let sessions = workspaces.first?["sessions"] as? [[String: Any]] else { return nil }
            return sessions.first(where: { ($0["flagged"] as? Bool) == true })?["customName"] as? String
        }, "committing an appended edit must store the bare `alpha-x`, never bake in ` : workspace 1`")
    }

    // MARK: - Fixture

    /// Renames the seeded session to "alpha" and adds two more renamed rows ("beta", "gamma"), leaving the
    /// single seeded workspace holding [alpha, beta, gamma]. Each rename targets the only freshly-added
    /// (default-named) row, which stays unique at that step (mirrors ReorderUITests.seedSessions).
    private func seedThreeSessions() {
        XCTAssertTrue(sessionRow().waitForExistence(timeout: 20), "seeded session should exist")
        let defaultName = (sessionRow().value as? String) ?? ""
        XCTAssertFalse(defaultName.isEmpty, "seeded session should expose a default name")
        rename(rowNamed: defaultName, to: "alpha")
        addSession()
        rename(rowNamed: defaultName, to: "beta")
        addSession()
        rename(rowNamed: defaultName, to: "gamma")
        XCTAssertTrue(pollSessionNames(["alpha", "beta", "gamma"], timeout: 10),
                      "the renamed sessions should persist in creation order")
    }

    // MARK: - Actions

    /// Clicks a flagged row that is NOT currently selected and asserts the persisted selection moves to it.
    private func clickFlaggedRowSelectsItsSession() {
        guard let alphaID = sessionID(named: "alpha"), let gammaID = sessionID(named: "gamma") else {
            return XCTFail("could not resolve the flagged sessions' ids from the snapshot")
        }
        let current = selectedSessionID()
        let (label, expectedID) = current == gammaID
            ? ("alpha : workspace 1", alphaID)
            : ("gamma : workspace 2", gammaID)
        let row = sessionRow(named: label)
        XCTAssertTrue(row.waitForHittable(timeout: 8), "the flagged row to click should be hittable")
        row.click()
        XCTAssertTrue(stateDir.pollSnapshot(equals: expectedID, timeout: 8) { $0["selectedSessionID"] as? String },
                      "clicking the flagged row should select its session")
    }

    /// Right-clicks the named session row and clicks its "Flag" context-menu item.
    private func flagRow(named name: String) {
        let row = sessionRow(named: name)
        XCTAssertTrue(row.waitForHittable(timeout: 10), "\(name) row should be hittable to flag")
        row.rightClick()
        let flag = presentedMenuItem("Flag")
        XCTAssertTrue(flag.waitForExistence(timeout: 5), "Flag menu item should appear")
        flag.click()
    }

    /// Moves the named session to another workspace via the row's "Move to ▸ <workspace>" submenu.
    private func moveSession(named name: String, toWorkspace ws: String) {
        let row = sessionRow(named: name)
        XCTAssertTrue(row.waitForHittable(timeout: 10), "\(name) row should be hittable to move")
        row.rightClick()
        let moveTo = app.menuItems["Move to"]
        XCTAssertTrue(moveTo.waitForExistence(timeout: 5), "Move to submenu should appear")
        moveTo.hover()
        let target = app.menuItems[ws]
        XCTAssertTrue(target.waitForExistence(timeout: 5), "target workspace in submenu should appear")
        target.click()
    }

    /// Opens the View menu and clicks the item titled `title`.
    private func invokeViewMenuItem(_ title: String) {
        let view = app.menuBars.firstMatch.menuBarItems["View"]
        XCTAssertTrue(view.waitForExistence(timeout: 5), "View menu should exist")
        view.click()
        let item = app.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(title) menu item should appear")
        item.click()
    }

    /// Adds a new session to the current workspace via the bottom-bar add-session menu.
    private func addSession() {
        let add = app.descendants(matching: .any).matching(identifier: "add-session").firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "bottom-bar add-session menu should exist")
        add.click()
        let newItem = presentedMenuItem("New Session")
        XCTAssertTrue(newItem.waitForExistence(timeout: 5), "New Session menu item should appear")
        newItem.click()
    }

    /// Adds a new (empty) workspace via the bottom-bar add-workspace button.
    private func addWorkspace() {
        app.buttons["New Workspace"].click()
    }

    /// Renames the session row currently showing `currentName` to `newName` via the inline editor
    /// (double-click to enter edit mode, retrying — far more reliable than the context menu when a
    /// bottom-bar menu was just dismissed). `currentName` must be unique among the rows at the call.
    private func rename(rowNamed currentName: String, to newName: String) {
        let row = sessionRow(named: currentName)
        XCTAssertTrue(row.waitForHittable(timeout: 10), "a session row named \(currentName) to rename should be hittable")
        let field = app.descendants(matching: .any).matching(identifier: "edit-field").firstMatch
        var editing = false
        for _ in 0..<5 {
            row.doubleClick()
            if field.waitForExistence(timeout: 2) { editing = true; break }
        }
        XCTAssertTrue(editing, "rename did not enter edit mode for \(currentName) (field never appeared)")
        app.typeKey("a", modifierFlags: .command)
        app.typeText("\(newName)\r")
        XCTAssertTrue(sessionRow(named: newName).waitForExistence(timeout: 5), "renamed session row should appear")
    }

    // MARK: - Element lookups

    /// The (first) session row, matched by its stable accessibility identifier.
    private func sessionRow() -> XCUIElement { app.staticTexts["session-row"] }

    /// A session row matched by its displayed name/label (lands in the StaticText `value`). Constrained to
    /// the `session-row` identifier so it never matches the window title (same cwd-basename text).
    private func sessionRow(named name: String) -> XCUIElement {
        app.staticTexts
            .matching(NSPredicate(format: "identifier == %@ AND value == %@", "session-row", name))
            .firstMatch
    }

    /// The on-screen (hittable) menu item with `title`, filtering out the closed menu-bar twin.
    private func presentedMenuItem(_ title: String, timeout: TimeInterval = 5) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let matches = app.menuItems.matching(identifier: title).allElementsBoundByIndex
            if let hit = matches.first(where: { $0.exists && $0.isHittable }) { return hit }
            usleep(150_000)
        }
        return app.menuItems[title].firstMatch
    }

    // MARK: - Snapshot pollers

    /// Polls until the visible `session-row` element count in the accessibility tree equals `expected`.
    /// NSOutlineView recycles cells, so the AX-tree count can lag a reload — hence the retry loop.
    private func pollRowCount(_ expected: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.staticTexts.matching(identifier: "session-row").count == expected { return true }
            usleep(200_000)
        }
        return app.staticTexts.matching(identifier: "session-row").count == expected
    }

    /// Polls the snapshot until the named session's `flagged` field is true.
    private func pollFlagged(_ name: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let s = snapshotSession(named: name), (s["flagged"] as? Bool) == true { return true }
            usleep(200_000)
        }
        return false
    }

    /// The persisted id of the session whose `customName` is `name` (nil until written).
    private func sessionID(named name: String) -> String? {
        snapshotSession(named: name)?["id"] as? String
    }

    /// The persisted selected-session id from the snapshot (nil until written).
    private func selectedSessionID() -> String? {
        guard let obj = snapshotObject() else { return nil }
        return obj["selectedSessionID"] as? String
    }

    /// The raw session dictionary (across all workspaces) whose `customName` is `name`.
    private func snapshotSession(named name: String) -> [String: Any]? {
        guard let obj = snapshotObject(), let workspaces = obj["workspaces"] as? [[String: Any]] else { return nil }
        for ws in workspaces {
            if let s = (ws["sessions"] as? [[String: Any]])?.first(where: { ($0["customName"] as? String) == name }) {
                return s
            }
        }
        return nil
    }

    /// The parsed hermetic window snapshot object (nil until the first window file is written).
    private func snapshotObject() -> [String: Any]? {
        guard let data = try? Data(contentsOf: stateDir.windowSnapshotFile()) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Polls the snapshot until the (single seeded workspace's) session `customName`s equal `expected`.
    private func pollSessionNames(_ expected: [String], timeout: TimeInterval) -> Bool {
        stateDir.pollSnapshot(equals: expected, timeout: timeout) { obj in
            guard let workspaces = obj["workspaces"] as? [[String: Any]],
                  let sessions = workspaces.first?["sessions"] as? [[String: Any]] else { return nil }
            return sessions.compactMap { $0["customName"] as? String }
        }
    }

    /// Polls the snapshot until the named workspace holds `expected` sessions.
    private func pollSessionCount(workspace name: String, expected: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let obj = snapshotObject(),
               let workspaces = obj["workspaces"] as? [[String: Any]],
               let ws = workspaces.first(where: { ($0["name"] as? String) == name }),
               ((ws["sessions"] as? [[String: Any]])?.count ?? 0) == expected {
                return true
            }
            usleep(200_000)
        }
        return false
    }
}
