import AppKit
import Darwin
import XCTest

/// End-to-end tests for the programmatic control channel: launch the real app with an isolated
/// `AGTERM_STATE_DIR` (which also locates the unix socket at `<stateDir>/agterm.sock`), speak the socket
/// directly from the test process (one newline-delimited JSON request → one response → close), and
/// assert against the response and the `workspaces.json` file-polling oracle the sidebar tests use.
@MainActor
final class ControlAPIUITests: ControlAPITestCase {
    override func setUp() async throws {
        if name.contains("testSessionSwap") { executionTimeAllowance = 35 }
        try await super.setUp()
    }

    func testTreeReturnsSeededWorkspaceAndSession() throws {
        let response = try sendCommand(#"{"cmd":"tree"}"#)
        XCTAssertEqual(response["ok"] as? Bool, true, "tree should succeed: \(response)")

        let result = try XCTUnwrap(response["result"] as? [String: Any], "tree should carry a result")
        let tree = try XCTUnwrap(result["tree"] as? [String: Any], "result should carry a tree")
        let workspaces = try XCTUnwrap(tree["workspaces"] as? [[String: Any]], "tree should list workspaces")
        XCTAssertEqual(workspaces.count, 1, "one seeded workspace expected")

        let workspace = workspaces[0]
        XCTAssertFalse((workspace["id"] as? String ?? "").isEmpty, "workspace should have an id")
        let sessions = try XCTUnwrap(workspace["sessions"] as? [[String: Any]], "workspace should list sessions")
        XCTAssertEqual(sessions.count, 1, "one seeded session expected")
        XCTAssertFalse((sessions[0]["id"] as? String ?? "").isEmpty, "session should have an id")
        XCTAssertEqual(sessions[0]["active"] as? Bool, true, "the seeded session should be active")
    }

    // `cat` holds the foreground so the next prompt can't clear the title, as a remote session keeps it.
    func testTreeExposesOscTitle() throws {
        let text = "printf '\\033]2;CTL-OSC-TITLE\\007'; cat\n"
        let payload: [String: Any] = ["cmd": "session.type", "args": ["text": text]]
        let line = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        let typed = try sendCommand(line)
        XCTAssertEqual(typed["ok"] as? Bool, true, "session.type should succeed: \(typed)")

        var title: String?
        for _ in 0..<40 {
            let resp = try sendCommand(#"{"cmd":"tree"}"#)
            if let t = firstSessionTitle(resp), t == "CTL-OSC-TITLE" { title = t; break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertEqual(title, "CTL-OSC-TITLE", "tree should expose the session's OSC title")
    }

    /// The first session's `title` from a `tree` response dict, or nil if absent.
    private func firstSessionTitle(_ response: [String: Any]) -> String? {
        guard let result = response["result"] as? [String: Any],
              let tree = result["tree"] as? [String: Any],
              let workspaces = tree["workspaces"] as? [[String: Any]],
              let sessions = workspaces.first?["sessions"] as? [[String: Any]] else { return nil }
        return sessions.first?["title"] as? String
    }

    // `tee` opens its file on start then blocks on the pty, so the foreground is `tee`, not the prompt.
    func testTreeExposesForegroundProcess() throws {
        let marker = markerDir.appendingPathComponent("fg-\(UUID().uuidString)").path
        let payload: [String: Any] = ["cmd": "session.type", "args": ["text": "tee \(marker)\n"]]
        let line = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        XCTAssertEqual(try sendCommand(line)["ok"] as? Bool, true, "session.type should succeed")

        var fg: [String]?
        for _ in 0..<40 {
            let resp = try sendCommand(#"{"cmd":"tree"}"#)
            if let f = firstSessionForeground(resp), f.first == "tee" { fg = f; break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertEqual(fg, ["tee", marker], "tree should expose the session's live foreground command")
    }

    /// The first session's `foreground` argv from a `tree` response dict, or nil if at the prompt.
    private func firstSessionForeground(_ response: [String: Any]) -> [String]? {
        guard let result = response["result"] as? [String: Any],
              let tree = result["tree"] as? [String: Any],
              let workspaces = tree["workspaces"] as? [[String: Any]],
              let sessions = workspaces.first?["sessions"] as? [[String: Any]] else { return nil }
        return sessions.first?["foreground"] as? [String]
    }

    // an idle session omits the status key entirely, which the second session is here to prove.
    func testTreeExposesAgentStatus() throws {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let treeResult = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let root = try XCTUnwrap(treeResult["tree"] as? [String: Any], "result should carry a tree")
        let workspaces = try XCTUnwrap(root["workspaces"] as? [[String: Any]], "tree should list workspaces")
        let sessions = try XCTUnwrap(workspaces.first?["sessions"] as? [[String: Any]], "workspace should list sessions")
        let seeded = try XCTUnwrap(sessions.first?["id"] as? String, "should have a seeded session id")

        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let createdResult = try XCTUnwrap(created["result"] as? [String: Any], "session.new should carry a result")
        let idleID = try XCTUnwrap(createdResult["id"] as? String, "session.new should return the new id")
        XCTAssertTrue(pollSessionCount(2, timeout: 10), "the new session should land")

        let before = try sendCommand(#"{"cmd":"tree"}"#)
        XCTAssertNil(sessionNode(before, id: seeded)?["status"], "an idle session should omit the status key")

        let set = try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"blocked"}}"#)
        XCTAssertEqual(set["ok"] as? Bool, true, "session.status blocked should succeed: \(set)")

        var seededStatus: String?
        for _ in 0..<40 {
            let resp = try sendCommand(#"{"cmd":"tree"}"#)
            if let s = sessionNode(resp, id: seeded)?["status"] as? String { seededStatus = s; break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertEqual(seededStatus, "blocked", "tree should report the seeded session's blocked status")

        let after = try sendCommand(#"{"cmd":"tree"}"#)
        XCTAssertNil(sessionNode(after, id: idleID)?["status"], "an idle session should omit the status key")
    }

    // a --command pane has no job-control shell, so its process GROUP is led by setuid-root `login` and only
    // the descent to login's own child can name the program. Pins the `.running` wiring: reverting the tree
    // to `ForegroundProcess.command` reports null here while every other gate stays green.
    func testTreeExposesForegroundOfCommandSession() throws {
        let marker = markerDir.appendingPathComponent("cmdfg-\(UUID().uuidString)").path
        let created = try sendCommand(#"{"cmd":"session.new","args":{"command":"tee \#(marker)"}}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "session.new --command should succeed: \(created)")
        let newID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "should return an id")

        var fg: [String]?
        for _ in 0..<40 {
            let resp = try sendCommand(#"{"cmd":"tree"}"#)
            if let f = sessionNode(resp, id: newID)?["foreground"] as? [String], f.first == "tee" { fg = f; break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertEqual(fg, ["tee", marker], "tree should expose a --command session's live foreground")
    }

    /// The session node matching `id` (case-insensitive) anywhere in a `tree` response, or nil.
    private func sessionNode(_ response: [String: Any], id: String) -> [String: Any]? {
        guard let result = response["result"] as? [String: Any],
              let tree = result["tree"] as? [String: Any],
              let workspaces = tree["workspaces"] as? [[String: Any]] else { return nil }
        for workspace in workspaces {
            guard let sessions = workspace["sessions"] as? [[String: Any]] else { continue }
            if let match = sessions.first(where: { ($0["id"] as? String)?.lowercased() == id.lowercased() }) {
                return match
            }
        }
        return nil
    }

    private func pollSessionNode(_ id: String, timeout: TimeInterval,
                                 matching predicate: ([String: Any]) -> Bool) throws -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let response = try sendCommand(#"{"cmd":"tree"}"#)
            if let node = sessionNode(response, id: id), predicate(node) { return node }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        let response = try sendCommand(#"{"cmd":"tree"}"#)
        guard let node = sessionNode(response, id: id), predicate(node) else { return nil }
        return node
    }

    func testSessionSwapExchangesTreeState() throws {
        let id = try activeSessionID()
        let split = try sendCommand(#"{"cmd":"session.split","target":"\#(id)","args":{"mode":"on"}}"#)
        XCTAssertEqual(split["ok"] as? Bool, true, "session.split should succeed: \(split)")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 4), "the split should be shown")

        let leftDir = markerDir.appendingPathComponent("swap-left", isDirectory: true)
        let rightDir = markerDir.appendingPathComponent("swap-right", isDirectory: true)
        try FileManager.default.createDirectory(at: leftDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rightDir, withIntermediateDirectories: true)
        let leftReady = markerDir.appendingPathComponent("swap-left-ready")
        let rightReady = markerDir.appendingPathComponent("swap-right-ready")
        let leftForeground = markerDir.appendingPathComponent("swap-left-foreground")
        let rightForeground = markerDir.appendingPathComponent("swap-right-foreground")
        let leftCommand = "printf READY > '\(leftReady.path)'; cd '\(leftDir.path)'; "
            + "printf '\\033]2;SWAP-LEFT-TITLE\\007'; exec tee '\(leftForeground.path)'\n"
        let rightCommand = "printf READY > '\(rightReady.path)'; cd '\(rightDir.path)'; "
            + "printf '\\033]2;SWAP-RIGHT-TITLE\\007'; exec tee '\(rightForeground.path)'\n"
        XCTAssertEqual(try typeUntilMarker(
            leftCommand, target: id, file: leftReady, select: false, pane: "left", attempts: 2, perAttempt: 2),
                       "READY", "the left pane should enter its distinct cwd/title/foreground")
        XCTAssertEqual(try typeUntilMarker(
            rightCommand, target: id, file: rightReady, select: false, pane: "right", attempts: 2, perAttempt: 2),
                       "READY", "the right pane should enter its distinct cwd/title/foreground")

        let before = try XCTUnwrap(pollSessionNode(id, timeout: 4) { node in
            URL(fileURLWithPath: node["cwd"] as? String ?? "").lastPathComponent == leftDir.lastPathComponent
                && node["title"] as? String == "SWAP-LEFT-TITLE"
                && node["foreground"] as? [String] == ["tee", leftForeground.path]
                && node["splitForeground"] as? [String] == ["tee", rightForeground.path]
        }, "tree should settle both panes before swap")
        XCTAssertEqual(before["split"] as? Bool, true)

        let swapped = try sendCommand(#"{"cmd":"session.swap","target":"\#(id)"}"#)
        XCTAssertEqual(swapped["ok"] as? Bool, true, "session.swap should succeed: \(swapped)")

        let after = try XCTUnwrap(pollSessionNode(id, timeout: 3) { node in
            URL(fileURLWithPath: node["cwd"] as? String ?? "").lastPathComponent == rightDir.lastPathComponent
                && node["title"] as? String == "SWAP-RIGHT-TITLE"
                && node["foreground"] as? [String] == ["tee", rightForeground.path]
                && node["splitForeground"] as? [String] == ["tee", leftForeground.path]
        }, "tree should expose the former right pane as the session primary")
        XCTAssertEqual(after["split"] as? Bool, true, "swap must not hide or close the split")
    }

    func testSessionSwapHiddenSplitReshowsInExchangedPositions() throws {
        let id = try activeSessionID()
        XCTAssertEqual(try sendCommand(
            #"{"cmd":"session.split","target":"\#(id)","args":{"mode":"on"}}"#)["ok"] as? Bool,
            true, "session.split on should succeed")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 4), "the split should be shown")

        let originalLeftFile = markerDir.appendingPathComponent("swap-original-left-tty")
        let originalRightFile = markerDir.appendingPathComponent("swap-original-right-tty")
        let originalLeft = try XCTUnwrap(typeUntilMarker(
            "tty > '\(originalLeftFile.path)'\n", target: id, file: originalLeftFile, select: false, pane: "left",
            attempts: 2, perAttempt: 2),
            "the original left pane should report its PTY")
        let originalRight = try XCTUnwrap(typeUntilMarker(
            "tty > '\(originalRightFile.path)'\n", target: id, file: originalRightFile, select: false, pane: "right",
            attempts: 2, perAttempt: 2),
            "the original right pane should report its PTY")
        XCTAssertNotEqual(originalLeft, originalRight, "the two pane identities must be distinct")
        XCTAssertEqual(try sendCommand(
            #"{"cmd":"session.focus","target":"\#(id)","args":{"pane":"left"}}"#)["ok"] as? Bool,
            true, "the original left pane should focus before hiding")
        XCTAssertTrue(try pollSplitFocused(id, expected: false, timeout: 3),
                      "the asynchronous left focus request should settle before hiding")

        XCTAssertEqual(try sendCommand(
            #"{"cmd":"session.split","target":"\#(id)","args":{"mode":"off"}}"#)["ok"] as? Bool,
            true, "session.split off should hide the split")
        XCTAssertTrue(pollActiveSessionSplit(false, timeout: 3), "the split should be hidden before swap")
        let swapped = try sendCommand(#"{"cmd":"session.swap","target":"\#(id)"}"#)
        XCTAssertEqual(swapped["ok"] as? Bool, true, "a hidden split should still swap: \(swapped)")
        XCTAssertEqual(try sendCommand(
            #"{"cmd":"session.split","target":"\#(id)","args":{"mode":"on"}}"#)["ok"] as? Bool,
            true, "session.split on should re-show the exchanged panes")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 3), "the exchanged split should be shown again")
        XCTAssertTrue(try pollSplitFocused(id, expected: true, timeout: 3),
                      "focus should follow the original left terminal into the right slot")

        app.activate()
        XCTAssertEqual(try sendCommand(
            #"{"cmd":"session.focus","target":"\#(id)","args":{"pane":"left"}}"#)["ok"] as? Bool,
            true, "the re-shown left pane should focus")
        XCTAssertTrue(try pollSplitFocused(id, expected: false, timeout: 3),
                      "the asynchronous left focus request should settle before keyboard input")
        let afterLeftFile = markerDir.appendingPathComponent("swap-after-left-tty")
        let afterLeft = try XCTUnwrap(keyboardTypeUntilMarker(
            "tty > '\(afterLeftFile.path)'", file: afterLeftFile, attempts: 2, perAttempt: 2),
            "the re-shown left pane should accept keyboard input")
        XCTAssertEqual(afterLeft, originalRight, "the original right terminal must now occupy the left position")

        XCTAssertEqual(try sendCommand(
            #"{"cmd":"session.focus","target":"\#(id)","args":{"pane":"right"}}"#)["ok"] as? Bool,
            true, "the re-shown right pane should focus")
        XCTAssertTrue(try pollSplitFocused(id, expected: true, timeout: 3),
                      "the asynchronous right focus request should settle before keyboard input")
        let afterRightFile = markerDir.appendingPathComponent("swap-after-right-tty")
        let afterRight = try XCTUnwrap(keyboardTypeUntilMarker(
            "tty > '\(afterRightFile.path)'", file: afterRightFile, attempts: 2, perAttempt: 2),
            "the re-shown right pane should accept keyboard input")
        XCTAssertEqual(afterRight, originalLeft, "the original left terminal must now occupy the right position")
    }

    // the WIPE itself is only observable across a quit, so this covers the arm, not the wipe.
    func testRestoreClearSucceeds() throws {
        let resp = try sendCommand(#"{"cmd":"restore.clear"}"#)
        XCTAssertEqual(resp["ok"] as? Bool, true, "restore.clear should succeed: \(resp)")

        // `restore clear` is app-global and CAPTURE-scoped, so a per-session override must survive it.
        let sessionID = try activeSessionID()
        XCTAssertEqual(try sendRestore(target: sessionID, mode: "set", command: "echo kept")["ok"] as? Bool, true,
                       "pinning an override should succeed")
        XCTAssertEqual(try sendCommand(#"{"cmd":"restore.clear"}"#)["ok"] as? Bool, true, "restore.clear should succeed")
        XCTAssertEqual(try restoreNode(sessionID)["restoreCommand"] as? String, "echo kept",
                       "restore.clear captures only — the per-session override must survive it")
    }

    // an EMPTY token counts as ABSENT (an older shell exports none); an unresolvable one falls back to
    // an explicit `--pane` rather than erroring.
    func testSessionRestorePaneIDFallsBackWhenEmptyOrUnresolvable() throws {
        let sessionID = try activeSessionID()
        let empty = try sendRestore(target: sessionID, mode: "set", command: "echo empty-token", paneID: "")
        XCTAssertEqual(empty["ok"] as? Bool, true, "an empty pane id must be treated as absent: \(empty)")
        XCTAssertEqual(try restoreNode(sessionID)["restoreCommand"] as? String, "echo empty-token",
                       "an empty token takes the main-pane path")

        let withPane = try sendRestore(target: sessionID, mode: "set", command: "echo fallback",
                                       pane: "left", paneID: "not-a-real-token")
        XCTAssertEqual(withPane["ok"] as? Bool, true,
                       "an unresolvable token with an explicit --pane must fall back, not error: \(withPane)")
        XCTAssertEqual(try restoreNode(sessionID)["restoreCommand"] as? String, "echo fallback",
                       "the explicit --pane is the intended fallback")
    }

    // the tri-state depends on presence: `--none` reads back as an EMPTY string, `--clear` omits the key.
    func testSessionRestoreReadsBackOnTree() throws {
        let sessionID = try activeSessionID()
        XCTAssertNil(try restoreNode(sessionID)["restoreCommand"], "a fresh session has no override pinned")

        XCTAssertEqual(try sendRestore(target: sessionID, mode: "set", command: "echo pinned")["ok"] as? Bool, true,
                       "session.restore set should succeed")
        XCTAssertEqual(try restoreNode(sessionID)["restoreCommand"] as? String, "echo pinned",
                       "tree should report the pinned command")

        XCTAssertEqual(try sendRestore(target: sessionID, mode: "none")["ok"] as? Bool, true,
                       "session.restore --none should succeed")
        XCTAssertEqual(try restoreNode(sessionID)["restoreCommand"] as? String, "",
                       "pinned-to-nothing reads back as an empty string, not an omitted key")

        XCTAssertEqual(try sendRestore(target: sessionID, mode: "clear")["ok"] as? Bool, true,
                       "session.restore --clear should succeed")
        XCTAssertNil(try restoreNode(sessionID)["restoreCommand"], "a cleared override omits the key entirely")
    }

    // the survivor is PROMOTED into the main slot, so its right-pane token must pin `restoreCommand`.
    func testSessionRestorePaneIDFollowsPromotedPane() throws {
        let sessionID = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(sessionID)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "split on should succeed")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the session should report split:true")
        let rightToken = try readPaneToken(target: sessionID, pane: "right")

        // prove the shell is READING before `exit`: a retry would land on the survivor and close the session.
        XCTAssertNotNil(try pollPaneText(target: sessionID, pane: "left", contains: "MAINRDY-42", retype: {
            _ = try self.sendCommand(self.typeRequest(text: "echo MAINRDY-$((6*7))\n", target: sessionID,
                                                      select: false, pane: "left"))
        }), "the main pane's shell should be reading keystrokes")

        _ = try sendCommand(typeRequest(text: "exit\n", target: sessionID, select: false, pane: "left"))
        XCTAssertTrue(pollActiveSessionSplit(false, timeout: 15), "the session should collapse to a single pane")

        XCTAssertEqual(try sendRestore(target: sessionID, mode: "set", command: "echo promoted",
                                       paneID: rightToken)["ok"] as? Bool, true,
                       "pinning via the survivor's own pane id should succeed")
        let node = try restoreNode(sessionID)
        XCTAssertEqual(node["restoreCommand"] as? String, "echo promoted",
                       "the promoted survivor's token must resolve to the MAIN pane")
        XCTAssertNil(node["splitRestoreCommand"], "nothing may be pinned on the vacated split slot")
    }

    // the last case is where session.restore diverges from session.status, which falls back to left.
    func testSessionRestoreRejectsUnrestorablePanes() throws {
        let sessionID = try activeSessionID()
        let noSplit = try sendRestore(target: sessionID, mode: "set", command: "echo x", pane: "right")
        XCTAssertEqual(noSplit["ok"] as? Bool, false, "the right pane of a split-less session should be rejected")
        XCTAssertEqual(noSplit["error"] as? String, "session has no split", "the error should name the cause: \(noSplit)")

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.scratch","target":"\#(sessionID)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "scratch on should succeed")
        let scratchToken = try readPaneToken(target: sessionID, pane: "scratch")
        let scratch = try sendRestore(target: sessionID, mode: "set", command: "echo x", paneID: scratchToken)
        XCTAssertEqual(scratch["ok"] as? Bool, false, "a token resolving to the scratch should be rejected")
        XCTAssertEqual(scratch["error"] as? String, "the scratch terminal is never restored",
                       "the error should name the cause: \(scratch)")

        let unknown = try sendRestore(target: sessionID, mode: "set", command: "echo x", paneID: "not-a-real-token")
        XCTAssertEqual(unknown["ok"] as? Bool, false, "an unresolvable token with no --pane fallback should be rejected")
        XCTAssertEqual(unknown["error"] as? String, "unknown pane id: not-a-real-token",
                       "the error should name the cause: \(unknown)")

        XCTAssertNil(try restoreNode(sessionID)["restoreCommand"], "a rejected pin must leave the main pane untouched")
    }

    /// Send a `session.restore` request, returning the raw response. `mode` is `set` | `none` | `clear`.
    private func sendRestore(target: String, mode: String, command: String? = nil,
                             pane: String? = nil, paneID: String? = nil) throws -> [String: Any] {
        var args: [String: Any] = ["mode": mode]
        if let command { args["command"] = command }
        if let pane { args["pane"] = pane }
        if let paneID { args["paneID"] = paneID }
        let obj: [String: Any] = ["cmd": "session.restore", "target": target, "args": args]
        return try sendCommand(String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self))
    }

    /// The `tree` node of the session with `id`, for reading the restore-override fields back.
    private func restoreNode(_ id: String) throws -> [String: Any] {
        let response = try sendCommand(#"{"cmd":"tree"}"#)
        return try XCTUnwrap(sessionNode(response, id: id), "the tree should carry the session's node: \(response)")
    }

    /// Read a pane's stable spawn token straight from its shell's `$AGTERM_PANE_ID` — the value a hook
    /// forwards as `--pane-id`. Echoes `<tag>-42[<token>]`, where the arithmetic 42 (from `$((6*7))`)
    /// proves the shell RAN the line, then extracts the token between the brackets.
    private func readPaneToken(target: String, pane: String) throws -> String {
        let tag = "RSTR-\(UUID().uuidString.prefix(8))"
        let needle = "\(tag)-42["
        let buffer = try pollPaneText(target: target, pane: pane, contains: needle, retype: {
            _ = try self.sendCommand(self.typeRequest(
                text: "printf '\(tag)-%s[%s]\\n' \"$((6*7))\" \"$AGTERM_PANE_ID\"\n",
                target: target, select: false, pane: pane))
        })
        let text = try XCTUnwrap(buffer, "reading the \(pane) pane's AGTERM_PANE_ID should land in its buffer")
        let pattern = NSRegularExpression.escapedPattern(for: needle) + "([-0-9A-Fa-f]+)\\]"
        let regex = try NSRegularExpression(pattern: pattern)
        let match = try XCTUnwrap(regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                                  "the \(pane) pane should echo a non-empty AGTERM_PANE_ID")
        return String(text[try XCTUnwrap(Range(match.range(at: 1), in: text))])
    }

    // Finder is outside the AX tree, so the returned id is all that proves the action was reached.
    func testSessionRevealSucceedsAndResolvesTargets() throws {
        let activeID = try activeSessionID()
        let revealed = try sendCommand(#"{"cmd":"session.reveal","target":"active"}"#)
        XCTAssertEqual(revealed["ok"] as? Bool, true, "session.reveal should succeed: \(revealed)")
        let result = try XCTUnwrap(revealed["result"] as? [String: Any])
        XCTAssertEqual((result["id"] as? String)?.lowercased(), activeID.lowercased())

        let missing = try sendCommand(#"{"cmd":"session.reveal","target":"ffffffff"}"#)
        XCTAssertEqual(missing["ok"] as? Bool, false, "an unknown target should fail")
        XCTAssertTrue((missing["error"] as? String)?.contains("no such session") == true)
    }

    // the pixels are not AX-observable (Metal surface), so this covers the round-trip and validation only.
    func testSessionBackgroundSetClearAndValidation() throws {
        let sid = try activeSessionID()

        let text = try sendCommand(#"{"cmd":"session.background","target":"\#(sid)","args":{"mode":"text","text":"STAGING","opacity":0.2}}"#)
        XCTAssertEqual(text["ok"] as? Bool, true, "session.background text should succeed: \(text)")

        let afterSet = try sendCommand(#"{"cmd":"tree"}"#)
        let setNode = try XCTUnwrap(sessionNode(afterSet, id: sid), "the session should appear in the tree")
        let bg = try XCTUnwrap(setNode["background"] as? [String: Any], "tree should expose the set watermark")
        XCTAssertEqual(bg["kind"] as? String, "text", "the watermark kind should read back")
        XCTAssertEqual(bg["text"] as? String, "STAGING", "the watermark text should read back")

        // the spec carries no opacity: a color honors the Settings translucency at render time.
        let colorSet = try sendCommand(##"{"cmd":"session.background","target":"\##(sid)","args":{"mode":"color","color":"#ff0000"}}"##)
        XCTAssertEqual(colorSet["ok"] as? Bool, true, "session.background color should succeed: \(colorSet)")
        let afterColor = try sendCommand(#"{"cmd":"tree"}"#)
        let colorNode = try XCTUnwrap(sessionNode(afterColor, id: sid), "the session should appear in the tree")
        let colorBg = try XCTUnwrap(colorNode["background"] as? [String: Any], "tree should expose the color background")
        XCTAssertEqual(colorBg["kind"] as? String, "color", "the color kind should read back")
        XCTAssertEqual(colorBg["colorHex"] as? String, "#ff0000", "the color hex should read back")

        let badColor = try sendCommand(#"{"cmd":"session.background","target":"\#(sid)","args":{"mode":"color","color":"red"}}"#)
        XCTAssertEqual(badColor["ok"] as? Bool, false, "a malformed color should be rejected")

        // unreachable from the CLI, whose argument is required, so raw JSON is the only cover.
        let emptyColor = try sendCommand(#"{"cmd":"session.background","target":"\#(sid)","args":{"mode":"color"}}"#)
        XCTAssertEqual(emptyColor["ok"] as? Bool, false, "color mode with no color should be rejected")
        XCTAssertEqual(emptyColor["error"] as? String, "session.background color requires a color",
                       "the empty-color guard should reject it")

        let missing = try sendCommand(#"{"cmd":"session.background","target":"\#(sid)","args":{"mode":"image","path":"/no/such.png"}}"#)
        XCTAssertEqual(missing["ok"] as? Bool, false, "a missing image file should be rejected")

        let badFit = try sendCommand(#"{"cmd":"session.background","target":"\#(sid)","args":{"mode":"image","path":"/no/such.png","fit":"fill"}}"#)
        XCTAssertEqual(badFit["ok"] as? Bool, false, "an invalid fit should be rejected")

        // a newline would smuggle an extra ghostty key in. The guard runs BEFORE the existence check, so
        // its own error proves it did the rejecting.
        let injection = try sendCommand(#"{"cmd":"session.background","target":"\#(sid)","args":{"mode":"image","path":"x.png\nclipboard-read = allow\ny.png"}}"#)
        XCTAssertEqual(injection["ok"] as? Bool, false, "an image path with a control char must be rejected")
        XCTAssertEqual(injection["error"] as? String, "image path must not contain control characters",
                       "the control-char guard, not the fileExists check, should reject it")

        let badOpacity = try sendCommand(#"{"cmd":"session.background","target":"\#(sid)","args":{"mode":"text","text":"X","opacity":5}}"#)
        XCTAssertEqual(badOpacity["ok"] as? Bool, false, "an out-of-range opacity should be rejected")

        let longText = String(repeating: "A", count: 5000)
        let tooLong = try sendCommand(#"{"cmd":"session.background","target":"\#(sid)","args":{"mode":"text","text":"\#(longText)"}}"#)
        XCTAssertEqual(tooLong["ok"] as? Bool, false, "an over-long watermark text should be rejected")

        let cleared = try sendCommand(#"{"cmd":"session.background","target":"\#(sid)","args":{"mode":"clear"}}"#)
        XCTAssertEqual(cleared["ok"] as? Bool, true, "session.background clear should succeed: \(cleared)")

        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        XCTAssertEqual(tree["ok"] as? Bool, true, "the server should stay alive after background commands")
        let clearedNode = try XCTUnwrap(sessionNode(tree, id: sid), "the session should still appear in the tree")
        XCTAssertNil(clearedNode["background"], "a cleared watermark should be absent from the tree node")
    }

    func testMalformedRequestErrorsAndServerStaysAlive() throws {
        let bad = try sendCommand("not json at all")
        XCTAssertEqual(bad["ok"] as? Bool, false, "malformed request should fail")
        XCTAssertFalse((bad["error"] as? String ?? "").isEmpty, "a failed request should carry an error string")

        let good = try sendCommand(#"{"cmd":"tree"}"#)
        XCTAssertEqual(good["ok"] as? Bool, true, "the server should still answer after a bad request")
    }

    func testSessionNewAndClose() throws {
        XCTAssertTrue(pollSessionCount(1, timeout: 10), "should start with the one seeded session")

        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "session.new should succeed: \(created)")
        let result = try XCTUnwrap(created["result"] as? [String: Any], "session.new should carry a result")
        let newID = try XCTUnwrap(result["id"] as? String, "session.new should return the new id")
        XCTAssertFalse(newID.isEmpty, "the new session id should not be empty")
        XCTAssertTrue(pollSessionCount(2, timeout: 10), "the new session should land in workspaces.json")

        let closed = try sendCommand(#"{"cmd":"session.close","target":"\#(newID)"}"#)
        XCTAssertEqual(closed["ok"] as? Bool, true, "session.close should succeed: \(closed)")
        XCTAssertTrue(pollSessionCount(1, timeout: 10), "closing the session should remove its row")
    }

    // the source needs a real non-home directory, or the cwd carry-over matches the default and proves nothing.
    func testSessionDuplicate() throws {
        let sourceID = UUID(uuidString: "DD100000-0000-0000-0000-000000000001")!
        // under home, which is not a symlink: a /tmp seed would hit /private canonicalization.
        let cwd = NSHomeDirectory() + "/agterm-dup-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: cwd) }
        let snapshot = """
        {"version":1,"selectedSessionID":"\(sourceID.uuidString)","workspaces":[\
        {"id":"\(UUID().uuidString)","name":"workspace 1","sessions":[\
        {"id":"\(sourceID.uuidString)","customName":null,"cwd":"\(cwd)"}]}]}
        """
        try relaunch(withSnapshot: snapshot)
        XCTAssertTrue(pollSessionCount(1, timeout: 10), "should start with the one seeded session")

        let dup = try sendCommand(#"{"cmd":"session.duplicate","target":"\#(sourceID.uuidString)"}"#)
        XCTAssertEqual(dup["ok"] as? Bool, true, "session.duplicate should succeed: \(dup)")
        let result = try XCTUnwrap(dup["result"] as? [String: Any], "session.duplicate should carry a result")
        let newID = try XCTUnwrap(result["id"] as? String, "session.duplicate should return the new id")
        XCTAssertFalse(newID.isEmpty, "the new session id should not be empty")
        XCTAssertNotEqual(newID.lowercased(), sourceID.uuidString.lowercased(), "the duplicate must be a new session")
        XCTAssertTrue(pollSessionCount(2, timeout: 10), "the duplicate should land in workspaces.json")

        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let treeResult = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let root = try XCTUnwrap(treeResult["tree"] as? [String: Any], "result should carry a tree")
        let workspace = try XCTUnwrap((root["workspaces"] as? [[String: Any]])?.first, "one seeded workspace expected")
        let sessions = try XCTUnwrap(workspace["sessions"] as? [[String: Any]], "workspace should list sessions")
        XCTAssertEqual(sessions.count, 2, "the source and its duplicate")

        XCTAssertEqual((sessions[0]["id"] as? String)?.lowercased(), sourceID.uuidString.lowercased(),
                       "the source stays first")
        XCTAssertEqual((sessions[1]["id"] as? String)?.lowercased(), newID.lowercased(),
                       "the duplicate lands right after its source")
        XCTAssertEqual(sessions[1]["cwd"] as? String, sessions[0]["cwd"] as? String,
                       "the duplicate carries its source's cwd")
        XCTAssertEqual(sessions[1]["cwd"] as? String, cwd, "the duplicate opens in the source's specific directory")
        XCTAssertEqual(sessions[1]["active"] as? Bool, true, "the duplicate becomes the active session")
    }

    // the save is deferred by the grace window, so the assertion goes through `tree`, not the file.
    func testSessionCloseMultipleTargets() throws {
        let firstID = UUID(uuidString: "AA100000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "AA200000-0000-0000-0000-000000000002")!
        let thirdID = UUID(uuidString: "AA300000-0000-0000-0000-000000000003")!
        let snapshot = """
        {"version":1,"selectedSessionID":"\(firstID.uuidString)","workspaces":[\
        {"id":"\(UUID().uuidString)","name":"workspace 1","sessions":[\
        {"id":"\(firstID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"},\
        {"id":"\(secondID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"},\
        {"id":"\(thirdID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"}]}]}
        """
        try relaunch(withSnapshot: snapshot)

        let closed = try sendCommand(#"{"cmd":"session.close","args":{"targets":["\#(secondID.uuidString)","\#(thirdID.uuidString)"]}}"#)
        XCTAssertEqual(closed["ok"] as? Bool, true, "batch session.close should succeed: \(closed)")
        XCTAssertEqual((closed["result"] as? [String: Any])?["affected"] as? Int, 2,
                       "batch close should report affected sessions separately from diagnostic counts")
        XCTAssertTrue(pollSessionCount(3, timeout: 1), "grace-enabled close must defer the persisted removal")

        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let node = try XCTUnwrap(sessionNode(tree, id: firstID.uuidString), "the first session should remain")
        XCTAssertEqual(node["id"] as? String, firstID.uuidString)
        XCTAssertNil(sessionNode(tree, id: secondID.uuidString), "the second session should be hidden by the grouped close")
        XCTAssertNil(sessionNode(tree, id: thirdID.uuidString), "the third session should be hidden by the grouped close")
    }

    // with grace disabled the close persists immediately instead of leaving the pre-close snapshot on disk.
    func testSessionCloseMultipleTargetsHonorsDisabledGraceUndo() throws {
        let firstID = UUID(uuidString: "AB100000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "AB200000-0000-0000-0000-000000000002")!
        let thirdID = UUID(uuidString: "AB300000-0000-0000-0000-000000000003")!
        let snapshot = """
        {"version":1,"selectedSessionID":"\(firstID.uuidString)","workspaces":[\
        {"id":"\(UUID().uuidString)","name":"workspace 1","sessions":[\
        {"id":"\(firstID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"},\
        {"id":"\(secondID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"},\
        {"id":"\(thirdID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"}]}]}
        """
        try relaunch(withSnapshot: snapshot)
        try relaunch(withSettings: #"{"closeGraceUndoEnabled":false}"#)

        let closed = try sendCommand(#"{"cmd":"session.close","args":{"targets":["\#(secondID.uuidString)","\#(thirdID.uuidString)"]}}"#)

        XCTAssertEqual(closed["ok"] as? Bool, true, "immediate batch session.close should succeed: \(closed)")
        XCTAssertEqual((closed["result"] as? [String: Any])?["affected"] as? Int, 2)
        XCTAssertTrue(pollSessionCount(1, timeout: 2), "grace-disabled close must persist both removals immediately")
    }

    // `resolveBatchSessions` errors before anything mutates, so the valid member must survive.
    func testSessionCloseBatchIsAllOrNothing() throws {
        let firstID = UUID(uuidString: "ABCD1111-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "ABCD2222-0000-0000-0000-000000000002")!
        let thirdID = UUID(uuidString: "AC330000-0000-0000-0000-000000000003")!
        let snapshot = """
        {"version":1,"selectedSessionID":"\(firstID.uuidString)","workspaces":[\
        {"id":"\(UUID().uuidString)","name":"workspace 1","sessions":[\
        {"id":"\(firstID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"},\
        {"id":"\(secondID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"},\
        {"id":"\(thirdID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"}]}]}
        """
        try relaunch(withSnapshot: snapshot)

        let unknown = try sendCommand(#"{"cmd":"session.close","args":{"targets":["\#(thirdID.uuidString)","eeee"]}}"#)
        XCTAssertEqual(unknown["ok"] as? Bool, false, "an unknown target must fail the whole batch")
        XCTAssertEqual(unknown["error"] as? String, "no such session: eeee")

        let ambiguous = try sendCommand(#"{"cmd":"session.close","args":{"targets":["\#(thirdID.uuidString)","abcd"]}}"#)
        XCTAssertEqual(ambiguous["ok"] as? Bool, false, "an ambiguous prefix must fail the whole batch")
        XCTAssertEqual(ambiguous["error"] as? String, "ambiguous session prefix 'abcd' → ABCD1111, ABCD2222")

        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        XCTAssertNotNil(sessionNode(tree, id: firstID.uuidString), "no session may close when batch resolution fails")
        XCTAssertNotNil(sessionNode(tree, id: secondID.uuidString), "no session may close when batch resolution fails")
        XCTAssertNotNil(sessionNode(tree, id: thirdID.uuidString), "the valid batch member must stay open")
    }

    // the marker file is the proof the command ran AS the process rather than being typed into a shell.
    func testSessionNewWithCommandRunsAsProcess() throws {
        let marker = NSTemporaryDirectory() + "agterm-cmd-\(UUID().uuidString).txt"
        let cmd = "printf RANCMD > \(marker)"
        let created = try sendCommand(#"{"cmd":"session.new","args":{"command":"\#(cmd)"}}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "session.new --command should succeed: \(created)")

        var ran = false
        for _ in 0..<40 {
            if let data = FileManager.default.contents(atPath: marker),
               String(data: data, encoding: .utf8) == "RANCMD" { ran = true; break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertTrue(ran, "the command should run as the session's process and write the marker file")
        try? FileManager.default.removeItem(atPath: marker)
    }

    // `true` exits immediately, so without --wait the session would vanish (issue #254).
    func testSessionNewCommandWaitHoldsSessionAfterExit() throws {
        let created = try sendCommand(#"{"cmd":"session.new","args":{"command":"true","wait":true}}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "session.new --command --wait should succeed: \(created)")
        let newID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new should return an id")

        RunLoop.current.run(until: Date().addingTimeInterval(2))

        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let node = try XCTUnwrap(sessionNode(tree, id: newID), "the held session must still exist after its command exited")
        XCTAssertEqual(node["commandWait"] as? Bool, true, "the tree should report commandWait=true for a held session")
    }

    // rejected SERVER-SIDE, since a raw socket client bypasses the CLI's own validate().
    func testSessionNewWaitWithoutCommandRejectedServerSide() throws {
        let resp = try sendCommand(#"{"cmd":"session.new","args":{"wait":true}}"#)
        XCTAssertEqual(resp["ok"] as? Bool, false, "--wait without --command must be rejected: \(resp)")
        XCTAssertEqual(resp["error"] as? String, "--wait requires --command")
    }

    // `head -n1 > marker` plus REAL keystrokes: the text lands only if the new session took first responder.
    func testSessionNewWithCommandFocusesTheNewSession() throws {
        let marker = NSTemporaryDirectory() + "agterm-focus-\(UUID().uuidString).txt"
        let cmd = "head -n1 > \(marker)"
        let created = try sendCommand(#"{"cmd":"session.new","args":{"command":"\#(cmd)"}}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "session.new --command should succeed: \(created)")

        RunLoop.current.run(until: Date().addingTimeInterval(2))
        app.typeText("FOCUSED")
        app.typeKey(.return, modifierFlags: [])

        var got = false
        for _ in 0..<40 {
            if let s = (try? String(contentsOfFile: marker, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines), s == "FOCUSED" { got = true; break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertTrue(got, "the new command session should be focused so typed text reaches its process")
        try? FileManager.default.removeItem(atPath: marker)
    }

    // the promoted survivor is the MAIN pane now, so its keystrokes must not clear the fresh split's
    // `.right` block. Real keystrokes are load-bearing: a session.type inject skips onUserInputClearsStatus.
    func testPromotedMainPaneDoesNotClearSplitRightStatus() throws {
        let sid = try activeSessionID()

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(sid)","args":{"mode":"on"}}"#)["ok"] as? Bool, true)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.typeKey(.leftArrow, modifierFlags: [.command, .option])
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        app.typeText("exit")
        app.typeKey(.return, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(2)) // shell exit + promotion + auto-focus

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(sid)","args":{"mode":"on"}}"#)["ok"] as? Bool, true)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.status","target":"\#(sid)","args":{"status":"blocked","pane":"right"}}"#)["ok"] as? Bool, true)
        var set = false
        for _ in 0..<10 {
            if (sessionNode(try sendCommand(#"{"cmd":"tree"}"#), id: sid)?["status"] as? String) == "blocked" { set = true; break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        XCTAssertTrue(set, "the .right block should be set before the keystroke test")

        app.typeKey(.leftArrow, modifierFlags: [.command, .option])
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        app.typeText("x")
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        XCTAssertEqual(sessionNode(tree, id: sid)?["status"] as? String, "blocked",
                       "typing in the promoted main pane must not clear the split pane's .right block")
    }

    func testSessionNewWithName() throws {
        let created = try sendCommand(#"{"cmd":"session.new","args":{"name":"myhost"}}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "session.new --name should succeed: \(created)")
        let newID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new should return an id")
        XCTAssertTrue(pollSessionName(id: newID, equals: "myhost", timeout: 10),
                      "the new session should carry the given custom name")
    }

    // the reuse leg is what makes it idempotent: two creates must land two sessions in ONE workspace.
    func testSessionNewWorkspaceNameCreatesThenReuses() throws {
        let missing = try sendCommand(#"{"cmd":"session.new","args":{"workspaceName":"servers"}}"#)
        XCTAssertEqual(missing["ok"] as? Bool, false, "name target with no match and no create should fail: \(missing)")
        XCTAssertTrue((missing["error"] as? String ?? "").contains("no workspace named"),
                      "should report the missing workspace name: \(missing)")
        XCTAssertTrue(pollWorkspaceNames(["workspace 1"], timeout: 5), "the failed call must not create a workspace")

        let created = try sendCommand(#"{"cmd":"session.new","args":{"workspaceName":"servers","createWorkspace":true}}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "create-workspace should succeed: \(created)")
        XCTAssertTrue(pollWorkspaceNames(["workspace 1", "servers"], timeout: 10), "the servers workspace should be created")

        let reused = try sendCommand(#"{"cmd":"session.new","args":{"workspaceName":"servers","createWorkspace":true}}"#)
        XCTAssertEqual(reused["ok"] as? Bool, true, "the second create should reuse the workspace: \(reused)")
        XCTAssertTrue(pollWorkspaceNames(["workspace 1", "servers"], timeout: 10), "still exactly one servers workspace")
        XCTAssertTrue(pollSessionCounts([1, 2], timeout: 10), "both sessions should land in the single servers workspace")

        let existing = try sendCommand(#"{"cmd":"session.new","args":{"workspaceName":"servers"}}"#)
        XCTAssertEqual(existing["ok"] as? Bool, true, "no-create name target of an existing workspace should succeed: \(existing)")
        XCTAssertTrue(pollSessionCounts([1, 3], timeout: 10), "the no-create name target should land a third session in servers")
    }

    // enforced SERVER-SIDE, since a raw socket caller bypasses the CLI's validate().
    func testSessionNewWorkspaceNameValidationErrors() throws {
        let both = try sendCommand(#"{"cmd":"session.new","args":{"workspace":"active","workspaceName":"servers"}}"#)
        XCTAssertEqual(both["ok"] as? Bool, false, "both --workspace and --workspace-name should fail: \(both)")
        XCTAssertTrue((both["error"] as? String ?? "").contains("not both"), "should report mutual exclusion: \(both)")

        let createNoName = try sendCommand(#"{"cmd":"session.new","args":{"createWorkspace":true}}"#)
        XCTAssertEqual(createNoName["ok"] as? Bool, false, "create-workspace with no name should fail: \(createNoName)")
        XCTAssertTrue((createNoName["error"] as? String ?? "").contains("requires --workspace-name"),
                      "should report create-needs-name: \(createNoName)")

        let blank = try sendCommand(#"{"cmd":"session.new","args":{"workspaceName":"   "}}"#)
        XCTAssertEqual(blank["ok"] as? Bool, false, "a blank workspace name should fail: \(blank)")
        XCTAssertTrue((blank["error"] as? String ?? "").contains("must not be blank"),
                      "a blank name should report must-not-be-blank, not suggest --create-workspace: \(blank)")
    }

    func testSessionNewNoSelectKeepsActiveSelection() throws {
        let original = try activeSessionID()

        let created = try sendCommand(#"{"cmd":"session.new","args":{"noSelect":true}}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "session.new --no-select should succeed: \(created)")
        let newID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new should return an id")
        XCTAssertNotEqual(newID.lowercased(), original.lowercased(), "the background session should be a new session")

        var confirmed = false
        for _ in 0..<20 {
            let tree = try sendCommand(#"{"cmd":"tree"}"#)
            if let newNode = sessionNode(tree, id: newID), let oldNode = sessionNode(tree, id: original),
               oldNode["active"] as? Bool == true, newNode["active"] as? Bool == false {
                confirmed = true
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        XCTAssertTrue(confirmed, "the new session should exist while the original stays active (not the new one)")
    }

    func testWorkspaceNewAndRename() throws {
        let created = try sendCommand(#"{"cmd":"workspace.new","args":{"name":"control ws"}}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "workspace.new should succeed: \(created)")
        let result = try XCTUnwrap(created["result"] as? [String: Any], "workspace.new should carry a result")
        let newID = try XCTUnwrap(result["id"] as? String, "workspace.new should return the new id")
        XCTAssertTrue(pollWorkspaceNames(["workspace 1", "control ws"], timeout: 10),
                      "the new workspace should land in workspaces.json")

        let renamed = try sendCommand(#"{"cmd":"workspace.rename","target":"\#(newID)","args":{"name":"renamed ws"}}"#)
        XCTAssertEqual(renamed["ok"] as? Bool, true, "workspace.rename should succeed: \(renamed)")
        XCTAssertTrue(pollWorkspaceNames(["workspace 1", "renamed ws"], timeout: 10),
                      "the rename should be reflected in workspaces.json")
    }

    func testWorkspaceDeleteLastErrors() throws {
        XCTAssertTrue(pollWorkspaceNames(["workspace 1"], timeout: 10), "should start with the one seeded workspace")

        let response = try sendCommand(#"{"cmd":"workspace.delete","target":"active"}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "deleting the last workspace should fail")
        XCTAssertEqual(response["error"] as? String, "cannot delete last workspace",
                       "should return the keep-one error: \(response)")
        XCTAssertTrue(pollWorkspaceNames(["workspace 1"], timeout: 5), "the workspace should still be present")
    }

    func testUnknownTargetErrors() throws {
        let response = try sendCommand(#"{"cmd":"session.close","target":"deadbeef"}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "an unknown target should fail")
        let error = try XCTUnwrap(response["error"] as? String, "an unknown target should carry an error")
        XCTAssertTrue(error.hasPrefix("no such session"), "should report no such session, got: \(error)")
    }

    // the surface's own shell is the oracle for "the text actually landed".
    func testSessionTypeIntoActiveSession() throws {
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let result = try XCTUnwrap(created["result"] as? [String: Any], "session.new should carry a result")
        let newID = try XCTUnwrap(result["id"] as? String, "session.new should return the new id")

        let file = markerDir.appendingPathComponent("active")
        let command = "tty > '\(file.path)'\n"
        // a freshly-realized shell may drop the first keystrokes, so the marker is the readiness wait.
        XCTAssertNotNil(try typeUntilMarker(command, target: newID, file: file, select: false),
                        "the typed command should run in the visible session's shell")
    }

    // session.type --select into a freshly created, never-shown session realizes it and the text lands.
    func testSessionTypeSelectRealizesNeverShownSession() throws {
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let result = try XCTUnwrap(created["result"] as? [String: Any], "session.new should carry a result")
        let newID = try XCTUnwrap(result["id"] as? String, "session.new should return the new id")

        let file = markerDir.appendingPathComponent("realized")
        let command = "tty > '\(file.path)'\n"
        // --select realizes the never-shown session; the marker rides out the shell-readiness race.
        XCTAssertNotNil(try typeUntilMarker(command, target: newID, file: file, select: true),
                        "the typed command should run in the realized session's shell")
    }

    // the eager deck realizes every restored session, so there are no never-shown ones left to error on.
    func testSessionTypeReachesEagerlyRealizedSession() throws {
        // the second is restored but never selected, yet its shell is already running.
        let selectedID = UUID()
        let otherID = UUID()
        let snapshot = """
        {"version":1,"selectedSessionID":"\(selectedID.uuidString)","workspaces":[\
        {"id":"\(UUID().uuidString)","name":"workspace 1","sessions":[\
        {"id":"\(selectedID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"},\
        {"id":"\(otherID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"}]}]}
        """
        try relaunch(withSnapshot: snapshot)

        let file = markerDir.appendingPathComponent("eager")
        XCTAssertNotNil(try typeUntilMarker("tty > '\(file.path)'\n", target: otherID.uuidString, file: file, select: false),
                        "session.type without select reaches the eagerly-realized, non-selected session")
    }

    // #349 end to end: create in the background, then type once with no retry. This does NOT discriminate
    // the realize poll — over two socket round-trips the surface has always come up by the time the type
    // lands, so it stays green against the pre-#349 fast-fail too. `ControlServerSessionActionsTests`
    // .testTypeWithoutSelectPollsInsteadOfDemandingSelect is what pins the poll.
    func testSessionTypeAfterNoSelectCreateLands() throws {
        let created = try sendCommand(#"{"cmd":"session.new","args":{"noSelect":true}}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "session.new --no-select should succeed: \(created)")
        let id = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String,
                               "session.new should carry the new id")

        let file = markerDir.appendingPathComponent("noselect-race")
        let typed = try sendCommand(typeRequest(text: "tty > '\(file.path)'\n", target: id, select: false))
        XCTAssertEqual(typed["ok"] as? Bool, true, "session.type into a background session should land: \(typed)")
        XCTAssertNotNil(pollMarker(file, timeout: 8), "the typed command should run in the new session")
    }

    // the with-selection path needs a real Metal-surface selection, verified by hand.
    func testSessionCopyWithoutSelectionErrors() throws {
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let result = try XCTUnwrap(created["result"] as? [String: Any], "session.new should carry a result")
        let newID = try XCTUnwrap(result["id"] as? String, "session.new should return the new id")

        let response = try sendCommand(#"{"cmd":"session.copy","target":"\#(newID)"}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "copy with no selection should fail: \(response)")
        XCTAssertEqual(response["error"] as? String, "no selection", "should report no selection: \(response)")
    }

    // two markers on separate lines: a select_all grabbing only the current line returns just the second.
    func testSessionSelectAllThenCopyReturnsBuffer() throws {
        let id = try activeSessionID()
        let first = "SELECTALLMARKERONE", second = "SELECTALLMARKERTWO"
        let onScreen = try pollPaneText(target: id, pane: "left", contains: second) {
            _ = try self.sendCommand(self.typeRequest(text: "echo \(first)\n", target: id, select: false))
            _ = try self.sendCommand(self.typeRequest(text: "printf '\\n\\n'\n", target: id, select: false))
            _ = try self.sendCommand(self.typeRequest(text: "echo \(second)\n", target: id, select: false))
        }
        XCTAssertNotNil(onScreen, "both echoed markers should appear in the buffer")

        let selected = try sendCommand(#"{"cmd":"session.selectall","target":"\#(id)"}"#)
        XCTAssertEqual(selected["ok"] as? Bool, true, "session.selectall should succeed: \(selected)")

        let copied = try sendCommand(#"{"cmd":"session.copy","target":"\#(id)"}"#)
        XCTAssertEqual(copied["ok"] as? Bool, true, "session.copy after select-all should succeed: \(copied)")
        let text = try XCTUnwrap((copied["result"] as? [String: Any])?["text"] as? String, "copy should return text")
        XCTAssertTrue(text.contains(first), "selection should span back to the first marker, got: \(text)")
        XCTAssertTrue(text.contains(second), "selection should include the last marker, got: \(text)")
    }

    // NSPasteboard.general is shared across processes, so the test process can seed it.
    func testSessionPasteInsertsClipboardText() throws {
        let id = try activeSessionID()
        let marker = "PASTECLIPMARKER"
        seedPasteboard { $0.setString(marker, forType: .string) }

        let found = try pollPaneText(target: id, pane: "left", contains: marker) {
            let pasted = try self.sendCommand(#"{"cmd":"session.paste","target":"\#(id)"}"#)
            XCTAssertEqual(pasted["ok"] as? Bool, true, "session.paste should succeed: \(pasted)")
        }
        XCTAssertNotNil(found, "the pasted clipboard marker should appear in the buffer")
    }

    // UNGATED, unlike the Edit menu's Paste item: an empty clipboard is `ok` with no buffer change, as
    // every other binding-action arm reports success without consulting libghostty's return.
    func testSessionPasteWithEmptyClipboardSucceedsWithoutChangingBuffer() throws {
        let id = try activeSessionID()
        seedPasteboard { _ in }  // cleared, nothing written

        let before = try sendCommand(#"{"cmd":"session.text","target":"\#(id)"}"#)
        let beforeText = (before["result"] as? [String: Any])?["text"] as? String

        let pasted = try sendCommand(#"{"cmd":"session.paste","target":"\#(id)"}"#)
        XCTAssertEqual(pasted["ok"] as? Bool, true, "session.paste on an empty clipboard should still be ok: \(pasted)")

        let after = try sendCommand(#"{"cmd":"session.text","target":"\#(id)"}"#)
        let afterText = (after["result"] as? [String: Any])?["text"] as? String
        XCTAssertEqual(beforeText, afterText, "an empty-clipboard paste must not change the buffer")
    }

    func testSessionPasteAndSelectAllRejectUnknownTarget() throws {
        for cmd in ["session.paste", "session.selectall"] {
            let response = try sendCommand(#"{"cmd":"\#(cmd)","target":"deadbeef"}"#)
            XCTAssertEqual(response["ok"] as? Bool, false, "\(cmd) with an unknown target should fail: \(response)")
            XCTAssertNotNil(response["error"] as? String, "\(cmd) should carry an error: \(response)")
        }
    }

    // session.search over the active session's scrollback: seed the screen with repeated needle text via
    // session.type (the surface's own shell renders it), then session.search "<needle>" reports a match
    // count + the "N of M" / "M matches" display string. --next/--prev step the selection and --close exits
    // search. The needle's render timing is async (the shell echo + the SEARCH_TOTAL callback), so the
    // open-with-needle call is retried until the count settles (the surface-readiness retry idiom).
    func testSessionSearch() throws {
        let needle = "agtermFINDME"
        // seed the screen: echo the needle several times so there are matches in the live surface. type into
        // the seeded active session (realized + visible at launch), and let the shell render it.
        let typed = try sendCommand(typeRequest(text: "echo \(needle) \(needle) \(needle)\n", target: nil, select: false))
        XCTAssertEqual(typed["ok"] as? Bool, true, "typing the needle into the active session should succeed: \(typed)")

        // open search with the needle. the echoed line + the async SEARCH_TOTAL callback can lag the first
        // call, so retry until the count settles (>= 1 match), re-sending the needle each attempt.
        var count: Int?
        var displayText: String?
        for _ in 0..<20 {
            let search = try sendCommand(#"{"cmd":"session.search","target":"active","args":{"text":"\#(needle)"}}"#)
            XCTAssertEqual(search["ok"] as? Bool, true, "session.search should succeed: \(search)")
            let result = try XCTUnwrap(search["result"] as? [String: Any], "session.search should carry a result")
            if let c = result["count"] as? Int, c >= 1 {
                count = c
                displayText = result["text"] as? String
                break
            }
            usleep(250_000)
        }
        XCTAssertNotNil(count, "session.search should report at least one match for the seeded needle")
        XCTAssertGreaterThanOrEqual(count ?? 0, 1, "the seeded needle should match at least once")
        let display = try XCTUnwrap(displayText, "session.search should return a display string with a match count")
        XCTAssertTrue(display.contains("of") || display.contains("match"),
                      "the display string should report 'N of M' or 'M matches', got: \(display)")

        // step the selection forward: the "N of M" selected index must ADVANCE (observable effect, not
        // just ok==true). it may lag a beat, so poll the next display until the index moves off the open's.
        let openIndex = selectedIndex(of: display)
        var advanced: String?
        for _ in 0..<12 {
            let next = try sendCommand(#"{"cmd":"session.search","target":"active","args":{"to":"next"}}"#)
            XCTAssertEqual(next["ok"] as? Bool, true, "session.search --next should succeed: \(next)")
            if let t = (next["result"] as? [String: Any])?["text"] as? String,
               let idx = selectedIndex(of: t), idx != openIndex {
                advanced = t
                break
            }
            usleep(150_000)
        }
        let advancedDisplay = try XCTUnwrap(advanced, "session.search --next should advance the selected match index off \(display)")

        // step back: the index must return toward the open position (observable, not just ok).
        let prev = try sendCommand(#"{"cmd":"session.search","target":"active","args":{"to":"prev"}}"#)
        XCTAssertEqual(prev["ok"] as? Bool, true, "session.search --prev should succeed: \(prev)")
        if let prevText = (prev["result"] as? [String: Any])?["text"] as? String, let prevIdx = selectedIndex(of: prevText) {
            XCTAssertNotEqual(prevIdx, selectedIndex(of: advancedDisplay),
                              "--prev should move the selected index back off the --next position")
        }

        // close, then confirm search actually exited: a re-open settles a fresh count again, proving the
        // close left the surface in a clean searchable state (the tree carries no search flag, so a
        // re-search is the best available socket oracle for a successful close).
        let close = try sendCommand(#"{"cmd":"session.search","target":"active","args":{"to":"close"}}"#)
        XCTAssertEqual(close["ok"] as? Bool, true, "session.search --close should succeed: \(close)")
        var reopened: Int?
        for _ in 0..<12 {
            let reopen = try sendCommand(#"{"cmd":"session.search","target":"active","args":{"text":"\#(needle)"}}"#)
            XCTAssertEqual(reopen["ok"] as? Bool, true, "re-opening search after close should succeed: \(reopen)")
            if let c = (reopen["result"] as? [String: Any])?["count"] as? Int, c >= 1 { reopened = c; break }
            usleep(250_000)
        }
        XCTAssertNotNil(reopened, "search should still find the needle after a --close (close left a clean state)")
    }

    // a SECOND search with a DIFFERENT needle must report the NEW needle's count, not the previous
    // query's stale count. the two needles are seeded with a clearly different number of occurrences, so
    // a stale count (the bar already open → searchTotal not reset → the settle-poll breaks on the prior
    // value) would return the first needle's count and the comparison would fail.
    func testSessionSearchSecondNeedleReportsFreshCount() throws {
        let rare = "agtermRARE"     // appears few times
        let common = "agtermCOMMON" // appears many more times
        // echo rare once and common five times on one line: both render in the command line + its echoed
        // output, so common matches markedly more than rare.
        let line = "echo \(rare) \(common) \(common) \(common) \(common) \(common)\n"
        let typed = try sendCommand(typeRequest(text: line, target: nil, select: false))
        XCTAssertEqual(typed["ok"] as? Bool, true, "typing the two needles should succeed: \(typed)")

        let rareCount = try settledSearchCount(needle: rare)
        let commonCount = try settledSearchCount(needle: common)
        XCTAssertGreaterThan(commonCount, rareCount,
                             "the second search must report the common needle's (larger) count, not the rare needle's stale count")
        try sendCloseSearch()
    }

    /// Opens search for `needle` and polls until a non-zero count settles, returning it. Re-sends the
    /// needle each attempt (the echo render + the async SEARCH_TOTAL callback can lag the first call).
    private func settledSearchCount(needle: String) throws -> Int {
        for _ in 0..<24 {
            let search = try sendCommand(#"{"cmd":"session.search","target":"active","args":{"text":"\#(needle)"}}"#)
            XCTAssertEqual(search["ok"] as? Bool, true, "session.search for \(needle) should succeed: \(search)")
            if let c = (search["result"] as? [String: Any])?["count"] as? Int, c >= 1 { return c }
            usleep(250_000)
        }
        XCTFail("session.search for \(needle) never settled a non-zero count")
        return 0
    }

    private func sendCloseSearch() throws {
        _ = try sendCommand(#"{"cmd":"session.search","target":"active","args":{"to":"close"}}"#)
    }

    // invalid `to` (not next|prev|close) errors before touching the surface — the mode-bearing guard,
    // matching the sibling focus/scratch/status error arms.
    func testSessionSearchRejectsInvalidDirection() throws {
        let response = try sendCommand(#"{"cmd":"session.search","target":"active","args":{"to":"sideways"}}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "an invalid --to should fail: \(response)")
        XCTAssertEqual(response["error"] as? String, "session.search --to must be next|prev|close",
                       "should report the allowed modes: \(response)")
    }

    // an EMPTY needle clears the query: libghostty tears the search thread down (emitting no fresh count),
    // so the arm returns ok with NO count and resets the bar's counter to nil — and a subsequent non-empty
    // query must still find matches, proving the empty needle left the surface in a clean searchable state
    // rather than a broken one. seeds a token, queries it, clears, then re-queries.
    func testSessionSearchEmptyNeedleClearsThenRecovers() throws {
        let needle = "agtermCLEARME"
        let typed = try sendCommand(typeRequest(text: "echo \(needle) \(needle)\n", target: nil, select: false))
        XCTAssertEqual(typed["ok"] as? Bool, true, "typing the needle should succeed: \(typed)")

        _ = try settledSearchCount(needle: needle) // open + settle a real count first

        // clear the query with an empty needle: ok, and no count in the result (counter blanks).
        let cleared = try sendCommand(#"{"cmd":"session.search","target":"active","args":{"text":""}}"#)
        XCTAssertEqual(cleared["ok"] as? Bool, true, "an empty needle should succeed (clears the query): \(cleared)")
        let clearedResult = try XCTUnwrap(cleared["result"] as? [String: Any], "empty-needle search should carry a result")
        XCTAssertNil(clearedResult["count"], "an empty needle should report no count (the counter is cleared): \(cleared)")

        // re-query the same needle: it must find matches again (the clear didn't break search).
        let recovered = try settledSearchCount(needle: needle)
        XCTAssertGreaterThanOrEqual(recovered, 1, "search must still find the needle after an empty-needle clear")
        try sendCloseSearch()
    }

    /// The 1-based selected index from a "S of N" display string (nil for "M matches" / "no matches" /
    /// other shapes), so a nav test can assert the index moved.
    private func selectedIndex(of display: String?) -> Int? {
        guard let display, let ofRange = display.range(of: " of ") else { return nil }
        return Int(display[display.startIndex..<ofRange.lowerBound].trimmingCharacters(in: .whitespaces))
    }

    // session.go navigates the selection in the sidebar's flattened order and returns the newly-selected
    // id: seed two sessions with the first selected, then next/last/first/prev step the selection and the
    // returned id (and the persisted selectedSessionID) track it. wrap is covered by the agtermCore tests.
    func testSessionGoNavigatesSelection() throws {
        let firstID = UUID(uuidString: "EEEE0000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "FFFF0000-0000-0000-0000-000000000002")!
        let snapshot = """
        {"version":1,"selectedSessionID":"\(firstID.uuidString)","workspaces":[\
        {"id":"\(UUID().uuidString)","name":"workspace 1","sessions":[\
        {"id":"\(firstID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"},\
        {"id":"\(secondID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"}]}]}
        """
        try relaunch(withSnapshot: snapshot)

        // next: first -> second; the response carries the second's id and it becomes active.
        let next = try sendCommand(#"{"cmd":"session.go","args":{"to":"next"}}"#)
        XCTAssertEqual(next["ok"] as? Bool, true, "session.go next should succeed: \(next)")
        XCTAssertEqual(((next["result"] as? [String: Any])?["id"] as? String)?.lowercased(),
                       secondID.uuidString.lowercased(), "next should select the second session: \(next)")
        XCTAssertTrue(pollActiveSessionID(secondID, timeout: 10), "the second session should become active")

        // first: jumps to the first session.
        let first = try sendCommand(#"{"cmd":"session.go","args":{"to":"first"}}"#)
        XCTAssertEqual(first["ok"] as? Bool, true, "session.go first should succeed: \(first)")
        XCTAssertEqual(((first["result"] as? [String: Any])?["id"] as? String)?.lowercased(),
                       firstID.uuidString.lowercased(), "first should select the first session: \(first)")
        XCTAssertTrue(pollActiveSessionID(firstID, timeout: 10), "the first session should become active")

        // last: jumps to the last (second) session.
        let last = try sendCommand(#"{"cmd":"session.go","args":{"to":"last"}}"#)
        XCTAssertEqual(last["ok"] as? Bool, true, "session.go last should succeed: \(last)")
        XCTAssertEqual(((last["result"] as? [String: Any])?["id"] as? String)?.lowercased(),
                       secondID.uuidString.lowercased(), "last should select the last session: \(last)")
        XCTAssertTrue(pollActiveSessionID(secondID, timeout: 10), "the last session should become active")
    }

    // session.go with an unknown direction returns the structured guard and does not change the selection.
    func testSessionGoInvalidDirectionErrors() throws {
        let response = try sendCommand(#"{"cmd":"session.go","args":{"to":"sideways"}}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "an invalid direction should fail: \(response)")
        XCTAssertEqual(response["error"] as? String, "session.go requires --to next|prev|first|last|next-attention|prev-attention",
                       "should return the direction guard: \(response)")
    }

    // session.go next-attention/prev-attention steps only through sessions needing attention (blocked or
    // completed), wrapping. seed three sessions (first selected, idle), mark the 2nd blocked and the 3rd
    // completed, then next-attention skips idle sessions, lands on each attention session, and wraps.
    func testSessionGoNavigatesAttentionSessions() throws {
        let firstID = UUID(uuidString: "AAAA0000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "BBBB0000-0000-0000-0000-000000000002")!
        let thirdID = UUID(uuidString: "CCCC0000-0000-0000-0000-000000000003")!
        let snapshot = """
        {"version":1,"selectedSessionID":"\(firstID.uuidString)","workspaces":[\
        {"id":"\(UUID().uuidString)","name":"workspace 1","sessions":[\
        {"id":"\(firstID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"},\
        {"id":"\(secondID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"},\
        {"id":"\(thirdID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"}]}]}
        """
        try relaunch(withSnapshot: snapshot)

        // mark the 2nd blocked and the 3rd completed; the selected 1st stays idle.
        let s2 = try sendCommand(#"{"cmd":"session.status","target":"\#(secondID.uuidString)","args":{"status":"blocked"}}"#)
        XCTAssertEqual(s2["ok"] as? Bool, true, "set blocked status: \(s2)")
        let s3 = try sendCommand(#"{"cmd":"session.status","target":"\#(thirdID.uuidString)","args":{"status":"completed"}}"#)
        XCTAssertEqual(s3["ok"] as? Bool, true, "set completed status: \(s3)")

        // next-attention from the idle first session skips to the blocked second.
        let n1 = try sendCommand(#"{"cmd":"session.go","args":{"to":"next-attention"}}"#)
        XCTAssertEqual(n1["ok"] as? Bool, true, "next-attention should succeed: \(n1)")
        XCTAssertEqual(((n1["result"] as? [String: Any])?["id"] as? String)?.lowercased(),
                       secondID.uuidString.lowercased(), "next-attention lands on the blocked session: \(n1)")
        XCTAssertTrue(pollActiveSessionID(secondID, timeout: 10), "the blocked session becomes active")

        // again -> the completed third.
        let n2 = try sendCommand(#"{"cmd":"session.go","args":{"to":"next-attention"}}"#)
        XCTAssertEqual(((n2["result"] as? [String: Any])?["id"] as? String)?.lowercased(),
                       thirdID.uuidString.lowercased(), "next-attention lands on the completed session: \(n2)")
        XCTAssertTrue(pollActiveSessionID(thirdID, timeout: 10), "the completed session becomes active")

        // wraps forward back to the blocked second.
        let n3 = try sendCommand(#"{"cmd":"session.go","args":{"to":"next-attention"}}"#)
        XCTAssertEqual(((n3["result"] as? [String: Any])?["id"] as? String)?.lowercased(),
                       secondID.uuidString.lowercased(), "next-attention wraps to the blocked session: \(n3)")
        XCTAssertTrue(pollActiveSessionID(secondID, timeout: 10), "wrapped to the blocked session")
    }

    // quick toggle makes the quick-terminal accessibility element appear, and toggling again hides it.
    func testQuickTerminalToggle() throws {
        let quick = app.descendants(matching: .any).matching(identifier: "quick-terminal").firstMatch
        XCTAssertFalse(quick.exists, "quick terminal should start hidden")

        let shown = try sendCommand(#"{"cmd":"quick","args":{"mode":"toggle"}}"#)
        XCTAssertEqual(shown["ok"] as? Bool, true, "quick toggle should succeed: \(shown)")
        XCTAssertTrue(quick.waitForExistence(timeout: 10), "quick terminal should appear")

        let hidden = try sendCommand(#"{"cmd":"quick","args":{"mode":"hide"}}"#)
        XCTAssertEqual(hidden["ok"] as? Bool, true, "quick hide should succeed: \(hidden)")
        XCTAssertTrue(waitForDisappearance(quick, timeout: 10), "quick terminal should hide")
    }

    // font.inc on the realized active session returns ok.
    func testFontIncreaseSucceeds() throws {
        let response = try sendCommand(#"{"cmd":"font.inc","target":"active"}"#)
        XCTAssertEqual(response["ok"] as? Bool, true, "font.inc on the active session should succeed: \(response)")
    }

    // an invalid mode returns an error and does NOT flip state.
    func testInvalidQuickModeErrors() throws {
        let quick = app.descendants(matching: .any).matching(identifier: "quick-terminal").firstMatch
        XCTAssertFalse(quick.exists, "quick terminal should start hidden")

        let response = try sendCommand(#"{"cmd":"quick","args":{"mode":"bogus"}}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "an invalid quick mode should fail")
        let error = try XCTUnwrap(response["error"] as? String, "an invalid mode should carry an error")
        XCTAssertTrue(error.contains("invalid quick mode"), "should report the invalid mode, got: \(error)")
        // state must not have flipped.
        XCTAssertFalse(quick.exists, "an invalid mode must leave the quick terminal hidden")
    }

    // quick.type before the overlay has ever been shown errors (not a silent drop); once shown, a typed
    // marker reads back off the quick terminal's own buffer via quick.text.
    func testQuickTypeAndReadText() throws {
        let quick = app.descendants(matching: .any).matching(identifier: "quick-terminal").firstMatch
        XCTAssertFalse(quick.exists, "quick terminal should start hidden")

        let closed = try sendCommand(#"{"cmd":"quick.type","args":{"text":"x"}}"#)
        XCTAssertEqual(closed["ok"] as? Bool, false, "quick.type before show should fail: \(closed)")
        XCTAssertEqual(closed["error"] as? String, "quick terminal not open", "should report the closed overlay")

        // show, then IMMEDIATELY type once — no waitForExistence, no retry. The server-side realize poll
        // must ride out the SwiftUI mount so this first post-show type lands, which is what proves the
        // show->type race is fixed (a regression that dropped the poll would return "not realized" here).
        let shown = try sendCommand(#"{"cmd":"quick","args":{"mode":"show"}}"#)
        XCTAssertEqual(shown["ok"] as? Bool, true, "quick show should succeed: \(shown)")
        let typed = try sendCommand(#"{"cmd":"quick.type","args":{"text":"QUICKPROBE"}}"#)
        XCTAssertEqual(typed["ok"] as? Bool, true, "a single quick.type right after quick show must land via the realize poll: \(typed)")

        // read the typed marker back off the quick surface, polling only for the shell echo to render (a
        // no-newline marker, so it stays on the prompt line and never executes).
        var readBack: String?
        for _ in 0..<20 {
            let response = try sendCommand(#"{"cmd":"quick.text","args":{"all":true}}"#)
            if let text = (response["result"] as? [String: Any])?["text"] as? String, text.contains("QUICKPROBE") {
                readBack = text
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        XCTAssertNotNil(readBack, "quick.text should read the typed marker back")
    }

    // session.select by a UNIQUE prefix of a session id resolves to that session: seed two sessions with
    // distinct id prefixes, select the second by a prefix unique to it, and assert the tree marks it active.
    func testSessionSelectByUniquePrefix() throws {
        let firstID = UUID(uuidString: "AAAA0000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "BBBB0000-0000-0000-0000-000000000002")!
        let snapshot = """
        {"version":1,"selectedSessionID":"\(firstID.uuidString)","workspaces":[\
        {"id":"\(UUID().uuidString)","name":"workspace 1","sessions":[\
        {"id":"\(firstID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"},\
        {"id":"\(secondID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"}]}]}
        """
        try relaunch(withSnapshot: snapshot)

        // "bbbb" is unique to the second session.
        let response = try sendCommand(#"{"cmd":"session.select","target":"bbbb"}"#)
        XCTAssertEqual(response["ok"] as? Bool, true, "select by unique prefix should succeed: \(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any], "select should carry a result")
        XCTAssertEqual((result["id"] as? String)?.lowercased(), secondID.uuidString.lowercased(),
                       "select should resolve the unique prefix to the second session: \(response)")
        XCTAssertTrue(pollActiveSessionID(secondID, timeout: 10), "the second session should become active")
    }

    // an ambiguous-prefix request returns the `ambiguous` error listing the candidate ids and changes nothing:
    // seed two sessions whose ids share a prefix, then select by that shared prefix.
    func testSessionSelectAmbiguousPrefixErrors() throws {
        let firstID = UUID(uuidString: "ABCD1111-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "ABCD2222-0000-0000-0000-000000000002")!
        let snapshot = """
        {"version":1,"selectedSessionID":"\(firstID.uuidString)","workspaces":[\
        {"id":"\(UUID().uuidString)","name":"workspace 1","sessions":[\
        {"id":"\(firstID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"},\
        {"id":"\(secondID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"}]}]}
        """
        try relaunch(withSnapshot: snapshot)

        // "abcd" matches both sessions.
        let response = try sendCommand(#"{"cmd":"session.select","target":"abcd"}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "an ambiguous prefix should fail")
        let error = try XCTUnwrap(response["error"] as? String, "an ambiguous prefix should carry an error")
        XCTAssertEqual(error, "ambiguous session prefix 'abcd' → ABCD1111, ABCD2222",
                       "should report the exact ambiguous-prefix wire string")
        // selection must be unchanged (the originally-selected first session stays active).
        XCTAssertTrue(pollActiveSessionID(firstID, timeout: 5), "an ambiguous select must not change the active session")
    }

    // `active` targeting with no explicit id works end-to-end: session.rename with the default `active` target
    // renames the currently selected session — verified via the name in workspaces.json.
    func testActiveTargetingWithNoExplicitID() throws {
        let response = try sendCommand(#"{"cmd":"session.rename","args":{"name":"active-renamed"}}"#)
        XCTAssertEqual(response["ok"] as? Bool, true, "rename of the active session should succeed: \(response)")
        XCTAssertTrue(pollFirstSessionName("active-renamed", timeout: 10),
                      "the active (seeded) session should be renamed via the default active target")
    }

    // session.move relocates a session to another workspace: create a second workspace, move the seeded
    // session into it, and assert (via json) workspace 1 is empty and the destination holds the session.
    func testSessionMoveToAnotherWorkspace() throws {
        let created = try sendCommand(#"{"cmd":"workspace.new","args":{"name":"dest ws"}}"#)
        let result = try XCTUnwrap(created["result"] as? [String: Any], "workspace.new should carry a result")
        let destID = try XCTUnwrap(result["id"] as? String, "workspace.new should return the new id")
        XCTAssertTrue(pollWorkspaceNames(["workspace 1", "dest ws"], timeout: 10), "the destination workspace should exist")

        // move the active (seeded) session into the new workspace.
        let moved = try sendCommand(#"{"cmd":"session.move","target":"active","args":{"workspace":"\#(destID)"}}"#)
        XCTAssertEqual(moved["ok"] as? Bool, true, "session.move should succeed: \(moved)")
        XCTAssertTrue(pollSessionCounts([0, 1], timeout: 10),
                      "the session should leave workspace 1 (0) and land in the destination (1)")
    }

    // session.move with neither --to nor a workspace returns the structured missing-arg guard.
    func testSessionMoveRequiresWorkspace() throws {
        let response = try sendCommand(#"{"cmd":"session.move","target":"active"}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "session.move without --to or a workspace should fail")
        XCTAssertEqual(response["error"] as? String, "session.move requires --to or a workspace", "should return the guard: \(response)")
    }

    // session.move with BOTH --to and a workspace is ambiguous and returns the either/or guard.
    func testSessionMoveBothToAndWorkspaceErrors() throws {
        let response = try sendCommand(#"{"cmd":"session.move","target":"active","args":{"to":"up","workspace":"active"}}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "session.move with both --to and a workspace should fail")
        XCTAssertEqual(response["error"] as? String, "session.move takes either --to or a workspace, not both",
                       "should return the either/or guard: \(response)")
    }

    // session.move with an invalid --to direction returns the direction guard.
    func testSessionMoveInvalidDirectionErrors() throws {
        let response = try sendCommand(#"{"cmd":"session.move","target":"active","args":{"to":"sideways"}}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "an invalid direction should fail: \(response)")
        XCTAssertEqual(response["error"] as? String, "session.move --to must be up|down|top|bottom",
                       "should return the direction guard: \(response)")
    }

    // workspace.move without --to returns the structured missing-arg guard.
    func testWorkspaceMoveRequiresTo() throws {
        let response = try sendCommand(#"{"cmd":"workspace.move","target":"active"}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "workspace.move without --to should fail")
        XCTAssertEqual(response["error"] as? String, "workspace.move requires --to",
                       "should return the missing-arg guard: \(response)")
    }

    // workspace.move with an invalid --to direction returns the direction guard.
    func testWorkspaceMoveInvalidDirectionErrors() throws {
        let response = try sendCommand(#"{"cmd":"workspace.move","target":"active","args":{"to":"sideways"}}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "an invalid direction should fail: \(response)")
        XCTAssertEqual(response["error"] as? String, "workspace.move --to must be up|down|top|bottom",
                       "should return the direction guard: \(response)")
    }

    // session.move --to reorders a session within its own workspace: seed three sessions in order,
    // move the last UP one step (B,A,C... ) and then the first to the TOP; assert the json order tracks it.
    func testSessionMoveReorderWithinWorkspace() throws {
        let firstID = UUID(uuidString: "A1110000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "A2220000-0000-0000-0000-000000000002")!
        let thirdID = UUID(uuidString: "A3330000-0000-0000-0000-000000000003")!
        let snapshot = """
        {"version":1,"selectedSessionID":"\(firstID.uuidString)","workspaces":[\
        {"id":"\(UUID().uuidString)","name":"workspace 1","sessions":[\
        {"id":"\(firstID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"},\
        {"id":"\(secondID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"},\
        {"id":"\(thirdID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"}]}]}
        """
        try relaunch(withSnapshot: snapshot)
        XCTAssertTrue(pollSessionOrder([firstID, secondID, thirdID], timeout: 10), "should start in seeded order")

        // move the third session up one step: [first, second, third] -> [first, third, second].
        let up = try sendCommand(#"{"cmd":"session.move","target":"\#(thirdID.uuidString)","args":{"to":"up"}}"#)
        XCTAssertEqual(up["ok"] as? Bool, true, "session.move --to up should succeed: \(up)")
        XCTAssertTrue(pollSessionOrder([firstID, thirdID, secondID], timeout: 10), "up should swap third above second")

        // move the first session to the top of the (now [first, third, second]) list — already top -> no-op,
        // so move it to the bottom to prove a non-trivial reorder, then top again to land it back at index 0.
        let bottom = try sendCommand(#"{"cmd":"session.move","target":"\#(firstID.uuidString)","args":{"to":"bottom"}}"#)
        XCTAssertEqual(bottom["ok"] as? Bool, true, "session.move --to bottom should succeed: \(bottom)")
        XCTAssertTrue(pollSessionOrder([thirdID, secondID, firstID], timeout: 10), "bottom should move first to the end")

        let top = try sendCommand(#"{"cmd":"session.move","target":"\#(firstID.uuidString)","args":{"to":"top"}}"#)
        XCTAssertEqual(top["ok"] as? Bool, true, "session.move --to top should succeed: \(top)")
        XCTAssertTrue(pollSessionOrder([firstID, thirdID, secondID], timeout: 10), "top should move first back to index 0")
    }

    // session.move --after/--before repositions a session within its own workspace in one round-trip
    // (no visible step-by-step shuffle): seed three ordered sessions, place one after a distant anchor
    // and another before an anchor, asserting the json order tracks each placement.
    func testSessionMovePlaceWithinWorkspace() throws {
        let firstID = UUID(uuidString: "B1110000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "B2220000-0000-0000-0000-000000000002")!
        let thirdID = UUID(uuidString: "B3330000-0000-0000-0000-000000000003")!
        let snapshot = """
        {"version":1,"selectedSessionID":"\(firstID.uuidString)","workspaces":[\
        {"id":"\(UUID().uuidString)","name":"workspace 1","sessions":[\
        {"id":"\(firstID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"},\
        {"id":"\(secondID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"},\
        {"id":"\(thirdID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"}]}]}
        """
        try relaunch(withSnapshot: snapshot)
        XCTAssertTrue(pollSessionOrder([firstID, secondID, thirdID], timeout: 10), "should start in seeded order")

        // place the third session right after the first: [first, second, third] -> [first, third, second].
        let after = try sendCommand(#"{"cmd":"session.move","target":"\#(thirdID.uuidString)","args":{"after":"\#(firstID.uuidString)"}}"#)
        XCTAssertEqual(after["ok"] as? Bool, true, "session.move --after should succeed: \(after)")
        XCTAssertTrue(pollSessionOrder([firstID, thirdID, secondID], timeout: 10), "after should place third right after first")

        // place the first session right before the second: [first, third, second] -> [third, first, second].
        let before = try sendCommand(#"{"cmd":"session.move","target":"\#(firstID.uuidString)","args":{"before":"\#(secondID.uuidString)"}}"#)
        XCTAssertEqual(before["ok"] as? Bool, true, "session.move --before should succeed: \(before)")
        XCTAssertTrue(pollSessionOrder([thirdID, firstID, secondID], timeout: 10), "before should place first right before second")
    }

    // session.move with multiple targets removes the whole block first, then inserts it at the
    // post-removal slot. A loop over single moves would need to recompute the anchor after each call.
    func testSessionMoveMultipleTargetsWithinWorkspaceBeforeAnchor() throws {
        let firstID = UUID(uuidString: "BB100000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "BB200000-0000-0000-0000-000000000002")!
        let thirdID = UUID(uuidString: "BB300000-0000-0000-0000-000000000003")!
        let fourthID = UUID(uuidString: "BB400000-0000-0000-0000-000000000004")!
        let fifthID = UUID(uuidString: "BB500000-0000-0000-0000-000000000005")!
        let snapshot = """
        {"version":1,"selectedSessionID":"\(firstID.uuidString)","workspaces":[\
        {"id":"\(UUID().uuidString)","name":"workspace 1","sessions":[\
        {"id":"\(firstID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"},\
        {"id":"\(secondID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"},\
        {"id":"\(thirdID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"},\
        {"id":"\(fourthID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"},\
        {"id":"\(fifthID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"}]}]}
        """
        try relaunch(withSnapshot: snapshot)

        let moved = try sendCommand(#"{"cmd":"session.move","args":{"targets":["\#(firstID.uuidString)","\#(secondID.uuidString)"],"before":"\#(fifthID.uuidString)"}}"#)
        XCTAssertEqual(moved["ok"] as? Bool, true, "batch session.move --before should succeed: \(moved)")
        XCTAssertEqual((moved["result"] as? [String: Any])?["affected"] as? Int, 2,
                       "batch move should report the sessions actually moved")
        XCTAssertTrue(pollSessionOrder([thirdID, fourthID, firstID, secondID, fifthID], timeout: 10),
                      "the batch should land before fifth after removing both moved rows first")
    }

    // A destination member in a multi-target request stays in place and is not counted. A one-element
    // args.targets request remains wire-equivalent to singular move and appends within the same workspace.
    func testSessionMoveBatchReportsActualAffectedAndNormalizesOneTarget() throws {
        let wsOneID = UUID(uuidString: "BC100000-0000-0000-0000-000000000001")!
        let wsTwoID = UUID(uuidString: "BC200000-0000-0000-0000-000000000002")!
        let aID = UUID(uuidString: "BC300000-0000-0000-0000-000000000003")!
        let bID = UUID(uuidString: "BC400000-0000-0000-0000-000000000004")!
        let cID = UUID(uuidString: "BC500000-0000-0000-0000-000000000005")!
        let snapshot = """
        {"version":1,"selectedSessionID":"\(aID.uuidString)","workspaces":[\
        {"id":"\(wsOneID.uuidString)","name":"one","sessions":[\
        {"id":"\(aID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"}]},\
        {"id":"\(wsTwoID.uuidString)","name":"two","sessions":[\
        {"id":"\(bID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"},\
        {"id":"\(cID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"}]}]}
        """
        try relaunch(withSnapshot: snapshot)

        let batch = try sendCommand(#"{"cmd":"session.move","args":{"targets":["\#(aID.uuidString)","\#(bID.uuidString)"],"workspace":"\#(wsTwoID.uuidString)"}}"#)
        XCTAssertEqual(batch["ok"] as? Bool, true, "mixed batch move should succeed: \(batch)")
        XCTAssertEqual((batch["result"] as? [String: Any])?["affected"] as? Int, 1,
                       "only the cross-workspace session should count as affected")
        XCTAssertTrue(pollSessionOrder(inWorkspace: 1, equals: [bID, cID, aID], timeout: 10))

        let oneTarget = try sendCommand(#"{"cmd":"session.move","args":{"targets":["\#(bID.uuidString)"],"workspace":"\#(wsTwoID.uuidString)"}}"#)
        XCTAssertEqual(oneTarget["ok"] as? Bool, true, "one-target array move should succeed: \(oneTarget)")
        XCTAssertEqual((oneTarget["result"] as? [String: Any])?["id"] as? String, bID.uuidString,
                       "one-target args.targets should return the singular response shape")
        XCTAssertNil((oneTarget["result"] as? [String: Any])?["affected"])
        XCTAssertTrue(pollSessionOrder(inWorkspace: 1, equals: [cID, aID, bID], timeout: 10),
                      "one-target args.targets should append like singular session.move")
    }

    // session.move --after with an anchor in ANOTHER workspace relocates the session to the anchor's
    // workspace AND positions it at the right slot in one round-trip (the anchor carries its own workspace).
    func testSessionMovePlaceCrossWorkspace() throws {
        let aID = UUID(uuidString: "C1110000-0000-0000-0000-000000000001")!
        let bID = UUID(uuidString: "C2220000-0000-0000-0000-000000000002")!
        let xID = UUID(uuidString: "C3330000-0000-0000-0000-000000000003")!
        let yID = UUID(uuidString: "C4440000-0000-0000-0000-000000000004")!
        let snapshot = """
        {"version":1,"selectedSessionID":"\(aID.uuidString)","workspaces":[\
        {"id":"\(UUID().uuidString)","name":"ws one","sessions":[\
        {"id":"\(aID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"},\
        {"id":"\(bID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"}]},\
        {"id":"\(UUID().uuidString)","name":"ws two","sessions":[\
        {"id":"\(xID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"},\
        {"id":"\(yID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"}]}]}
        """
        try relaunch(withSnapshot: snapshot)
        XCTAssertTrue(pollSessionCounts([2, 2], timeout: 10), "should start with two sessions per workspace")

        // move B (in ws one) right after X (in ws two): ws one -> [A], ws two -> [X, B, Y].
        let moved = try sendCommand(#"{"cmd":"session.move","target":"\#(bID.uuidString)","args":{"after":"\#(xID.uuidString)"}}"#)
        XCTAssertEqual(moved["ok"] as? Bool, true, "cross-workspace session.move --after should succeed: \(moved)")
        XCTAssertTrue(pollSessionCounts([1, 3], timeout: 10), "B should leave ws one (1) and land in ws two (3)")
        XCTAssertTrue(pollSessionOrder(inWorkspace: 1, equals: [xID, bID, yID], timeout: 10),
                      "B should land right after X in ws two")
    }

    // session.new --after/--before creates a session at the chosen slot in one round-trip, returning the
    // new id in result.id; assert both the placement (json order) and that the returned id is the new one.
    func testSessionNewPlaceRelativeToAnchor() throws {
        let firstID = UUID(uuidString: "D1110000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "D2220000-0000-0000-0000-000000000002")!
        let thirdID = UUID(uuidString: "D3330000-0000-0000-0000-000000000003")!
        let snapshot = """
        {"version":1,"selectedSessionID":"\(firstID.uuidString)","workspaces":[\
        {"id":"\(UUID().uuidString)","name":"workspace 1","sessions":[\
        {"id":"\(firstID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"},\
        {"id":"\(secondID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"},\
        {"id":"\(thirdID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"}]}]}
        """
        try relaunch(withSnapshot: snapshot)
        XCTAssertTrue(pollSessionOrder([firstID, secondID, thirdID], timeout: 10), "should start in seeded order")

        // create right after the first session: [first, NEW, second, third].
        let afterResp = try sendCommand(#"{"cmd":"session.new","args":{"after":"\#(firstID.uuidString)"}}"#)
        XCTAssertEqual(afterResp["ok"] as? Bool, true, "session.new --after should succeed: \(afterResp)")
        let afterID = try XCTUnwrap(((afterResp["result"] as? [String: Any])?["id"] as? String).flatMap(UUID.init(uuidString:)),
                                    "session.new should return the new id: \(afterResp)")
        XCTAssertTrue(pollSessionOrder([firstID, afterID, secondID, thirdID], timeout: 10),
                      "the new session should land right after first")

        // create right before the third session: [first, NEW1, second, NEW2, third].
        let beforeResp = try sendCommand(#"{"cmd":"session.new","args":{"before":"\#(thirdID.uuidString)"}}"#)
        XCTAssertEqual(beforeResp["ok"] as? Bool, true, "session.new --before should succeed: \(beforeResp)")
        let beforeID = try XCTUnwrap(((beforeResp["result"] as? [String: Any])?["id"] as? String).flatMap(UUID.init(uuidString:)),
                                     "session.new should return the new id: \(beforeResp)")
        XCTAssertTrue(pollSessionOrder([firstID, afterID, secondID, beforeID, thirdID], timeout: 10),
                      "the new session should land right before third")
    }

    // session.new --after with an anchor in ANOTHER workspace creates the new session in the anchor's
    // workspace (not the active one) at the right slot — the "anchor carries its own workspace" claim for
    // session.new, which a single-workspace snapshot can't distinguish from currentWorkspaceID.
    func testSessionNewPlaceCrossWorkspace() throws {
        let aID = UUID(uuidString: "E1110000-0000-0000-0000-000000000001")!
        let bID = UUID(uuidString: "E2220000-0000-0000-0000-000000000002")!
        let xID = UUID(uuidString: "E3330000-0000-0000-0000-000000000003")!
        let yID = UUID(uuidString: "E4440000-0000-0000-0000-000000000004")!
        let snapshot = """
        {"version":1,"selectedSessionID":"\(aID.uuidString)","workspaces":[\
        {"id":"\(UUID().uuidString)","name":"ws one","sessions":[\
        {"id":"\(aID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"},\
        {"id":"\(bID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"}]},\
        {"id":"\(UUID().uuidString)","name":"ws two","sessions":[\
        {"id":"\(xID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"},\
        {"id":"\(yID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"}]}]}
        """
        try relaunch(withSnapshot: snapshot)
        XCTAssertTrue(pollSessionCounts([2, 2], timeout: 10), "should start with two sessions per workspace")

        // create right after X (in ws two) while the active session A is in ws one: the new session must
        // land in ws two (the anchor's workspace), not ws one: ws one -> [A, B], ws two -> [X, NEW, Y].
        let resp = try sendCommand(#"{"cmd":"session.new","args":{"after":"\#(xID.uuidString)"}}"#)
        XCTAssertEqual(resp["ok"] as? Bool, true, "cross-workspace session.new --after should succeed: \(resp)")
        let newID = try XCTUnwrap(((resp["result"] as? [String: Any])?["id"] as? String).flatMap(UUID.init(uuidString:)),
                                  "session.new should return the new id: \(resp)")
        XCTAssertTrue(pollSessionCounts([2, 3], timeout: 10), "the new session should land in ws two (3), ws one unchanged (2)")
        XCTAssertTrue(pollSessionOrder(inWorkspace: 1, equals: [xID, newID, yID], timeout: 10),
                      "the new session should land right after X in ws two")
    }

    // session.move rejects --after + --before together with the either/or guard.
    func testSessionMovePlaceRejectsAfterAndBefore() throws {
        let response = try sendCommand(#"{"cmd":"session.move","target":"active","args":{"after":"active","before":"active"}}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "--after + --before should fail")
        XCTAssertEqual(response["error"] as? String, "use either --after or --before, not both",
                       "should return the either/or guard: \(response)")
    }

    // session.move rejects a placement anchor combined with --to (the anchor already names the slot).
    func testSessionMovePlaceRejectsAfterAndTo() throws {
        let response = try sendCommand(#"{"cmd":"session.move","target":"active","args":{"after":"active","to":"up"}}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "--after + --to should fail")
        XCTAssertEqual(response["error"] as? String, "session.move takes --after/--before or --to, not both",
                       "should return the placement/--to guard: \(response)")
    }

    // session.move rejects a placement anchor combined with a workspace (the anchor carries its workspace).
    func testSessionMovePlaceRejectsAfterAndWorkspace() throws {
        let response = try sendCommand(#"{"cmd":"session.move","target":"active","args":{"after":"active","workspace":"active"}}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "--after + a workspace should fail")
        XCTAssertEqual(response["error"] as? String, "session.move takes --after/--before or a workspace, not both",
                       "should return the placement/workspace guard: \(response)")
    }

    // session.new rejects --after + --before together, and a placement anchor combined with a workspace.
    func testSessionNewPlaceRejectsConflicts() throws {
        let both = try sendCommand(#"{"cmd":"session.new","args":{"after":"active","before":"active"}}"#)
        XCTAssertEqual(both["ok"] as? Bool, false, "--after + --before should fail")
        XCTAssertEqual(both["error"] as? String, "use either --after or --before, not both",
                       "should return the either/or guard: \(both)")

        let withWorkspace = try sendCommand(#"{"cmd":"session.new","args":{"after":"active","workspace":"active"}}"#)
        XCTAssertEqual(withWorkspace["ok"] as? Bool, false, "--after + a workspace should fail")
        XCTAssertEqual(withWorkspace["error"] as? String, "session.new takes --after/--before or a workspace, not both",
                       "should return the placement/workspace guard: \(withWorkspace)")
    }

    // workspace.move --to reorders a workspace among its siblings: seed three workspaces, move the last
    // to the top and then one up; assert the json workspace-name order tracks it.
    func testWorkspaceMoveReorder() throws {
        let snapshot = """
        {"version":1,"selectedSessionID":null,"workspaces":[\
        {"id":"\(UUID().uuidString)","name":"alpha","sessions":[\
        {"id":"\(UUID().uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"}]},\
        {"id":"\(UUID().uuidString)","name":"beta","sessions":[\
        {"id":"\(UUID().uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"}]},\
        {"id":"\(UUID().uuidString)","name":"gamma","sessions":[\
        {"id":"\(UUID().uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"}]}]}
        """
        try relaunch(withSnapshot: snapshot)
        XCTAssertTrue(pollWorkspaceNames(["alpha", "beta", "gamma"], timeout: 10), "should start in seeded order")

        // capture gamma's id (the last workspace) from the tree, then move it to the top.
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let treeResult = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let root = try XCTUnwrap(treeResult["tree"] as? [String: Any], "result should carry a tree")
        let workspaces = try XCTUnwrap(root["workspaces"] as? [[String: Any]], "tree should list workspaces")
        let gammaID = try XCTUnwrap(workspaces.first(where: { ($0["name"] as? String) == "gamma" })?["id"] as? String,
                                    "should find gamma's id")

        let top = try sendCommand(#"{"cmd":"workspace.move","target":"\#(gammaID)","args":{"to":"top"}}"#)
        XCTAssertEqual(top["ok"] as? Bool, true, "workspace.move --to top should succeed: \(top)")
        XCTAssertTrue(pollWorkspaceNames(["gamma", "alpha", "beta"], timeout: 10), "top should move gamma to index 0")

        // move gamma down one step: [gamma, alpha, beta] -> [alpha, gamma, beta].
        let down = try sendCommand(#"{"cmd":"workspace.move","target":"\#(gammaID)","args":{"to":"down"}}"#)
        XCTAssertEqual(down["ok"] as? Bool, true, "workspace.move --to down should succeed: \(down)")
        XCTAssertTrue(pollWorkspaceNames(["alpha", "gamma", "beta"], timeout: 10), "down should move gamma below alpha")
    }

    // session.rename with no name arg returns the structured missing-arg guard.
    func testSessionRenameRequiresName() throws {
        let response = try sendCommand(#"{"cmd":"session.rename","target":"active"}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "session.rename without a name should fail")
        XCTAssertEqual(response["error"] as? String, "session.rename requires a name", "should return the guard: \(response)")
    }

    // workspace.select selects a workspace's first session: create a second workspace with a session,
    // select that workspace by id, and assert its session becomes active.
    func testWorkspaceSelect() throws {
        let firstID = UUID(uuidString: "CCCC0000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "DDDD0000-0000-0000-0000-000000000002")!
        let secondWorkspaceID = UUID()
        let snapshot = """
        {"version":1,"selectedSessionID":"\(firstID.uuidString)","workspaces":[\
        {"id":"\(UUID().uuidString)","name":"workspace 1","sessions":[\
        {"id":"\(firstID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"}]},\
        {"id":"\(secondWorkspaceID.uuidString)","name":"workspace 2","sessions":[\
        {"id":"\(secondID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"}]}]}
        """
        try relaunch(withSnapshot: snapshot)

        let response = try sendCommand(#"{"cmd":"workspace.select","target":"\#(secondWorkspaceID.uuidString)"}"#)
        XCTAssertEqual(response["ok"] as? Bool, true, "workspace.select should succeed: \(response)")
        XCTAssertTrue(pollActiveSessionID(secondID, timeout: 10),
                      "selecting workspace 2 should make its first session active")
    }

    // font.dec and font.reset on the realized active session return ok.
    func testFontDecreaseAndResetSucceed() throws {
        let dec = try sendCommand(#"{"cmd":"font.dec","target":"active"}"#)
        XCTAssertEqual(dec["ok"] as? Bool, true, "font.dec on the active session should succeed: \(dec)")

        let reset = try sendCommand(#"{"cmd":"font.reset","target":"active"}"#)
        XCTAssertEqual(reset["ok"] as? Bool, true, "font.reset on the active session should succeed: \(reset)")
    }

    // MARK: - Version

    // version and the tree's app are two projections of one AppIdentity, so they must agree, and version
    // must answer without resolving a window.
    func testVersionReportsTheServingAppAndMatchesTheTree() throws {
        let response = try sendCommand(#"{"cmd":"version"}"#)
        XCTAssertEqual(response["ok"] as? Bool, true, "version should succeed: \(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any], "version should carry a result")
        let app = try XCTUnwrap(result["app"] as? [String: Any], "version should carry an app identity: \(response)")
        let version = try XCTUnwrap(app["version"] as? String, "the identity should carry a version: \(app)")
        XCTAssertFalse(version.isEmpty, "the version should not be empty: \(app)")

        let tree = try XCTUnwrap(try sendCommand(#"{"cmd":"tree"}"#)["result"] as? [String: Any],
                                 "tree should carry a result")
        let treeApp = try XCTUnwrap((tree["tree"] as? [String: Any])?["app"] as? [String: Any],
                                    "the tree top level should carry the same app identity")
        XCTAssertEqual(treeApp["version"] as? String, version, "the two projections must agree: \(treeApp)")
        XCTAssertEqual(treeApp["commit"] as? String, app["commit"] as? String,
                       "the commit must come from the same identity: \(treeApp)")
    }

    // app-global: a target and a window selector are ignored rather than resolved or rejected.
    func testVersionIgnoresTargetAndWindow() throws {
        let response = try sendCommand(#"{"cmd":"version","target":"active","args":{"window":"nope"}}"#)
        XCTAssertEqual(response["ok"] as? Bool, true, "version should ignore addressing: \(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any], "version should carry a result")
        XCTAssertNotNil(result["app"], "the identity should come back regardless of addressing: \(response)")
    }

    // MARK: - Keymap

    // keymap.reload re-reads keymap.conf and returns the parse-diagnostic count. With no keymap file
    // seeded (the auto-created starter is all comments), a reload reports zero diagnostics.
    func testKeymapReloadReportsZeroDiagnostics() throws {
        let response = try sendCommand(#"{"cmd":"keymap.reload"}"#)
        XCTAssertEqual(response["ok"] as? Bool, true, "keymap.reload should succeed: \(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any], "keymap.reload should carry a result")
        XCTAssertEqual(result["count"] as? Int, 0, "the all-comment starter keymap should have no diagnostics: \(response)")
    }

    // a keymap.conf with a broken line seeded under <stateDir>/config surfaces in the diagnostic count
    // keymap.reload returns: relaunch with the broken file in place (so the starter isn't created over
    // it), then keymap.reload reports a non-zero count.
    func testKeymapReloadReportsDiagnosticsForBrokenFile() throws {
        try relaunch(withKeymap: "bogus verb here\n")
        let response = try sendCommand(#"{"cmd":"keymap.reload"}"#)
        XCTAssertEqual(response["ok"] as? Bool, true, "keymap.reload should succeed even with a broken file: \(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any], "keymap.reload should carry a result")
        let count = try XCTUnwrap(result["count"] as? Int, "keymap.reload should return a diagnostic count: \(response)")
        XCTAssertGreaterThanOrEqual(count, 1, "a broken keymap line should yield at least one diagnostic: \(response)")
    }

    // keymap.list is the read side of keymap.reload: what the keymap resolved, plus what the menu bar is
    // actually dispatching. Seed an override and a custom command, then assert both halves came back and
    // that the override moved the chord.
    func testKeymapListReportsResolvedChordsAndLiveMenu() throws {
        try relaunch(withKeymap: "map cmd+e close_session\ncommand \"Bound\" cmd+shift+e echo hi\n")
        let response = try sendCommand(#"{"cmd":"keymap.list"}"#)
        XCTAssertEqual(response["ok"] as? Bool, true, "keymap.list should succeed: \(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any], "keymap.list should carry a result")
        let keymap = try XCTUnwrap(result["keymap"] as? [String: Any], "keymap.list should carry a keymap payload")

        let actions = try XCTUnwrap(keymap["actions"] as? [[String: Any]], "the payload should list actions")
        XCTAssertGreaterThan(actions.count, 40, "every built-in should be listed, not just the bound ones")
        let close = try XCTUnwrap(actions.first { $0["action"] as? String == "close_session" },
                                  "close_session should be listed: \(actions)")
        XCTAssertEqual(close["chord"] as? String, "cmd+e", "the override should be reflected: \(close)")
        XCTAssertEqual(close["overridden"] as? Bool, true, "an overridden action should be marked: \(close)")

        let commands = try XCTUnwrap(keymap["commands"] as? [[String: Any]], "the payload should list custom commands")
        XCTAssertEqual(commands.first?["name"] as? String, "Bound")
        XCTAssertEqual(commands.first?["shortcut"] as? String, "cmd+shift+e")

        // the live half: the menu bar carries real key equivalents, rendered in keymap syntax so the two
        // lists compare directly. This is what a model-only listing cannot show.
        let menu = try XCTUnwrap(keymap["menu"] as? [[String: Any]], "the payload should carry the live menu")
        XCTAssertFalse(menu.isEmpty, "the menu bar should report key equivalents: \(menu)")
        let chords = menu.compactMap { $0["chord"] as? String }
        XCTAssertTrue(chords.contains("cmd+n"), "a stable built-in chord should appear in the menu: \(chords)")
        // arrows and return arrive from AppKit as function-key/control CHARACTERS. They have to be
        // rendered as the keymap's named keys or the chord comes back with the key missing (`cmd+opt+`)
        // and cannot be compared against the action list above, which is the whole point of this section.
        XCTAssertTrue(chords.contains("cmd+opt+up"), "an arrow chord should render its named key: \(chords)")
        XCTAssertTrue(chords.contains("cmd+shift+return"), "a return chord should render its named key: \(chords)")
        // the seeded override moved Close Session to ⌘E, and the stock File ▸ Close then holds ⌘W — the
        // exact pairing that made #296 diagnosable at a glance.
        XCTAssertTrue(chords.contains("cmd+e"), "the rebound Close Session chord should show in the menu: \(chords)")
        // a shift-bound built-in has to render `cmd+shift+n`, NOT the uppercase-character spelling
        // `cmd+n` AppKit also accepts — that would collide on the page with New Window's real ⌘N and
        // report a binding that does not exist. Only a live menu can settle which spelling SwiftUI used.
        XCTAssertTrue(chords.contains("cmd+shift+n"),
                      "a shift-bound built-in should carry shift in the mask, not fold into an uppercase key: \(chords)")
        XCTAssertEqual(chords.filter { $0 == "cmd+n" }.count, 1,
                       "only New Session holds ⌘N; a folded shift chord would duplicate it: \(chords)")
        // items are attributed to their top-level menu. The nested-submenu recursion cannot be asserted
        // here — agterm's own submenus carry no key equivalents and Services entries depend on the user's
        // system settings — so it is covered in agtermTests/LiveMenuKeyEquivalentsTests instead.
        let menus = Set(menu.compactMap { $0["menu"] as? String })
        XCTAssertTrue(menus.contains("File"), "top-level menus should be attributed by their menu-bar title: \(menus)")
        XCTAssertNotNil(keymap["path"] as? String, "the payload should name the keymap file")
    }

    // MARK: - Config

    // config.reload re-reads the agterm-scoped ghostty.conf and returns the config-diagnostic count.
    // assert ok rather than count==0: the count merges the host's real ~/.config/ghostty/config (not
    // AGTERM_STATE_DIR-isolated), so a count==0 assert would be flaky on a host with its own config.
    func testConfigReloadSucceeds() throws {
        let response = try sendCommand(#"{"cmd":"config.reload"}"#)
        XCTAssertEqual(response["ok"] as? Bool, true, "config.reload should succeed: \(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any], "config.reload should carry a result")
        XCTAssertNotNil(result["count"] as? Int, "config.reload should return a diagnostic count: \(response)")
    }

    // a ghostty.conf with a malformed line seeded under <stateDir>/config surfaces in the diagnostic
    // count config.reload returns: relaunch with the malformed file in place (so the starter isn't
    // created over it), then config.reload reports a non-zero count. Use an UNKNOWN key (not a bad value
    // of a known key) so the line is an unambiguous, deterministic diagnostic that raises the count on its
    // own — independent of any diagnostics the host's own ~/.config/ghostty/config might also contribute.
    func testConfigReloadReportsDiagnosticsForMalformedFile() throws {
        try relaunch(withGhosttyConfig: "nonexistent-ghostty-key-xyz = 1\n")
        let response = try sendCommand(#"{"cmd":"config.reload"}"#)
        XCTAssertEqual(response["ok"] as? Bool, true, "config.reload should succeed even with a malformed file: \(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any], "config.reload should carry a result")
        let count = try XCTUnwrap(result["count"] as? Int, "config.reload should return a diagnostic count: \(response)")
        XCTAssertGreaterThanOrEqual(count, 1, "an unknown ghostty.conf key should yield at least one diagnostic: \(response)")
    }

    func testThemeListAndSet() throws {
        // list: a non-empty set of bundled themes, including the repo's own "agterm" theme. a fresh
        // install seeds the agterm theme as the default, so it is the current theme.
        let listed = try sendCommand(#"{"cmd":"theme.list"}"#)
        XCTAssertEqual(listed["ok"] as? Bool, true, "theme.list should succeed: \(listed)")
        let listResult = try XCTUnwrap(listed["result"] as? [String: Any], "theme.list should carry a result")
        let themes = try XCTUnwrap(listResult["themes"] as? [String], "theme.list should return themes")
        XCTAssertTrue(themes.contains("agterm"), "the bundled theme set should include the repo's agterm theme")
        XCTAssertEqual(listResult["theme"] as? String, "agterm", "a fresh install defaults to the agterm theme")

        // set a different known theme and get it echoed back.
        let set = try sendCommand(#"{"cmd":"theme.set","args":{"name":"Dracula"}}"#)
        XCTAssertEqual(set["ok"] as? Bool, true, "theme.set should succeed: \(set)")
        XCTAssertEqual((set["result"] as? [String: Any])?["theme"] as? String, "Dracula", "theme.set echoes the applied theme")

        // list again: the just-set theme is now current.
        let after = try sendCommand(#"{"cmd":"theme.list"}"#)
        XCTAssertEqual((after["result"] as? [String: Any])?["theme"] as? String, "Dracula", "theme.list marks the current theme")

        // an unknown theme name is rejected, not silently ignored.
        let bad = try sendCommand(#"{"cmd":"theme.set","args":{"name":"NotARealTheme"}}"#)
        XCTAssertEqual(bad["ok"] as? Bool, false, "an unknown theme should fail: \(bad)")
        XCTAssertTrue((bad["error"] as? String ?? "").contains("unknown theme"), "the error should name the cause: \(bad)")

        // no name selects ghostty's built-in default ("default ghostty" = nil current).
        let cleared = try sendCommand(#"{"cmd":"theme.set"}"#)
        XCTAssertEqual(cleared["ok"] as? Bool, true, "theme.set with no name should select the ghostty default: \(cleared)")
        let afterClear = try sendCommand(#"{"cmd":"theme.list"}"#)
        XCTAssertNil((afterClear["result"] as? [String: Any])?["theme"], "ghostty built-in is current again (nil)")
    }

    /// Wait for `element` to stop existing (polled), returning true if it disappears within `timeout`.
    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            usleep(150_000)
        }
        return !element.exists
    }
}
