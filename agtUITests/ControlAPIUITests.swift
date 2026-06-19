import Darwin
import XCTest

/// End-to-end tests for the programmatic control channel: launch the real app with an isolated
/// `AGT_STATE_DIR` (which also locates the unix socket at `<stateDir>/agt.sock`), speak the socket
/// directly from the test process (one newline-delimited JSON request → one response → close), and
/// assert against the response and the `workspaces.json` file-polling oracle the sidebar tests use.
@MainActor
final class ControlAPIUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stateDir: URL!
    private var socketPath: String!
    private var markerDir: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agt-ctluitest-\(UUID().uuidString)", isDirectory: true)
        markerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agt-ctlmarker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: markerDir, withIntermediateDirectories: true)
        // socket path constraints: it must be (a) under the unix-socket sun_path ~104-byte limit and
        // (b) inside the runner's sandbox grant. The per-test AGT_STATE_DIR subdir pushes the path to
        // ~135 bytes (too long), and /tmp is outside the runner sandbox (connect → EPERM). The runner's
        // own temp dir (NSTemporaryDirectory(), ~81 bytes) with a short filename satisfies both.
        socketPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("agtc-\(UUID().uuidString.prefix(8)).sock")
        app = XCUIApplication()
        app.launchEnvironment["AGT_STATE_DIR"] = stateDir.path
        app.launchEnvironment["AGT_CONTROL_SOCKET"] = socketPath
        app.launch()
        // the seeded session row proves the window (and thus the control server's scene .task) is up.
        XCTAssertTrue(app.staticTexts["session-row"].waitForExistence(timeout: 30), "seeded session should exist")
    }

    override func tearDown() async throws {
        app?.terminate()
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
        if let socketPath { try? FileManager.default.removeItem(atPath: socketPath) }
        if let markerDir { try? FileManager.default.removeItem(at: markerDir) }
    }

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
        let response = try sendCommand(typeRequest(text: command, target: newID, select: false))
        XCTAssertEqual(response["ok"] as? Bool, true, "session.type into the visible session should succeed: \(response)")
        XCTAssertNotNil(pollMarker(file, timeout: 12), "the typed command should run in the visible session's shell")
    }

    // session.type --select into a freshly created, never-shown session realizes it and the text lands.
    func testSessionTypeSelectRealizesNeverShownSession() throws {
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let result = try XCTUnwrap(created["result"] as? [String: Any], "session.new should carry a result")
        let newID = try XCTUnwrap(result["id"] as? String, "session.new should return the new id")

        let file = markerDir.appendingPathComponent("realized")
        let command = "tty > '\(file.path)'\n"
        let response = try sendCommand(typeRequest(text: command, target: newID, select: true))
        XCTAssertEqual(response["ok"] as? Bool, true, "session.type --select should realize and succeed: \(response)")
        XCTAssertNotNil(pollMarker(file, timeout: 10), "the typed command should run in the realized session's shell")
    }

    // session.type without select into a never-shown session returns the "not realized" error.
    func testSessionTypeWithoutSelectErrorsOnNeverShownSession() throws {
        // pre-seed two sessions with the FIRST selected and relaunch, so the second session is restored but
        // never shown — its surface stays nil (the lazy-creation gotcha), the deterministic never-realized case.
        let selectedID = UUID()
        let neverShownID = UUID()
        let snapshot = """
        {"version":1,"selectedSessionID":"\(selectedID.uuidString)","workspaces":[\
        {"id":"\(UUID().uuidString)","name":"workspace 1","sessions":[\
        {"id":"\(selectedID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"},\
        {"id":"\(neverShownID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"}]}]}
        """
        try relaunch(withSnapshot: snapshot)

        let response = try sendCommand(typeRequest(text: "echo hi\n", target: neverShownID.uuidString, select: false))
        XCTAssertEqual(response["ok"] as? Bool, false, "typing into a never-shown session without select should fail")
        XCTAssertEqual(response["error"] as? String, "session not realized; use select",
                       "should report the use-select error: \(response)")
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

    // session.overlay.open requires a command.
    func testOverlayOpenRequiresCommand() throws {
        let response = try sendCommand(#"{"cmd":"session.overlay.open","target":"active"}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "open with no command should fail: \(response)")
        XCTAssertEqual(response["error"] as? String, "session.overlay.open requires a command", "\(response)")
    }

    // session.overlay open/close lifecycle and the guards: a long-lived command (cat waits on stdin)
    // keeps the overlay up, so a second open errors; after close, closing again errors. The overlay
    // actually rendering and running a TUI is verified manually (the Metal surface is not in the tree).
    func testOverlayOpenCloseLifecycle() throws {
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let result = try XCTUnwrap(created["result"] as? [String: Any], "session.new should carry a result")
        let id = try XCTUnwrap(result["id"] as? String, "session.new should return the new id")

        let open = try sendCommand(#"{"cmd":"session.overlay.open","target":"\#(id)","args":{"command":"cat"}}"#)
        XCTAssertEqual(open["ok"] as? Bool, true, "overlay open should succeed: \(open)")

        let again = try sendCommand(#"{"cmd":"session.overlay.open","target":"\#(id)","args":{"command":"cat"}}"#)
        XCTAssertEqual(again["ok"] as? Bool, false, "a second open while active should fail: \(again)")
        XCTAssertEqual(again["error"] as? String, "overlay already open", "\(again)")

        let close = try sendCommand(#"{"cmd":"session.overlay.close","target":"\#(id)"}"#)
        XCTAssertEqual(close["ok"] as? Bool, true, "overlay close should succeed: \(close)")

        let closeAgain = try sendCommand(#"{"cmd":"session.overlay.close","target":"\#(id)"}"#)
        XCTAssertEqual(closeAgain["ok"] as? Bool, false, "closing with no overlay should fail: \(closeAgain)")
        XCTAssertEqual(closeAgain["error"] as? String, "no overlay", "\(closeAgain)")
    }

    // the overlay auto-closes when its command exits (the SHOW_CHILD_EXITED path): open an overlay
    // running a command that writes a marker then exits — the marker proves the command ran inside the
    // overlay, and the tree's overlay flag clearing proves the overlay vanished with no key press.
    func testOverlayAutoClosesWhenCommandExits() throws {
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let result = try XCTUnwrap(created["result"] as? [String: Any], "session.new should carry a result")
        let id = try XCTUnwrap(result["id"] as? String, "session.new should return the new id")

        let marker = markerDir.appendingPathComponent("overlay-ran")
        let open = try sendCommand(#"{"cmd":"session.overlay.open","target":"\#(id)","args":{"command":"sh -c 'echo ran > \#(marker.path)'"}}"#)
        XCTAssertEqual(open["ok"] as? Bool, true, "overlay open should succeed: \(open)")

        XCTAssertNotNil(pollMarker(marker, timeout: 12), "the overlay command should run inside the overlay")
        XCTAssertTrue(pollSessionOverlay(id: id, expected: false, timeout: 10),
                      "the overlay should auto-close when the command exits (no press-any-key prompt)")
    }

    // statusbar toggle flips statusBarHidden in workspaces.json.
    func testStatusBarToggle() throws {
        XCTAssertTrue(pollStatusBarHidden(false, timeout: 10), "status bar should start visible")

        let toggled = try sendCommand(#"{"cmd":"statusbar","args":{"mode":"toggle"}}"#)
        XCTAssertEqual(toggled["ok"] as? Bool, true, "statusbar toggle should succeed: \(toggled)")
        XCTAssertTrue(pollStatusBarHidden(true, timeout: 10), "toggle should hide the status bar")

        let back = try sendCommand(#"{"cmd":"statusbar","args":{"mode":"on"}}"#)
        XCTAssertEqual(back["ok"] as? Bool, true, "statusbar on should succeed: \(back)")
        XCTAssertTrue(pollStatusBarHidden(false, timeout: 10), "on should show the status bar again")
    }

    // session.split toggle shows split:true in the tree; toggling again clears it.
    func testSessionSplitToggle() throws {
        let split = try sendCommand(#"{"cmd":"session.split","target":"active","args":{"mode":"toggle"}}"#)
        XCTAssertEqual(split["ok"] as? Bool, true, "session.split toggle should succeed: \(split)")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the active session should report split:true")

        let unsplit = try sendCommand(#"{"cmd":"session.split","target":"active","args":{"mode":"off"}}"#)
        XCTAssertEqual(unsplit["ok"] as? Bool, true, "session.split off should succeed: \(unsplit)")
        XCTAssertTrue(pollActiveSessionSplit(false, timeout: 10), "off should clear the split")
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
    func testInvalidStatusBarModeErrors() throws {
        XCTAssertTrue(pollStatusBarHidden(false, timeout: 10), "status bar should start visible")

        let response = try sendCommand(#"{"cmd":"statusbar","args":{"mode":"bogus"}}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "an invalid statusbar mode should fail")
        let error = try XCTUnwrap(response["error"] as? String, "an invalid mode should carry an error")
        XCTAssertTrue(error.contains("invalid statusbar mode"), "should report the invalid mode, got: \(error)")
        // state must not have flipped.
        XCTAssertTrue(pollStatusBarHidden(false, timeout: 5), "an invalid mode must leave the status bar visible")
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
        let firstID = UUID(uuidString: "ABCD0000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "ABCD0000-0000-0000-0000-000000000002")!
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
        XCTAssertTrue(error.hasPrefix("ambiguous session prefix 'abcd'"), "should report the ambiguous prefix, got: \(error)")
        // both 8-char candidate prefixes must be listed.
        XCTAssertTrue(error.contains(String(firstID.uuidString.prefix(8)).lowercased())
                      || error.contains(String(firstID.uuidString.prefix(8))), "should list the first candidate, got: \(error)")
        XCTAssertTrue(error.contains(String(secondID.uuidString.prefix(8)).lowercased())
                      || error.contains(String(secondID.uuidString.prefix(8))), "should list the second candidate, got: \(error)")
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

    // session.move with no workspace arg returns the structured missing-arg guard.
    func testSessionMoveRequiresWorkspace() throws {
        let response = try sendCommand(#"{"cmd":"session.move","target":"active"}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "session.move without a workspace should fail")
        XCTAssertEqual(response["error"] as? String, "session.move requires a workspace", "should return the guard: \(response)")
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

    /// Wait for `element` to stop existing (polled), returning true if it disappears within `timeout`.
    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            usleep(150_000)
        }
        return !element.exists
    }

    /// Terminate the running app, write `snapshot` as the hermetic `workspaces.json`, and relaunch with the
    /// same isolated state dir + socket so a test can control the restored session set.
    private func relaunch(withSnapshot snapshot: String) throws {
        app.terminate()
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try Data(snapshot.utf8).write(to: stateDir.appendingPathComponent("workspaces.json"))
        app = XCUIApplication()
        app.launchEnvironment["AGT_STATE_DIR"] = stateDir.path
        app.launchEnvironment["AGT_CONTROL_SOCKET"] = socketPath
        app.launch()
        XCTAssertTrue(app.staticTexts["session-row"].waitForExistence(timeout: 30), "restored session should exist")
    }

    /// Build a `session.type` request line with JSON-escaped `text` (covers the newline and the quoted path).
    private func typeRequest(text: String, target: String? = nil, select: Bool) -> String {
        var obj: [String: Any] = ["cmd": "session.type", "args": ["text": text, "select": select]]
        if let target { obj["target"] = target }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8)!
    }

    /// Polls `file` until its (trimmed) contents are non-empty, returning them, or nil on timeout.
    private func pollMarker(_ file: URL, timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let contents = try? String(contentsOf: file, encoding: .utf8) {
                let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            usleep(150_000)
        }
        return nil
    }

    // MARK: - Snapshot oracle

    /// Polls the hermetic snapshot file until the (single) seeded workspace holds `expected` sessions.
    private func pollSessionCount(_ expected: Int, timeout: TimeInterval) -> Bool {
        let file = stateDir.appendingPathComponent("workspaces.json")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: file),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let workspaces = obj["workspaces"] as? [[String: Any]],
               let ws = workspaces.first,
               ((ws["sessions"] as? [[String: Any]])?.count ?? -1) == expected {
                return true
            }
            usleep(200_000)
        }
        return false
    }

    /// Polls the hermetic snapshot file until each workspace's session count equals `expected`, in order.
    private func pollSessionCounts(_ expected: [Int], timeout: TimeInterval) -> Bool {
        let file = stateDir.appendingPathComponent("workspaces.json")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: file),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let workspaces = obj["workspaces"] as? [[String: Any]],
               workspaces.map({ ($0["sessions"] as? [[String: Any]])?.count ?? -1 }) == expected {
                return true
            }
            usleep(200_000)
        }
        return false
    }

    /// Polls the hermetic snapshot file until `statusBarHidden` equals `expected`.
    private func pollStatusBarHidden(_ expected: Bool, timeout: TimeInterval) -> Bool {
        let file = stateDir.appendingPathComponent("workspaces.json")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: file),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (obj["statusBarHidden"] as? Bool ?? false) == expected {
                return true
            }
            usleep(200_000)
        }
        return false
    }

    /// Polls the hermetic snapshot file until the (single seeded workspace's) first session's `isSplit`
    /// equals `expected`.
    private func pollActiveSessionSplit(_ expected: Bool, timeout: TimeInterval) -> Bool {
        let file = stateDir.appendingPathComponent("workspaces.json")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: file),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let workspaces = obj["workspaces"] as? [[String: Any]],
               let sessions = workspaces.first?["sessions"] as? [[String: Any]],
               (sessions.first?["isSplit"] as? Bool ?? false) == expected {
                return true
            }
            usleep(200_000)
        }
        return false
    }

    /// Polls `tree` (overlay state is not persisted to workspaces.json) until the session with `id` has
    /// `overlay` equal to `expected`. Absent/nil treated as false.
    private func pollSessionOverlay(id: String, expected: Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let tree = try? sendCommand(#"{"cmd":"tree"}"#),
               let result = tree["result"] as? [String: Any],
               let t = result["tree"] as? [String: Any],
               let workspaces = t["workspaces"] as? [[String: Any]] {
                for ws in workspaces {
                    let sessions = ws["sessions"] as? [[String: Any]] ?? []
                    for s in sessions where (s["id"] as? String)?.lowercased() == id.lowercased() {
                        if (s["overlay"] as? Bool ?? false) == expected { return true }
                    }
                }
            }
            usleep(200_000)
        }
        return false
    }

    /// Polls the hermetic snapshot file until `selectedSessionID` equals `expected`.
    private func pollActiveSessionID(_ expected: UUID, timeout: TimeInterval) -> Bool {
        let file = stateDir.appendingPathComponent("workspaces.json")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: file),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (obj["selectedSessionID"] as? String)?.lowercased() == expected.uuidString.lowercased() {
                return true
            }
            usleep(200_000)
        }
        return false
    }

    /// Polls the hermetic snapshot file until the (single seeded workspace's) first session's `customName`
    /// equals `expected`.
    private func pollFirstSessionName(_ expected: String, timeout: TimeInterval) -> Bool {
        let file = stateDir.appendingPathComponent("workspaces.json")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: file),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let workspaces = obj["workspaces"] as? [[String: Any]],
               let sessions = workspaces.first?["sessions"] as? [[String: Any]],
               (sessions.first?["customName"] as? String) == expected {
                return true
            }
            usleep(200_000)
        }
        return false
    }

    /// Polls the hermetic snapshot file until the workspace names equal `expected`, in order.
    private func pollWorkspaceNames(_ expected: [String], timeout: TimeInterval) -> Bool {
        let file = stateDir.appendingPathComponent("workspaces.json")
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

    // MARK: - Socket client

    /// Connect to the app's control socket, send `line` (newline-terminated), read the single response
    /// line, and parse it as JSON. Retries the connect briefly since the server's scene `.task` may bind a
    /// beat after the window appears.
    private func sendCommand(_ line: String) throws -> [String: Any] {
        let fd = try connect(to: socketPath)
        defer { close(fd) }

        var payload = Data(line.utf8)
        payload.append(UInt8(ascii: "\n"))
        try writeAll(fd, payload)

        let data = readLine(fd)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(obj, "response should be a JSON object, got: \(String(data: data, encoding: .utf8) ?? "<binary>")")
    }

    /// Open a unix-domain stream socket and connect to `path`, retrying for a few seconds while the server
    /// finishes binding.
    private func connect(to path: String) throws -> Int32 {
        let deadline = Date().addingTimeInterval(15)
        var lastErrno: Int32 = 0
        repeat {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw posixError("socket", errno) }

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = path.utf8CString
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { buf in
                    pathBytes.withUnsafeBufferPointer { src in
                        buf.update(from: src.baseAddress!, count: src.count)
                    }
                }
            }
            let result = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result == 0 { return fd }
            lastErrno = errno
            close(fd)
            usleep(200_000)
        } while Date() < deadline
        throw posixError("connect(\(path))", lastErrno)
    }

    private func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while offset < data.count {
                let n = write(fd, base + offset, data.count - offset)
                if n <= 0 { throw posixError("write", errno) }
                offset += n
            }
        }
    }

    /// Read bytes up to the first newline (exclusive), or to EOF.
    private func readLine(_ fd: Int32) -> Data {
        var buffer = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n <= 0 { return buffer }
            if byte == UInt8(ascii: "\n") { return buffer }
            buffer.append(byte)
        }
    }

    private func posixError(_ op: String, _ code: Int32) -> NSError {
        NSError(domain: "control-socket", code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "\(op) failed: \(String(cString: strerror(code)))"])
    }
}
