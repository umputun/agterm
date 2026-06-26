import XCTest

/// Real UI tests for the focus-a-workspace feature. These launch the actual app and drive the sidebar
/// through the accessibility API — the behavioral coverage the host-free `agtermCore` unit tests can't
/// reach (the focus-filtered tree data source + the bottom-bar pill live in `WorkspaceSidebar.Coordinator`
/// / `ContentView`).
///
/// Accessibility-tree facts these queries rely on (shared with SidebarUITests/FlaggedViewUITests):
/// - a session row exposes its name as a StaticText `value` under the `session-row` identifier;
/// - a workspace header exposes its name as a StaticText `label`;
/// - the bottom-bar "<name> ✕" focus escape hatch is a button with identifier `focus-pill`.
@MainActor
final class FocusWorkspaceUITests: XCTestCase {
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

    /// End-to-end focus: seed two workspaces (workspace 1 holding the visible session, workspace 2 empty),
    /// focus workspace 2 via its header's context menu — the OTHER workspace's header AND its session row
    /// leave the AX tree, and the "workspace 2 ✕" focus pill appears — then click the pill ✕ and confirm
    /// the hidden workspace and its session row return.
    ///
    /// Focusing the (empty) other workspace is what makes a *visible* session row (workspace 1's, which is
    /// expanded because it holds the selection) leave the AX tree — a non-focused workspace's own sessions
    /// are collapsed, so only the focused-away workspace's rows are reliably observable as disappearing.
    func testFocusWorkspaceHidesOthersAndPillRestores() throws {
        // workspace 1: [visible] (seeded, selected, expanded); workspace 2: empty.
        XCTAssertTrue(sessionRow().waitForExistence(timeout: 20), "seeded session should exist")
        let defaultName = (sessionRow().value as? String) ?? ""
        XCTAssertFalse(defaultName.isEmpty, "seeded session should expose a default name")
        rename(rowNamed: defaultName, to: "visible")
        addWorkspace()
        XCTAssertTrue(app.staticTexts["workspace 2"].waitForExistence(timeout: 5), "second workspace should appear")

        // unfocused: the visible session row and both workspace headers are present, no pill.
        XCTAssertTrue(sessionRow(named: "visible").waitForExistence(timeout: 8), "visible row should exist unfocused")
        XCTAssertTrue(app.staticTexts["workspace 1"].waitForExistence(timeout: 5), "workspace 1 header should exist")
        XCTAssertFalse(app.buttons["focus-pill"].exists, "no focus pill before focusing")

        // focus workspace 2 via its header's context menu: workspace 1 (header + its visible session row)
        // leaves the AX tree.
        focusWorkspace("workspace 2")
        XCTAssertTrue(sessionRow(named: "visible").waitForNonExistence(timeout: 8),
                      "the other workspace's session row should leave the AX tree while focused")
        XCTAssertTrue(app.staticTexts["workspace 1"].waitForNonExistence(timeout: 5),
                      "the other workspace's header should leave the AX tree while focused")
        XCTAssertTrue(app.staticTexts["workspace 2"].waitForExistence(timeout: 5),
                      "the focused workspace's header should remain")

        // the "workspace 2 ✕" focus escape-hatch pill appears.
        let pill = app.buttons["focus-pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 8), "the focus pill should appear while a workspace is focused")

        // clicking the pill ✕ unfocuses: the hidden workspace + its session row return, and the pill goes away.
        pill.click()
        XCTAssertTrue(sessionRow(named: "visible").waitForExistence(timeout: 8),
                      "unfocusing via the pill should restore the other workspace's session row")
        XCTAssertTrue(app.staticTexts["workspace 1"].waitForExistence(timeout: 5),
                      "unfocusing should restore the other workspace's header")
        XCTAssertTrue(app.buttons["focus-pill"].waitForNonExistence(timeout: 5),
                      "the focus pill should disappear after unfocusing")
    }

    // MARK: - Actions

    /// Right-clicks the named workspace header and clicks its "Focus" context-menu item.
    private func focusWorkspace(_ name: String) {
        let header = app.staticTexts[name]
        XCTAssertTrue(header.waitForHittable(timeout: 8), "\(name) header should be hittable to focus")
        header.rightClick()
        let focus = presentedMenuItem("Focus")
        XCTAssertTrue(focus.waitForExistence(timeout: 5), "Focus menu item should appear")
        focus.click()
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

    /// A session row matched by its displayed name (lands in the StaticText `value`). Constrained to the
    /// `session-row` identifier so it never matches the window title (same cwd-basename text).
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
}
