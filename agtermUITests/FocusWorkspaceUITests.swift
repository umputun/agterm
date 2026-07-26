import XCTest

/// Real UI tests for the workspace focus SET — the marked workspaces plus the on/off filter flag. These
/// launch the actual app and drive the sidebar through the accessibility API — the behavioral coverage the
/// host-free `agtermCore` unit tests can't reach (the filtered tree data source lives in
/// `WorkspaceSidebar.Coordinator`, the bottom-bar toggle in `WindowContentView`).
///
/// This suite is also the regression coverage for the two surfaces whose own output is NOT
/// accessibility-observable: the marked row's filled `square.grid.2x2` icon and the row menu's
/// Focus/Unfocus + Add/Remove-from-Focus label flips. Neither can be asserted directly (an SF Symbol on a
/// recycled cell is not in the AX tree, and a menu label is only observable by invoking it), so they are
/// covered here through what they DO: which rows the tree renders.
///
/// Accessibility-tree facts these queries rely on (shared with SidebarUITests/FlaggedViewUITests):
/// - a session row exposes its name as a StaticText `value` under the `session-row` identifier;
/// - a workspace row exposes its name as a StaticText `value` under the `workspace-row` identifier (and
///   also as its `label`), so a workspace leaving the filtered tree is directly observable;
/// - the bottom-bar filter toggle is a button with identifier `focus-filter-toggle`, whose `value` is
///   `on`/`off` and whose `isEnabled` is false exactly while nothing is marked — the only
///   accessibility-observable read of the filter state.
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

    /// End-to-end single-workspace focus (the set-of-one case every pre-set script and muscle memory
    /// relies on): seed two workspaces (workspace 1 holding the visible session, workspace 2 empty), Focus
    /// workspace 2 from its row's context menu — the OTHER workspace's row AND its session row leave the AX
    /// tree while the toggle flips to `on` — then invoke the same item, which now reads "Unfocus", and
    /// confirm the hidden workspace and its session row return with the toggle back to `off` AND disabled
    /// (Unfocus clears the set, it does not merely suspend the filter).
    ///
    /// Focusing the (empty) other workspace is what makes a *visible* session row (workspace 1's, which is
    /// expanded because it holds the selection) leave the AX tree — a non-focused workspace's own sessions
    /// are collapsed, so only the focused-away workspace's rows are reliably observable as disappearing.
    func testFocusWorkspaceHidesOthersAndUnfocusRestores() throws {
        // workspace 1: [visible] (seeded, selected, expanded); workspace 2: empty.
        XCTAssertTrue(sessionRow().waitForExistence(timeout: 20), "seeded session should exist")
        let defaultName = (sessionRow().value as? String) ?? ""
        XCTAssertFalse(defaultName.isEmpty, "seeded session should expose a default name")
        rename(rowNamed: defaultName, to: "visible")
        addWorkspace()
        XCTAssertTrue(workspaceRow(named: "workspace 2").waitForExistence(timeout: 5), "second workspace should appear")

        // unfiltered: the visible session row and both workspace rows are present, and the toggle reads
        // off + disabled because nothing is marked yet.
        XCTAssertTrue(sessionRow(named: "visible").waitForExistence(timeout: 8), "visible row should exist unfiltered")
        XCTAssertTrue(workspaceRow(named: "workspace 1").waitForExistence(timeout: 5), "workspace 1 row should exist")
        XCTAssertTrue(pollFilterToggle(value: "off", enabled: false, timeout: 8),
                      "with nothing marked the filter toggle should read off and be disabled")

        // Focus workspace 2 via its row's context menu: workspace 1 (row + its visible session row) leaves
        // the AX tree and the filter reports on.
        invokeWorkspaceMenuItem("Focus", onWorkspace: "workspace 2")
        XCTAssertTrue(sessionRow(named: "visible").waitForNonExistence(timeout: 8),
                      "the other workspace's session row should leave the AX tree while filtered")
        XCTAssertTrue(workspaceRow(named: "workspace 1").waitForNonExistence(timeout: 5),
                      "the other workspace's row should leave the AX tree while filtered")
        XCTAssertTrue(workspaceRow(named: "workspace 2").waitForExistence(timeout: 5),
                      "the marked workspace's row should remain")
        XCTAssertTrue(pollFilterToggle(value: "on", enabled: true, timeout: 8),
                      "focusing a workspace should turn the filter on and enable the toggle")

        // the item's label has flipped to "Unfocus" (the set is exactly this workspace AND the filter is
        // on); invoking it clears the set, so the hidden workspace + its session row return.
        invokeWorkspaceMenuItem("Unfocus", onWorkspace: "workspace 2")
        XCTAssertTrue(sessionRow(named: "visible").waitForExistence(timeout: 8),
                      "Unfocus should restore the other workspace's session row")
        XCTAssertTrue(workspaceRow(named: "workspace 1").waitForExistence(timeout: 5),
                      "Unfocus should restore the other workspace's row")
        XCTAssertTrue(pollFilterToggle(value: "off", enabled: false, timeout: 8),
                      "Unfocus CLEARS the set (not just the flag), so the toggle goes back to off AND disabled")
    }

    /// The multi-workspace working set: mark two of three workspaces via the row menu's "Add to Focus" and
    /// confirm the tree renders exactly those two while the third stays out. This is what the set
    /// generalization buys over the old one-or-all filter, and it is the only assertion that would catch
    /// "Add to Focus" being wired to the replace-toggle by mistake (which would leave ONE row visible).
    func testAddToFocusKeepsBothMarkedWorkspacesVisible() throws {
        markFirstTwoOfThreeWorkspaces()

        XCTAssertTrue(workspaceRow(named: "workspace 1").waitForExistence(timeout: 8),
                      "the first marked workspace should render")
        XCTAssertTrue(workspaceRow(named: "workspace 2").waitForExistence(timeout: 8),
                      "the second marked workspace should render alongside it — membership is additive")
        XCTAssertTrue(workspaceRow(named: "workspace 3").waitForNonExistence(timeout: 8),
                      "the unmarked third workspace should stay out of the filtered tree")
        XCTAssertTrue(pollWorkspaceRowCount(2, timeout: 8), "exactly the two marked workspaces should render")
    }

    /// The bottom-bar toggle SUSPENDS the filter without destroying the set: with two workspaces marked,
    /// one click brings the whole tree back (and the toggle stays ENABLED, since the set is still there),
    /// and a second click restores exactly the same two rows with nothing re-marked. That survival is the
    /// point of splitting membership from the on/off flag — the old pill could only clear.
    func testFilterToggleSuspendsAndRestoresTheMarkedSet() throws {
        markFirstTwoOfThreeWorkspaces()
        XCTAssertTrue(pollWorkspaceRowCount(2, timeout: 8), "the filtered tree should start at the two marked workspaces")

        // suspend: the whole tree returns, the toggle reads off but stays ENABLED — the set survives.
        filterToggle().click()
        XCTAssertTrue(pollFilterToggle(value: "off", enabled: true, timeout: 8),
                      "suspending should read off yet stay enabled — the marked set is untouched")
        XCTAssertTrue(pollWorkspaceRowCount(3, timeout: 8), "suspending the filter should bring every workspace row back")
        XCTAssertTrue(workspaceRow(named: "workspace 3").waitForExistence(timeout: 8),
                      "the unmarked workspace should be visible while the filter is suspended")

        // re-enable: the SAME two rows come back with nothing re-marked, proving the set survived.
        filterToggle().click()
        XCTAssertTrue(pollFilterToggle(value: "on", enabled: true, timeout: 8), "re-enabling should read on")
        XCTAssertTrue(pollWorkspaceRowCount(2, timeout: 8), "re-enabling should filter back down to the marked set")
        XCTAssertTrue(workspaceRow(named: "workspace 1").waitForExistence(timeout: 8), "workspace 1 should still be marked")
        XCTAssertTrue(workspaceRow(named: "workspace 2").waitForExistence(timeout: 8), "workspace 2 should still be marked")
        XCTAssertTrue(workspaceRow(named: "workspace 3").waitForNonExistence(timeout: 5),
                      "the unmarked workspace should be filtered out again")
    }

    /// The toggle is DISABLED while nothing is marked and enabled once a workspace joins the set — the GUI
    /// half of the "enabled + empty set is unrepresentable" invariant (the store refuses to enable an empty
    /// set, so an enabled-but-inert button would misrepresent what a click does). Removing the last member
    /// puts it back. `isEnabled` and `value` are both accessibility-observable, so this belongs in an e2e
    /// rather than in the manual checks.
    ///
    /// It is also the direct read of the mark-only contract on the two accessibility-observable fields:
    /// "Add to Focus" moves `isEnabled` false → true while `value` stays `off`, so the two must be
    /// asserted together — a marking add that also flipped `value` to `on` would pass an `isEnabled`-only
    /// check.
    func testFilterToggleIsDisabledUntilAWorkspaceIsMarked() throws {
        XCTAssertTrue(sessionRow().waitForExistence(timeout: 20), "seeded session should exist")
        let toggle = filterToggle()
        XCTAssertTrue(toggle.waitForExistence(timeout: 8), "the filter toggle should be in the bottom bar")
        XCTAssertEqual(toggle.label, "Toggle Workspace Filter", "the toggle should carry its accessibility label")
        XCTAssertTrue(pollFilterToggle(value: "off", enabled: false, timeout: 8),
                      "with nothing marked the toggle should be disabled and read off")

        invokeWorkspaceMenuItem("Add to Focus", onWorkspace: "workspace 1")
        XCTAssertTrue(pollFilterToggle(value: "off", enabled: true, timeout: 8),
                      "marking a workspace should enable the toggle WITHOUT turning the filter on")

        // the item now reads "Remove from Focus"; taking the last member out empties the set, so the
        // toggle must go back to disabled rather than sit enabled over an empty filter.
        invokeWorkspaceMenuItem("Remove from Focus", onWorkspace: "workspace 1")
        XCTAssertTrue(pollFilterToggle(value: "off", enabled: false, timeout: 8),
                      "removing the last member should empty the set and disable the toggle again")
    }

    // MARK: - Fixture

    /// Seeds three workspaces (the seeded "workspace 1" plus two empty ones), marks the first two into the
    /// focus set via their rows' "Add to Focus" item, then applies the set with one click of the bottom-bar
    /// toggle — leaving the filter ON with a two-member set.
    ///
    /// "Add to Focus" MARKS ONLY, so both rows stay on screen and the second workspace can be right-clicked
    /// straight away. That is what the mark-only contract buys: an N-workspace set costs N marks plus one
    /// click, instead of a suspend/mark/re-enable round-trip per extra member (each mark would otherwise
    /// collapse the tree onto the marked set and hide the rows still to be marked).
    private func markFirstTwoOfThreeWorkspaces() {
        XCTAssertTrue(sessionRow().waitForExistence(timeout: 20), "seeded session should exist")
        addWorkspace()
        XCTAssertTrue(workspaceRow(named: "workspace 2").waitForExistence(timeout: 8), "second workspace should appear")
        addWorkspace()
        XCTAssertTrue(workspaceRow(named: "workspace 3").waitForExistence(timeout: 8), "third workspace should appear")

        invokeWorkspaceMenuItem("Add to Focus", onWorkspace: "workspace 1")
        XCTAssertTrue(pollFilterToggle(value: "off", enabled: true, timeout: 8),
                      "marking should ENABLE the toggle while leaving the filter off")
        XCTAssertTrue(pollWorkspaceRowCount(3, timeout: 8),
                      "marking must not narrow the tree — the rows still to be marked stay reachable")

        invokeWorkspaceMenuItem("Add to Focus", onWorkspace: "workspace 2")
        XCTAssertTrue(pollFilterToggle(value: "off", enabled: true, timeout: 8),
                      "a second mark still leaves the filter off")
        XCTAssertTrue(pollWorkspaceRowCount(3, timeout: 8), "the whole tree is still on screen after both marks")

        filterToggle().click()
        XCTAssertTrue(pollFilterToggle(value: "on", enabled: true, timeout: 8),
                      "one click of the toggle applies the marked set")
    }

    // MARK: - Actions

    /// Right-clicks the named workspace row and clicks the context-menu item titled `item`. The workspace
    /// group holds Focus (or Unfocus) followed by Add to Focus (or Remove from Focus), so the title a test
    /// passes here is itself an assertion about the label flip.
    private func invokeWorkspaceMenuItem(_ item: String, onWorkspace name: String) {
        let row = workspaceRow(named: name)
        XCTAssertTrue(row.waitForHittable(timeout: 10), "\(name) row should be hittable to open its menu")
        row.rightClick()
        let entry = presentedMenuItem(item)
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "\(item) menu item should appear on the \(name) row menu")
        entry.click()
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

    /// A workspace row matched by its displayed name (lands in the StaticText `value`), constrained to the
    /// `workspace-row` identifier — the direct read of which workspaces the filtered tree renders.
    private func workspaceRow(named name: String) -> XCUIElement {
        app.staticTexts
            .matching(NSPredicate(format: "identifier == %@ AND value == %@", "workspace-row", name))
            .firstMatch
    }

    /// The bottom-bar filter toggle — both the control and the only accessibility-observable read of the
    /// filter state.
    private func filterToggle() -> XCUIElement { app.buttons["focus-filter-toggle"] }

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

    // MARK: - Pollers

    /// Polls the filter toggle until it reports BOTH `value` (`on`/`off`) and `enabled`. The two are
    /// asserted together because they answer different questions — whether the filter applies, and whether
    /// anything is marked — and only their combination pins the state the pill used to show.
    private func pollFilterToggle(value: String, enabled: Bool, timeout: TimeInterval) -> Bool {
        let toggle = filterToggle()
        return poll(until: toggle.exists && (toggle.value as? String) == value && toggle.isEnabled == enabled,
                    timeout: timeout)
    }

    /// Polls until the visible `workspace-row` element count equals `expected`. NSOutlineView recycles
    /// cells, so the AX-tree count can lag a reload — hence the retry loop.
    private func pollWorkspaceRowCount(_ expected: Int, timeout: TimeInterval) -> Bool {
        poll(until: app.staticTexts.matching(identifier: "workspace-row").count == expected, timeout: timeout)
    }

}
