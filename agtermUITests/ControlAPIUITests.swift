import Darwin
import XCTest

/// End-to-end tests for the programmatic control channel: launch the real app with an isolated
/// `AGTERM_STATE_DIR` (which also locates the unix socket at `<stateDir>/agterm.sock`), speak the socket
/// directly from the test process (one newline-delimited JSON request → one response → close), and
/// assert against the response and the `workspaces.json` file-polling oracle the sidebar tests use.
@MainActor
final class ControlAPIUITests: ControlAPITestCase {
    // a `tree` request returns the seeded workspace and session with non-empty ids.
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

    // the tree exposes a session's raw OSC title. Set one by typing a printf that emits OSC 2, held by
    // `cat` so the local shell can't clear it at the next prompt (mirroring how a remote keeps its title).
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

    // tree exposes each session's LIVE foreground command: run a non-shell blocking process (`tee` opens
    // its file on start, then blocks reading the pty) so the foreground is `tee`, not the shell prompt.
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

    // tree exposes each session's agent status: setting `blocked` surfaces `status: "blocked"` on that
    // session's node, while a session left idle omits the key entirely (the read side of session.status).
    func testTreeExposesAgentStatus() throws {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let treeResult = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let root = try XCTUnwrap(treeResult["tree"] as? [String: Any], "result should carry a tree")
        let workspaces = try XCTUnwrap(root["workspaces"] as? [[String: Any]], "tree should list workspaces")
        let sessions = try XCTUnwrap(workspaces.first?["sessions"] as? [[String: Any]], "workspace should list sessions")
        let seeded = try XCTUnwrap(sessions.first?["id"] as? String, "should have a seeded session id")

        // a second session stays idle so its node can prove the status key is omitted when idle.
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let createdResult = try XCTUnwrap(created["result"] as? [String: Any], "session.new should carry a result")
        let idleID = try XCTUnwrap(createdResult["id"] as? String, "session.new should return the new id")
        XCTAssertTrue(pollSessionCount(2, timeout: 10), "the new session should land")

        // baseline: every fresh session is idle, so the seeded node omits the status key.
        let before = try sendCommand(#"{"cmd":"tree"}"#)
        XCTAssertNil(sessionNode(before, id: seeded)?["status"], "an idle session should omit the status key")

        // set blocked on the seeded session; its node now reports status "blocked".
        let set = try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"blocked"}}"#)
        XCTAssertEqual(set["ok"] as? Bool, true, "session.status blocked should succeed: \(set)")

