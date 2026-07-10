import Foundation
import XCTest

/// Control-channel e2e for the sidebar visibility/mode/expand-collapse, workspace focus, session
/// flag, agent-status glyph, and notification-badge behaviors. Subclass of `ControlAPITestCase`.
@MainActor
final class ControlSidebarStatusUITests: ControlAPITestCase {
    // an OSC 9 desktop notification from an UNFOCUSED pane badges its sidebar row, and selecting the
    // session clears it. Fire into the seeded session (realized at launch) after a new session takes
    // focus, so suppression doesn't drop it and no --select (which would re-focus it) is needed.
    func testUnfocusedNotificationBadgesRowAndClearsOnSelect() throws {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let treeResult = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let root = try XCTUnwrap(treeResult["tree"] as? [String: Any], "result should carry a tree")
        let workspaces = try XCTUnwrap(root["workspaces"] as? [[String: Any]], "tree should list workspaces")
        let sessions = try XCTUnwrap(workspaces.first?["sessions"] as? [[String: Any]], "workspace should list sessions")
        let seeded = try XCTUnwrap(sessions.first?["id"] as? String, "should have a seeded session id")

        // a second session takes focus, leaving the seeded one realized but unfocused.
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.new"}"#)["ok"] as? Bool, true)
        XCTAssertTrue(pollSessionCount(2, timeout: 10), "the new session should land")

        // emit OSC 9 from the unfocused seeded session (printf interprets the octal escapes).
        let typed = try sendCommand(typeRequest(text: "printf '\\033]9;agterm test\\007'\n", target: seeded, select: false))
        XCTAssertEqual(typed["ok"] as? Bool, true, "typing into the realized seeded session should succeed: \(typed)")

        XCTAssertTrue(app.staticTexts["notify-badge"].waitForExistence(timeout: 12),
                      "an unseen badge should appear on the unfocused session's row")

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(seeded)"}"#)["ok"] as? Bool, true)
        XCTAssertTrue(app.staticTexts["notify-badge"].waitForNonExistence(timeout: 12),
                      "selecting the session should clear its badge")
    }

    // the `sidebar` control command shows/hides the custom sidebar (the custom split has no system
    // toggle). hiding removes the session rows from the AX tree; showing restores them. mode is
    // show|hide|toggle on the frontmost window, and an unknown mode is an error.
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

