import Foundation
import XCTest

/// Control-channel e2e for the sidebar visibility/mode/expand-collapse, workspace focus, session
/// flag, agent-status glyph, and notification-badge behaviors. Subclass of `ControlAPITestCase`.
@MainActor
final class ControlSidebarStatusUITests: ControlAPITestCase {
    // the pane must be UNFOCUSED or suppression drops the notification, and --select would re-focus it.
    func testUnfocusedNotificationBadgesRowAndClearsOnSelect() throws {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let treeResult = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let root = try XCTUnwrap(treeResult["tree"] as? [String: Any], "result should carry a tree")
        let workspaces = try XCTUnwrap(root["workspaces"] as? [[String: Any]], "tree should list workspaces")
        let sessions = try XCTUnwrap(workspaces.first?["sessions"] as? [[String: Any]], "workspace should list sessions")
        let seeded = try XCTUnwrap(sessions.first?["id"] as? String, "should have a seeded session id")

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.new"}"#)["ok"] as? Bool, true)
        XCTAssertTrue(pollSessionCount(2, timeout: 10), "the new session should land")

        let typed = try sendCommand(typeRequest(text: "printf '\\033]9;agterm test\\007'\n", target: seeded, select: false))
        XCTAssertEqual(typed["ok"] as? Bool, true, "typing into the realized seeded session should succeed: \(typed)")

        XCTAssertTrue(app.staticTexts["notify-badge"].waitForExistence(timeout: 12),
                      "an unseen badge should appear on the unfocused session's row")

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(seeded)"}"#)["ok"] as? Bool, true)
        XCTAssertTrue(app.staticTexts["notify-badge"].waitForNonExistence(timeout: 12),
                      "selecting the session should clear its badge")
    }

