import XCTest

/// Real UI tests for drag-and-drop reorder within the sidebar. These launch the
/// actual app and drive the `NSOutlineView` through the accessibility API, the
/// coverage the host-free `agtermCore` unit tests cannot reach (the drag-drop
/// index handling lives in `WorkspaceSidebar.Coordinator`).
@MainActor
final class ReorderUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stateDir: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        // hermetic state: a fresh temp dir per test so the app seeds exactly one
        // "workspace 1" + one session, and we never touch the real workspaces.json.
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

    // Drag a session UP onto a higher sibling and confirm the persisted order changed through the
    // full sidebar drop path (validateDrop → acceptDrop → moveSessions). Three sessions are seeded with
    // aaa/bbb/ccc custom names so the persisted order is an unambiguous oracle. Dropping ccc ON
    // aaa's row inserts ccc just after aaa: [aaa, bbb, ccc] → [aaa, ccc, bbb].
    func testReorderSessionUp() throws {
        try relaunchWithSessions(["aaa", "bbb", "ccc"])
        dragRow(named: "ccc", onto: "aaa")
        XCTAssertTrue(pollSessionNames(["aaa", "ccc", "bbb"], timeout: 10),
                      "dragging ccc up onto aaa should reorder to [aaa, ccc, bbb]")
    }

    // Drag a session DOWN onto a lower sibling. Dropping bbb ON ccc's row inserts bbb just after
    // ccc: [aaa, bbb, ccc] → [aaa, ccc, bbb]. The downward path exercises the same-workspace
    // `childIndex - 1` post-removal adjustment in `acceptDrop` (sourceIndex 1 < dropChildIndex 3)
    // that the up-move does not.
    func testReorderSessionDown() throws {
        try relaunchWithSessions(["aaa", "bbb", "ccc"])
        dragRow(named: "bbb", onto: "ccc")
        XCTAssertTrue(pollSessionNames(["aaa", "ccc", "bbb"], timeout: 10),
                      "dragging bbb down onto ccc should reorder to [aaa, ccc, bbb]")
    }

    // Drag a session DOWN onto a MIDDLE row (not the last). With four sessions [aaa, bbb, ccc, ddd],
    // dragging aaa onto ccc's row inserts aaa just after ccc → [bbb, ccc, aaa, ddd]. This discriminates
    // the same-workspace downward `childIndex - 1` post-removal adjustment: WITH it the session lands at
    // index 2 ([bbb, ccc, aaa, ddd]); WITHOUT it the append-clamp would push it to the END
    // ([bbb, ccc, ddd, aaa]) — the two outcomes differ only because the drop is NOT onto the last row.
    func testReorderSessionDownPastMiddle() throws {
        try relaunchWithSessions(["aaa", "bbb", "ccc", "ddd"])
        dragRow(named: "aaa", onto: "ccc")
        XCTAssertTrue(pollSessionNames(["bbb", "ccc", "aaa", "ddd"], timeout: 10),
                      "dragging aaa down onto the middle row ccc should land it between ccc and ddd")
    }

    // Shift-click creates a range, Command-click toggles one row out, and right-clicking inside the
    // remaining multi-selection must keep it for batch context-menu actions. Right-clicking outside the
    // selection should narrow to that clicked row. The oracle is the persisted flag state because AppKit's
    // transient outline multi-selection is not serialized.
    func testMultiSelectContextMenuKeepsAndNarrowsSelection() throws {
        try relaunchWithSessions(["aaa", "bbb", "ccc", "ddd"])

        sessionRow(named: "aaa").click()
        modifiedClick(sessionRow(named: "ccc"), modifiers: .shift)
        modifiedClick(sessionRow(named: "bbb"), modifiers: .command)

        sessionRow(named: "aaa").rightClick()
        let flagSessions = presentedMenuItem("Flag Sessions")
        XCTAssertTrue(flagSessions.waitForExistence(timeout: 5), "multi-selection context menu should offer Flag Sessions")
        flagSessions.click()
        XCTAssertTrue(pollFlagged(["aaa": true, "bbb": false, "ccc": true, "ddd": false], timeout: 8),
                      "batch flag should affect the Shift/Cmd-click multi-selection only")

        sessionRow(named: "ddd").rightClick()
        let flag = presentedMenuItem("Flag")
        XCTAssertTrue(flag.waitForExistence(timeout: 5), "right-click outside the selection should narrow to one row")
        flag.click()
        XCTAssertTrue(pollFlagged(["aaa": true, "bbb": false, "ccc": true, "ddd": true], timeout: 8),
                      "outside right-click should flag only the clicked row")
    }

    // Dragging from any selected row should move the whole selected block, not just the row under the
    // pointer. Dropping bbb/ccc onto ddd inserts the block after ddd:
    // [aaa, bbb, ccc, ddd, eee] -> [aaa, ddd, bbb, ccc, eee].
    func testDragSelectedSessionsMovesBlock() throws {
        try relaunchWithSessions(["aaa", "bbb", "ccc", "ddd", "eee"])
        sessionRow(named: "bbb").click()
        modifiedClick(sessionRow(named: "ccc"), modifiers: .shift)

        dragSelectedRow(named: "bbb", onto: "ddd")
        XCTAssertTrue(pollSessionNames(["aaa", "ddd", "bbb", "ccc", "eee"], timeout: 10),
                      "dragging a selected block onto ddd should move bbb+ccc together after ddd")
    }

    // The primary batch-drag workflow is cross-workspace: the AppKit pasteboard must carry every selected
    // id, resolve the destination row's owning workspace, and persist the ordered block there.
    func testDragSelectedSessionsAcrossWorkspacesMovesBlock() throws {
        try relaunchWithWorkspaces([
            (name: "one", sessions: ["aaa", "bbb"]),
            (name: "two", sessions: ["ccc", "ddd"]),
        ])
        sessionRow(named: "aaa").click()
        modifiedClick(sessionRow(named: "bbb"), modifiers: .shift)
        sessionRow(named: "aaa").rightClick()
        XCTAssertTrue(presentedMenuItem("Close 2 Sessions").waitForExistence(timeout: 5),
                      "the source rows must remain multi-selected before dragging")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

        dragSelectedRow(named: "aaa", onto: "ccc")

        XCTAssertTrue(pollWorkspaceSessionNames([
            "one": [],
            "two": ["ccc", "aaa", "bbb", "ddd"],
        ], timeout: 10), "the selected block should move after ccc in workspace two")
    }

    // Confirmation is normally bypassed in XCUITests. This test opts in narrowly and verifies the exact
    // batch-close regression: one alert names the selected count, and Cancel leaves every session intact.
    func testMultiSessionCloseRequiresOneConfirmation() throws {
        try relaunchWithWorkspaces([
            (name: "workspace 1", sessions: ["aaa", "bbb", "ccc"]),
        ], confirmClose: true)
        sessionRow(named: "aaa").click()
        modifiedClick(sessionRow(named: "ccc"), modifiers: .shift)

        sessionRow(named: "aaa").rightClick()
        let close = presentedMenuItem("Close 3 Sessions")
        XCTAssertTrue(close.waitForExistence(timeout: 5), "batch context menu should offer one close command")
        close.click()

        let alert = app.dialogs.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "batch close should present a confirmation alert")
        XCTAssertTrue(alert.staticTexts["Close 3 Sessions?"].exists, "the alert should report the batch size")
        XCTAssertEqual(app.dialogs.count, 1, "batch close should present exactly one confirmation")
        alert.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(pollSessionNames(["aaa", "bbb", "ccc"], timeout: 5),
                      "cancelling the batch confirmation must leave every session open")
    }

    // Drag a workspace UP above a higher sibling and confirm the persisted order changed through the
    // full sidebar drop path (validateDrop → acceptDrop → moveWorkspace). Three workspaces are created
    // (workspace 1/2/3). Dropping "workspace 3" near the TOP edge of "workspace 1" lands a top-level
    // between-rows drop above it: [workspace 1, workspace 2, workspace 3] → [workspace 3, workspace 1, workspace 2].
    func testReorderWorkspace() throws {
        seedThreeWorkspaces()
        dragWorkspaceRow(named: "workspace 3", toTopOf: "workspace 1")
        XCTAssertTrue(pollWorkspaceNames(["workspace 3", "workspace 1", "workspace 2"], timeout: 10),
                      "dragging workspace 3 above workspace 1 should reorder to [workspace 3, workspace 1, workspace 2]")
    }

    // Drop a workspace onto a SESSION row that belongs to another workspace — the realistic case the
    // edge-sliver test misses. With workspaces expanded (each holding sessions, like the real app), the
    // space between workspace rows is filled with session rows, so a dragged workspace lands ON a session
    // (or workspace) row, which AppKit proposes as `item != nil`. The original `guard item == nil` rejected
    // every such drop (the reported "can't drag workspaces" bug). Dropping workspace 3 onto workspace 1's
    // session row reorders it just after its owning workspace: [w1, w2, w3] → [w1, w3, w2].
    func testReorderWorkspaceOntoSessionRow() throws {
        seedThreeWorkspaces() // workspace 1 keeps the seeded session; 2 and 3 are empty
        dragWorkspaceOntoSessionRow(named: "workspace 3")
        XCTAssertTrue(pollWorkspaceNames(["workspace 1", "workspace 3", "workspace 2"], timeout: 10),
                      "dropping workspace 3 onto workspace 1's session row should land it after workspace 1 → [w1, w3, w2]")
    }

    // MARK: - Fixture

    /// Relaunches with a prewritten window snapshot so tests that specifically exercise selection/drag
    /// gestures don't depend on the slower inline-rename fixture.
    private func relaunchWithSessions(_ names: [String]) throws {
        try relaunchWithWorkspaces([(name: "workspace 1", sessions: names)])
    }

    /// Relaunches with named workspaces and sessions. `confirmClose` opts one focused test back into the
    /// close modal that ordinary XCUITest launches suppress to avoid hanging unrelated close flows.
    private func relaunchWithWorkspaces(_ fixtures: [(name: String, sessions: [String])], confirmClose: Bool = false) throws {
        let snapshotFile = stateDir.windowSnapshotFile()
        app.terminate()

        var firstSessionID: String?
        let workspaces = fixtures.map { fixture -> [String: Any] in
            let sessions = fixture.sessions.map { name -> [String: Any] in
                let id = UUID().uuidString
                if firstSessionID == nil { firstSessionID = id }
                return ["id": id, "customName": name, "cwd": NSHomeDirectory()]
            }
            return ["id": UUID().uuidString, "name": fixture.name, "sessions": sessions]
        }
        let selectedSessionID = try XCTUnwrap(firstSessionID, "the fixture must contain at least one session")
        let snapshot: [String: Any] = [
            "version": 1,
            "selectedSessionID": selectedSessionID,
            "workspaces": workspaces,
            "sidebarVisible": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: snapshotFile, options: .atomic)
        if confirmClose {
            try Data(#"{"confirmCloseSession":true}"#.utf8)
                .write(to: stateDir.appendingPathComponent("settings.json"), options: .atomic)
        }

        app = XCUIApplication()
        app.launchEnvironment["AGTERM_STATE_DIR"] = stateDir.path
        if confirmClose { app.launchEnvironment["AGTERM_UITEST_ALLOW_CLOSE_CONFIRMATION"] = "1" }
        app.launchForUITest()
        for name in fixtures.flatMap(\.sessions) {
            XCTAssertTrue(sessionRow(named: name).waitForExistence(timeout: 10), "seeded session \(name) should be visible")
        }
    }

    /// Adds two more workspaces to the seeded one, leaving the tree holding
    /// [workspace 1, workspace 2, workspace 3] (workspace 1 keeps the seeded session; 2 and 3 are empty).
    private func seedThreeWorkspaces() {
        XCTAssertTrue(app.staticTexts["workspace 1"].waitForExistence(timeout: 20), "seeded workspace should exist")
        addWorkspace()
        addWorkspace()
        XCTAssertTrue(pollWorkspaceNames(["workspace 1", "workspace 2", "workspace 3"], timeout: 10),
                      "the three workspaces should persist in creation order")
    }

    // MARK: - Helpers

    /// The (single, seeded) session row, matched by its stable accessibility identifier.
    private func sessionRow() -> XCUIElement { app.staticTexts["session-row"] }

    /// A session row matched by its displayed name (lands in the StaticText `value`). Constrained
    /// to the `session-row` identifier so it never matches the window title (which carries the same
    /// cwd-basename text).
    private func sessionRow(named name: String) -> XCUIElement {
        app.staticTexts
            .matching(NSPredicate(format: "identifier == %@ AND value == %@", "session-row", name))
            .firstMatch
    }

    /// A workspace row matched by its displayed name (lands in the StaticText `value`), constrained
    /// to the `workspace-row` identifier.
    private func workspaceRow(named name: String) -> XCUIElement {
        app.staticTexts
            .matching(NSPredicate(format: "identifier == %@ AND value == %@", "workspace-row", name))
            .firstMatch
    }

    /// Drags the workspace row named `source` to the TOP edge of the row named `target`. Aiming the
    /// drop at the top sliver of the target lands a top-level between-rows drop ABOVE it (the only
    /// valid workspace-reorder slot — `proposedItem == nil`), so the dragged workspace inserts just
    /// before the target. Same gesture mechanics as `dragRow`: select the source first (the outline
    /// only drags the selected row), then a mouse-native coordinate drag.
    private func dragWorkspaceRow(named source: String, toTopOf target: String) {
        let from = workspaceRow(named: source)
        let to = workspaceRow(named: target)
        XCTAssertTrue(from.waitForHittable(timeout: 10), "\(source) row should be hittable to drag")
        XCTAssertTrue(to.waitForHittable(timeout: 10), "\(target) row should be hittable as a drop target")
        from.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let start = from.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // the top sliver of the target → NSOutlineView proposes a drop above it at the top level.
        let end = to.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05))
        start.click(forDuration: 0.7, thenDragTo: end, withVelocity: 180, thenHoldForDuration: 0.25)
    }

    /// Drags the workspace row named `source` onto the CENTER of the seeded session row (which belongs to
    /// workspace 1) — so the drop lands ON a session row (`item != nil`), the realistic case where a
    /// workspace reorder must still work. Same gesture mechanics as `dragWorkspaceRow(named:toTopOf:)`.
    private func dragWorkspaceOntoSessionRow(named source: String) {
        let from = workspaceRow(named: source)
        let to = sessionRow()
        XCTAssertTrue(from.waitForHittable(timeout: 10), "\(source) row should be hittable to drag")
        XCTAssertTrue(to.waitForHittable(timeout: 10), "the session row should be hittable as a drop target")
        from.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let start = from.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = to.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.click(forDuration: 0.7, thenDragTo: end, withVelocity: 180, thenHoldForDuration: 0.25)
    }

    /// Adds a new (empty) workspace via the bottom-bar add-workspace button.
    private func addWorkspace() {
        app.buttons["New Workspace"].click()
    }

    /// Drags the session row named `source` onto the row named `target`. Two details make the
    /// NSOutlineView drag deliver to the drop delegate reliably:
    /// 1. drag via `coordinate(withNormalizedOffset:)`, NOT element-to-element — the AX element is
    ///    the recycled `NSTextField` inside the row, while the drag tracking lives in the outline,
    ///    so a coordinate drag targets the outline machinery directly;
    /// 2. use the mouse-native `click(forDuration:thenDragTo:withVelocity:thenHoldForDuration:)`
    ///    (with a final hold), NOT the touch `press(...)`.
    private func dragRow(named source: String, onto target: String) {
        let from = sessionRow(named: source)
        let to = sessionRow(named: target)
        XCTAssertTrue(from.waitForHittable(timeout: 10), "\(source) row should be hittable to drag")
        XCTAssertTrue(to.waitForHittable(timeout: 10), "\(target) row should be hittable as a drop target")
        // select the source row first: the outline only begins a drag from the selected row, so an
        // unselected source (e.g. a middle row that wasn't the last one touched) never starts a drag.
        from.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let start = from.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = to.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.click(forDuration: 0.7, thenDragTo: end, withVelocity: 180, thenHoldForDuration: 0.25)
    }

    /// Drags from a row that is already part of the current selection. Unlike `dragRow`, this must not
    /// click the source first: a plain click would collapse the multi-selection before the drag begins.
    private func dragSelectedRow(named source: String, onto target: String) {
        let from = sessionRow(named: source)
        let to = sessionRow(named: target)
        XCTAssertTrue(from.waitForHittable(timeout: 10), "\(source) row should be hittable to drag")
        XCTAssertTrue(to.waitForHittable(timeout: 10), "\(target) row should be hittable as a drop target")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let start = from.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = to.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.click(forDuration: 0.7, thenDragTo: end, withVelocity: 180, thenHoldForDuration: 0.25)
    }

    /// Xcode's macOS XCUIElement has no modifier-click overload, so apply XCTest key modifiers
    /// around a coordinate click to exercise AppKit's normal Shift/Cmd selection path.
    private func modifiedClick(_ element: XCUIElement, modifiers: XCUIElement.KeyModifierFlags) {
        XCTAssertTrue(element.waitForHittable(timeout: 10), "row should be hittable for modified click")
        app.activate()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let coordinate = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        XCUIElement.perform(withKeyModifiers: modifiers) {
            coordinate.click()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
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

    /// Polls the hermetic snapshot file until the (single seeded workspace's) session
    /// `customName`s equal `expected`, in order.
    private func pollSessionNames(_ expected: [String], timeout: TimeInterval) -> Bool {
        stateDir.pollSnapshot(equals: expected, timeout: timeout) { obj in
            guard let workspaces = obj["workspaces"] as? [[String: Any]],
                  let sessions = workspaces.first?["sessions"] as? [[String: Any]] else { return nil }
            return sessions.compactMap { $0["customName"] as? String }
        }
    }

    /// Polls every named workspace's persisted session labels, preserving each workspace's session order.
    private func pollWorkspaceSessionNames(_ expected: [String: [String]], timeout: TimeInterval) -> Bool {
        stateDir.pollSnapshot(equals: expected, timeout: timeout) { obj in
            guard let workspaces = obj["workspaces"] as? [[String: Any]] else { return nil }
            var result: [String: [String]] = [:]
            for workspace in workspaces {
                guard let name = workspace["name"] as? String,
                      expected.keys.contains(name),
                      let sessions = workspace["sessions"] as? [[String: Any]] else { continue }
                result[name] = sessions.compactMap { $0["customName"] as? String }
            }
            return result.count == expected.count ? result : nil
        }
    }

    /// Polls the seeded workspace until every named session's persisted `flagged` field matches.
    private func pollFlagged(_ expected: [String: Bool], timeout: TimeInterval) -> Bool {
        stateDir.pollSnapshot(equals: expected, timeout: timeout) { obj in
            guard let workspaces = obj["workspaces"] as? [[String: Any]],
                  let sessions = workspaces.first?["sessions"] as? [[String: Any]] else { return nil }
            var result: [String: Bool] = [:]
            for session in sessions {
                guard let name = session["customName"] as? String, expected.keys.contains(name) else { continue }
                result[name] = session["flagged"] as? Bool ?? false
            }
            return result.count == expected.count ? result : nil
        }
    }

    /// Polls the hermetic snapshot file until the workspace `name`s equal `expected`, in order.
    private func pollWorkspaceNames(_ expected: [String], timeout: TimeInterval) -> Bool {
        stateDir.pollSnapshot(equals: expected, timeout: timeout) { obj in
            guard let workspaces = obj["workspaces"] as? [[String: Any]] else { return nil }
            return workspaces.compactMap { $0["name"] as? String }
        }
    }
}