    // session.flag flags a session for the flagged working-set view; sidebar.mode flagged switches the
    // sidebar to the flat list of just the flagged sessions (each labeled "session : workspace"), so an
    // unflagged session's row is absent in flagged mode and returns when switched back to tree.
    func testSessionFlagAndSidebarModeFlagged() throws {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 10), "seeded session row")

        // name the seeded session and add a second one, so the two are distinguishable by name.
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

        // both rows present in tree mode.
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "both session rows should be present in tree mode")

        // flag the seeded session.
        let flag = try sendCommand(#"{"cmd":"session.flag","target":"\#(seededID)","args":{"mode":"on"}}"#)
        XCTAssertEqual(flag["ok"] as? Bool, true, "session.flag on should succeed: \(flag)")

        // switch to the flat flagged view: exactly one row, the flagged "flagme", labeled with its
        // workspace; the unflagged "keepme" row is absent.
        let mode = try sendCommand(#"{"cmd":"sidebar.mode","args":{"mode":"flagged"}}"#)
        XCTAssertEqual(mode["ok"] as? Bool, true, "sidebar.mode flagged should succeed: \(mode)")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "flagged mode should show only the one flagged row")
        XCTAssertTrue(sessionRowValueExists(containing: "flagme"), "the flagged session's row should be present")
        XCTAssertFalse(sessionRowValueExists(containing: "keepme"), "the unflagged session's row should be absent")

        // toggling back to the tree restores both rows.
        XCTAssertEqual(try sendCommand(#"{"cmd":"sidebar.mode","args":{"mode":"toggle"}}"#)["ok"] as? Bool, true,
                       "sidebar.mode toggle should succeed")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "toggling back to tree restores the full tree")

        // session.flag clear unflags everything: flag BOTH, view the flat list (two rows), then clear → the
        // flagged view empties (zero rows).
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.flag","target":"\#(newID)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "flagging the second session should succeed")
        XCTAssertEqual(try sendCommand(#"{"cmd":"sidebar.mode","args":{"mode":"flagged"}}"#)["ok"] as? Bool, true,
                       "switching to flagged should succeed")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "both flagged rows should be present")
        let cleared = try sendCommand(#"{"cmd":"session.flag","args":{"mode":"clear"}}"#)
        XCTAssertEqual(cleared["ok"] as? Bool, true, "session.flag clear should succeed: \(cleared)")
        XCTAssertTrue(pollSessionRowCount(0, timeout: 10), "clearing all flags empties the flagged view")
        // back to the tree so the invalid-mode check below runs against the full tree.
        XCTAssertEqual(try sendCommand(#"{"cmd":"sidebar.mode","args":{"mode":"tree"}}"#)["ok"] as? Bool, true,
                       "switching back to tree should succeed")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "the sessions themselves are not closed by clear")

        // an invalid mode errors rather than silently no-opping.
        let bad = try sendCommand(#"{"cmd":"sidebar.mode","args":{"mode":"bogus"}}"#)
        XCTAssertEqual(bad["ok"] as? Bool, false, "an invalid sidebar mode should error: \(bad)")
        XCTAssertTrue((bad["error"] as? String ?? "").contains("invalid sidebar mode"), "should report invalid mode: \(bad)")
    }

    // workspace.focus collapses the sidebar tree to a single workspace's subtree — the other workspaces'
    // session rows leave the AX tree; unfocusing restores them. Orthogonal to the flagged view.
    func testWorkspaceFocusHidesOtherWorkspaces() throws {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 10), "seeded session row")

        // capture the seeded workspace + session, name the session so it's findable by value.
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let result = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let t = try XCTUnwrap(result["tree"] as? [String: Any], "result should carry a tree")
        let ws = try XCTUnwrap((t["workspaces"] as? [[String: Any]])?.first, "should have a workspace")
        let firstWsID = try XCTUnwrap(ws["id"] as? String, "should have a seeded workspace id")
        let seededID = try XCTUnwrap((ws["sessions"] as? [[String: Any]])?.first?["id"] as? String, "should have a seeded session")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(seededID)","args":{"name":"stay"}}"#)["ok"] as? Bool,
                       true, "renaming the seeded session should succeed")

        // add a second workspace with its own session.
        let newWs = try sendCommand(#"{"cmd":"workspace.new","args":{"name":"second"}}"#)
        let secondWsID = try XCTUnwrap((newWs["result"] as? [String: Any])?["id"] as? String, "workspace.new should return an id")
        let created = try sendCommand(#"{"cmd":"session.new","args":{"workspace":"\#(secondWsID)"}}"#)
        let newSessID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new should return an id")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(newSessID)","args":{"name":"hidden"}}"#)["ok"] as? Bool,
                       true, "renaming the new session should succeed")

        // both rows present in the unfocused tree.
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "both session rows should be present unfocused")

        // select the first workspace's session (so the active session is inside the workspace we focus),
        // then focus the FIRST workspace: the second workspace's session row disappears.
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(seededID)"}"#)["ok"] as? Bool, true,
                       "selecting the seeded session should succeed")
        let focus = try sendCommand(#"{"cmd":"workspace.focus","target":"\#(firstWsID)","args":{"mode":"on"}}"#)
        XCTAssertEqual(focus["ok"] as? Bool, true, "workspace.focus on should succeed: \(focus)")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "focusing one workspace should hide the other's rows")
        XCTAssertTrue(sessionRowValueExists(containing: "stay"), "the focused workspace's session should remain")
        XCTAssertFalse(sessionRowValueExists(containing: "hidden"), "the other workspace's session should be hidden")

        // workspace.focus off on a NON-focused workspace is a no-op — it unfocuses only the currently
        // focused one, so the focus on the first workspace must survive (the other's rows stay hidden).
        XCTAssertEqual(try sendCommand(#"{"cmd":"workspace.focus","target":"\#(secondWsID)","args":{"mode":"off"}}"#)["ok"] as? Bool,
                       true, "workspace.focus off on a non-focused workspace should succeed (no-op)")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "the focus on the first workspace should be unchanged")
        XCTAssertTrue(sessionRowValueExists(containing: "stay"), "the focused workspace's session should still remain")
        XCTAssertFalse(sessionRowValueExists(containing: "hidden"), "the other workspace's session should still be hidden")

        // unfocus restores the full tree.
        XCTAssertEqual(try sendCommand(#"{"cmd":"workspace.focus","target":"\#(firstWsID)","args":{"mode":"off"}}"#)["ok"] as? Bool,
                       true, "workspace.focus off should succeed")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "unfocusing should restore the full tree")

        // an invalid mode errors rather than silently no-opping.
        let bad = try sendCommand(#"{"cmd":"workspace.focus","target":"\#(firstWsID)","args":{"mode":"bogus"}}"#)
        XCTAssertEqual(bad["ok"] as? Bool, false, "an invalid focus mode should error: \(bad)")
        XCTAssertTrue((bad["error"] as? String ?? "").contains("invalid focus mode"), "should report invalid mode: \(bad)")
    }

    // sidebar.collapse collapses every workspace except the active session's — the others' session rows
    // leave the AX tree while the active workspace's stay; sidebar.expand re-expands every workspace and
    // restores them.
    func testSidebarExpandCollapse() throws {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 10), "seeded session row")

        // capture the seeded workspace + session, name the session so it's findable by value.
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let result = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let t = try XCTUnwrap(result["tree"] as? [String: Any], "result should carry a tree")
        let ws = try XCTUnwrap((t["workspaces"] as? [[String: Any]])?.first, "should have a workspace")
        let seededID = try XCTUnwrap((ws["sessions"] as? [[String: Any]])?.first?["id"] as? String, "should have a seeded session")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(seededID)","args":{"name":"stay"}}"#)["ok"] as? Bool,
                       true, "renaming the seeded session should succeed")

        // add a second workspace with its own session in a different workspace.
        let newWs = try sendCommand(#"{"cmd":"workspace.new","args":{"name":"second"}}"#)
        let secondWsID = try XCTUnwrap((newWs["result"] as? [String: Any])?["id"] as? String, "workspace.new should return an id")
        let created = try sendCommand(#"{"cmd":"session.new","args":{"workspace":"\#(secondWsID)"}}"#)
        let newSessID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new should return an id")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(newSessID)","args":{"name":"hidden"}}"#)["ok"] as? Bool,
                       true, "renaming the new session should succeed")

        // both rows present with both workspaces expanded (the sidebar expands all on launch).
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "both session rows should be present expanded")

        // select the seeded session so the ACTIVE workspace is the first one, then collapse: the second
        // workspace folds away (its "hidden" row leaves the AX tree) while the active workspace stays open.
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(seededID)"}"#)["ok"] as? Bool, true,
                       "selecting the seeded session should succeed")
        let collapse = try sendCommand(#"{"cmd":"sidebar.collapse"}"#)
        XCTAssertEqual(collapse["ok"] as? Bool, true, "sidebar.collapse should succeed: \(collapse)")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "collapse should hide the non-active workspace's rows")
        XCTAssertTrue(sessionRowValueExists(containing: "stay"), "the active workspace's session should remain")
        XCTAssertFalse(sessionRowValueExists(containing: "hidden"), "the collapsed workspace's session should be hidden")

        // expand re-opens every workspace and restores both rows.
        let expand = try sendCommand(#"{"cmd":"sidebar.expand"}"#)
        XCTAssertEqual(expand["ok"] as? Bool, true, "sidebar.expand should succeed: \(expand)")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "expand should restore every workspace's rows")
        XCTAssertTrue(sessionRowValueExists(containing: "hidden"), "the collapsed workspace's session should return")
    }

    /// Whether any `session-row` exposes `needle` in its accessibility value (the row's displayed name —
    /// `session : workspace` in flagged mode). The sidebar surfaces the row name via `value`, not `label`.
    private func sessionRowValueExists(containing needle: String) -> Bool {
        app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND value CONTAINS %@", "session-row", needle))
            .firstMatch.exists
    }

    // session.status sets a session's agent indicator: a valid state returns ok + the resolved id, an
    // unknown state returns the literal `invalid status` error, and an unknown target is not-found.
    func testSessionStatusSetsIndicator() throws {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let treeResult = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let root = try XCTUnwrap(treeResult["tree"] as? [String: Any], "result should carry a tree")
        let workspaces = try XCTUnwrap(root["workspaces"] as? [[String: Any]], "tree should list workspaces")
        let sessions = try XCTUnwrap(workspaces.first?["sessions"] as? [[String: Any]], "workspace should list sessions")
        let seeded = try XCTUnwrap(sessions.first?["id"] as? String, "should have a seeded session id")

        // a valid state with a blink flag succeeds and echoes the resolved id.
        let ok = try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"active","blink":true}}"#)
        XCTAssertEqual(ok["ok"] as? Bool, true, "session.status active should succeed: \(ok)")
        let result = try XCTUnwrap(ok["result"] as? [String: Any], "session.status should carry a result")
        XCTAssertEqual((result["id"] as? String)?.lowercased(), seeded.lowercased(),
                       "session.status should return the resolved session id: \(ok)")

        // an unknown state returns the literal guard string the arm emits.
        let bad = try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"bogus"}}"#)
        XCTAssertEqual(bad["ok"] as? Bool, false, "an unknown status should fail: \(bad)")
        XCTAssertEqual(bad["error"] as? String, "invalid status", "should report invalid status: \(bad)")

        // an unknown target is the structured not-found error (mirrors testUnknownTargetErrors).
        let unknown = try sendCommand(#"{"cmd":"session.status","target":"deadbeef","args":{"status":"active"}}"#)
        XCTAssertEqual(unknown["ok"] as? Bool, false, "an unknown target should fail: \(unknown)")
        let error = try XCTUnwrap(unknown["error"] as? String, "an unknown target should carry an error")
        XCTAssertTrue(error.hasPrefix("no such session"), "should report no such session, got: \(error)")
    }

    func testSessionStatusSoundValidatesName() throws {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let treeResult = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let root = try XCTUnwrap(treeResult["tree"] as? [String: Any], "result should carry a tree")
        let workspaces = try XCTUnwrap(root["workspaces"] as? [[String: Any]], "tree should list workspaces")
        let sessions = try XCTUnwrap(workspaces.first?["sessions"] as? [[String: Any]], "workspace should list sessions")
        let seeded = try XCTUnwrap(sessions.first?["id"] as? String, "should have a seeded session id")

        // reads the seeded session's current status from a fresh tree (nil when idle/absent).
        func currentStatus() throws -> String? {
            let t = try sendCommand(#"{"cmd":"tree"}"#)
            let r = try XCTUnwrap(t["result"] as? [String: Any])
            let ws = try XCTUnwrap((r["tree"] as? [String: Any])?["workspaces"] as? [[String: Any]])
            let all = ws.flatMap { $0["sessions"] as? [[String: Any]] ?? [] }
            return all.first { ($0["id"] as? String) == seeded }?["status"] as? String
        }

        // the default-beep keyword resolves and the command succeeds.
        let ok = try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"active","sound":"default"}}"#)
        XCTAssertEqual(ok["ok"] as? Bool, true, "session.status --sound default should succeed: \(ok)")

        // establish a known baseline, then try to set a DIFFERENT status with an unknown sound.
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"completed"}}"#)["ok"] as? Bool, true)
        XCTAssertEqual(try currentStatus(), "completed", "baseline status should be completed")

        let bad = try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"active","sound":"NoSuchSoundXYZ"}}"#)
        XCTAssertEqual(bad["ok"] as? Bool, false, "an unknown sound should fail: \(bad)")
        let error = try XCTUnwrap(bad["error"] as? String, "an unknown sound should carry an error")
        XCTAssertTrue(error.hasPrefix("unknown sound: NoSuchSoundXYZ"), "should report the unknown sound, got: \(error)")

        // the rejected call must NOT have changed the status — validation happens before the mutation.
        XCTAssertEqual(try currentStatus(), "completed", "an unknown sound must leave the status unchanged")
    }

    // session.status --color sets a per-call glyph tint. The tint itself is NOT accessibility-observable
    // (glyph color, like the cursor's solid/hollow state, isn't in the AX tree — covered host-free +
    // manual), so this drives the command path end-to-end: a valid #rrggbb applies the status, and a
    // malformed color is rejected before the mutation and leaves the status unchanged.
    func testSessionStatusColorValidatesHex() throws {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let treeResult = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let root = try XCTUnwrap(treeResult["tree"] as? [String: Any], "result should carry a tree")
        let workspaces = try XCTUnwrap(root["workspaces"] as? [[String: Any]], "tree should list workspaces")
        let sessions = try XCTUnwrap(workspaces.first?["sessions"] as? [[String: Any]], "workspace should list sessions")
        let seeded = try XCTUnwrap(sessions.first?["id"] as? String, "should have a seeded session id")

        func currentStatus() throws -> String? {
            let t = try sendCommand(#"{"cmd":"tree"}"#)
            let r = try XCTUnwrap(t["result"] as? [String: Any])
            let ws = try XCTUnwrap((r["tree"] as? [String: Any])?["workspaces"] as? [[String: Any]])
            let all = ws.flatMap { $0["sessions"] as? [[String: Any]] ?? [] }
            return all.first { ($0["id"] as? String) == seeded }?["status"] as? String
        }

        // a valid #rrggbb applies the status and shows the glyph. NOTE: the `"#ff0000"` value contains the
        // `"#` sequence, which would close a `#"..."#` raw string early, so this line uses the `##"..."##`
        // delimiter (and `\##(seeded)` interpolation) — the rest of the file's `#"..."#` JSON has no `#`.
        let ok = try sendCommand(##"{"cmd":"session.status","target":"\##(seeded)","args":{"status":"blocked","color":"#ff0000"}}"##)
        XCTAssertEqual(ok["ok"] as? Bool, true, "session.status --color #ff0000 should succeed: \(ok)")
        XCTAssertEqual(try currentStatus(), "blocked", "the status should be applied")
        XCTAssertTrue(app.staticTexts["agent-status"].waitForExistence(timeout: 12),
                      "the status glyph should appear on the session's row")

        // a malformed color is rejected before the mutation.
        let bad = try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"active","color":"nope"}}"#)
        XCTAssertEqual(bad["ok"] as? Bool, false, "a malformed color should fail: \(bad)")
        XCTAssertEqual(bad["error"] as? String, "invalid color (expected #rrggbb)", "should report the invalid color: \(bad)")

        // the rejected call must NOT have changed the status — validation happens before the mutation.
        XCTAssertEqual(try currentStatus(), "blocked", "an invalid color must leave the status unchanged")
    }

    // the agent-status icon shows on every non-idle session, the selected one INCLUDED — there is no
    // visibility gate. Set active on a non-selected session → the icon appears; select that session → it
    // STAYS (active is keep-state); set completed --auto-reset on a non-selected session → it shows, then
    // VISITING (selecting) it clears the auto-reset flash.
    func testAgentStatusIconShowsRegardlessOfSelectionAndAutoResetClears() throws {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let treeResult = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let root = try XCTUnwrap(treeResult["tree"] as? [String: Any], "result should carry a tree")
        let workspaces = try XCTUnwrap(root["workspaces"] as? [[String: Any]], "tree should list workspaces")
        let sessions = try XCTUnwrap(workspaces.first?["sessions"] as? [[String: Any]], "workspace should list sessions")
        let seeded = try XCTUnwrap(sessions.first?["id"] as? String, "should have a seeded session id")

        // a second session takes focus, leaving the seeded one realized but non-selected.
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let createdResult = try XCTUnwrap(created["result"] as? [String: Any], "session.new should carry a result")
        let secondID = try XCTUnwrap(createdResult["id"] as? String, "session.new should return the new id")
        XCTAssertTrue(pollSessionCount(2, timeout: 10), "the new session should land")

        // negative baseline: no status set yet, so no agent-status icon exists on any row.
        XCTAssertTrue(app.staticTexts["agent-status"].waitForNonExistence(timeout: 5),
                      "no agent-status icon should exist before any status is set")

        // set active on the non-selected seeded session: the icon appears.
        let status = try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"active"}}"#)
        XCTAssertEqual(status["ok"] as? Bool, true, "session.status active should succeed: \(status)")
        XCTAssertTrue(app.staticTexts["agent-status"].waitForExistence(timeout: 12),
                      "the status icon should appear on the session's row")

        // selecting that session KEEPS the icon — active is keep-state and there is no visibility gate.
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(seeded)"}"#)["ok"] as? Bool, true)
        XCTAssertTrue(app.staticTexts["agent-status"].waitForExistence(timeout: 5),
                      "the active status icon stays on the selected session (no visibility gate)")

        // completed --auto-reset on the now non-selected session shows, then VISITING it clears it.
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(secondID)"}"#)["ok"] as? Bool, true)
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"completed","autoReset":true}}"#)["ok"] as? Bool, true)
        XCTAssertTrue(app.staticTexts["agent-status"].waitForExistence(timeout: 12),
                      "completed --auto-reset should show on the non-selected session")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(seeded)"}"#)["ok"] as? Bool, true)
        XCTAssertTrue(app.staticTexts["agent-status"].waitForNonExistence(timeout: 12),
                      "visiting a completed --auto-reset session should clear its icon")
    }

    // typing into a session flagged for your attention (`blocked` or `completed`) clears the glyph — the
    // input-driven clear. blocked covers the Esc-decline case Claude Code fires no hook for; completed clears
    // the finished flash once you re-engage. wired off GhosttySurfaceView.keyDown, so it MUST be driven by the
    // real keyboard: `session.type`/inject calls ghostty_surface_key directly, bypassing keyDown.
    func testTypingClearsBlockedOrCompletedStatus() throws {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let treeResult = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let root = try XCTUnwrap(treeResult["tree"] as? [String: Any], "result should carry a tree")
        let workspaces = try XCTUnwrap(root["workspaces"] as? [[String: Any]], "tree should list workspaces")
        let sessions = try XCTUnwrap(workspaces.first?["sessions"] as? [[String: Any]], "workspace should list sessions")
        let seeded = try XCTUnwrap(sessions.first?["id"] as? String, "should have a seeded session id")

        // press a real key into the focused terminal until the glyph clears. keyboard focus return can be
        // async, so retry (mirrors the marker-poll retry idiom).
        func typeUntilGlyphCleared() -> Bool {
            for _ in 0..<8 {
                app.typeKey(.escape, modifierFlags: [])
                if app.staticTexts["agent-status"].waitForNonExistence(timeout: 2) { return true }
            }
            return false
        }

        // both attention states clear on a keystroke; active would NOT (agent still working), idle has no glyph.
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
}