        var seededStatus: String?
        for _ in 0..<40 {
            let resp = try sendCommand(#"{"cmd":"tree"}"#)
            if let s = sessionNode(resp, id: seeded)?["status"] as? String { seededStatus = s; break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertEqual(seededStatus, "blocked", "tree should report the seeded session's blocked status")

        // the untouched second session is still idle, so it omits the status key.
        let after = try sendCommand(#"{"cmd":"tree"}"#)
        XCTAssertNil(sessionNode(after, id: idleID)?["status"], "an idle session should omit the status key")
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

    // restore.clear succeeds and the server keeps serving. The saved-command WIPE is only observable across
    // a quit (the field is populated at quit, consumed at restore), so the cross-relaunch behavior is left
    // to the arm's trivial nil+saveAllOpen logic plus the protocol round-trip + CLI parse tests.
    func testRestoreClearSucceeds() throws {
        let resp = try sendCommand(#"{"cmd":"restore.clear"}"#)
        XCTAssertEqual(resp["ok"] as? Bool, true, "restore.clear should succeed: \(resp)")
    }

    // session.background sets a text watermark and clears it; bad input (missing image, invalid fit) is
    // rejected and the server stays alive. The actual pixels are not AX-observable (Metal surface), so this
    // covers the control round-trip + validation, like the other surface-state commands.
    func testSessionBackgroundSetClearAndValidation() throws {
        let sid = try activeSessionID()

        let text = try sendCommand(#"{"cmd":"session.background","target":"\#(sid)","args":{"mode":"text","text":"STAGING","opacity":0.2}}"#)
        XCTAssertEqual(text["ok"] as? Bool, true, "session.background text should succeed: \(text)")

        // read-back: the watermark spec now rides the session's tree node (set/clear/query symmetry).
        let afterSet = try sendCommand(#"{"cmd":"tree"}"#)
        let setNode = try XCTUnwrap(sessionNode(afterSet, id: sid), "the session should appear in the tree")
        let bg = try XCTUnwrap(setNode["background"] as? [String: Any], "tree should expose the set watermark")
        XCTAssertEqual(bg["kind"] as? String, "text", "the watermark kind should read back")
        XCTAssertEqual(bg["text"] as? String, "STAGING", "the watermark text should read back")

        // a solid background color reads back with kind "color" and the hex. The spec carries no opacity —
        // a color honors the Settings window translucency at render time.
        let colorSet = try sendCommand(##"{"cmd":"session.background","target":"\##(sid)","args":{"mode":"color","color":"#ff0000"}}"##)
        XCTAssertEqual(colorSet["ok"] as? Bool, true, "session.background color should succeed: \(colorSet)")
        let afterColor = try sendCommand(#"{"cmd":"tree"}"#)
        let colorNode = try XCTUnwrap(sessionNode(afterColor, id: sid), "the session should appear in the tree")
        let colorBg = try XCTUnwrap(colorNode["background"] as? [String: Any], "tree should expose the color background")
        XCTAssertEqual(colorBg["kind"] as? String, "color", "the color kind should read back")
        XCTAssertEqual(colorBg["colorHex"] as? String, "#ff0000", "the color hex should read back")

        let badColor = try sendCommand(#"{"cmd":"session.background","target":"\#(sid)","args":{"mode":"color","color":"red"}}"#)
        XCTAssertEqual(badColor["ok"] as? Bool, false, "a malformed color should be rejected")

        // color mode with no color hits the "requires a color" guard (unreachable from the CLI, whose
        // argument is required, so the raw-JSON e2e is the only cover for this arm).
        let emptyColor = try sendCommand(#"{"cmd":"session.background","target":"\#(sid)","args":{"mode":"color"}}"#)
        XCTAssertEqual(emptyColor["ok"] as? Bool, false, "color mode with no color should be rejected")
        XCTAssertEqual(emptyColor["error"] as? String, "session.background color requires a color",
                       "the empty-color guard should reject it")

        let missing = try sendCommand(#"{"cmd":"session.background","target":"\#(sid)","args":{"mode":"image","path":"/no/such.png"}}"#)
        XCTAssertEqual(missing["ok"] as? Bool, false, "a missing image file should be rejected")

        let badFit = try sendCommand(#"{"cmd":"session.background","target":"\#(sid)","args":{"mode":"image","path":"/no/such.png","fit":"fill"}}"#)
        XCTAssertEqual(badFit["ok"] as? Bool, false, "an invalid fit should be rejected")

        // config-injection vector: a newline in the image path would smuggle an extra ghostty key into the
        // per-surface overlay. The control-char guard runs BEFORE the format/existence checks, so its own
        // error proves it (not fileExists) did the rejecting.
        let injection = try sendCommand(#"{"cmd":"session.background","target":"\#(sid)","args":{"mode":"image","path":"x.png\nclipboard-read = allow\ny.png"}}"#)
        XCTAssertEqual(injection["ok"] as? Bool, false, "an image path with a control char must be rejected")
        XCTAssertEqual(injection["error"] as? String, "image path must not contain control characters",
                       "the control-char guard, not the fileExists check, should reject it")

        let badOpacity = try sendCommand(#"{"cmd":"session.background","target":"\#(sid)","args":{"mode":"text","text":"X","opacity":5}}"#)
        XCTAssertEqual(badOpacity["ok"] as? Bool, false, "an out-of-range opacity should be rejected")

        // an over-long text must be rejected at the boundary so the renderer never attempts a huge bitmap.
        let longText = String(repeating: "A", count: 5000)
        let tooLong = try sendCommand(#"{"cmd":"session.background","target":"\#(sid)","args":{"mode":"text","text":"\#(longText)"}}"#)
        XCTAssertEqual(tooLong["ok"] as? Bool, false, "an over-long watermark text should be rejected")

        let cleared = try sendCommand(#"{"cmd":"session.background","target":"\#(sid)","args":{"mode":"clear"}}"#)
        XCTAssertEqual(cleared["ok"] as? Bool, true, "session.background clear should succeed: \(cleared)")

        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        XCTAssertEqual(tree["ok"] as? Bool, true, "the server should stay alive after background commands")
        // read-back after clear: the background key is omitted from the node.
        let clearedNode = try XCTUnwrap(sessionNode(tree, id: sid), "the session should still appear in the tree")
        XCTAssertNil(clearedNode["background"], "a cleared watermark should be absent from the tree node")
    }

    // a malformed JSON line returns ok:false with an error, and the server stays alive: a
    // subsequent valid `tree` still succeeds.
    func testMalformedRequestErrorsAndServerStaysAlive() throws {
        let bad = try sendCommand("not json at all")
        XCTAssertEqual(bad["ok"] as? Bool, false, "malformed request should fail")
        XCTAssertFalse((bad["error"] as? String ?? "").isEmpty, "a failed request should carry an error string")

        let good = try sendCommand(#"{"cmd":"tree"}"#)
        XCTAssertEqual(good["ok"] as? Bool, true, "the server should still answer after a bad request")
    }

    // session.new returns an id and the session appears in workspaces.json; session.close removes it.
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

    // session.new --command runs the command AS the session's process (no shell echo): create a session
    // whose command writes a marker file, then read it back — proof the command ran as the process, not
    // typed into a shell. The session closes when the command exits (kitty-style).
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

    // a control session.new (frontmost window) FOCUSES the new session, so real keystrokes reach it: the
    // command is `head -n1 > marker` (captures one typed line), and we type via the keyboard — the text
    // only lands if the new session grabbed first responder. Guards the gate-command focus fix.
    func testSessionNewWithCommandFocusesTheNewSession() throws {
        let marker = NSTemporaryDirectory() + "agterm-focus-\(UUID().uuidString).txt"
        let cmd = "head -n1 > \(marker)"
        let created = try sendCommand(#"{"cmd":"session.new","args":{"command":"\#(cmd)"}}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "session.new --command should succeed: \(created)")

        // let the surface mount and grab first responder (focusActiveSession's bounded retry), then type.
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

    // session.new --name seeds the new session's custom name at creation (open a session already labeled,
    // without a follow-up rename). Verify the returned id carries the given name in the persisted snapshot.
    func testSessionNewWithName() throws {
        let created = try sendCommand(#"{"cmd":"session.new","args":{"name":"myhost"}}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "session.new --name should succeed: \(created)")
        let newID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new should return an id")
        XCTAssertTrue(pollSessionName(id: newID, equals: "myhost", timeout: 10),
                      "the new session should carry the given custom name")
    }

    // session.new --workspace-name addresses a workspace by its sidebar label. Without --create-workspace
    // a missing name errors (nothing created); with it, the workspace is created once and REUSED on the
    // next call (idempotent), so two creates land two sessions in a single "servers" workspace.
    func testSessionNewWorkspaceNameCreatesThenReuses() throws {
        // no match + no create -> error, and nothing is created.
        let missing = try sendCommand(#"{"cmd":"session.new","args":{"workspaceName":"servers"}}"#)
        XCTAssertEqual(missing["ok"] as? Bool, false, "name target with no match and no create should fail: \(missing)")
        XCTAssertTrue((missing["error"] as? String ?? "").contains("no workspace named"),
                      "should report the missing workspace name: \(missing)")
        XCTAssertTrue(pollWorkspaceNames(["workspace 1"], timeout: 5), "the failed call must not create a workspace")

        // create: the "servers" workspace is added and the session lands in it.
        let created = try sendCommand(#"{"cmd":"session.new","args":{"workspaceName":"servers","createWorkspace":true}}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "create-workspace should succeed: \(created)")
        XCTAssertTrue(pollWorkspaceNames(["workspace 1", "servers"], timeout: 10), "the servers workspace should be created")

        // reuse: a second call with the same name does NOT create a duplicate; both sessions sit in servers.
        let reused = try sendCommand(#"{"cmd":"session.new","args":{"workspaceName":"servers","createWorkspace":true}}"#)
        XCTAssertEqual(reused["ok"] as? Bool, true, "the second create should reuse the workspace: \(reused)")
        XCTAssertTrue(pollWorkspaceNames(["workspace 1", "servers"], timeout: 10), "still exactly one servers workspace")
        XCTAssertTrue(pollSessionCounts([1, 2], timeout: 10), "both sessions should land in the single servers workspace")

        // no-create name target of an EXISTING workspace succeeds and lands there (a third session).
        let existing = try sendCommand(#"{"cmd":"session.new","args":{"workspaceName":"servers"}}"#)
        XCTAssertEqual(existing["ok"] as? Bool, true, "no-create name target of an existing workspace should succeed: \(existing)")
        XCTAssertTrue(pollSessionCounts([1, 3], timeout: 10), "the no-create name target should land a third session in servers")
    }

    // the ControlServer arm enforces the two addressing rules independently of the CLI validate() (a raw
    // socket caller bypasses the CLI), and a blank name reports must-not-be-blank rather than a misleading
    // --create-workspace suggestion.
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

    // workspace.new returns an id and the workspace appears; workspace.rename is reflected in json.
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

    // workspace.delete of the last workspace returns the keep-one error and leaves the workspace present.
    func testWorkspaceDeleteLastErrors() throws {
        XCTAssertTrue(pollWorkspaceNames(["workspace 1"], timeout: 10), "should start with the one seeded workspace")

        let response = try sendCommand(#"{"cmd":"workspace.delete","target":"active"}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "deleting the last workspace should fail")
        XCTAssertEqual(response["error"] as? String, "cannot delete last workspace",
                       "should return the keep-one error: \(response)")
        // the workspace must still be there a beat later.
        XCTAssertTrue(pollWorkspaceNames(["workspace 1"], timeout: 5), "the workspace should still be present")
    }

    // a command with an unknown target returns a structured "no such …" error.
    func testUnknownTargetErrors() throws {
        let response = try sendCommand(#"{"cmd":"session.close","target":"deadbeef"}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "an unknown target should fail")
        let error = try XCTUnwrap(response["error"] as? String, "an unknown target should carry an error")
        XCTAssertTrue(error.hasPrefix("no such session"), "should report no such session, got: \(error)")
    }

    // session.type without select into a visible, realized session writes its tty to a file — read it back
    // (the split-test idiom: the surface's own shell is the oracle for "the text actually landed"). A new
    // session is selected and shown on creation, so its surface is realized — the immediate-inject arm.
    func testSessionTypeIntoActiveSession() throws {
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let result = try XCTUnwrap(created["result"] as? [String: Any], "session.new should carry a result")
        let newID = try XCTUnwrap(result["id"] as? String, "session.new should return the new id")

        let file = markerDir.appendingPathComponent("active")
        let command = "tty > '\(file.path)'\n"
        // type-and-retry: a freshly-realized surface's shell may not be ready for the first keystrokes under
        // full-suite load, so re-inject until the shell writes the marker (the deterministic readiness wait).
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
        // --select realizes the never-shown session; type-and-retry rides out the shell-readiness race so a
        // dropped first injection under full-suite load doesn't fail the test (the marker is the readiness signal).
        XCTAssertNotNil(try typeUntilMarker(command, target: newID, file: file, select: true),
                        "the typed command should run in the realized session's shell")
    }

    // eager session realization means a restored-but-not-selected session is already live, so session.type
    // without --select reaches it (there are no never-shown sessions left to error on).
    func testSessionTypeReachesEagerlyRealizedSession() throws {
        // pre-seed two sessions with the FIRST selected and relaunch; the second is restored but never
        // selected, yet the deck realizes every session at startup, so its shell is already running.
        let selectedID = UUID()
        let otherID = UUID()
        let snapshot = """
        {"version":1,"selectedSessionID":"\(selectedID.uuidString)","workspaces":[\
        {"id":"\(UUID().uuidString)","name":"workspace 1","sessions":[\
        {"id":"\(selectedID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"},\
        {"id":"\(otherID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"}]}]}
        """
        try relaunch(withSnapshot: snapshot)

        // type WITHOUT --select into the non-selected session; the command must land in its shell.
        let file = markerDir.appendingPathComponent("eager")
        XCTAssertNotNil(try typeUntilMarker("tty > '\(file.path)'\n", target: otherID.uuidString, file: file, select: false),
                        "session.type without select reaches the eagerly-realized, non-selected session")
    }

    // session.copy on a session with no selection returns the "no selection" error (a fresh session has
    // none). The with-selection path needs a real text selection in the Metal surface, verified manually.
    func testSessionCopyWithoutSelectionErrors() throws {
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let result = try XCTUnwrap(created["result"] as? [String: Any], "session.new should carry a result")
        let newID = try XCTUnwrap(result["id"] as? String, "session.new should return the new id")

        let response = try sendCommand(#"{"cmd":"session.copy","target":"\#(newID)"}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "copy with no selection should fail: \(response)")
        XCTAssertEqual(response["error"] as? String, "no selection", "should report no selection: \(response)")
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