    // the custom split has no system toggle, so hiding is observable as the rows leaving the AX tree.
    func testSidebarShowHideToggle() throws {
        XCTAssertTrue(app.staticTexts["session-row"].waitForExistence(timeout: 10), "sidebar should start visible")

        XCTAssertEqual(try sendCommand(#"{"cmd":"sidebar","args":{"mode":"hide"}}"#)["ok"] as? Bool, true,
                       "sidebar hide should succeed")
        XCTAssertTrue(app.staticTexts["session-row"].waitForNonExistence(timeout: 10),
                      "hiding the sidebar should remove the session rows")

        XCTAssertEqual(try sendCommand(#"{"cmd":"sidebar","args":{"mode":"show"}}"#)["ok"] as? Bool, true,
                       "sidebar show should succeed")
        XCTAssertTrue(app.staticTexts["session-row"].waitForExistence(timeout: 10),
                      "showing the sidebar should restore the session rows")

        let bad = try sendCommand(#"{"cmd":"sidebar","args":{"mode":"sideways"}}"#)
        XCTAssertEqual(bad["ok"] as? Bool, false, "an invalid sidebar mode should error")
    }

    // flagged rows are labeled "session : workspace", which is how they are told apart from tree rows.
    func testSessionFlagAndSidebarModeFlagged() throws {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 10), "seeded session row")

        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let result = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let t = try XCTUnwrap(result["tree"] as? [String: Any], "result should carry a tree")
        let ws = try XCTUnwrap((t["workspaces"] as? [[String: Any]])?.first, "should have a workspace")
        let seededID = try XCTUnwrap((ws["sessions"] as? [[String: Any]])?.first?["id"] as? String, "should have a seeded session")

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(seededID)","args":{"name":"flagme"}}"#)["ok"] as? Bool,
                       true, "renaming the seeded session should succeed")
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let newID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new should return an id")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(newID)","args":{"name":"keepme"}}"#)["ok"] as? Bool,
                       true, "renaming the new session should succeed")

        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "both session rows should be present in tree mode")

        let flag = try sendCommand(#"{"cmd":"session.flag","target":"\#(seededID)","args":{"mode":"on"}}"#)
        XCTAssertEqual(flag["ok"] as? Bool, true, "session.flag on should succeed: \(flag)")

        let mode = try sendCommand(#"{"cmd":"sidebar.mode","args":{"mode":"flagged"}}"#)
        XCTAssertEqual(mode["ok"] as? Bool, true, "sidebar.mode flagged should succeed: \(mode)")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "flagged mode should show only the one flagged row")
        XCTAssertTrue(sessionRowValueExists(containing: "flagme"), "the flagged session's row should be present")
        XCTAssertFalse(sessionRowValueExists(containing: "keepme"), "the unflagged session's row should be absent")

        XCTAssertEqual(try sendCommand(#"{"cmd":"sidebar.mode","args":{"mode":"toggle"}}"#)["ok"] as? Bool, true,
                       "sidebar.mode toggle should succeed")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "toggling back to tree restores the full tree")

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.flag","target":"\#(newID)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "flagging the second session should succeed")
        XCTAssertEqual(try sendCommand(#"{"cmd":"sidebar.mode","args":{"mode":"flagged"}}"#)["ok"] as? Bool, true,
                       "switching to flagged should succeed")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "both flagged rows should be present")
        let cleared = try sendCommand(#"{"cmd":"session.flag","args":{"mode":"clear"}}"#)
        XCTAssertEqual(cleared["ok"] as? Bool, true, "session.flag clear should succeed: \(cleared)")
        XCTAssertTrue(pollSessionRowCount(0, timeout: 10), "clearing all flags empties the flagged view")
        XCTAssertEqual(try sendCommand(#"{"cmd":"sidebar.mode","args":{"mode":"tree"}}"#)["ok"] as? Bool, true,
                       "switching back to tree should succeed")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "the sessions themselves are not closed by clear")

        let bad = try sendCommand(#"{"cmd":"sidebar.mode","args":{"mode":"bogus"}}"#)
        XCTAssertEqual(bad["ok"] as? Bool, false, "an invalid sidebar mode should error: \(bad)")
        XCTAssertTrue((bad["error"] as? String ?? "").contains("invalid sidebar mode"), "should report invalid mode: \(bad)")
    }

    // orthogonal to the flagged view: the flat list ignores the marked set entirely.
    func testWorkspaceFocusHidesOtherWorkspaces() throws {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 10), "seeded session row")

        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let result = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let t = try XCTUnwrap(result["tree"] as? [String: Any], "result should carry a tree")
        let ws = try XCTUnwrap((t["workspaces"] as? [[String: Any]])?.first, "should have a workspace")
        let firstWsID = try XCTUnwrap(ws["id"] as? String, "should have a seeded workspace id")
        let seededID = try XCTUnwrap((ws["sessions"] as? [[String: Any]])?.first?["id"] as? String, "should have a seeded session")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(seededID)","args":{"name":"stay"}}"#)["ok"] as? Bool,
                       true, "renaming the seeded session should succeed")

        let newWs = try sendCommand(#"{"cmd":"workspace.new","args":{"name":"second"}}"#)
        let secondWsID = try XCTUnwrap((newWs["result"] as? [String: Any])?["id"] as? String, "workspace.new should return an id")
        let created = try sendCommand(#"{"cmd":"session.new","args":{"workspace":"\#(secondWsID)"}}"#)
        let newSessID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new should return an id")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(newSessID)","args":{"name":"hidden"}}"#)["ok"] as? Bool,
                       true, "renaming the new session should succeed")

        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "both session rows should be present unfocused")

        // the active session must be INSIDE the focused workspace, or the narrowing moves the selection.
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(seededID)"}"#)["ok"] as? Bool, true,
                       "selecting the seeded session should succeed")
        let focus = try sendCommand(#"{"cmd":"workspace.focus","target":"\#(firstWsID)","args":{"mode":"on"}}"#)
        XCTAssertEqual(focus["ok"] as? Bool, true, "workspace.focus on should succeed: \(focus)")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "focusing one workspace should hide the other's rows")
        XCTAssertTrue(sessionRowValueExists(containing: "stay"), "the focused workspace's session should remain")
        XCTAssertFalse(sessionRowValueExists(containing: "hidden"), "the other workspace's session should be hidden")

        // `off` on a NON-member only drops it from the set, so the first workspace's mark survives.
        XCTAssertEqual(try sendCommand(#"{"cmd":"workspace.focus","target":"\#(secondWsID)","args":{"mode":"off"}}"#)["ok"] as? Bool,
                       true, "workspace.focus off on a non-focused workspace should succeed (no-op)")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "the focus on the first workspace should be unchanged")
        XCTAssertTrue(sessionRowValueExists(containing: "stay"), "the focused workspace's session should still remain")
        XCTAssertFalse(sessionRowValueExists(containing: "hidden"), "the other workspace's session should still be hidden")

        XCTAssertEqual(try sendCommand(#"{"cmd":"workspace.focus","target":"\#(firstWsID)","args":{"mode":"off"}}"#)["ok"] as? Bool,
                       true, "workspace.focus off should succeed")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "unfocusing should restore the full tree")

        // an invalid mode errors rather than silently no-opping.
        let bad = try sendCommand(#"{"cmd":"workspace.focus","target":"\#(firstWsID)","args":{"mode":"bogus"}}"#)
        XCTAssertEqual(bad["ok"] as? Bool, false, "an invalid focus mode should error: \(bad)")
        XCTAssertTrue((bad["error"] as? String ?? "").contains("invalid focus mode"), "should report invalid mode: \(bad)")
    }

    // `focused` reports SET MEMBERSHIP, independently of whether the filter applies.
    func testWorkspaceFocusAddBuildsAMultiWorkspaceSet() throws {
        let ids = try seedFocusWorkspaces([(workspace: "second", session: "hidden"),
                                           (workspace: "third", session: "buried")])
        let (first, second, third) = (ids[0], ids[1], ids[2])

        // `add` NEVER turns the filter on, or marking row by row would hide the rows still to be marked.
        XCTAssertEqual(try sendCommand(#"{"cmd":"workspace.focus","target":"\#(third)","args":{"mode":"add"}}"#)["ok"] as? Bool,
                       true, "workspace.focus add should succeed on an empty set")
        XCTAssertEqual(treeWorkspaceFilter(), false, "add must leave the filter off")
        XCTAssertEqual(try workspaceFocusedFlag(third), true, "the added workspace should read back focused")
        XCTAssertTrue(pollSessionRowCount(3, timeout: 10), "with the filter off every session row still renders")

        let focus = try sendCommand(#"{"cmd":"workspace.focus","target":"\#(first)","args":{"mode":"on"}}"#)
        XCTAssertEqual(focus["ok"] as? Bool, true, "workspace.focus on should succeed: \(focus)")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "marking one workspace should hide the other two")
        XCTAssertTrue(sessionRowValueExists(containing: "stay"), "the marked workspace's session should remain")
        XCTAssertEqual(try workspaceFocusedFlag(first), true, "the marked workspace should read back focused")
        XCTAssertNil(try workspaceFocusedFlag(second), "an unmarked workspace should omit focused")
        XCTAssertNil(try workspaceFocusedFlag(third), "an unmarked workspace should omit focused")
        XCTAssertEqual(treeWorkspaceFilter(), true, "the filter should be on")

        let added = try sendCommand(#"{"cmd":"workspace.focus","target":"\#(second)","args":{"mode":"add"}}"#)
        XCTAssertEqual(added["ok"] as? Bool, true, "workspace.focus add should succeed: \(added)")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "add should widen the filtered tree to both marked workspaces")
        XCTAssertTrue(sessionRowValueExists(containing: "stay"), "the first marked workspace's session should still render")
        XCTAssertTrue(sessionRowValueExists(containing: "hidden"), "the newly marked workspace's session should render")
        XCTAssertFalse(sessionRowValueExists(containing: "buried"), "the unmarked workspace's session should stay hidden")
        XCTAssertEqual(try workspaceFocusedFlag(first), true, "add must not drop the existing member")
        XCTAssertEqual(try workspaceFocusedFlag(second), true, "the added workspace should read back focused")
        XCTAssertNil(try workspaceFocusedFlag(third), "the unmarked workspace should still omit focused")

        XCTAssertEqual(try sendCommand(#"{"cmd":"workspace.focus","target":"\#(second)","args":{"mode":"add"}}"#)["ok"] as? Bool,
                       true, "re-adding an existing member should succeed")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "a repeat add should leave the set unchanged")
        XCTAssertEqual(try workspaceFocusedFlag(second), true, "a repeat add should keep the membership")

        let removed = try sendCommand(#"{"cmd":"workspace.focus","target":"\#(second)","args":{"mode":"off"}}"#)
        XCTAssertEqual(removed["ok"] as? Bool, true, "workspace.focus off should succeed: \(removed)")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "off should narrow the tree back to the remaining member")
        XCTAssertNil(try workspaceFocusedFlag(second), "the removed workspace should no longer read back focused")
        XCTAssertEqual(try workspaceFocusedFlag(first), true, "the surviving member should keep its mark")
        XCTAssertEqual(treeWorkspaceFilter(), true, "a non-empty set keeps the filter on")
    }

    // `on` with an EMPTY set is refused, so the row-visibility contract's filter term
    // (`!workspaceFilter || focused`) can never report true with nothing focused.
    func testWorkspaceFilterTogglesWithoutLosingTheSet() throws {
        let ids = try seedFocusWorkspaces([(workspace: "second", session: "hidden")])
        let first = ids[0]

        let empty = try sendCommand(#"{"cmd":"workspace.filter","args":{"mode":"on"}}"#)
        XCTAssertEqual(empty["ok"] as? Bool, true, "workspace.filter on should succeed with an empty set: \(empty)")
        XCTAssertEqual(treeWorkspaceFilter(), false, "enabling an empty set must be refused — enabled + empty is unrepresentable")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "an empty set filters nothing")

        XCTAssertEqual(try sendCommand(#"{"cmd":"workspace.focus","target":"\#(first)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "workspace.focus on should succeed")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "marking one workspace should hide the other")
        XCTAssertTrue(pollWorkspaceFilter(true, timeout: 10), "the filter should read on")

        let off = try sendCommand(#"{"cmd":"workspace.filter","args":{"mode":"off"}}"#)
        XCTAssertEqual(off["ok"] as? Bool, true, "workspace.filter off should succeed: \(off)")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "suspending the filter should restore the full tree")
        XCTAssertTrue(pollWorkspaceFilter(false, timeout: 10), "the filter should read off")
        XCTAssertEqual(try workspaceFocusedFlag(first), true,
                       "the mark must survive the filter being off — that is what makes re-enabling one call")

        XCTAssertEqual(try sendCommand(#"{"cmd":"workspace.filter","args":{"mode":"on"}}"#)["ok"] as? Bool, true,
                       "workspace.filter on should succeed")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "re-enabling should apply the preserved set")
        XCTAssertTrue(pollWorkspaceFilter(true, timeout: 10), "the filter should read on again")

        XCTAssertEqual(try sendCommand(#"{"cmd":"workspace.filter","args":{"mode":"toggle"}}"#)["ok"] as? Bool, true,
                       "workspace.filter toggle should succeed")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "toggle should suspend the filter")
        XCTAssertTrue(pollWorkspaceFilter(false, timeout: 10), "toggle should read off")
        XCTAssertEqual(try sendCommand(#"{"cmd":"workspace.filter","args":{"mode":"toggle"}}"#)["ok"] as? Bool, true,
                       "workspace.filter toggle should succeed")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "toggle should re-apply the filter")
        XCTAssertTrue(pollWorkspaceFilter(true, timeout: 10), "toggle should read on")

        // an invalid mode errors rather than silently no-opping.
        let bad = try sendCommand(#"{"cmd":"workspace.filter","args":{"mode":"bogus"}}"#)
        XCTAssertEqual(bad["ok"] as? Bool, false, "an invalid filter mode should error: \(bad)")
        XCTAssertTrue((bad["error"] as? String ?? "").contains("invalid workspace filter mode"),
                      "should report the invalid mode: \(bad)")
        XCTAssertTrue(pollWorkspaceFilter(true, timeout: 10), "a rejected mode must leave the filter unchanged")
    }

    // the difference is invisible in the row count — a collapsed workspace's row shows either way — so
    // both polarities are asserted through the `focused` read-back.
    func testWorkspaceNewJoinsTheMarkedSetUnlessCollapsed() throws {
        let ids = try seedFocusWorkspaces([])
        let first = ids[0]
        XCTAssertEqual(try sendCommand(#"{"cmd":"workspace.focus","target":"\#(first)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "workspace.focus on should succeed")
        XCTAssertTrue(pollWorkspaceFilter(true, timeout: 10), "the filter should be applied")

        let quiet = try sendCommand(#"{"cmd":"workspace.new","args":{"name":"quiet","collapsed":true}}"#)
        let quietID = try XCTUnwrap((quiet["result"] as? [String: Any])?["id"] as? String, "workspace.new returns an id")
        XCTAssertNil(try workspaceFocusedFlag(quietID), "a --collapsed create must stay out of the marked set")
        XCTAssertEqual(try workspaceFocusedFlag(first), true, "the existing member is untouched")

        let loud = try sendCommand(#"{"cmd":"workspace.new","args":{"name":"loud"}}"#)
        let loudID = try XCTUnwrap((loud["result"] as? [String: Any])?["id"] as? String, "workspace.new returns an id")
        XCTAssertEqual(try workspaceFocusedFlag(loudID), true,
                       "a plain create joins the set, so it is visible rather than filtered away")
        XCTAssertTrue(pollWorkspaceFilter(true, timeout: 10), "neither create suspends the filter")
    }

    // the second window is MINIMIZED so the seeded one stays frontmost: an arm ignoring `--window` would
    // land on the frontmost, whose filter is asserted to stay off throughout.
    func testWorkspaceFilterDrivesABackgroundWindow() throws {
        let frontID = try XCTUnwrap(try windowIDs().first, "the seeded window should have an id")
        let created = try sendCommand(#"{"cmd":"window.new","args":{"name":"parked","minimized":true}}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "window.new should succeed: \(created)")
        let backID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "window.new returns an id")
        XCTAssertTrue(pollWindowCount(2, timeout: 10), "the second window should register")

        let backWs = try XCTUnwrap(treeWorkspaces(window: backID).first?["id"] as? String,
                                   "the new window should have a seeded workspace")
        let focused = try sendCommand(#"{"cmd":"workspace.focus","target":"\#(backWs)","args":{"mode":"on","window":"\#(backID)"}}"#)
        XCTAssertEqual(focused["ok"] as? Bool, true, "workspace.focus should succeed on a background window: \(focused)")
        XCTAssertTrue(pollWorkspaceFilter(true, window: backID, timeout: 10),
                      "the background window's filter should be applied")
        XCTAssertEqual(treeWorkspaceFilter(window: frontID), false,
                       "the frontmost window's own filter must be untouched")

        XCTAssertEqual(try sendCommand(#"{"cmd":"workspace.filter","args":{"mode":"off","window":"\#(backID)"}}"#)["ok"] as? Bool,
                       true, "workspace.filter off should succeed on a background window")
        XCTAssertTrue(pollWorkspaceFilter(false, window: backID, timeout: 10), "the background filter should read off")
        XCTAssertEqual(try workspaceFocusedFlag(backWs, window: backID), true, "suspending keeps the marked set")

        XCTAssertEqual(try sendCommand(#"{"cmd":"workspace.filter","args":{"mode":"toggle","window":"\#(backID)"}}"#)["ok"] as? Bool,
                       true, "workspace.filter toggle should succeed on a background window")
        XCTAssertTrue(pollWorkspaceFilter(true, window: backID, timeout: 10), "toggle should re-apply it")
        XCTAssertEqual(treeWorkspaceFilter(window: frontID), false,
                       "no command named the frontmost window, so its filter should still be off")
    }

    /// Every window id from `window.list`, in list order.
    private func windowIDs() throws -> [String] {
        let response = try sendCommand(#"{"cmd":"window.list"}"#)
        let windows = try XCTUnwrap((response["result"] as? [String: Any])?["windows"] as? [[String: Any]],
                                    "window.list should carry windows")
        return windows.compactMap { $0["id"] as? String }
    }

    /// Polls `window.list` until it reports `expected` windows.
    private func pollWindowCount(_ expected: Int, timeout: TimeInterval) -> Bool {
        poll(until: (try? windowIDs().count) == expected, timeout: timeout)
    }

    /// Seeds the fixture the focus-set control tests share: renames the seeded session to `stay`, then adds
    /// one workspace per entry of `extras`, each holding one renamed session. Returns the workspace ids in
    /// tree order (the seeded one first). Every session is created BEFORE any focus command, and the seeded
    /// one is re-selected at the end, so no `session.new` selection sits outside the set a test marks (which
    /// would trip the cross-set auto-disable and silently turn the filter off mid-test).
    private func seedFocusWorkspaces(_ extras: [(workspace: String, session: String)]) throws -> [String] {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 10), "seeded session row")
        let ws = try XCTUnwrap(treeWorkspaces().first, "should have a seeded workspace")
        let firstWsID = try XCTUnwrap(ws["id"] as? String, "should have a seeded workspace id")
        let seededID = try XCTUnwrap((ws["sessions"] as? [[String: Any]])?.first?["id"] as? String, "seeded session id")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(seededID)","args":{"name":"stay"}}"#)["ok"] as? Bool,
                       true, "renaming the seeded session should succeed")

        var ids = [firstWsID]
        for extra in extras {
            let created = try sendCommand(#"{"cmd":"workspace.new","args":{"name":"\#(extra.workspace)"}}"#)
            let wsID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "workspace.new should return an id")
            let session = try sendCommand(#"{"cmd":"session.new","args":{"workspace":"\#(wsID)"}}"#)
            let sessionID = try XCTUnwrap((session["result"] as? [String: Any])?["id"] as? String,
                                          "session.new should return an id")
            let renamed = try sendCommand(#"{"cmd":"session.rename","target":"\#(sessionID)","args":{"name":"\#(extra.session)"}}"#)
            XCTAssertEqual(renamed["ok"] as? Bool, true, "renaming the new session should succeed: \(renamed)")
            ids.append(wsID)
        }
        XCTAssertTrue(pollSessionRowCount(extras.count + 1, timeout: 10), "every seeded session row should be present")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(seededID)"}"#)["ok"] as? Bool, true,
                       "selecting the seeded session should succeed")
        return ids
    }

    /// Whether the workspace with `id` reports `focused` in a window's tree — SET MEMBERSHIP, omitted (nil)
    /// for a non-member and reported independently of the filter flag. The single-read twin of the polling
    /// `workspaceFocused`.
    private func workspaceFocusedFlag(_ id: String, window: String? = nil) throws -> Bool? {
        try treeWorkspaces(window: window)
            .first { ($0["id"] as? String)?.lowercased() == id.lowercased() }?["focused"] as? Bool
    }

    /// A window's top-level `workspaceFilter` — whether its marked set is currently applied. Always
    /// populated on an app-produced tree (like `sidebarVisible`), so nil means the read itself failed.
    private func treeWorkspaceFilter(window: String? = nil) -> Bool? {
        guard let result = (try? sendCommand(treeRequest(window: window)))?["result"] as? [String: Any],
              let root = result["tree"] as? [String: Any] else { return nil }
        return root["workspaceFilter"] as? Bool
    }

    /// Polls a window's `workspaceFilter` until it equals `expected`.
    private func pollWorkspaceFilter(_ expected: Bool, window: String? = nil, timeout: TimeInterval) -> Bool {
        poll(until: treeWorkspaceFilter(window: window) == expected, timeout: timeout)
    }

    // a plain --create-workspace joins the set (addWorkspace's reveal); --no-select threads
    // revealNewWorkspace:false so a background create leaves it alone.
    func testSessionNewNoSelectCreateWorkspacePreservesFocus() throws {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 10), "seeded session row")

        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let workspaces = try XCTUnwrap(((tree["result"] as? [String: Any])?["tree"] as? [String: Any])?["workspaces"] as? [[String: Any]],
                                       "tree should carry workspaces")
        let firstWsID = try XCTUnwrap(workspaces.first?["id"] as? String, "seeded workspace id")

        XCTAssertEqual(try sendCommand(#"{"cmd":"workspace.focus","target":"\#(firstWsID)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "workspace.focus on should succeed")
        XCTAssertTrue(workspaceFocused(firstWsID, timeout: 5), "the seeded workspace should be focused")

        let created = try sendCommand(#"{"cmd":"session.new","args":{"workspaceName":"bg","createWorkspace":true,"noSelect":true}}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "background create-workspace should succeed: \(created)")
        XCTAssertTrue(workspaceFocused(firstWsID, timeout: 5),
                      "--no-select --create-workspace must keep the marked workspace marked")
        XCTAssertEqual(treeWorkspaceFilter(), true, "the filter must still be applied after a background create")
        let background = try XCTUnwrap(treeWorkspaces().first { ($0["name"] as? String) == "bg" },
                                       "the background-created workspace should be in the tree")
        XCTAssertNil(background["focused"],
                     "a background create must NOT widen the set — that reveal is the foreground path's job")
    }

    func testSidebarWidthSetsEchoesAndReadsBackOnTree() throws {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 10), "seeded session row")

        let set = try sendCommand(#"{"cmd":"sidebar.width","args":{"sidebarWidth":312.5}}"#)
        XCTAssertEqual(set["ok"] as? Bool, true, "sidebar.width should succeed: \(set)")
        let setResult = try XCTUnwrap(set["result"] as? [String: Any], "sidebar.width should carry a result")
        XCTAssertEqual(setResult["sidebarWidth"] as? Double, 312.5, "the echo should report the stored width")

        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let result = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let t = try XCTUnwrap(result["tree"] as? [String: Any], "result should carry a tree")
        XCTAssertEqual(t["sidebarWidth"] as? Double, 312.5, "the tree should read back the width the command wrote")

        // an out-of-range request answers ok, so the echo is the only thing that reports the clamp
        let clamped = try sendCommand(#"{"cmd":"sidebar.width","args":{"sidebarWidth":9000}}"#)
        XCTAssertEqual(clamped["ok"] as? Bool, true, "an out-of-range width should still succeed: \(clamped)")
        let clampedResult = try XCTUnwrap(clamped["result"] as? [String: Any], "the clamped call should carry a result")
        XCTAssertEqual(clampedResult["sidebarWidth"] as? Double, 560, "the echo should report the clamped bound")

        let missing = try sendCommand(#"{"cmd":"sidebar.width"}"#)
        XCTAssertEqual(missing["ok"] as? Bool, false, "a width-less sidebar.width should be refused: \(missing)")
    }

    func testSidebarExpandCollapse() throws {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 10), "seeded session row")

        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let result = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let t = try XCTUnwrap(result["tree"] as? [String: Any], "result should carry a tree")
        let ws = try XCTUnwrap((t["workspaces"] as? [[String: Any]])?.first, "should have a workspace")
        let seededID = try XCTUnwrap((ws["sessions"] as? [[String: Any]])?.first?["id"] as? String, "should have a seeded session")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(seededID)","args":{"name":"stay"}}"#)["ok"] as? Bool,
                       true, "renaming the seeded session should succeed")

        let newWs = try sendCommand(#"{"cmd":"workspace.new","args":{"name":"second"}}"#)
        let secondWsID = try XCTUnwrap((newWs["result"] as? [String: Any])?["id"] as? String, "workspace.new should return an id")
        let created = try sendCommand(#"{"cmd":"session.new","args":{"workspace":"\#(secondWsID)"}}"#)
        let newSessID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new should return an id")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(newSessID)","args":{"name":"hidden"}}"#)["ok"] as? Bool,
                       true, "renaming the new session should succeed")

        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "both session rows should be present expanded")

        // the ACTIVE workspace is what stays open, so the selection decides which one folds.
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(seededID)"}"#)["ok"] as? Bool, true,
                       "selecting the seeded session should succeed")
        let collapse = try sendCommand(#"{"cmd":"sidebar.collapse"}"#)
        XCTAssertEqual(collapse["ok"] as? Bool, true, "sidebar.collapse should succeed: \(collapse)")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "collapse should hide the non-active workspace's rows")
        XCTAssertTrue(sessionRowValueExists(containing: "stay"), "the active workspace's session should remain")
        XCTAssertFalse(sessionRowValueExists(containing: "hidden"), "the collapsed workspace's session should be hidden")

        let expand = try sendCommand(#"{"cmd":"sidebar.expand"}"#)
        XCTAssertEqual(expand["ok"] as? Bool, true, "sidebar.expand should succeed: \(expand)")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "expand should restore every workspace's rows")
        XCTAssertTrue(sessionRowValueExists(containing: "hidden"), "the collapsed workspace's session should return")
    }

    func testWorkspaceGoStepsBetweenWorkspacesAndWraps() throws {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 10), "seeded session row")

        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let result = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let t = try XCTUnwrap(result["tree"] as? [String: Any], "result should carry a tree")
        let firstWs = try XCTUnwrap((t["workspaces"] as? [[String: Any]])?.first, "should have a workspace")
        let firstWsID = try XCTUnwrap(firstWs["id"] as? String, "the workspace should carry an id")
        let seededID = try XCTUnwrap((firstWs["sessions"] as? [[String: Any]])?.first?["id"] as? String, "seeded session")

        let newWs = try sendCommand(#"{"cmd":"workspace.new","args":{"name":"second"}}"#)
        let secondWsID = try XCTUnwrap((newWs["result"] as? [String: Any])?["id"] as? String, "workspace.new returns an id")
        let created = try sendCommand(#"{"cmd":"session.new","args":{"workspace":"\#(secondWsID)"}}"#)
        let secondSessID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new returns an id")

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(seededID)"}"#)["ok"] as? Bool, true,
                       "selecting the seeded session should succeed")

        let next = try sendCommand(#"{"cmd":"workspace.go","args":{"to":"next"}}"#)
        XCTAssertEqual(next["ok"] as? Bool, true, "workspace.go next should succeed: \(next)")
        XCTAssertEqual((next["result"] as? [String: Any])?["id"] as? String, secondWsID, "it should land on the second workspace")
        XCTAssertTrue(pollActiveSession(secondSessID, timeout: 10), "landing selects the target's first session")

        // wrapping is what makes a repeated keystroke a cycle rather than a dead end at the last workspace
        let wrapped = try sendCommand(#"{"cmd":"workspace.go","args":{"to":"next"}}"#)
        XCTAssertEqual((wrapped["result"] as? [String: Any])?["id"] as? String, firstWsID, "next at the end wraps to the first")
        XCTAssertTrue(pollActiveSession(seededID, timeout: 10), "the wrap selects the first workspace's first session")

        let back = try sendCommand(#"{"cmd":"workspace.go","args":{"to":"prev"}}"#)
        XCTAssertEqual((back["result"] as? [String: Any])?["id"] as? String, secondWsID, "prev at the start wraps to the last")

        let bad = try sendCommand(#"{"cmd":"workspace.go","args":{"to":"sideways"}}"#)
        XCTAssertEqual(bad["ok"] as? Bool, false, "an unknown direction is rejected")
        XCTAssertEqual(bad["error"] as? String, "workspace.go requires --to next|prev")
    }

    // issue #435: collapsing a workspace must not steer navigation — the fold is a display state, so the
    // step lands on the collapsed workspace exactly as it would on an open one
    func testWorkspaceGoStepsIntoACollapsedWorkspace() throws {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 10), "seeded session row")

        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let result = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let t = try XCTUnwrap(result["tree"] as? [String: Any], "result should carry a tree")
        let firstWs = try XCTUnwrap((t["workspaces"] as? [[String: Any]])?.first, "should have a workspace")
        let seededID = try XCTUnwrap((firstWs["sessions"] as? [[String: Any]])?.first?["id"] as? String, "seeded session")

        let newWs = try sendCommand(#"{"cmd":"workspace.new","args":{"name":"folded"}}"#)
        let foldedWsID = try XCTUnwrap((newWs["result"] as? [String: Any])?["id"] as? String, "workspace.new returns an id")
        let created = try sendCommand(#"{"cmd":"session.new","args":{"workspace":"\#(foldedWsID)"}}"#)
        let foldedSessID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new returns an id")

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(seededID)"}"#)["ok"] as? Bool, true,
                       "selecting the seeded session should succeed")
        XCTAssertEqual(try sendCommand(#"{"cmd":"workspace.collapse","target":"\#(foldedWsID)"}"#)["ok"] as? Bool, true,
                       "collapsing the second workspace should succeed")

        let next = try sendCommand(#"{"cmd":"workspace.go","args":{"to":"next"}}"#)
        XCTAssertEqual((next["result"] as? [String: Any])?["id"] as? String, foldedWsID, "a folded workspace is still stepped into")
        XCTAssertTrue(pollActiveSession(foldedSessID, timeout: 10), "it selects the folded workspace's first session")
    }

    /// Polls `tree` until `sessionID` reports `active`. Selection lands through the store and the outline's
    /// row sync, so an immediate read can race the step.
    private func pollActiveSession(_ sessionID: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let tree = try? sendCommand(#"{"cmd":"tree"}"#),
               let result = tree["result"] as? [String: Any],
               let t = result["tree"] as? [String: Any],
               let workspaces = t["workspaces"] as? [[String: Any]] {
                let sessions = workspaces.flatMap { ($0["sessions"] as? [[String: Any]]) ?? [] }
                if sessions.first(where: { $0["id"] as? String == sessionID })?["active"] as? Bool == true { return true }
            }
            usleep(200_000)
        }
        return false
    }

    /// Whether any `session-row` exposes `needle` in its accessibility value (the row's displayed name —
    /// `session : workspace` in flagged mode). The sidebar surfaces the row name via `value`, not `label`.
    private func sessionRowValueExists(containing needle: String) -> Bool {
        app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND value CONTAINS %@", "session-row", needle))
            .firstMatch.exists
    }

    func testSessionStatusSetsIndicator() throws {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let treeResult = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let root = try XCTUnwrap(treeResult["tree"] as? [String: Any], "result should carry a tree")
        let workspaces = try XCTUnwrap(root["workspaces"] as? [[String: Any]], "tree should list workspaces")
        let sessions = try XCTUnwrap(workspaces.first?["sessions"] as? [[String: Any]], "workspace should list sessions")
        let seeded = try XCTUnwrap(sessions.first?["id"] as? String, "should have a seeded session id")

        let ok = try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"active","blink":true}}"#)
        XCTAssertEqual(ok["ok"] as? Bool, true, "session.status active should succeed: \(ok)")
        let result = try XCTUnwrap(ok["result"] as? [String: Any], "session.status should carry a result")
        XCTAssertEqual((result["id"] as? String)?.lowercased(), seeded.lowercased(),
                       "session.status should return the resolved session id: \(ok)")

        let bad = try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"bogus"}}"#)
        XCTAssertEqual(bad["ok"] as? Bool, false, "an unknown status should fail: \(bad)")
        XCTAssertEqual(bad["error"] as? String, "invalid status", "should report invalid status: \(bad)")

        let unknown = try sendCommand(#"{"cmd":"session.status","target":"deadbeef","args":{"status":"active"}}"#)
        XCTAssertEqual(unknown["ok"] as? Bool, false, "an unknown target should fail: \(unknown)")
        let error = try XCTUnwrap(unknown["error"] as? String, "an unknown target should carry an error")
        XCTAssertTrue(error.hasPrefix("no such session"), "should report no such session, got: \(error)")
    }

    func testSessionStatusSoundValidatesName() throws {
        let seeded = try activeSessionID()

        func currentStatus() throws -> String? { try sessionNode(id: seeded)["status"] as? String }

        let ok = try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"active","sound":"default"}}"#)
        XCTAssertEqual(ok["ok"] as? Bool, true, "session.status --sound default should succeed: \(ok)")

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"completed"}}"#)["ok"] as? Bool, true)
        XCTAssertEqual(try currentStatus(), "completed", "baseline status should be completed")

        let bad = try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"active","sound":"NoSuchSoundXYZ"}}"#)
        XCTAssertEqual(bad["ok"] as? Bool, false, "an unknown sound should fail: \(bad)")
        let error = try XCTUnwrap(bad["error"] as? String, "an unknown sound should carry an error")
        XCTAssertTrue(error.hasPrefix("unknown sound: NoSuchSoundXYZ"), "should report the unknown sound, got: \(error)")

        // validation happens before the mutation, so the status must be unchanged.
        XCTAssertEqual(try currentStatus(), "completed", "an unknown sound must leave the status unchanged")
    }

    // the tint is NOT in the AX tree, so this drives the command path only; the color is verified by eye.
    func testSessionStatusColorValidatesHex() throws {
        let seeded = try activeSessionID()

        func currentStatus() throws -> String? { try sessionNode(id: seeded)["status"] as? String }

        // `"#ff0000"` contains `"#`, which closes a `#"..."#` raw string early — hence the `##"..."##` delimiter.
        let ok = try sendCommand(##"{"cmd":"session.status","target":"\##(seeded)","args":{"status":"blocked","color":"#ff0000"}}"##)
        XCTAssertEqual(ok["ok"] as? Bool, true, "session.status --color #ff0000 should succeed: \(ok)")
        XCTAssertEqual(try currentStatus(), "blocked", "the status should be applied")
        XCTAssertTrue(app.staticTexts["agent-status"].waitForExistence(timeout: 12),
                      "the status glyph should appear on the session's row")

        let bad = try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"active","color":"nope"}}"#)
        XCTAssertEqual(bad["ok"] as? Bool, false, "a malformed color should fail: \(bad)")
        XCTAssertEqual(bad["error"] as? String, "invalid color (expected #rrggbb)", "should report the invalid color: \(bad)")

        // the rejected call must NOT have changed the status — validation happens before the mutation.
        XCTAssertEqual(try currentStatus(), "blocked", "an invalid color must leave the status unchanged")
    }

    // `StatusIconView` exposes only the state NAME to AX, so the drawn shape cannot be asserted here.
    func testSessionStatusShapeValidatesAndReadsBack() throws {
        let seeded = try activeSessionID()

        let ok = try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"blocked","shape":"triangle"}}"#)
        XCTAssertEqual(ok["ok"] as? Bool, true, "session.status --shape triangle should succeed: \(ok)")
        XCTAssertTrue(app.staticTexts["agent-status"].waitForExistence(timeout: 12),
                      "the status glyph should appear on the session's row")
        XCTAssertEqual(app.staticTexts["agent-status"].value as? String, "blocked",
                       "the glyph keeps reporting the state name — the silhouette is not accessibility-observable")

        var node = try sessionNode(id: seeded)
        XCTAssertEqual(node["status"] as? String, "blocked", "the status should be applied")
        XCTAssertEqual(node["statusShape"] as? String, "triangle", "the tree should report the per-call shape")

        let bad = try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"active","shape":"hexagon"}}"#)
        XCTAssertEqual(bad["ok"] as? Bool, false, "an unknown shape should fail: \(bad)")
        XCTAssertEqual(bad["error"] as? String, "invalid shape: hexagon (circle|square|triangle|diamond|capsule|star)",
                       "should report the accepted shapes: \(bad)")
        node = try sessionNode(id: seeded)
        XCTAssertEqual(node["status"] as? String, "blocked", "an invalid shape must leave the status unchanged")
        XCTAssertEqual(node["statusShape"] as? String, "triangle", "an invalid shape must leave the shape unchanged")

        // without --shape the override is discarded and the glyph falls back to the Settings shape.
        let cleared = try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"active"}}"#)
        XCTAssertEqual(cleared["ok"] as? Bool, true, "session.status without --shape should succeed: \(cleared)")
        node = try sessionNode(id: seeded)
        XCTAssertEqual(node["status"] as? String, "active", "the new status should be applied")
        XCTAssertNil(node["statusShape"], "a status set without --shape should clear the shape read-back")
    }

    func testSessionStatusChangedAtRefreshesOnEveryNonIdleSetAndClearsOnIdle() throws {
        let seeded = try activeSessionID()

        let first = try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"active"}}"#)
        XCTAssertEqual(first["ok"] as? Bool, true, "session.status active should succeed: \(first)")
        var node = try sessionNode(id: seeded)
        let stamped = try XCTUnwrap(node["statusChangedAt"] as? Double,
                                    "a non-idle status should stamp the change time: \(node)")

        // the stock hooks re-push `active` on every tool event, so an unchanged status must still move the
        // stamp — that is what makes "now minus statusChangedAt" the agent's liveness rather than its last
        // state change.
        let again = try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"active"}}"#)
        XCTAssertEqual(again["ok"] as? Bool, true, "re-pushing the same status should succeed: \(again)")
        node = try sessionNode(id: seeded)
        let refreshed = try XCTUnwrap(node["statusChangedAt"] as? Double,
                                      "the re-push should keep reporting a stamp: \(node)")
        XCTAssertGreaterThan(refreshed, stamped, "an unchanged status must still refresh the stamp")

        let cleared = try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"idle"}}"#)
        XCTAssertEqual(cleared["ok"] as? Bool, true, "session.status idle should succeed: \(cleared)")
        node = try sessionNode(id: seeded)
        XCTAssertNil(node["status"], "idle should clear the status read-back")
        XCTAssertNil(node["statusChangedAt"], "idle draws no glyph, so it must report no change time")
    }

    // there is no visibility gate: the icon shows on the selected session too.
    func testAgentStatusIconShowsRegardlessOfSelectionAndAutoResetClears() throws {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let treeResult = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let root = try XCTUnwrap(treeResult["tree"] as? [String: Any], "result should carry a tree")
        let workspaces = try XCTUnwrap(root["workspaces"] as? [[String: Any]], "tree should list workspaces")
        let sessions = try XCTUnwrap(workspaces.first?["sessions"] as? [[String: Any]], "workspace should list sessions")
        let seeded = try XCTUnwrap(sessions.first?["id"] as? String, "should have a seeded session id")

        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let createdResult = try XCTUnwrap(created["result"] as? [String: Any], "session.new should carry a result")
        let secondID = try XCTUnwrap(createdResult["id"] as? String, "session.new should return the new id")
        XCTAssertTrue(pollSessionCount(2, timeout: 10), "the new session should land")

        XCTAssertTrue(app.staticTexts["agent-status"].waitForNonExistence(timeout: 5),
                      "no agent-status icon should exist before any status is set")

        let status = try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"active"}}"#)
        XCTAssertEqual(status["ok"] as? Bool, true, "session.status active should succeed: \(status)")
        XCTAssertTrue(app.staticTexts["agent-status"].waitForExistence(timeout: 12),
                      "the status icon should appear on the session's row")

        // `active` is keep-state, so selecting the session does not clear it.
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(seeded)"}"#)["ok"] as? Bool, true)
        XCTAssertTrue(app.staticTexts["agent-status"].waitForExistence(timeout: 5),
                      "the active status icon stays on the selected session (no visibility gate)")

        // an auto-reset flash clears on VISIT, unlike `active`.
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(secondID)"}"#)["ok"] as? Bool, true)
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"completed","autoReset":true}}"#)["ok"] as? Bool, true)
        XCTAssertTrue(app.staticTexts["agent-status"].waitForExistence(timeout: 12),
                      "completed --auto-reset should show on the non-selected session")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(seeded)"}"#)["ok"] as? Bool, true)
        XCTAssertTrue(app.staticTexts["agent-status"].waitForNonExistence(timeout: 12),
                      "visiting a completed --auto-reset session should clear its icon")
    }

    // the keyboard path is wired off GhosttySurfaceView.keyDown, so this MUST be a real keystroke;
    // `session.type` reaches the same clear through injectAsUserInput and is covered in PaneAwareStatusUITests.
    func testTypingClearsBlockedOrCompletedStatus() throws {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let treeResult = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let root = try XCTUnwrap(treeResult["tree"] as? [String: Any], "result should carry a tree")
        let workspaces = try XCTUnwrap(root["workspaces"] as? [[String: Any]], "tree should list workspaces")
        let sessions = try XCTUnwrap(workspaces.first?["sessions"] as? [[String: Any]], "workspace should list sessions")
        let seeded = try XCTUnwrap(sessions.first?["id"] as? String, "should have a seeded session id")

        // keyboard focus return is async, so retry until the glyph clears.
        func typeUntilGlyphCleared() -> Bool {
            for _ in 0..<8 {
                app.typeKey(.escape, modifierFlags: [])
                if app.staticTexts["agent-status"].waitForNonExistence(timeout: 2) { return true }
            }
            return false
        }

        // `active` would NOT clear — the agent is still working.
        for state in ["blocked", "completed"] {
            let set = try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"\#(state)"}}"#)
            XCTAssertEqual(set["ok"] as? Bool, true, "session.status \(state) should succeed: \(set)")
            XCTAssertTrue(app.staticTexts["agent-status"].waitForExistence(timeout: 12),
                          "\(state) should show the agent-status glyph")
            XCTAssertTrue(typeUntilGlyphCleared(), "typing into a \(state) session should clear its glyph")
        }
    }

    // an `active` glyph clears ONLY on an interrupt keystroke. Ctrl-C is an interrupt just like Esc — Claude
    // Code and most TUIs treat it as Esc for dismissing a pending prompt — so it must drop the stale glyph
    // where ordinary typing (host-free tested) does not. covers the app-side `isInterruptKeystroke` wiring
    // the host-free `clearedByKeystroke` cannot reach.
    func testCtrlCClearsActiveStatus() throws {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let treeResult = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let root = try XCTUnwrap(treeResult["tree"] as? [String: Any], "result should carry a tree")
        let workspaces = try XCTUnwrap(root["workspaces"] as? [[String: Any]], "tree should list workspaces")
        let sessions = try XCTUnwrap(workspaces.first?["sessions"] as? [[String: Any]], "workspace should list sessions")
        let seeded = try XCTUnwrap(sessions.first?["id"] as? String, "should have a seeded session id")

        let set = try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"active"}}"#)
        XCTAssertEqual(set["ok"] as? Bool, true, "session.status active should succeed: \(set)")
        XCTAssertTrue(app.staticTexts["agent-status"].waitForExistence(timeout: 12),
                      "active should show the agent-status glyph")

        // Ctrl-C into the focused terminal must clear it. keyboard focus return can be async, so retry.
        for _ in 0..<8 {
            app.typeKey("c", modifierFlags: .control)
            if app.staticTexts["agent-status"].waitForNonExistence(timeout: 2) { return }
        }
        XCTFail("Ctrl-C into an active session should clear its glyph")
    }

    // the General → "Show notification badges" toggle gates the red count pill's RENDERING (the count
    // keeps tracking either way): fire a notification on a non-selected session so notify-badge shows,
    // toggle the setting off → the badge hides, toggle on → it reappears with the same count.
    func testNotificationBadgeToggleHidesAndShowsBadge() throws {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let treeResult = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let root = try XCTUnwrap(treeResult["tree"] as? [String: Any], "result should carry a tree")
        let workspaces = try XCTUnwrap(root["workspaces"] as? [[String: Any]], "tree should list workspaces")
        let sessions = try XCTUnwrap(workspaces.first?["sessions"] as? [[String: Any]], "workspace should list sessions")
        let seeded = try XCTUnwrap(sessions.first?["id"] as? String, "should have a seeded session id")

        // a second session takes focus, leaving the seeded one non-selected so its badge persists.
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.new"}"#)["ok"] as? Bool, true)
        XCTAssertTrue(pollSessionCount(2, timeout: 10), "the new session should land")

        // notify (no focus-suppression) bumps the non-selected session's unseen count → the badge shows.
        let notified = try sendCommand(#"{"cmd":"notify","target":"\#(seeded)","args":{"body":"hi"}}"#)
        XCTAssertEqual(notified["ok"] as? Bool, true, "notify should succeed: \(notified)")
        XCTAssertTrue(app.staticTexts["notify-badge"].waitForExistence(timeout: 12),
                      "the count badge should appear on the non-selected session's row")

        // turn the count badges off → the pill hides (render-only; the count keeps tracking).
        toggleNotificationBadges()
        XCTAssertTrue(app.staticTexts["notify-badge"].waitForNonExistence(timeout: 12),
                      "hiding the badge setting should hide the count pill")

        // turn it back on → the pill reappears with the still-tracked count.
        toggleNotificationBadges()
        XCTAssertTrue(app.staticTexts["notify-badge"].waitForExistence(timeout: 12),
                      "re-enabling the badge setting should show the count pill again")
    }

    // session.seen clears a session's unseen badge WITHOUT changing the selection/focus — the focus-free
    // counterpart to notify. Fire notify on a non-selected session so the badge + tree `unseen` read-back
    // show, then session.seen clears both while the selection stays on the other session.
    func testSessionSeenClearsBadgeWithoutFocus() throws {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let treeResult = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let root = try XCTUnwrap(treeResult["tree"] as? [String: Any], "result should carry a tree")
        let workspaces = try XCTUnwrap(root["workspaces"] as? [[String: Any]], "tree should list workspaces")
        let sessions = try XCTUnwrap(workspaces.first?["sessions"] as? [[String: Any]], "workspace should list sessions")
        let seeded = try XCTUnwrap(sessions.first?["id"] as? String, "should have a seeded session id")

        // a second session takes focus, leaving the seeded one non-selected so its badge persists.
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        XCTAssertEqual(created["ok"] as? Bool, true)
        let newSession = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new returns the new id")
        XCTAssertTrue(pollSessionCount(2, timeout: 10), "the new session should land")

        // notify (no focus-suppression) bumps the non-selected session's unseen count → the badge shows.
        let notified = try sendCommand(#"{"cmd":"notify","target":"\#(seeded)","args":{"body":"hi"}}"#)
        XCTAssertEqual(notified["ok"] as? Bool, true, "notify should succeed: \(notified)")
        XCTAssertTrue(app.staticTexts["notify-badge"].waitForExistence(timeout: 12),
                      "the count badge should appear on the non-selected session's row")

        // the tree read-back surfaces the unseen count and the new session is the active one.
        XCTAssertEqual(unseenCount(forSession: seeded), 1, "tree should report the seeded session's unseen count")
        XCTAssertEqual(activeNodeID(), newSession, "the new session should be the active selection")

        // session.seen clears the badge; it targets the NON-selected session and returns its id.
        let seen = try sendCommand(#"{"cmd":"session.seen","target":"\#(seeded)"}"#)
        XCTAssertEqual(seen["ok"] as? Bool, true, "session.seen should succeed: \(seen)")
        XCTAssertEqual((seen["result"] as? [String: Any])?["id"] as? String, seeded, "session.seen echoes the target id")
        XCTAssertTrue(app.staticTexts["notify-badge"].waitForNonExistence(timeout: 12),
                      "session.seen should clear the count pill")

        // the clear is focus-free: the selection is unchanged and the tree no longer reports unseen.
        XCTAssertEqual(activeNodeID(), newSession, "session.seen must NOT change the active selection")
        XCTAssertNil(unseenCount(forSession: seeded), "the seeded session's unseen count should be cleared (omitted)")

        // idempotent: a second seen on an already-clear session is ok AND a genuine no-op (end-state holds).
        let again = try sendCommand(#"{"cmd":"session.seen","target":"\#(seeded)"}"#)
        XCTAssertEqual(again["ok"] as? Bool, true, "session.seen is idempotent when the badge is already zero")
        XCTAssertNil(unseenCount(forSession: seeded), "a repeat seen keeps the badge cleared")
        XCTAssertEqual(activeNodeID(), newSession, "a repeat seen must not change the active selection")

        // an unknown target errors through the shared resolver, like the other session.* commands.
        let bad = try sendCommand(#"{"cmd":"session.seen","target":"deadbeef"}"#)
        XCTAssertEqual(bad["ok"] as? Bool, false, "session.seen with an unknown target should fail")
        XCTAssertTrue((bad["error"] as? String ?? "").hasPrefix("no such session"),
                      "should report no such session, got: \(bad)")
    }

    // returning agterm to the foreground on a session that's on screen clears that session's badge — the
    // same "you've seen it" clear a focus transition does. Reproduced across two windows because re-keying
    // a window fires the SAME NSWindow.didBecomeKey path as app reactivation, without the flaky
    // background-the-app dance: open a second window so the seeded session's window loses key, notify the
    // seeded session so its badge shows, then re-select its window. window.select does NOT re-select the
    // session, so only the didBecomeKey → onFocusChange clear can drop the badge — a genuine regression
    // for #155 (the badge used to stay stuck until you switched sessions and back).
    func testRefocusingWindowClearsOnScreenSessionBadge() throws {
        let seeded = try activeSessionID()

        // capture the seeded window's id before opening a second one — window.select needs it to re-key
        // the ORIGINAL window (--target defaults to the active window, which becomes the new one).
        let windows = try XCTUnwrap(
            (try sendCommand(#"{"cmd":"window.list"}"#)["result"] as? [String: Any])?["windows"] as? [[String: Any]],
            "window.list should carry windows")
        let firstWindow = try XCTUnwrap(windows.first?["id"] as? String, "should have the seeded window id")

        // a second window materializes and takes key, so the seeded session's window is no longer key (its
        // focused pane keeps first responder per-window, but the window isn't key — the bug's precondition).
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.new"}"#)["ok"] as? Bool, true)
        let appeared = Date().addingTimeInterval(10)
        while Date() < appeared, app.windows.count < 2 { usleep(200_000) }
        XCTAssertGreaterThanOrEqual(app.windows.count, 2, "the second window should materialize and take key")

        // notify (no focus-suppression) bumps the seeded session's badge while its window is unkeyed.
        let notified = try sendCommand(#"{"cmd":"notify","target":"\#(seeded)","args":{"body":"hi"}}"#)
        XCTAssertEqual(notified["ok"] as? Bool, true, "notify should succeed: \(notified)")
        XCTAssertTrue(app.staticTexts["notify-badge"].waitForExistence(timeout: 12),
                      "the badge should appear on the seeded session's row")

        // re-key the seeded session's window (the cmd-tab / reactivating-click equivalent). No session
        // switch happens, so a passing clear here can only come from the didBecomeKey → onFocusChange path.
        // window.select can return before the window is actually key under XCUITest, so wait for it to report
        // active before asserting the didBecomeKey-driven clear.
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.select","target":"\#(firstWindow)"}"#)["ok"] as? Bool, true)
        XCTAssertTrue(pollWindowActive(firstWindow, timeout: 12), "window 1 should become key again after window.select")
        XCTAssertTrue(app.staticTexts["notify-badge"].waitForNonExistence(timeout: 12),
                      "refocusing the window should clear the on-screen session's badge without a session switch")
    }

    // the refocus clear is gated on liveFocus, so it clears ONLY the focused pane's session — never other
    // badged sessions in the same window. This is the inverse of testRefocusingWindowClearsOnScreenSessionBadge:
    // a regression that dropped the liveFocus guard (clearing every session's badge on didBecomeKey) would
    // still pass the positive test but fail this one. The seeded session holds focus while a SECOND session
    // carries the badge; refocus lands on the seeded (focused) session, so the second session's pill must
    // survive. The badged session is deliberately the non-focused one so its badge is tree-verifiable both
    // before and after the refocus (a focused session in a key window can't hold an unseen badge).
    func testRefocusingWindowKeepsNonFocusedSessionBadge() throws {
        let seeded = try activeSessionID()
        let firstWindow = try XCTUnwrap(
            ((try sendCommand(#"{"cmd":"window.list"}"#)["result"] as? [String: Any])?["windows"] as? [[String: Any]])?
                .first?["id"] as? String, "should have the seeded window id")

        // add a second session, then re-select the seeded one so IT holds focus and the second is the
        // non-focused session whose badge the refocus must leave alone.
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let other = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new returns the new id")
        XCTAssertTrue(pollSessionCount(2, timeout: 10), "the second session should land")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(seeded)"}"#)["ok"] as? Bool, true)

        // badge the NON-focused second session and confirm the badge landed — an unfocused session isn't
        // "seen", so its badge persists and is readable via the frontmost tree while window 1 is frontmost.
        XCTAssertEqual(try sendCommand(#"{"cmd":"notify","target":"\#(other)","args":{"body":"hi"}}"#)["ok"] as? Bool, true)
        XCTAssertTrue(pollUnseen(other, equals: 1, timeout: 12), "the non-focused session should carry a badge before the refocus")

        // a second window materializes and takes key, so window 1 is no longer key.
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.new"}"#)["ok"] as? Bool, true)
        let appeared = Date().addingTimeInterval(10)
        while Date() < appeared, app.windows.count < 2 { usleep(200_000) }
        XCTAssertGreaterThanOrEqual(app.windows.count, 2, "the second window should materialize and take key")

        // re-key window 1 (the cmd-tab refocus). Focus lands on the SEEDED session, never the badged one, so
        // the non-focused session's pill must survive. Wait for the window to actually become key first.
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.select","target":"\#(firstWindow)"}"#)["ok"] as? Bool, true)
        XCTAssertTrue(pollWindowActive(firstWindow, timeout: 12), "window 1 should become key again after window.select")
        XCTAssertEqual(unseenCount(forSession: other), 1, "a non-focused session's badge must survive the refocus")
    }

    // polls window.list until the window with `id` reports active (frontmost/key), or times out. Under
    // XCUITest a window.select response can arrive before the window is actually key, so tests wait on this
    // before asserting a didBecomeKey-driven effect. Returns true on match, false on timeout.
    private func pollWindowActive(_ id: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let result = (try? sendCommand(#"{"cmd":"window.list"}"#))?["result"] as? [String: Any],
               let windows = result["windows"] as? [[String: Any]],
               windows.contains(where: { ($0["id"] as? String)?.lowercased() == id.lowercased() && $0["active"] as? Bool == true }) {
                return true
            }
            usleep(200_000)
        }
        return false
    }

    // polls the frontmost window's tree until the given session's unseen count equals `expected` (nil = the
    // badge is cleared / omitted), returning true on match or false on timeout.
    private func pollUnseen(_ id: String, equals expected: Int?, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if unseenCount(forSession: id) == expected { return true }
            usleep(200_000)
        }
        return unseenCount(forSession: id) == expected
    }

    // the unseen badge count reported for a session in the current tree, or nil when omitted (zero).
    private func unseenCount(forSession id: String) -> Int? {
        guard let result = (try? sendCommand(#"{"cmd":"tree"}"#))?["result"] as? [String: Any],
              let root = result["tree"] as? [String: Any],
              let workspaces = root["workspaces"] as? [[String: Any]] else { return nil }
        for workspace in workspaces {
            for session in (workspace["sessions"] as? [[String: Any]] ?? []) where session["id"] as? String == id {
                return session["unseen"] as? Int
            }
        }
        return nil
    }

    // the id of the active (selected) session in the current tree, or nil when none is selected.
    // (distinct from ControlAPITestCase.activeSessionID(), which returns the first session unconditionally.)
    private func activeNodeID() -> String? {
        guard let result = (try? sendCommand(#"{"cmd":"tree"}"#))?["result"] as? [String: Any],
              let root = result["tree"] as? [String: Any],
              let workspaces = root["workspaces"] as? [[String: Any]] else { return nil }
        for workspace in workspaces {
            for session in (workspace["sessions"] as? [[String: Any]] ?? []) where session["active"] as? Bool == true {
                return session["id"] as? String
            }
        }
        return nil
    }

    // whether the workspace with `id` reports focused:true in the current tree (omitted/nil = not focused).
    private func workspaceFocused(_ id: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let result = (try? sendCommand(#"{"cmd":"tree"}"#))?["result"] as? [String: Any],
               let root = result["tree"] as? [String: Any],
               let workspaces = root["workspaces"] as? [[String: Any]],
               let ws = workspaces.first(where: { ($0["id"] as? String)?.lowercased() == id.lowercased() }),
               ws["focused"] as? Bool == true { return true }
            usleep(200_000)
        } while Date() < deadline
        return false
    }

    // notify posts a banner for the active session; a missing body errors.
    func testNotifySend() throws {
        let ok = try sendCommand(#"{"cmd":"notify","target":"active","args":{"body":"hello","title":"Test"}}"#)
        XCTAssertEqual(ok["ok"] as? Bool, true, "notify with a body should succeed: \(ok)")

        let noBody = try sendCommand(#"{"cmd":"notify","target":"active"}"#)
        XCTAssertEqual(noBody["ok"] as? Bool, false, "notify without a body should fail: \(noBody)")
        XCTAssertTrue((noBody["error"] as? String ?? "").contains("requires a body"), "should report missing body: \(noBody)")
    }

    /// Opens Settings (Cmd+,), switches to General, and clicks the "Show notification badges" toggle.
    /// Retries the tab/toggle click each tick (a stale or half-open Settings window can drop the first
    /// click), mirroring SettingsUITests' robust `settingsControl`.
    private func toggleNotificationBadges() {
        let toggle = app.descendants(matching: .any).matching(identifier: "settings-notification-badges").firstMatch
        let tabButton = app.buttons["Notifications"].firstMatch
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if toggle.exists, toggle.isHittable { toggle.click(); return }
            if tabButton.exists, tabButton.isHittable {
                tabButton.click()
            } else {
                app.typeKey(",", modifierFlags: .command) // settings not open yet (or lost) — (re)open
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTFail("the notification-badges toggle never became hittable")
    }

    func testWorkspaceCollapseAndExpand() throws {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 10), "seeded session row")

        // name the seeded session, then add a second workspace with its own named session.
        let seededID = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(seededID)","args":{"name":"stay"}}"#)["ok"] as? Bool,
                       true, "renaming the seeded session should succeed")
        let newWs = try sendCommand(#"{"cmd":"workspace.new","args":{"name":"second"}}"#)
        let secondWsID = try XCTUnwrap((newWs["result"] as? [String: Any])?["id"] as? String, "workspace.new should return an id")
        let created = try sendCommand(#"{"cmd":"session.new","args":{"workspace":"\#(secondWsID)"}}"#)
        let newSessID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new should return an id")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(newSessID)","args":{"name":"hidden"}}"#)["ok"] as? Bool,
                       true, "renaming the new session should succeed")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "both session rows should be present expanded")

        // collapse ONLY the second workspace: its "hidden" row leaves the AX tree, "stay" stays — unlike
        // sidebar.collapse, this targets one workspace and does not depend on which one is active.
        let collapse = try sendCommand(#"{"cmd":"workspace.collapse","target":"\#(secondWsID)"}"#)
        XCTAssertEqual(collapse["ok"] as? Bool, true, "workspace.collapse should succeed: \(collapse)")
        XCTAssertEqual((collapse["result"] as? [String: Any])?["id"] as? String, secondWsID, "should echo the workspace id")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "collapse should hide the targeted workspace's rows")
        XCTAssertTrue(sessionRowValueExists(containing: "stay"), "the untouched workspace's session should remain")
        XCTAssertFalse(sessionRowValueExists(containing: "hidden"), "the collapsed workspace's session should be hidden")

        // read-back: the collapsed workspace reports collapsed == true, the other omits the field.
        let collapsedTree = try treeWorkspaces()
        XCTAssertEqual(collapsedTree.first { $0["id"] as? String == secondWsID }?["collapsed"] as? Bool, true,
                       "the collapsed workspace should read back collapsed == true")
        XCTAssertNil(collapsedTree.first { $0["id"] as? String != secondWsID }?["collapsed"],
                     "an expanded workspace should omit the collapsed field")

        // expand it again: the "hidden" row returns and the field is omitted.
        let expand = try sendCommand(#"{"cmd":"workspace.expand","target":"\#(secondWsID)"}"#)
        XCTAssertEqual(expand["ok"] as? Bool, true, "workspace.expand should succeed: \(expand)")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "expand should restore the workspace's rows")
        XCTAssertTrue(sessionRowValueExists(containing: "hidden"), "the expanded workspace's session should return")
        let expandedTree = try treeWorkspaces()
        XCTAssertNil(expandedTree.first { $0["id"] as? String == secondWsID }?["collapsed"],
                     "the re-expanded workspace should omit the collapsed field")
    }

    func testWorkspaceNewCollapsedStaysClosedWhenFilled() throws {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 10), "seeded session row")
        let seededID = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(seededID)","args":{"name":"stay"}}"#)["ok"] as? Bool,
                       true, "renaming the seeded session should succeed")

        // create a COLLAPSED workspace, then fill it with a background (--no-select) session: it must NOT open.
        let newWs = try sendCommand(#"{"cmd":"workspace.new","args":{"name":"quiet","collapsed":true}}"#)
        let quietID = try XCTUnwrap((newWs["result"] as? [String: Any])?["id"] as? String, "workspace.new should return an id")
        XCTAssertEqual(try treeWorkspaces().first { $0["id"] as? String == quietID }?["collapsed"] as? Bool, true,
                       "a --collapsed workspace should read back collapsed == true")
        let created = try sendCommand(#"{"cmd":"session.new","args":{"workspace":"\#(quietID)","noSelect":true}}"#)
        let buriedID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new should return an id")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(buriedID)","args":{"name":"buried"}}"#)["ok"] as? Bool,
                       true, "renaming the buried session should succeed")

        // the buried session stays hidden inside the collapsed workspace; the selection never left "stay".
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "the collapsed workspace's session should stay hidden")
        XCTAssertFalse(sessionRowValueExists(containing: "buried"), "the buried session should not be visible")
        XCTAssertEqual(try activeSessionID(), seededID, "the background add must not move the selection")

        // expanding the workspace reveals the buried session.
        XCTAssertEqual(try sendCommand(#"{"cmd":"workspace.expand","target":"\#(quietID)"}"#)["ok"] as? Bool, true,
                       "workspace.expand should succeed")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "expanding should reveal the buried session")
        XCTAssertTrue(sessionRowValueExists(containing: "buried"), "the buried session should now be visible")
    }

    func testWorkspaceCollapsePersistsWithSidebarHidden() throws {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 10), "seeded session row")
        // add a second workspace to target.
        let newWs = try sendCommand(#"{"cmd":"workspace.new","args":{"name":"target"}}"#)
        let wsID = try XCTUnwrap((newWs["result"] as? [String: Any])?["id"] as? String, "workspace.new should return an id")

        // HIDE the sidebar: WindowContentView mounts WorkspaceSidebar only while sidebarVisible, so hiding
        // tears down its Coordinator and the .agtermSetWorkspaceExpanded observer. A notification-only
        // persist would silently drop here — the store write must happen in the control arm regardless.
        XCTAssertEqual(try sendCommand(#"{"cmd":"sidebar","args":{"mode":"hide"}}"#)["ok"] as? Bool, true,
                       "sidebar hide should succeed")
        XCTAssertTrue(pollTreeSidebarHidden(timeout: 10), "the sidebar should report hidden")

        // collapse the target with the sidebar hidden: the read-back must reflect it IMMEDIATELY.
        let collapse = try sendCommand(#"{"cmd":"workspace.collapse","target":"\#(wsID)"}"#)
        XCTAssertEqual(collapse["ok"] as? Bool, true, "workspace.collapse should succeed: \(collapse)")
        XCTAssertEqual(try treeWorkspaces().first { $0["id"] as? String == wsID }?["collapsed"] as? Bool, true,
                       "collapse must persist with the sidebar hidden — collapsed reads back true immediately")

        // expand it again while still hidden: the field clears.
        XCTAssertEqual(try sendCommand(#"{"cmd":"workspace.expand","target":"\#(wsID)"}"#)["ok"] as? Bool, true,
                       "workspace.expand should succeed")
        XCTAssertNil(try treeWorkspaces().first { $0["id"] as? String == wsID }?["collapsed"],
                     "expand must persist with the sidebar hidden — collapsed omitted")
    }

    /// The workspace nodes of a window's tree — the frontmost window's by default, or the window named by
    /// `window` (the selector every focus/filter command also honors, so the read-back can follow a command
    /// into a background window).
    private func treeWorkspaces(window: String? = nil) throws -> [[String: Any]] {
        let tree = try sendCommand(treeRequest(window: window))
        let result = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let t = try XCTUnwrap(result["tree"] as? [String: Any], "result should carry a tree")
        return try XCTUnwrap(t["workspaces"] as? [[String: Any]], "tree should carry workspaces")
    }

    /// A `tree` request line, optionally scoped to one window.
    private func treeRequest(window: String?) -> String {
        guard let window else { return #"{"cmd":"tree"}"# }
        return #"{"cmd":"tree","args":{"window":"\#(window)"}}"#
    }

    /// Polls until the tree's top-level `sidebarVisible` reads false (draining the run loop so SwiftUI can
    /// tear the sidebar down), proving the Coordinator observer is gone before the collapse.
    private func pollTreeSidebarHidden(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let tree = try? sendCommand(#"{"cmd":"tree"}"#),
               let result = tree["result"] as? [String: Any],
               let t = result["tree"] as? [String: Any],
               (t["sidebarVisible"] as? Bool) == false {
                return true
            }
            usleep(200_000)
        }
        return false
    }
}
