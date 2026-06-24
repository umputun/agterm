import Darwin
import XCTest

/// End-to-end tests for the programmatic control channel: launch the real app with an isolated
/// `AGTERM_STATE_DIR` (which also locates the unix socket at `<stateDir>/agterm.sock`), speak the socket
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
            .appendingPathComponent("agterm-ctluitest-\(UUID().uuidString)", isDirectory: true)
        markerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-ctlmarker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: markerDir, withIntermediateDirectories: true)
        // socket path constraints: it must be (a) under the unix-socket sun_path ~104-byte limit and
        // (b) inside the runner's sandbox grant. The per-test AGTERM_STATE_DIR subdir pushes the path to
        // ~135 bytes (too long), and /tmp is outside the runner sandbox (connect → EPERM). The runner's
        // own temp dir (NSTemporaryDirectory(), ~81 bytes) with a short filename satisfies both.
        socketPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("agtermc-\(UUID().uuidString.prefix(8)).sock")
        app = XCUIApplication()
        app.launchEnvironment["AGTERM_STATE_DIR"] = stateDir.path
        app.launchEnvironment["AGTERM_CONTROL_SOCKET"] = socketPath
        app.launchForUITest()
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

    // session.overlay.result reports the overlay program's exit status once it exits (the --block path).
    // while the program runs, result errors "overlay still running"; after exit it returns result.exitCode.
    func testOverlayResultReportsExitCode() throws {
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let result = try XCTUnwrap(created["result"] as? [String: Any], "session.new should carry a result")
        let id = try XCTUnwrap(result["id"] as? String, "session.new should return the new id")

        let open = try sendCommand(#"{"cmd":"session.overlay.open","target":"\#(id)","args":{"command":"sh -c 'exit 7'"}}"#)
        XCTAssertEqual(open["ok"] as? Bool, true, "overlay open should succeed: \(open)")

        // poll session.overlay.result (errors while running) until the program exits and the code is reported.
        var exitCode: Int?
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let res = try sendCommand(#"{"cmd":"session.overlay.result","target":"\#(id)"}"#)
            if res["ok"] as? Bool == true {
                exitCode = (res["result"] as? [String: Any])?["exitCode"] as? Int
                break
            }
            usleep(200_000)
        }
        XCTAssertEqual(exitCode, 7, "session.overlay.result should report the program's exit status")
    }

    // session.overlay.result errors "overlay still running" while the program is up, and "no overlay
    // result" after a force-close where the program never recorded a status (killed before the wrapper).
    func testOverlayResultStillRunningThenClosed() throws {
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let result = try XCTUnwrap(created["result"] as? [String: Any], "session.new should carry a result")
        let id = try XCTUnwrap(result["id"] as? String, "session.new should return the new id")

        // cat with no input blocks indefinitely, so the overlay stays up.
        let open = try sendCommand(#"{"cmd":"session.overlay.open","target":"\#(id)","args":{"command":"cat"}}"#)
        XCTAssertEqual(open["ok"] as? Bool, true, "overlay open should succeed: \(open)")
        XCTAssertTrue(pollSessionOverlay(id: id, expected: true, timeout: 10), "the overlay should be up")

        let running = try sendCommand(#"{"cmd":"session.overlay.result","target":"\#(id)"}"#)
        XCTAssertEqual(running["ok"] as? Bool, false, "result should error while the overlay is running")
        XCTAssertEqual(running["error"] as? String, "overlay still running")

        let closed = try sendCommand(#"{"cmd":"session.overlay.close","target":"\#(id)"}"#)
        XCTAssertEqual(closed["ok"] as? Bool, true, "overlay close should succeed: \(closed)")
        XCTAssertTrue(pollSessionOverlay(id: id, expected: false, timeout: 10), "the overlay should be gone")

        // cat was killed before the wrapper's `echo $?`, so no status was recorded.
        let after = try sendCommand(#"{"cmd":"session.overlay.result","target":"\#(id)"}"#)
        XCTAssertEqual(after["ok"] as? Bool, false, "result should error when no status was recorded")
        XCTAssertEqual(after["error"] as? String, "no overlay result")
    }

    // closing an overlay must hand keyboard focus back to the underlying session terminal. this test is
    // DISCRIMINATING: it first proves the overlay actually grabbed keyboard focus (an overlay shell
    // `read` captures a typed line), so the after-close assertion is meaningful — then proves the same
    // keystrokes reach the underlying session shell once the overlay is gone. (overlay rendering/opacity
    // is verified manually; this asserts the focus handoff, which is automatable.)
    func testOverlayCloseReturnsFocusToSession() throws {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let treeResult = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let root = try XCTUnwrap(treeResult["tree"] as? [String: Any], "result should carry a tree")
        let workspaces = try XCTUnwrap(root["workspaces"] as? [[String: Any]], "tree should list workspaces")
        let sessions = try XCTUnwrap(workspaces.first?["sessions"] as? [[String: Any]], "workspace should list sessions")
        let id = try XCTUnwrap(sessions.first?["id"] as? String, "should have a seeded session id")

        // the session's tty, captured by injecting into its surface directly (independent of focus).
        let sessionTTY = markerDir.appendingPathComponent("session-tty")
        XCTAssertEqual(try sendCommand(typeRequest(text: "tty > '\(sessionTTY.path)'\n", target: id, select: false))["ok"] as? Bool,
                       true, "typing tty into the session should succeed")
        let sessionTtyValue = try XCTUnwrap(pollMarker(sessionTTY, timeout: 12), "the session should report its tty")

        // open an overlay whose shell captures one keyboard line, then stays alive (cat) so the overlay
        // remains up until we close it. the captured line proves the overlay holds keyboard focus.
        let ovlMarker = markerDir.appendingPathComponent("overlay-keys")
        let ovlCmd = "sh -c 'IFS= read -r x; printf %s \"$x\" > \(ovlMarker.path); cat'"
        let ovlJSON = try! JSONSerialization.data(withJSONObject:
            ["cmd": "session.overlay.open", "target": id, "args": ["command": ovlCmd]])
        let open = try sendCommand(String(data: ovlJSON, encoding: .utf8)!)
        XCTAssertEqual(open["ok"] as? Bool, true, "overlay open should succeed: \(open)")
        XCTAssertTrue(pollSessionOverlay(id: id, expected: true, timeout: 10), "the overlay should be up")

        // type via the KEYBOARD while the overlay is up; the overlay shell's `read` should capture it,
        // proving the overlay (not the session) holds first responder.
        usleep(800_000) // let the overlay surface attach, grab focus, and the shell reach `read`
        app.typeText("OVLFOCUS")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(pollMarker(ovlMarker, timeout: 12), "OVLFOCUS",
                       "the overlay must hold keyboard focus while open (else this test can't assert the handoff)")

        let close = try sendCommand(#"{"cmd":"session.overlay.close","target":"\#(id)"}"#)
        XCTAssertEqual(close["ok"] as? Bool, true, "overlay close should succeed: \(close)")
        XCTAssertTrue(pollSessionOverlay(id: id, expected: false, timeout: 10), "the overlay should be gone")

        // after the overlay tears down, type via the keyboard again: it must now reach the underlying
        // session shell (same tty), proving focus returned. focus return is async (focusAfterReparent is a
        // bounded makeFirstResponder retry that wins the teardown/re-host race over a few run-loop turns),
        // so a single fixed-sleep keystroke burst can land before first responder is the session and be
        // lost. re-type until the marker appears (same idiom as typeUntilMarker for surface-readiness):
        // re-typing the tty line is idempotent — once focus is correct one burst writes the tty.
        let afterTTY = markerDir.appendingPathComponent("after-close-tty")
        let afterValue = keyboardTypeUntilMarker("tty > '\(afterTTY.path)'", file: afterTTY)
        XCTAssertNotNil(afterValue, "after overlay close, keyboard focus should return to the session terminal")
        XCTAssertEqual(afterValue, sessionTtyValue, "focus should return to the SAME session terminal, not be lost")
    }

    // session.split toggle shows split:true in the tree; off hides it (keep-alive, mirrors ⌘D — the
    // pane's surface is NOT destroyed, only closeSplit on shell-exit does that), clearing split:false.
    func testSessionSplitToggle() throws {
        let split = try sendCommand(#"{"cmd":"session.split","target":"active","args":{"mode":"toggle"}}"#)
        XCTAssertEqual(split["ok"] as? Bool, true, "session.split toggle should succeed: \(split)")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the active session should report split:true")

        let unsplit = try sendCommand(#"{"cmd":"session.split","target":"active","args":{"mode":"off"}}"#)
        XCTAssertEqual(unsplit["ok"] as? Bool, true, "session.split off should succeed: \(unsplit)")
        XCTAssertTrue(pollActiveSessionSplit(false, timeout: 10), "off should clear the split")
    }

    // session.scratch toggle shows scratch:true in the tree; off hides it (keep-alive — the shell's
    // surface is NOT destroyed, only the shell's own `exit` does that), clearing scratch:false. An
    // unknown mode is rejected.
    func testSessionScratchToggle() throws {
        let on = try sendCommand(#"{"cmd":"session.scratch","target":"active","args":{"mode":"toggle"}}"#)
        XCTAssertEqual(on["ok"] as? Bool, true, "session.scratch toggle should succeed: \(on)")
        XCTAssertTrue(pollActiveSessionScratch(true, timeout: 10), "the active session should report scratch:true")

        // `on` while already shown is idempotent (the delta guard skips the redundant toggle, so it does
        // NOT flip back to hidden).
        let onAgain = try sendCommand(#"{"cmd":"session.scratch","target":"active","args":{"mode":"on"}}"#)
        XCTAssertEqual(onAgain["ok"] as? Bool, true, "session.scratch on (already on) should succeed: \(onAgain)")
        XCTAssertTrue(pollActiveSessionScratch(true, timeout: 10), "on while shown stays scratch:true")

        let off = try sendCommand(#"{"cmd":"session.scratch","target":"active","args":{"mode":"off"}}"#)
        XCTAssertEqual(off["ok"] as? Bool, true, "session.scratch off should succeed: \(off)")
        XCTAssertTrue(pollActiveSessionScratch(false, timeout: 10), "off should hide the scratch")

        // `off` while already hidden is idempotent.
        let offAgain = try sendCommand(#"{"cmd":"session.scratch","target":"active","args":{"mode":"off"}}"#)
        XCTAssertEqual(offAgain["ok"] as? Bool, true, "session.scratch off (already off) should succeed: \(offAgain)")
        XCTAssertTrue(pollActiveSessionScratch(false, timeout: 10), "off while hidden stays scratch:false")

        let bad = try sendCommand(#"{"cmd":"session.scratch","target":"active","args":{"mode":"bogus"}}"#)
        XCTAssertEqual(bad["ok"] as? Bool, false, "invalid scratch mode should fail: \(bad)")
        XCTAssertTrue((bad["error"] as? String ?? "").contains("invalid scratch mode"), "should report invalid mode: \(bad)")
    }

    // session.scratch on a NON-active target selects it first (the scratch is full-coverage and grabs
    // focus on show, so it must be the visible session), then shows the scratch on it.
    func testSessionScratchOnSelectsTarget() throws {
        // the seeded session is active; capture its id.
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let result = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let t = try XCTUnwrap(result["tree"] as? [String: Any], "result should carry a tree")
        let ws = try XCTUnwrap((t["workspaces"] as? [[String: Any]])?.first, "should have a workspace")
        let seededID = try XCTUnwrap((ws["sessions"] as? [[String: Any]])?.first?["id"] as? String, "should have a seeded session")

        // create a second session — session.new focuses it, so the seeded one is no longer active.
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let newID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new should return an id")
        XCTAssertNotEqual(newID.lowercased(), seededID.lowercased(), "the new session is distinct")

        // show scratch on the non-active seeded session: it should become active AND report scratch:true.
        let on = try sendCommand(#"{"cmd":"session.scratch","target":"\#(seededID)","args":{"mode":"on"}}"#)
        XCTAssertEqual(on["ok"] as? Bool, true, "session.scratch on a non-active target should succeed: \(on)")
        XCTAssertTrue(pollSessionActiveAndScratch(id: seededID, timeout: 10),
                      "showing scratch should select the target and report scratch:true")
    }

    // session.focus errors on a non-split session, succeeds on each pane once split, and rejects an
    // unknown pane.
    func testSessionFocusPane() throws {
        let notSplit = try sendCommand(#"{"cmd":"session.focus","target":"active","args":{"pane":"right"}}"#)
        XCTAssertEqual(notSplit["ok"] as? Bool, false, "focus on a non-split session should fail: \(notSplit)")
        XCTAssertTrue((notSplit["error"] as? String ?? "").contains("not split"), "should report not split: \(notSplit)")

        let split = try sendCommand(#"{"cmd":"session.split","target":"active","args":{"mode":"on"}}"#)
        XCTAssertEqual(split["ok"] as? Bool, true, "split on should succeed: \(split)")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the active session should report split:true")

        let right = try sendCommand(#"{"cmd":"session.focus","target":"active","args":{"pane":"right"}}"#)
        XCTAssertEqual(right["ok"] as? Bool, true, "focus right should succeed: \(right)")
        let left = try sendCommand(#"{"cmd":"session.focus","target":"active","args":{"pane":"left"}}"#)
        XCTAssertEqual(left["ok"] as? Bool, true, "focus left should succeed: \(left)")

        let bad = try sendCommand(#"{"cmd":"session.focus","target":"active","args":{"pane":"bogus"}}"#)
        XCTAssertEqual(bad["ok"] as? Bool, false, "invalid pane should fail: \(bad)")
        XCTAssertTrue((bad["error"] as? String ?? "").contains("invalid pane"), "should report invalid pane: \(bad)")
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

    // the agent-status icon is gated by the visibility rule: it shows only on a session that is NOT the
    // frontmost window's selected one. Set status on a non-selected session → the icon appears; select that
    // session → it hides; select a different session → it reappears (mirrors the notify-badge test).
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
        // async, so retry (mirrors keyboardTypeUntilMarker's retry idiom).
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

    // notify posts a banner for the active session; a missing body errors.
    func testNotifySend() throws {
        let ok = try sendCommand(#"{"cmd":"notify","target":"active","args":{"body":"hello","title":"Test"}}"#)
        XCTAssertEqual(ok["ok"] as? Bool, true, "notify with a body should succeed: \(ok)")

        let noBody = try sendCommand(#"{"cmd":"notify","target":"active"}"#)
        XCTAssertEqual(noBody["ok"] as? Bool, false, "notify without a body should fail: \(noBody)")
        XCTAssertTrue((noBody["error"] as? String ?? "").contains("requires a body"), "should report missing body: \(noBody)")
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

    // MARK: - Window commands

    // window.new opens a second window and window.list reflects it: the new window is present + open,
    // and the list keeps the active-flag invariant (exactly one of the two windows is active). Which
    // window is frontmost depends on AppKit key-window timing, so the test asserts the invariant rather
    // than which one — `window.select` flipping the active flag is covered by the captured-id test.
    func testWindowNewAndList() throws {
        // the seeded launch has exactly one window, and it's the active one.
        let initial = try windowList()
        XCTAssertEqual(initial.count, 1, "should start with the one seeded window: \(initial)")
        XCTAssertEqual(initial.first?["active"] as? Bool, true, "the seeded window should be active")
        let baselineWindows = app.windows.count

        let created = try sendCommand(#"{"cmd":"window.new","args":{"name":"second"}}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "window.new should succeed: \(created)")
        let result = try XCTUnwrap(created["result"] as? [String: Any], "window.new should carry a result")
        let newID = try XCTUnwrap(result["id"] as? String, "window.new should return the new id")

        // poll until the list shows two windows, the new one present + open, with exactly one active.
        let settled = pollWindowList(timeout: 10) { list in
            guard list.count == 2 else { return false }
            guard let made = list.first(where: { ($0["id"] as? String)?.lowercased() == newID.lowercased() }) else { return false }
            let activeCount = list.filter { ($0["active"] as? Bool) == true }.count
            return (made["open"] as? Bool) == true && activeCount == 1
        }
        XCTAssertTrue(settled, "the new window should appear open with exactly one active window in window.list")

        // an ACTUAL on-screen window must materialize, not just the library JSON open flag — window.new
        // pre-loads the new store (so window.list always shows open:true), but the spawned SwiftUI window
        // self-dismisses if its claim is dropped. polling app.windows guards that regression.
        let appeared = pollAppWindows(atLeast: baselineWindows + 1, timeout: 10)
        XCTAssertTrue(appeared, "window.new must render a real on-screen window, got \(app.windows.count) (baseline \(baselineWindows))")
    }

    /// Polls until the app exposes at least `count` on-screen windows.
    private func pollAppWindows(atLeast count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.windows.count >= count { return true }
            usleep(200_000)
        }
        return false
    }

    // window.resize sets the active window's frame size; the on-screen window reflects it.
    func testWindowResize() throws {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session")
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "window should exist")
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.resize","args":{"width":1000,"height":700}}"#)["ok"] as? Bool, true)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let size = window.frame.size
            if abs(size.width - 1000) < 8, abs(size.height - 700) < 8 { return }
            usleep(150_000)
        }
        XCTFail("window did not resize to 1000x700, got \(window.frame.size)")
    }

    // window.move repositions the active window; moving right+down shifts the on-screen origin right+down
    // (a relative check, robust to screen-coordinate/menu-bar offsets).
    func testWindowMove() throws {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session")
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "window should exist")
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.move","args":{"x":80,"y":80}}"#)["ok"] as? Bool, true)
        usleep(700_000)
        let first = window.frame.origin
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.move","args":{"x":280,"y":240}}"#)["ok"] as? Bool, true)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let o = window.frame.origin
            if o.x > first.x + 100, o.y > first.y + 100 { return }
            usleep(150_000)
        }
        XCTFail("window did not move right+down: first=\(first) now=\(window.frame.origin)")
    }

    // window.close marks the window closed, after which a session command targeting it returns the
    // "window not open" error. (--window routing into the second window is exercised first to prove
    // the round-trip, then the close flips it to the error path.)
    func testClosedWindowTargetingErrors() throws {
        let created = try sendCommand(#"{"cmd":"window.new"}"#)
        let result = try XCTUnwrap(created["result"] as? [String: Any], "window.new should carry a result")
        let windowB = try XCTUnwrap(result["id"] as? String, "window.new should return the new id")
        XCTAssertTrue(pollWindowList(timeout: 10) { $0.count == 2 }, "the second window should appear")

        // routing into the still-open window B works.
        let openTree = try sendCommand(#"{"cmd":"tree","args":{"window":"\#(windowB)"}}"#)
        XCTAssertEqual(openTree["ok"] as? Bool, true, "tree --window B should succeed while open: \(openTree)")

        // close window B, then wait until the index/list marks it closed. window.close drives AppKit's
        // performClose → willCloseNotification → per-window surface teardown → library.closeWindow, a
        // heavier round-trip than the other commands; under full-suite CPU contention the willClose handler
        // can be delayed past a tight budget, so allow a longer settle (the open flag is the deterministic
        // readiness signal — this waits for it, it isn't a blanket sleep).
        let closed = try sendCommand(#"{"cmd":"window.close","target":"\#(windowB)"}"#)
        XCTAssertEqual(closed["ok"] as? Bool, true, "window.close should succeed: \(closed)")
        let settled = pollWindowList(timeout: 30) { list in
            list.first(where: { ($0["id"] as? String)?.lowercased() == windowB.lowercased() })?["open"] as? Bool == false
        }
        XCTAssertTrue(settled, "window B should be marked closed after window.close")

        // a session command targeting the now-closed window returns the structured closed-window error.
        let response = try sendCommand(#"{"cmd":"tree","args":{"window":"\#(windowB)"}}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "targeting a closed window should fail: \(response)")
        XCTAssertEqual(response["error"] as? String, "window not open — window.select it first",
                       "should return the closed-window error: \(response)")
    }

    // --window targeting routes session.new + tree to the right window: a session added to window B with
    // --window lands in B's tree (now two sessions) and NOT in the frontmost (A) tree (still one).
    func testWindowTargetingRoutesToTheRightTree() throws {
        let initial = try windowList()
        let windowA = try XCTUnwrap(initial.first?["id"] as? String, "the seeded window id")

        let created = try sendCommand(#"{"cmd":"window.new"}"#)
        let result = try XCTUnwrap(created["result"] as? [String: Any], "window.new should carry a result")
        let windowB = try XCTUnwrap(result["id"] as? String, "window.new should return the new id")
        XCTAssertTrue(pollWindowList(timeout: 10) { $0.count == 2 }, "the second window should appear")

        // add a session to window B by id.
        let added = try sendCommand(#"{"cmd":"session.new","args":{"window":"\#(windowB)"}}"#)
        XCTAssertEqual(added["ok"] as? Bool, true, "session.new --window B should succeed: \(added)")

        // window B's tree now holds two sessions; window A's still holds one.
        XCTAssertTrue(pollTreeSessionCount(window: windowB, expected: 2, timeout: 10),
                      "the new session should land in window B's tree")
        XCTAssertTrue(pollTreeSessionCount(window: windowA, expected: 1, timeout: 5),
                      "window A's tree should be unchanged")
    }

    // an id captured from one window resolves with no --window even while another window is frontmost:
    // create window B + a session in it, raise window A to make it frontmost, then session.select the
    // captured B-session id with no --window — it resolves cross-window and selects it in B's store.
    func testCapturedIDResolvesWhileAnotherWindowFrontmost() throws {
        let initial = try windowList()
        let windowA = try XCTUnwrap(initial.first?["id"] as? String, "the seeded window id")

        let created = try sendCommand(#"{"cmd":"window.new"}"#)
        let result = try XCTUnwrap(created["result"] as? [String: Any], "window.new should carry a result")
        let windowB = try XCTUnwrap(result["id"] as? String, "window.new should return the new id")
        XCTAssertTrue(pollWindowList(timeout: 10) { $0.count == 2 }, "the second window should appear")

        // capture a session id created in window B.
        let added = try sendCommand(#"{"cmd":"session.new","args":{"window":"\#(windowB)"}}"#)
        let addedResult = try XCTUnwrap(added["result"] as? [String: Any], "session.new should carry a result")
        let sessionID = try XCTUnwrap(addedResult["id"] as? String, "session.new should return the new session id")

        // raise window A so it becomes frontmost (window B was frontmost right after window.new).
        XCTAssertTrue(selectWindowUntilActive(windowA, timeout: 15),
                      "window A should become active")

        // select the B-session by id with NO --window: it resolves cross-window to window B's store.
        let selected = try sendCommand(#"{"cmd":"session.select","target":"\#(sessionID)"}"#)
        XCTAssertEqual(selected["ok"] as? Bool, true, "selecting the captured id with no --window should succeed: \(selected)")
        XCTAssertEqual((selected["result"] as? [String: Any])?["id"] as? String, sessionID,
                       "select should resolve to the captured B-session id: \(selected)")

        // confirm it actually selected in window B's tree.
        XCTAssertTrue(pollTreeActiveSession(window: windowB, sessionID: sessionID, timeout: 10),
                      "the captured session should be active in window B's tree")
    }

    // a WORKSPACE id captured from window B resolves cross-window with no --window even while window A
    // is frontmost (exercises the cross-window workspace resolver arm, distinct from the session one).
    func testCapturedWorkspaceIDResolvesCrossWindow() throws {
        let created = try sendCommand(#"{"cmd":"window.new"}"#)
        let windowB = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "window.new should return the new id")
        XCTAssertTrue(pollWindowList(timeout: 10) { $0.count == 2 }, "the second window should appear")

        // create a workspace in window B and capture its id.
        let madeWs = try sendCommand(#"{"cmd":"workspace.new","args":{"window":"\#(windowB)","name":"betaws"}}"#)
        let workspaceID = try XCTUnwrap((madeWs["result"] as? [String: Any])?["id"] as? String,
                                        "workspace.new should return the new workspace id")

        // select the B-workspace by id with NO --window: it resolves cross-window to window B's store.
        let selected = try sendCommand(#"{"cmd":"workspace.select","target":"\#(workspaceID)"}"#)
        XCTAssertEqual(selected["ok"] as? Bool, true, "selecting the captured workspace id cross-window should succeed: \(selected)")
        XCTAssertEqual((selected["result"] as? [String: Any])?["id"] as? String, workspaceID,
                       "select should resolve to the captured B-workspace id: \(selected)")
    }

    // an unknown id with no --window is searched across ALL open windows and, found nowhere, returns
    // the structured not-found error (the cross-window resolver's miss path).
    func testCrossWindowUnknownIDErrors() throws {
        let created = try sendCommand(#"{"cmd":"window.new"}"#)
        _ = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "window.new should return the new id")
        XCTAssertTrue(pollWindowList(timeout: 10) { $0.count == 2 }, "the second window should appear")

        let bogus = UUID().uuidString
        let response = try sendCommand(#"{"cmd":"session.select","target":"\#(bogus)"}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "an id matching no open window should fail: \(response)")
        XCTAssertEqual(response["error"] as? String, "no such session: \(bogus)",
                       "should return the cross-window not-found error: \(response)")
    }

    // after closing the frontmost window, the remaining window becomes active — window.list reports
    // exactly one open window and it is flagged active (the frontmost invariant survives a close).
    func testRemainingWindowBecomesActiveAfterClosingFrontmost() throws {
        let created = try sendCommand(#"{"cmd":"window.new"}"#)
        let windowB = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "window.new should return the new id")
        XCTAssertTrue(pollWindowList(timeout: 10) { $0.count == 2 }, "the second window should appear")

        // close the just-created (frontmost) window B.
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.close","target":"\#(windowB)"}"#)["ok"] as? Bool, true)

        // exactly one window remains open, and the surviving (frontmost-or-first) window is active.
        let settled = pollWindowList(timeout: 30) { list in
            let open = list.filter { ($0["open"] as? Bool) == true }
            let active = list.filter { ($0["active"] as? Bool) == true }
            return open.count == 1 && active.count == 1 && (open.first?["id"] as? String) == (active.first?["id"] as? String)
        }
        XCTAssertTrue(settled, "the remaining open window should become the single active window after closing the frontmost")
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

    // MARK: - Window oracles

    /// Sends `window.list` and returns the windows array.
    private func windowList() throws -> [[String: Any]] {
        let response = try sendCommand(#"{"cmd":"window.list"}"#)
        XCTAssertEqual(response["ok"] as? Bool, true, "window.list should succeed: \(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any], "window.list should carry a result")
        return try XCTUnwrap(result["windows"] as? [[String: Any]], "window.list should return windows")
    }

    /// Re-issues `window.select` for `id` while polling `window.list` for that window's `active` flag.
    /// `window.select` returns ok as soon as the window is OPEN, not when it has become key — and the
    /// `active` flag flips only on the async `didBecomeKey`/`didBecomeMain`, which macOS can drop or
    /// delay under XCUITest (a `makeKeyAndOrderFront` that doesn't take is never re-issued by a single
    /// select). Re-selecting (idempotent: raises again) recovers a dropped activation; `app.activate()`
    /// first so the app is the active application (a window can't become key while the app is inactive).
    private func selectWindowUntilActive(_ id: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            app.activate()
            _ = try? sendCommand(#"{"cmd":"window.select","target":"\#(id)"}"#)
            if pollWindowList(timeout: 2, { list in
                list.first(where: { ($0["id"] as? String)?.lowercased() == id.lowercased() })?["active"] as? Bool == true
            }) { return true }
        }
        return false
    }

    /// Polls `window.list` until `predicate` holds, or times out.
    private func pollWindowList(timeout: TimeInterval, _ predicate: ([[String: Any]]) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let list = try? windowList(), predicate(list) { return true }
            usleep(200_000)
        }
        return false
    }

    /// Polls `tree --window <window>` until its (single) workspace holds `expected` sessions.
    private func pollTreeSessionCount(window: String, expected: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let workspaces = try? windowTreeWorkspaces(window: window),
               (workspaces.first?["sessions"] as? [[String: Any]])?.count == expected {
                return true
            }
            usleep(200_000)
        }
        return false
    }

    /// Polls `tree --window <window>` until the session with `sessionID` is marked active.
    private func pollTreeActiveSession(window: String, sessionID: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let workspaces = try? windowTreeWorkspaces(window: window) {
                for ws in workspaces {
                    let sessions = ws["sessions"] as? [[String: Any]] ?? []
                    for s in sessions where (s["id"] as? String)?.lowercased() == sessionID.lowercased() {
                        if (s["active"] as? Bool) == true { return true }
                    }
                }
            }
            usleep(200_000)
        }
        return false
    }

    /// Sends `tree --window <window>` and returns its workspaces array.
    private func windowTreeWorkspaces(window: String) throws -> [[String: Any]] {
        let response = try sendCommand(#"{"cmd":"tree","args":{"window":"\#(window)"}}"#)
        let result = try XCTUnwrap(response["result"] as? [String: Any], "tree should carry a result")
        let tree = try XCTUnwrap(result["tree"] as? [String: Any], "result should carry a tree")
        return try XCTUnwrap(tree["workspaces"] as? [[String: Any]], "tree should list workspaces")
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

    /// Opens Settings (Cmd+,), switches to General, and clicks the "Show notification badges" toggle.
    /// Retries the tab/toggle click each tick (a stale or half-open Settings window can drop the first
    /// click), mirroring SettingsUITests' robust `settingsControl`.
    private func toggleNotificationBadges() {
        let toggle = app.descendants(matching: .any).matching(identifier: "settings-notification-badges").firstMatch
        let tabButton = app.buttons["General"].firstMatch
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

    /// Terminate the running app, write `snapshot` as the (single) window's per-window snapshot file,
    /// and relaunch with the same isolated state dir + socket so a test can control the restored
    /// session set. `windows.json` (written by the first launch) already points at this file, so the
    /// relaunched window loads the seeded snapshot.
    private func relaunch(withSnapshot snapshot: String) throws {
        app.terminate()
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try Data(snapshot.utf8).write(to: stateDir.windowSnapshotFile())
        app = XCUIApplication()
        app.launchEnvironment["AGTERM_STATE_DIR"] = stateDir.path
        app.launchEnvironment["AGTERM_CONTROL_SOCKET"] = socketPath
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].waitForExistence(timeout: 30), "restored session should exist")
    }

    /// Terminate the running app, write `keymap` to `<stateDir>/config/keymap.conf`, and relaunch with the
    /// same isolated state dir + socket. Writing the file before relaunch means `ensureStarterKeymap()`
    /// finds it present and never overwrites it, so the seeded content is what gets parsed.
    private func relaunch(withKeymap keymap: String) throws {
        app.terminate()
        let configDir = stateDir.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try Data(keymap.utf8).write(to: configDir.appendingPathComponent("keymap.conf"))
        app = XCUIApplication()
        app.launchEnvironment["AGTERM_STATE_DIR"] = stateDir.path
        app.launchEnvironment["AGTERM_CONTROL_SOCKET"] = socketPath
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].waitForExistence(timeout: 30), "seeded session should exist")
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

    /// Types `command` + Return via the real keyboard (XCUI `typeText`), retrying until `file` reports a
    /// non-empty marker. The keyboard routes to whatever holds first responder, and focus return after an
    /// overlay/pane teardown is async (a bounded makeFirstResponder retry), so the first burst can land
    /// before the session is first responder and be dropped. Re-typing each attempt is idempotent for a
    /// `cmd > file` command. Returns the marker contents, or nil if it never appeared across all attempts.
    private func keyboardTypeUntilMarker(_ command: String, file: URL,
                                         attempts: Int = 6, perAttempt: TimeInterval = 2.5) -> String? {
        for _ in 0..<attempts {
            try? FileManager.default.removeItem(at: file)
            app.typeText(command)
            app.typeKey(.return, modifierFlags: [])
            if let value = pollMarker(file, timeout: perAttempt) { return value }
        }
        return nil
    }

    /// Inject `command` (which redirects to `file`) and wait for the shell to write it back, retrying the
    /// inject if the marker hasn't appeared yet. A freshly-realized surface's shell/pty may not be ready to
    /// read when the first keystrokes land (especially under full-suite CPU load), so a single injection can
    /// be dropped — re-injecting once the shell has had time to spawn is the deterministic readiness wait.
    /// The marker file is the readiness signal: when it's non-empty the command actually ran. Returns the
    /// marker contents, or nil if it never appeared across all attempts. Asserts each type request returns ok.
    private func typeUntilMarker(_ command: String, target: String, file: URL, select: Bool,
                                 attempts: Int = 4, perAttempt: TimeInterval = 4) throws -> String? {
        for attempt in 0..<attempts {
            // clear any marker a prior attempt's late injection may have written, so a stale value
            // can't be read as this attempt's success.
            try? FileManager.default.removeItem(at: file)
            let typed = try sendCommand(typeRequest(text: command, target: target, select: select))
            XCTAssertEqual(typed["ok"] as? Bool, true, "typing the probe (attempt \(attempt)) should succeed: \(typed)")
            if let value = pollMarker(file, timeout: perAttempt) { return value }
        }
        return nil
    }

    // MARK: - Snapshot oracle

    /// Polls the hermetic snapshot file until the (single) seeded workspace holds `expected` sessions.
    private func pollSessionCount(_ expected: Int, timeout: TimeInterval) -> Bool {
        stateDir.pollSnapshot(equals: expected, timeout: timeout) { obj in
            guard let workspaces = obj["workspaces"] as? [[String: Any]], let ws = workspaces.first else { return nil }
            return (ws["sessions"] as? [[String: Any]])?.count ?? -1
        }
    }

    /// Polls the hermetic snapshot file until each workspace's session count equals `expected`, in order.
    private func pollSessionCounts(_ expected: [Int], timeout: TimeInterval) -> Bool {
        stateDir.pollSnapshot(equals: expected, timeout: timeout) { obj in
            guard let workspaces = obj["workspaces"] as? [[String: Any]] else { return nil }
            return workspaces.map { ($0["sessions"] as? [[String: Any]])?.count ?? -1 }
        }
    }

    /// Polls the hermetic snapshot file until the (single seeded workspace's) first session's `isSplit`
    /// equals `expected`.
    private func pollActiveSessionSplit(_ expected: Bool, timeout: TimeInterval) -> Bool {
        stateDir.pollSnapshot(equals: expected, timeout: timeout) { obj in
            guard let workspaces = obj["workspaces"] as? [[String: Any]],
                  let sessions = workspaces.first?["sessions"] as? [[String: Any]] else { return nil }
            return sessions.first?["isSplit"] as? Bool ?? false
        }
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

    /// Polls `tree` (scratch state is not persisted to workspaces.json) until the ACTIVE session has
    /// `scratch` equal to `expected`. Absent/nil treated as false.
    private func pollActiveSessionScratch(_ expected: Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let tree = try? sendCommand(#"{"cmd":"tree"}"#),
               let result = tree["result"] as? [String: Any],
               let t = result["tree"] as? [String: Any],
               let workspaces = t["workspaces"] as? [[String: Any]] {
                for ws in workspaces {
                    let sessions = ws["sessions"] as? [[String: Any]] ?? []
                    for s in sessions where (s["active"] as? Bool ?? false) {
                        if (s["scratch"] as? Bool ?? false) == expected { return true }
                    }
                }
            }
            usleep(200_000)
        }
        return false
    }

    /// Polls `tree` until the session with `id` is BOTH active and has `scratch == true` (used to verify
    /// session.scratch on a non-active target selects it before showing).
    private func pollSessionActiveAndScratch(id: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let tree = try? sendCommand(#"{"cmd":"tree"}"#),
               let result = tree["result"] as? [String: Any],
               let t = result["tree"] as? [String: Any],
               let workspaces = t["workspaces"] as? [[String: Any]] {
                for ws in workspaces {
                    for s in (ws["sessions"] as? [[String: Any]] ?? [])
                    where (s["id"] as? String)?.lowercased() == id.lowercased() {
                        if (s["active"] as? Bool ?? false) && (s["scratch"] as? Bool ?? false) { return true }
                    }
                }
            }
            usleep(200_000)
        }
        return false
    }

    /// Polls the hermetic snapshot file until `selectedSessionID` equals `expected`.
    private func pollActiveSessionID(_ expected: UUID, timeout: TimeInterval) -> Bool {
        stateDir.pollSnapshot(equals: expected.uuidString.lowercased(), timeout: timeout) { obj in
            (obj["selectedSessionID"] as? String)?.lowercased()
        }
    }

    /// Polls the hermetic snapshot file until the (single seeded workspace's) first session's `customName`
    /// equals `expected`.
    private func pollFirstSessionName(_ expected: String, timeout: TimeInterval) -> Bool {
        stateDir.pollSnapshot(equals: expected, timeout: timeout) { obj in
            guard let workspaces = obj["workspaces"] as? [[String: Any]],
                  let sessions = workspaces.first?["sessions"] as? [[String: Any]] else { return nil }
            return sessions.first?["customName"] as? String
        }
    }

    /// Polls the hermetic snapshot file until the (single seeded workspace's) session ids equal
    /// `expected`, in order (case-insensitive compare).
    private func pollSessionOrder(_ expected: [UUID], timeout: TimeInterval) -> Bool {
        let wanted = expected.map { $0.uuidString.lowercased() }
        return stateDir.pollSnapshot(equals: wanted, timeout: timeout) { obj in
            guard let workspaces = obj["workspaces"] as? [[String: Any]],
                  let sessions = workspaces.first?["sessions"] as? [[String: Any]] else { return nil }
            return sessions.compactMap { ($0["id"] as? String)?.lowercased() }
        }
    }

    /// Polls the hermetic snapshot file until the workspace names equal `expected`, in order.
    private func pollWorkspaceNames(_ expected: [String], timeout: TimeInterval) -> Bool {
        stateDir.pollSnapshot(equals: expected, timeout: timeout) { obj in
            guard let workspaces = obj["workspaces"] as? [[String: Any]] else { return nil }
            return workspaces.compactMap { $0["name"] as? String }
        }
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
            if n < 0 {
                if errno == EINTR { continue } // a signal interrupted the blocking read; retry, don't treat as EOF
                return buffer
            }
            if n == 0 { return buffer } // EOF
            if byte == UInt8(ascii: "\n") { return buffer }
            buffer.append(byte)
        }
    }

    private func posixError(_ op: String, _ code: Int32) -> NSError {
        NSError(domain: "control-socket", code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "\(op) failed: \(String(cString: strerror(code)))"])
    }
}
