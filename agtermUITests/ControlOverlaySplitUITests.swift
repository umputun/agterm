import Darwin
import XCTest

/// Control-channel e2e for the overlay lifecycle, the scratch terminal, and the split-pane commands
/// (session.split/scratch/focus/resize) plus the ⌘W cover-peel precedence. Subclass of
/// `ControlAPITestCase`.
@MainActor
final class ControlOverlaySplitUITests: ControlAPITestCase {
    // session.overlay.open requires a command.
    func testOverlayOpenRequiresCommand() throws {
        let response = try sendCommand(#"{"cmd":"session.overlay.open","target":"active"}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "open with no command should fail: \(response)")
        XCTAssertEqual(response["error"] as? String, "session.overlay.open requires a command", "\(response)")
    }

    // `cat` waits on stdin, which is what keeps the overlay up long enough to assert against.
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

    // a raw JSON client skips the CLI's validate(), so the dispatcher is the real enforcement boundary.
    // Geometry is a Metal surface, not in the AX tree, so only the command path is asserted.
    func testOverlayResizeSwitchesFloatingAndFull() throws {
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let result = try XCTUnwrap(created["result"] as? [String: Any], "session.new should carry a result")
        let id = try XCTUnwrap(result["id"] as? String, "session.new should return the new id")

        let noOverlay = try sendCommand(#"{"cmd":"session.overlay.resize","target":"\#(id)","args":{"sizePercent":60}}"#)
        XCTAssertEqual(noOverlay["ok"] as? Bool, false, "resize with no overlay should fail: \(noOverlay)")
        XCTAssertEqual(noOverlay["error"] as? String, "no overlay", "\(noOverlay)")

        let open = try sendCommand(#"{"cmd":"session.overlay.open","target":"\#(id)","args":{"command":"cat"}}"#)
        XCTAssertEqual(open["ok"] as? Bool, true, "overlay open should succeed: \(open)")
        XCTAssertTrue(pollSessionOverlay(id: id, expected: true, timeout: 10), "the overlay should be up")

        let toFloating = try sendCommand(#"{"cmd":"session.overlay.resize","target":"\#(id)","args":{"sizePercent":60}}"#)
        XCTAssertEqual(toFloating["ok"] as? Bool, true, "resize to floating should succeed: \(toFloating)")
        XCTAssertTrue(pollSessionOverlay(id: id, expected: true, timeout: 5), "the overlay stays up after resize")

        let toFull = try sendCommand(#"{"cmd":"session.overlay.resize","target":"\#(id)","args":{"full":true}}"#)
        XCTAssertEqual(toFull["ok"] as? Bool, true, "resize back to full should succeed: \(toFull)")

        let neither = try sendCommand(#"{"cmd":"session.overlay.resize","target":"\#(id)"}"#)
        XCTAssertEqual(neither["ok"] as? Bool, false, "resize with neither arg should fail: \(neither)")
        let both = try sendCommand(#"{"cmd":"session.overlay.resize","target":"\#(id)","args":{"sizePercent":50,"full":true}}"#)
        XCTAssertEqual(both["ok"] as? Bool, false, "resize with both args should fail: \(both)")
        let oob = try sendCommand(#"{"cmd":"session.overlay.resize","target":"\#(id)","args":{"sizePercent":150}}"#)
        XCTAssertEqual(oob["ok"] as? Bool, false, "resize with out-of-range percent should fail: \(oob)")

        let close = try sendCommand(#"{"cmd":"session.overlay.close","target":"\#(id)"}"#)
        XCTAssertEqual(close["ok"] as? Bool, true, "overlay close should succeed: \(close)")
    }

    // the colored surface is a Metal layer, not in the AX tree, so only the arm is asserted.
    func testOverlayOpenWithBackgroundColorAndRejectsBadColor() throws {
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let result = try XCTUnwrap(created["result"] as? [String: Any], "session.new should carry a result")
        let id = try XCTUnwrap(result["id"] as? String, "session.new should return the new id")

        let bad = try sendCommand(#"{"cmd":"session.overlay.open","target":"\#(id)","args":{"command":"cat","color":"purple"}}"#)
        XCTAssertEqual(bad["ok"] as? Bool, false, "a malformed color should be rejected: \(bad)")
        XCTAssertEqual(bad["error"] as? String, "invalid color: purple (#rrggbb)", "\(bad)")
        XCTAssertTrue(pollSessionOverlay(id: id, expected: false, timeout: 5), "the rejected open must not open an overlay")

        // ##"…"## delimiters: the value's leading `"#` would close a `#"…"#` raw string.
        let open = try sendCommand(##"{"cmd":"session.overlay.open","target":"\##(id)","args":{"command":"cat","color":"#2a1a3a"}}"##)
        XCTAssertEqual(open["ok"] as? Bool, true, "overlay open with a valid color should succeed: \(open)")
        XCTAssertTrue(pollSessionOverlay(id: id, expected: true, timeout: 10), "the colored overlay should be up")

        let close = try sendCommand(#"{"cmd":"session.overlay.close","target":"\#(id)"}"#)
        XCTAssertEqual(close["ok"] as? Bool, true, "overlay close should succeed: \(close)")
    }

    // the marker proves the command ran INSIDE the overlay; the cleared flag proves it vanished unaided.
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

    func testOverlayResultReportsExitCode() throws {
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let result = try XCTUnwrap(created["result"] as? [String: Any], "session.new should carry a result")
        let id = try XCTUnwrap(result["id"] as? String, "session.new should return the new id")

        let open = try sendCommand(#"{"cmd":"session.overlay.open","target":"\#(id)","args":{"command":"sh -c 'exit 7'"}}"#)
        XCTAssertEqual(open["ok"] as? Bool, true, "overlay open should succeed: \(open)")

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

    func testOverlayResultStillRunningThenClosed() throws {
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let result = try XCTUnwrap(created["result"] as? [String: Any], "session.new should carry a result")
        let id = try XCTUnwrap(result["id"] as? String, "session.new should return the new id")

        // `cat` with no input blocks indefinitely, so the overlay stays up.
        let open = try sendCommand(#"{"cmd":"session.overlay.open","target":"\#(id)","args":{"command":"cat"}}"#)
        XCTAssertEqual(open["ok"] as? Bool, true, "overlay open should succeed: \(open)")
        XCTAssertTrue(pollSessionOverlay(id: id, expected: true, timeout: 10), "the overlay should be up")

        let running = try sendCommand(#"{"cmd":"session.overlay.result","target":"\#(id)"}"#)
        XCTAssertEqual(running["ok"] as? Bool, false, "result should error while the overlay is running")
        XCTAssertEqual(running["error"] as? String, "overlay still running")

        let closed = try sendCommand(#"{"cmd":"session.overlay.close","target":"\#(id)"}"#)
        XCTAssertEqual(closed["ok"] as? Bool, true, "overlay close should succeed: \(closed)")
        XCTAssertTrue(pollSessionOverlay(id: id, expected: false, timeout: 10), "the overlay should be gone")

        // killed before the wrapper's `echo $?`, so no status was recorded.
        let after = try sendCommand(#"{"cmd":"session.overlay.result","target":"\#(id)"}"#)
        XCTAssertEqual(after["ok"] as? Bool, false, "result should error when no status was recorded")
        XCTAssertEqual(after["error"] as? String, "no overlay result")
    }

    // DISCRIMINATING: the overlay shell's `read` first proves the overlay HELD focus, or the after-close
    // assertion would pass vacuously.
    func testOverlayCloseReturnsFocusToSession() throws {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let treeResult = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let root = try XCTUnwrap(treeResult["tree"] as? [String: Any], "result should carry a tree")
        let workspaces = try XCTUnwrap(root["workspaces"] as? [[String: Any]], "tree should list workspaces")
        let sessions = try XCTUnwrap(workspaces.first?["sessions"] as? [[String: Any]], "workspace should list sessions")
        let id = try XCTUnwrap(sessions.first?["id"] as? String, "should have a seeded session id")

        // injected directly into the surface, so the capture is independent of focus.
        let sessionTTY = markerDir.appendingPathComponent("session-tty")
        XCTAssertEqual(try sendCommand(typeRequest(text: "tty > '\(sessionTTY.path)'\n", target: id, select: false))["ok"] as? Bool,
                       true, "typing tty into the session should succeed")
        let sessionTtyValue = try XCTUnwrap(pollMarker(sessionTTY, timeout: 12), "the session should report its tty")

        // the captured line proves the overlay holds keyboard focus.
        let ovlMarker = markerDir.appendingPathComponent("overlay-keys")
        let ovlCmd = "sh -c 'IFS= read -r x; printf %s \"$x\" > \(ovlMarker.path); cat'"
        let ovlJSON = try! JSONSerialization.data(withJSONObject:
            ["cmd": "session.overlay.open", "target": id, "args": ["command": ovlCmd]])
        let open = try sendCommand(String(data: ovlJSON, encoding: .utf8)!)
        XCTAssertEqual(open["ok"] as? Bool, true, "overlay open should succeed: \(open)")
        XCTAssertTrue(pollSessionOverlay(id: id, expected: true, timeout: 10), "the overlay should be up")

        usleep(800_000) // let the overlay surface attach, grab focus, and the shell reach `read`
        app.typeText("OVLFOCUS")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(pollMarker(ovlMarker, timeout: 12), "OVLFOCUS",
                       "the overlay must hold keyboard focus while open (else this test can't assert the handoff)")

        let close = try sendCommand(#"{"cmd":"session.overlay.close","target":"\#(id)"}"#)
        XCTAssertEqual(close["ok"] as? Bool, true, "overlay close should succeed: \(close)")
        XCTAssertTrue(pollSessionOverlay(id: id, expected: false, timeout: 10), "the overlay should be gone")

        // focus return is async (a bounded makeFirstResponder retry), so a single burst can land before
        // the session is first responder. Re-typing the tty line is idempotent.
        let afterTTY = markerDir.appendingPathComponent("after-close-tty")
        let afterValue = keyboardTypeUntilMarker("tty > '\(afterTTY.path)'", file: afterTTY)
        XCTAssertNotNil(afterValue, "after overlay close, keyboard focus should return to the session terminal")
        XCTAssertEqual(afterValue, sessionTtyValue, "focus should return to the SAME session terminal, not be lost")
    }

    // a sidebar click must restore focus to the cover ON TOP, not the pane behind it — otherwise the
    // cover's program silently stops receiving input.
    //
    // the pre-click line is load-bearing: it proves the cover's own auto-focus retry has FINISHED, so a
    // retry still in flight cannot take focus back and mask a steal.
    func testSidebarClickKeepsFocusOnOverlayNotPaneBehind() throws {
        let id = try activeSessionID()
        let pre = markerDir.appendingPathComponent("overlay-pre-click")
        let post = markerDir.appendingPathComponent("overlay-post-click")
        // retyping is NOT idempotent here — each `read` consumes one line — so the markers are polled.
        let ovlCmd = "sh -c 'IFS= read -r a; printf %s \"$a\" > \(pre.path); " +
            "IFS= read -r b; printf %s \"$b\" > \(post.path); cat'"
        let ovlJSON = try! JSONSerialization.data(withJSONObject:
            ["cmd": "session.overlay.open", "target": id, "args": ["command": ovlCmd, "sizePercent": 50]])
        let open = try sendCommand(String(data: ovlJSON, encoding: .utf8)!)
        XCTAssertEqual(open["ok"] as? Bool, true, "floating overlay open should succeed: \(open)")
        XCTAssertTrue(pollSessionOverlay(id: id, expected: true, timeout: 10), "the floating overlay should be up")
        usleep(800_000) // let the overlay surface attach, grab focus, and the shell reach the first `read`

        assertSidebarClickKeepsFocusOnCover(pre: pre, post: post, cover: "overlay")
    }

    // the scratch terminal is the other `topmostSurface` branch (scratchActive -> scratchSurface) and is
    // full-coverage, so a sidebar click landing on the pane would type into a shell that is not even visible.
    func testSidebarClickKeepsFocusOnScratchNotPaneBehind() throws {
        let pre = markerDir.appendingPathComponent("scratch-pre-click")
        let post = markerDir.appendingPathComponent("scratch-post-click")
        let cmd = "sh -c 'IFS= read -r a; printf %s \"$a\" > \(pre.path); " +
            "IFS= read -r b; printf %s \"$b\" > \(post.path); cat'"
        let json = try! JSONSerialization.data(withJSONObject:
            ["cmd": "session.scratch", "target": "active", "args": ["mode": "on", "command": cmd]])
        let show = try sendCommand(String(data: json, encoding: .utf8)!)
        XCTAssertEqual(show["ok"] as? Bool, true, "showing the scratch should succeed: \(show)")
        XCTAssertTrue(pollActiveSessionScratch(true, timeout: 10), "the scratch should be up")
        usleep(800_000) // let the scratch surface attach, grab focus, and the shell reach the first `read`

        assertSidebarClickKeepsFocusOnCover(pre: pre, post: post, cover: "scratch")
    }

    // a pane's shell exiting collapses the split and re-hosts the survivor, so its `onExit` re-grabs first
    // responder. while a cover is up that grab must land on the cover, not on the surviving pane underneath
    // it — otherwise finishing a command in a background pane silently steals the keyboard from the overlay.
    func testPaneExitUnderOverlayKeepsFocusOnOverlay() throws {
        let id = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(id)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "opening the split should succeed")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the split should be up")

        let pre = markerDir.appendingPathComponent("paneexit-pre")
        let post = markerDir.appendingPathComponent("paneexit-post")
        let ovlCmd = "sh -c 'IFS= read -r a; printf %s \"$a\" > \(pre.path); " +
            "IFS= read -r b; printf %s \"$b\" > \(post.path); cat'"
        let ovlJSON = try! JSONSerialization.data(withJSONObject:
            ["cmd": "session.overlay.open", "target": id, "args": ["command": ovlCmd, "sizePercent": 50]])
        XCTAssertEqual(try sendCommand(String(data: ovlJSON, encoding: .utf8)!)["ok"] as? Bool, true,
                       "floating overlay open should succeed")
        XCTAssertTrue(pollSessionOverlay(id: id, expected: true, timeout: 10), "the overlay should be up")
        usleep(800_000) // let the overlay attach, grab focus, and its shell reach the first `read`

        // prove the overlay owns the keyboard before the exit, so a later steal is attributable to onExit.
        app.typeText("PRECLICK")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(pollMarker(pre, timeout: 12), "PRECLICK", "the overlay must hold keyboard focus before the exit")

        // exit the MAIN pane's shell by injecting into its surface directly (injection is focus-independent,
        // so this drives closePrimaryPane -> onExit without touching first responder).
        let typeJSON = try! JSONSerialization.data(withJSONObject:
            ["cmd": "session.type", "target": id, "args": ["text": "exit\n", "pane": "left"]])
        XCTAssertEqual(try sendCommand(String(data: typeJSON, encoding: .utf8)!)["ok"] as? Bool, true,
                       "typing exit into the main pane should succeed")
        // the split pane is promoted to the sole pane, so the session stops reporting a split.
        XCTAssertTrue(pollActiveSessionSplit(false, timeout: 12), "the main pane's exit should collapse the split")
        usleep(500_000) // onExit's focusAfterReparent retries; no observable signal to poll on

        app.typeText("OVLCLICK")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(pollMarker(post, timeout: 12), "OVLCLICK",
                       "a pane exit under an overlay must leave focus on the overlay, not the surviving pane")
    }

    /// Shared body of the two sidebar-click focus tests: prove the cover holds focus, click the covered
    /// session's own sidebar row (selection is a no-op, but the sidebar's focus-restore runs), then prove
    /// the keyboard still reaches the cover rather than the pane it sits on.
    private func assertSidebarClickKeepsFocusOnCover(pre: URL, post: URL, cover: String) {
        app.typeText("PRECLICK")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(pollMarker(pre, timeout: 12), "PRECLICK",
                       "the \(cover) must hold keyboard focus before the click (else this test can't assert a steal)")

        let row = app.staticTexts["session-row"].firstMatch
        XCTAssertTrue(row.isHittable, "the covered session's sidebar row should be clickable")
        row.click()
        usleep(500_000) // the sidebar's focus-restore runs off the click; no observable signal to poll on

        app.typeText("OVLCLICK")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(pollMarker(post, timeout: 12), "OVLCLICK",
                       "a sidebar click must restore focus to the \(cover), not the pane behind it")
    }

    // a FULL overlay opened in a BACKGROUND (non-selected) session must NOT steal keyboard first responder.
    // the overlay's auto-focus is gated on its deck slot being active (deckActive), so typing reaches the
    // still-visible active session, not the hidden overlay. guards the focus-steal bug where a revdiff overlay
    // in a non-active session silently swallowed input typed into the active session.
    func testBackgroundSessionOverlayDoesNotStealKeyboardFocus() throws {
        // seeded session A is the visible/active one.
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let treeResult = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let root = try XCTUnwrap(treeResult["tree"] as? [String: Any], "result should carry a tree")
        let workspaces = try XCTUnwrap(root["workspaces"] as? [[String: Any]], "tree should list workspaces")
        let sessions = try XCTUnwrap(workspaces.first?["sessions"] as? [[String: Any]], "workspace should list sessions")
        let sessionA = try XCTUnwrap(sessions.first?["id"] as? String, "should have a seeded session id")

        // create a second session B; session.new focuses the new session, so re-select A to make B a
        // background (mounted-but-hidden) deck slot — the exact setup where the overlay opens out of view.
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let sessionB = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String,
                                     "session.new should return the new id")
        XCTAssertTrue(pollSessionCount(2, timeout: 10), "the second session should land")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(sessionA)"}"#)["ok"] as? Bool, true,
                       "re-selecting A should succeed so B is the background session")

        // capture A's tty by injecting directly into its surface (focus-independent): the oracle for
        // "the keyboard reached the active session A".
        let ttyA = markerDir.appendingPathComponent("session-a-tty")
        let ttyAValue = try XCTUnwrap(typeUntilMarker("tty > '\(ttyA.path)'\n", target: sessionA, file: ttyA, select: false),
                                      "the active session A should report its tty")

        // open a FULL overlay (no sizePercent) in the BACKGROUND session B; its shell captures one keyboard
        // line into a marker then stays alive (cat). a captured marker would mean the hidden overlay stole
        // first responder.
        let ovlMarker = markerDir.appendingPathComponent("bg-overlay-keys")
        let ovlCmd = "sh -c 'IFS= read -r x; printf %s \"$x\" > \(ovlMarker.path); cat'"
        let ovlJSON = try! JSONSerialization.data(withJSONObject:
            ["cmd": "session.overlay.open", "target": sessionB, "args": ["command": ovlCmd]])
        XCTAssertEqual(try sendCommand(String(data: ovlJSON, encoding: .utf8)!)["ok"] as? Bool, true,
                       "opening a full overlay in the background session should succeed")
        XCTAssertTrue(pollSessionOverlay(id: sessionB, expected: true, timeout: 10), "B's overlay should be up")
        // give a buggy build ample time to grab focus and reach the overlay shell's `read`.
        usleep(800_000)

        // type via the real keyboard: with the fix it reaches the visible active session A (writing A's tty);
        // with the bug it goes to B's hidden overlay (writing ovlMarker, then swallowed by cat).
        let afterTTY = markerDir.appendingPathComponent("after-type-tty")
        // unwrap first so a nil (active session never received the keystrokes — the bug) reads clearly,
        // distinct from a non-nil-but-wrong tty (keystrokes reached some other surface).
        let afterValue = try XCTUnwrap(keyboardTypeUntilMarker("tty > '\(afterTTY.path)'", file: afterTTY),
                                       "keyboard input must reach the active session (its tty marker should be written)")
        XCTAssertEqual(afterValue, ttyAValue,
                       "keyboard input must reach the visible active session, not the background overlay")
        XCTAssertNil(pollMarker(ovlMarker, timeout: 2),
                     "the background session's overlay must NOT capture keyboard input")
    }

    // a FULL overlay opened on a BACKGROUND target with no `follow` runs its program in the eager deck
    // WITHOUT changing the active session: create A (background), then B (active), open the overlay on A,
    // assert its program ran (overlay.result reports an exit code) and the active session is still B.
    func testOverlayOpenDefaultDoesNotSwitchActiveSession() throws {
        let a = try newSession() // first session
        let b = try newSession() // second session becomes active, so A is a background (non-selected) session
        XCTAssertTrue(pollActiveSessionID(b, timeout: 10), "B should be the active session after creation")

        let open = try sendCommand(#"{"cmd":"session.overlay.open","target":"\#(a.uuidString)","args":{"command":"sh -c 'exit 3'"}}"#)
        XCTAssertEqual(open["ok"] as? Bool, true, "opening a full overlay on the background session should succeed: \(open)")

        // the program runs in the background (mounts in the eager deck); overlay.result reports its exit code.
        XCTAssertEqual(pollOverlayExitCode(target: a.uuidString, timeout: 15), 3,
                       "the background full overlay's program should run and report its exit code")
        // the active session is unchanged — a default (no follow) open does NOT switch to the target.
        XCTAssertTrue(pollActiveSessionID(b, timeout: 5), "a default (no follow) open must not change the active session")
    }

    // a FLOATING overlay (sizePercent) opened on a BACKGROUND target with no `follow` runs its program in
    // the eager deck WITHOUT changing the active session — the core parity assertion. Before the in-deck
    // render, a floating overlay only mounted for the active session, so a background floating overlay never
    // ran (its exit code would never appear); this proves it now runs like the full overlay does.
    func testFloatingOverlayOnBackgroundRunsWithoutSwitch() throws {
        let a = try newSession()
        let b = try newSession() // active; A is background
        XCTAssertTrue(pollActiveSessionID(b, timeout: 10), "B should be the active session after creation")

        let open = try sendCommand(#"{"cmd":"session.overlay.open","target":"\#(a.uuidString)","args":{"command":"sh -c 'exit 5'","sizePercent":70}}"#)
        XCTAssertEqual(open["ok"] as? Bool, true, "opening a floating overlay on the background session should succeed: \(open)")

        // the floating overlay's program must run in the background (mounts in the eager deck like the full one).
        XCTAssertEqual(pollOverlayExitCode(target: a.uuidString, timeout: 15), 5,
                       "the background floating overlay's program should run and report its exit code")
        XCTAssertTrue(pollActiveSessionID(b, timeout: 5), "a default (no follow) floating open must not change the active session")
    }

    // `follow: true` on a BACKGROUND target switches the active session to that target — for BOTH the full
    // and the floating overlay (two distinct background targets, since only one overlay may be open per
    // session). `cat` blocks so each overlay stays up; the assertion is purely that the selection switched.
    func testOverlayOpenFollowSwitchesToTarget() throws {
        let full = try newSession()     // background target for the full overlay
        let floating = try newSession() // background target for the floating overlay
        let active = try newSession()   // newest session is active; both targets are background
        XCTAssertTrue(pollActiveSessionID(active, timeout: 10), "the newest session should be active before the follow-opens")

        // FULL overlay with follow → the active session becomes the full target.
        let openFull = try sendCommand(#"{"cmd":"session.overlay.open","target":"\#(full.uuidString)","args":{"command":"cat","follow":true}}"#)
        XCTAssertEqual(openFull["ok"] as? Bool, true, "full overlay open with follow should succeed: \(openFull)")
        XCTAssertTrue(pollActiveSessionID(full, timeout: 10), "follow must switch the active session to the full-overlay target")
        XCTAssertTrue(pollSessionOverlay(id: full.uuidString, expected: true, timeout: 10),
                      "the full overlay must actually mount on its target, not just select it")

        // FLOATING overlay with follow → the active session becomes the (different, background) floating target.
        let openFloat = try sendCommand(#"{"cmd":"session.overlay.open","target":"\#(floating.uuidString)","args":{"command":"cat","sizePercent":70,"follow":true}}"#)
        XCTAssertEqual(openFloat["ok"] as? Bool, true, "floating overlay open with follow should succeed: \(openFloat)")
        XCTAssertTrue(pollActiveSessionID(floating, timeout: 10), "follow must switch the active session to the floating-overlay target")
        XCTAssertTrue(pollSessionOverlay(id: floating.uuidString, expected: true, timeout: 10),
                      "the floating overlay must actually mount on its target, not just select it")
    }

    // `follow: true` targeting the ALREADY-active session succeeds and stays on it (the select is a no-op).
    func testOverlayOpenFollowOnActiveSessionIsNoop() throws {
        let a = try newSession()
        let b = try newSession() // B is active
        XCTAssertTrue(pollActiveSessionID(b, timeout: 10), "B should be the active session after creation")

        let open = try sendCommand(#"{"cmd":"session.overlay.open","target":"\#(b.uuidString)","args":{"command":"cat","follow":true}}"#)
        XCTAssertEqual(open["ok"] as? Bool, true, "follow on the already-active session should succeed: \(open)")
        XCTAssertTrue(pollSessionOverlay(id: b.uuidString, expected: true, timeout: 10), "the overlay should be up on B")
        XCTAssertTrue(pollActiveSessionID(b, timeout: 5), "follow on the already-active session must stay on it")
    }

    // session.split toggle shows split:true in the tree; off hides it (keep-alive, mirrors ⌘D — the
    // pane's surface is NOT destroyed, only closeSplit does that), clearing split:false.
    func testSessionSplitToggle() throws {
        let split = try sendCommand(#"{"cmd":"session.split","target":"active","args":{"mode":"toggle"}}"#)
        XCTAssertEqual(split["ok"] as? Bool, true, "session.split toggle should succeed: \(split)")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the active session should report split:true")

        let unsplit = try sendCommand(#"{"cmd":"session.split","target":"active","args":{"mode":"off"}}"#)
        XCTAssertEqual(unsplit["ok"] as? Bool, true, "session.split off should succeed: \(unsplit)")
        XCTAssertTrue(pollActiveSessionSplit(false, timeout: 10), "off should clear the split")
    }

    // the tree is the only surface that tells a hidden pane from a closed one.
    func testSessionSplitCloseTearsDownAHiddenPane() throws {
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"active","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "session.split on should succeed")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the active session should report split:true")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"active","args":{"mode":"off"}}"#)["ok"] as? Bool,
                       true, "session.split off should succeed")
        XCTAssertTrue(pollActiveSessionSplit(false, timeout: 10), "off should hide the split")
        XCTAssertEqual(try activeSessionNode()["hasSplit"] as? Bool, true, "a hidden pane is still alive")

        let closed = try sendCommand(#"{"cmd":"session.split.close","target":"active"}"#)
        XCTAssertEqual(closed["ok"] as? Bool, true, "session.split.close should succeed: \(closed)")

        var node = try activeSessionNode()
        let deadline = Date().addingTimeInterval(10)
        while node["hasSplit"] != nil, Date() < deadline {
            usleep(200_000)
            node = try activeSessionNode()
        }
        XCTAssertNil(node["hasSplit"], "closing drops the pane out of the tree entirely")
        XCTAssertNil(node["splitFocused"], "and the fields that ride on it")

        let again = try sendCommand(#"{"cmd":"session.split.close","target":"active"}"#)
        XCTAssertEqual(again["ok"] as? Bool, true, "closing with no split is ok, not an error: \(again)")
    }

    /// The active session's `tree` node, so a test can read fields the hermetic snapshot does not persist.
    private func activeSessionNode() throws -> [String: Any] {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let treeResult = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let root = try XCTUnwrap(treeResult["tree"] as? [String: Any], "result should carry a tree")
        let workspaces = try XCTUnwrap(root["workspaces"] as? [[String: Any]], "tree should list workspaces")
        let sessions = try XCTUnwrap(workspaces.first?["sessions"] as? [[String: Any]], "workspace should list sessions")
        return try XCTUnwrap(sessions.first, "should have a seeded session")
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

    // ⌘W with the scratch shown DISMISSES the scratch, not the session under it. The scratch renders
    // full-pane over the active session, so the close shortcut must target the cover, not the hidden session.
    func testCloseSessionShortcutHidesScratchInsteadOfClosingSession() throws {
        let on = try sendCommand(#"{"cmd":"session.scratch","target":"active","args":{"mode":"on"}}"#)
        XCTAssertEqual(on["ok"] as? Bool, true, "session.scratch on should succeed: \(on)")
        XCTAssertTrue(pollActiveSessionScratch(true, timeout: 10), "the scratch should be shown")

        app.activate() // set up entirely over the socket, so ensure the app is frontmost before ⌘W
        app.typeKey("w", modifierFlags: .command)

        // the flag poll is the real oracle: a CLOSED session vanishes from the tree, so scratch:false can
        // never be observed and this times out (catching the bug). row-count is a post-dismiss invariant
        // (checked AFTER the dismiss so it can't early-return on stale pre-close state).
        XCTAssertTrue(pollActiveSessionScratch(false, timeout: 10), "⌘W should hide the scratch")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "⌘W must not close the session behind the scratch")
    }

    // ⌘W with a full overlay up DISMISSES the overlay (closes it), not the session under it. `cat` blocks
    // so the overlay stays up until ⌘W; the session row surviving proves the session wasn't closed instead.
    func testCloseSessionShortcutClosesOverlayInsteadOfClosingSession() throws {
        let seededID = try activeSessionID()

        let open = try sendCommand(#"{"cmd":"session.overlay.open","target":"\#(seededID)","args":{"command":"cat"}}"#)
        XCTAssertEqual(open["ok"] as? Bool, true, "overlay open should succeed: \(open)")
        XCTAssertTrue(pollSessionOverlay(id: seededID, expected: true, timeout: 10), "the overlay should be up")

        app.activate()
        app.typeKey("w", modifierFlags: .command)

        XCTAssertTrue(pollSessionOverlay(id: seededID, expected: false, timeout: 10), "⌘W should close the overlay")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "⌘W must not close the session behind the overlay")
    }

    // ⌘W closes a FLOATING overlay (sizePercent set, session visible behind it) without closing the session.
    // The floating overlay still holds first responder, so the close shortcut targets it, not the session.
    func testCloseSessionShortcutClosesFloatingOverlayInsteadOfClosingSession() throws {
        let seededID = try activeSessionID()

        let open = try sendCommand(#"{"cmd":"session.overlay.open","target":"\#(seededID)","args":{"command":"cat","sizePercent":70}}"#)
        XCTAssertEqual(open["ok"] as? Bool, true, "floating overlay open should succeed: \(open)")
        XCTAssertTrue(pollSessionOverlay(id: seededID, expected: true, timeout: 10), "the floating overlay should be up")

        app.activate()
        app.typeKey("w", modifierFlags: .command)

        XCTAssertTrue(pollSessionOverlay(id: seededID, expected: false, timeout: 10), "⌘W should close the floating overlay")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "⌘W must not close the session behind the floating overlay")
    }

    // ⌘W peels stacked covers in z-order: a full overlay (zIndex 2) opened over a shown scratch (zIndex 1).
    // First ⌘W closes the overlay (scratch stays), second ⌘W hides the scratch, and the session survives both.
    func testCloseSessionShortcutPeelsStackedCoversInPrecedenceOrder() throws {
        let seededID = try activeSessionID()

        let onScratch = try sendCommand(#"{"cmd":"session.scratch","target":"active","args":{"mode":"on"}}"#)
        XCTAssertEqual(onScratch["ok"] as? Bool, true, "session.scratch on should succeed: \(onScratch)")
        XCTAssertTrue(pollActiveSessionScratch(true, timeout: 10), "the scratch should be shown")

        let open = try sendCommand(#"{"cmd":"session.overlay.open","target":"\#(seededID)","args":{"command":"cat"}}"#)
        XCTAssertEqual(open["ok"] as? Bool, true, "overlay open over the scratch should succeed: \(open)")
        XCTAssertTrue(pollSessionOverlay(id: seededID, expected: true, timeout: 10), "the overlay should be up over the scratch")

        app.activate()
        // ⌘W #1: the overlay is topmost, so it closes; the scratch stays shown.
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(pollSessionOverlay(id: seededID, expected: false, timeout: 10), "⌘W #1 should close the overlay")
        XCTAssertTrue(pollActiveSessionScratch(true, timeout: 10), "the scratch should remain after the overlay closes")

        app.activate()
        // ⌘W #2: now the scratch is topmost, so it hides.
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(pollActiveSessionScratch(false, timeout: 10), "⌘W #2 should hide the scratch")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "the session survives peeling both covers")
    }

    // session.scratch --command runs the command AS the scratch's process (not a shell): the command
    // writes a marker file, proving it ran. It exits immediately (run-once), so the scratch then closes —
    // the marker is the oracle. The command is argv-style (no shell), so the redirect is wrapped in sh -c.
    func testSessionScratchCommandRunsAsProcess() throws {
        let marker = NSTemporaryDirectory() + "agterm-scratchcmd-\(UUID().uuidString).txt"
        let payload: [String: Any] = ["cmd": "session.scratch", "target": "active",
                                      "args": ["mode": "on", "command": "sh -c 'printf SCRATCHRAN > \(marker)'"]]
        let line = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        let resp = try sendCommand(line)
        XCTAssertEqual(resp["ok"] as? Bool, true, "session.scratch --command should succeed: \(resp)")

        var ran = false
        for _ in 0..<40 {
            if let s = try? String(contentsOfFile: marker, encoding: .utf8), s == "SCRATCHRAN" { ran = true; break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertTrue(ran, "the scratch command should run as the scratch's process")
        try? FileManager.default.removeItem(atPath: marker)
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
        XCTAssertTrue((notSplit["error"] as? String ?? "").contains("no split"), "should report no split: \(notSplit)")

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

    // session.resize errors on a non-split session, sets an absolute fraction (clamped) and a relative
    // nudge on a split, persists it to workspaces.json, and rejects a request carrying no fraction.
    func testSessionResizeSplitDivider() throws {
        let notSplit = try sendCommand(#"{"cmd":"session.resize","target":"active","args":{"ratio":0.7}}"#)
        XCTAssertEqual(notSplit["ok"] as? Bool, false, "resize on a non-split session should fail: \(notSplit)")
        XCTAssertTrue((notSplit["error"] as? String ?? "").contains("no split"), "should report no split: \(notSplit)")

        let split = try sendCommand(#"{"cmd":"session.split","target":"active","args":{"mode":"on"}}"#)
        XCTAssertEqual(split["ok"] as? Bool, true, "split on should succeed: \(split)")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the active session should report split:true")

        // relative nudge from the nil base (0.5 default) before any absolute set: grow-left 0.1 -> 0.6.
        let fromDefault = try sendCommand(#"{"cmd":"session.resize","target":"active","args":{"ratioDelta":0.1}}"#)
        XCTAssertEqual(fromDefault["ok"] as? Bool, true, "nudge from default should succeed: \(fromDefault)")
        XCTAssertEqual((fromDefault["result"] as? [String: Any])?["ratio"] as? Double ?? -1, 0.6, accuracy: 0.0001,
                       "0.5 default + 0.1 = 0.6: \(fromDefault)")

        // server rejects both fraction forms at once — the CLI's validate() blocks this, but a raw client can send it.
        let both = try sendCommand(#"{"cmd":"session.resize","target":"active","args":{"ratio":0.7,"ratioDelta":0.1}}"#)
        XCTAssertEqual(both["ok"] as? Bool, false, "both ratio and delta should fail: \(both)")
        XCTAssertTrue((both["error"] as? String ?? "").contains("mutually exclusive"), "should report mutual exclusion: \(both)")

        // absolute fraction: echoed in result.ratio and persisted to the snapshot.
        let abs = try sendCommand(#"{"cmd":"session.resize","target":"active","args":{"ratio":0.7}}"#)
        XCTAssertEqual(abs["ok"] as? Bool, true, "absolute resize should succeed: \(abs)")
        XCTAssertEqual((abs["result"] as? [String: Any])?["ratio"] as? Double ?? -1, 0.7, accuracy: 0.0001,
                       "should echo the applied ratio: \(abs)")
        XCTAssertTrue(pollSplitRatio(0.7, timeout: 10), "0.7 should land in workspaces.json")

        // out-of-range absolute clamps to the cap (0.95).
        let clamped = try sendCommand(#"{"cmd":"session.resize","target":"active","args":{"ratio":2.0}}"#)
        XCTAssertEqual(clamped["ok"] as? Bool, true, "clamped resize should succeed: \(clamped)")
        XCTAssertEqual((clamped["result"] as? [String: Any])?["ratio"] as? Double ?? -1, 0.95, accuracy: 0.0001,
                       "2.0 should clamp to 0.95: \(clamped)")

        // relative nudge: grow-right 0.1 (a negative delta) from 0.95 lands at 0.85.
        let nudged = try sendCommand(#"{"cmd":"session.resize","target":"active","args":{"ratioDelta":-0.1}}"#)
        XCTAssertEqual(nudged["ok"] as? Bool, true, "relative resize should succeed: \(nudged)")
        XCTAssertEqual((nudged["result"] as? [String: Any])?["ratio"] as? Double ?? -1, 0.85, accuracy: 0.0001,
                       "0.95 - 0.1 = 0.85: \(nudged)")

        // neither a ratio nor a delta is a usage error.
        let empty = try sendCommand(#"{"cmd":"session.resize","target":"active","args":{}}"#)
        XCTAssertEqual(empty["ok"] as? Bool, false, "resize with no fraction should fail: \(empty)")
    }

    // the GUI half of session.resize. Real mouse events are the point: the gesture is recognized from a
    // shared local event monitor, which only sees the second press once the first one's divider-drag
    // tracking loop has ended, and nothing below the app can stand in for that.
    func testDoubleClickOnDividerRestoresEvenSplit() throws {
        let split = try sendCommand(#"{"cmd":"session.split","target":"active","args":{"mode":"on"}}"#)
        XCTAssertEqual(split["ok"] as? Bool, true, "split on should succeed: \(split)")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the active session should report split:true")

        let offset = try sendCommand(#"{"cmd":"session.resize","target":"active","args":{"ratio":0.7}}"#)
        XCTAssertEqual(offset["ok"] as? Bool, true, "absolute resize should succeed: \(offset)")
        XCTAssertTrue(pollSplitRatio(0.7, timeout: 10), "the divider should start off center")

        let divider = app.splitters.firstMatch
        XCTAssertTrue(divider.waitForExistence(timeout: 8), "the split should publish a divider")
        divider.doubleClick()
        XCTAssertTrue(pollSplitRatio(0.5, timeout: 10), "double-clicking the divider should restore the even split")
    }

    // the divider-normalize regression guard. A pane overlay renders INSIDE the NSSplitView's arranged
    // subview, so mounting or freeing one must never re-lay-out the split. `splitRatio` in the tree is
    // captured off the LIVE NSSplitView by `SplitRatioAccessor`, so a normalize surfaces here as 0.5.
    func testPaneOverlayOpenAndCloseKeepSplitRatio() throws {
        let id = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(id)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "opening the split should succeed")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the split should be up")

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.resize","target":"\#(id)","args":{"ratio":0.3}}"#)["ok"] as? Bool,
                       true, "setting a non-default divider should succeed")
        XCTAssertTrue(pollSplitRatio(0.3, timeout: 10), "0.3 should reach the live divider")

        for pane in ["right", "left"] {
            let marker = markerDir.appendingPathComponent("pane-overlay-\(pane)")
            let cmd = "sh -c 'printf UP > \(marker.path); cat'"
            let json = try! JSONSerialization.data(withJSONObject:
                ["cmd": "session.overlay.open", "target": id, "args": ["command": cmd, "pane": pane]])
            XCTAssertEqual(try sendCommand(String(data: json, encoding: .utf8)!)["ok"] as? Bool, true,
                           "opening the \(pane) pane overlay should succeed")
            // the marker proves the surface REALIZED, so the ratio below is read after whatever layout the
            // mount caused, not before it.
            XCTAssertEqual(pollMarker(marker, timeout: 15), "UP", "the \(pane) pane overlay's program should run")
            XCTAssertTrue(pollPaneOverlays(id: id, contains: pane, timeout: 10),
                          "the tree should report the \(pane) pane overlay")
            settle()
            XCTAssertEqual(try liveSplitRatio(id: id), 0.3, accuracy: 0.02,
                           "opening the \(pane) pane overlay must not move the divider")

            let close = try sendCommand(#"{"cmd":"session.overlay.close","target":"\#(id)","args":{"pane":"\#(pane)"}}"#)
            XCTAssertEqual(close["ok"] as? Bool, true, "closing the \(pane) pane overlay should succeed: \(close)")
            XCTAssertTrue(pollPaneOverlays(id: id, equals: nil, timeout: 10), "no pane overlay should remain")
            settle()
            XCTAssertEqual(try liveSplitRatio(id: id), 0.3, accuracy: 0.02,
                           "closing the \(pane) pane overlay must not move the divider")
        }
    }

    // a pane overlay covers ONE pane, so the sibling stays live and usable. A Metal surface is absent from
    // the AX tree, so the oracle is `tty`: after focusing the UNCOVERED pane, real keyboard input must land
    // in that pane's own shell, and the overlay's `read` must capture nothing.
    func testPaneOverlayLeavesSiblingPaneInteractive() throws {
        let id = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(id)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "opening the split should succeed")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the split should be up")

        // injected, so the capture is independent of focus: the identity the keyboard must reach later.
        let leftTTY = markerDir.appendingPathComponent("left-pane-tty")
        let leftValue = try XCTUnwrap(typeUntilMarker("tty > '\(leftTTY.path)'\n", target: id, file: leftTTY, select: false),
                                      "the left pane should report its tty")

        let ovlMarker = markerDir.appendingPathComponent("right-overlay-keys")
        let ovlCmd = "sh -c 'IFS= read -r x; printf %s \"$x\" > \(ovlMarker.path); cat'"
        let json = try! JSONSerialization.data(withJSONObject:
            ["cmd": "session.overlay.open", "target": id, "args": ["command": ovlCmd, "pane": "right"]])
        XCTAssertEqual(try sendCommand(String(data: json, encoding: .utf8)!)["ok"] as? Bool, true,
                       "opening the right pane overlay should succeed")
        XCTAssertTrue(pollPaneOverlays(id: id, contains: "right", timeout: 10), "the right pane overlay should be up")
        usleep(1_500_000) // let the overlay surface attach and finish its one-shot focus grab

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.focus","target":"\#(id)","args":{"pane":"left"}}"#)["ok"] as? Bool,
                       true, "focusing the uncovered pane should succeed")
        usleep(500_000) // focusSplitPane's bounded makeFirstResponder retry; no observable signal to poll on

        app.activate()
        let afterTTY = markerDir.appendingPathComponent("sibling-after-tty")
        let afterValue = try XCTUnwrap(keyboardTypeUntilMarker("tty > '\(afterTTY.path)'", file: afterTTY),
                                       "the uncovered pane must accept keyboard input while its sibling is covered")
        XCTAssertEqual(afterValue, leftValue, "keyboard input must reach the uncovered LEFT pane, not another surface")
        XCTAssertNil(pollMarker(ovlMarker, timeout: 2),
                     "the right pane's overlay must not capture input meant for the uncovered pane")
    }

    // the two slots are independent, not one overlay carrying a pane tag: both may be up at once and either
    // may close without disturbing the other. `paneOverlays` is ordered left-then-right, so a slot shadowing
    // the other reads back as a missing entry.
    func testBothPaneOverlaysOpenAtOnceAndCloseIndependently() throws {
        let id = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(id)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "opening the split should succeed")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the split should be up")

        var markers: [String: URL] = [:]
        for pane in ["left", "right"] {
            let marker = markerDir.appendingPathComponent("both-\(pane)")
            markers[pane] = marker
            let json = try! JSONSerialization.data(withJSONObject: [
                "cmd": "session.overlay.open", "target": id,
                "args": ["command": "sh -c 'printf \(pane.uppercased()) > \(marker.path); cat'", "pane": pane]])
            XCTAssertEqual(try sendCommand(String(data: json, encoding: .utf8)!)["ok"] as? Bool, true,
                           "opening the \(pane) pane overlay should succeed")
        }
        // each marker proves that pane's OWN surface realized and ran its OWN command, so the read-back below
        // is about two live overlays rather than two occupied slots.
        XCTAssertEqual(pollMarker(markers["left"]!, timeout: 15), "LEFT", "the left pane overlay's program should run")
        XCTAssertEqual(pollMarker(markers["right"]!, timeout: 15), "RIGHT", "the right pane overlay's program should run")
        XCTAssertTrue(pollPaneOverlays(id: id, equals: ["left", "right"], timeout: 10),
                      "both slots should report open, ordered left then right")

        let closeLeft = try sendCommand(#"{"cmd":"session.overlay.close","target":"\#(id)","args":{"pane":"left"}}"#)
        XCTAssertEqual(closeLeft["ok"] as? Bool, true, "closing the left pane overlay should succeed: \(closeLeft)")
        XCTAssertTrue(pollPaneOverlays(id: id, equals: ["right"], timeout: 10),
                      "closing left must leave the right pane overlay up")

        let closeLeftAgain = try sendCommand(#"{"cmd":"session.overlay.close","target":"\#(id)","args":{"pane":"left"}}"#)
        XCTAssertEqual(closeLeftAgain["ok"] as? Bool, false,
                       "the left slot is empty, so a second close should fail: \(closeLeftAgain)")
        XCTAssertEqual(closeLeftAgain["error"] as? String, "no overlay", "\(closeLeftAgain)")

        let closeRight = try sendCommand(#"{"cmd":"session.overlay.close","target":"\#(id)","args":{"pane":"right"}}"#)
        XCTAssertEqual(closeRight["ok"] as? Bool, true, "closing the right pane overlay should succeed: \(closeRight)")
        XCTAssertTrue(pollPaneOverlays(id: id, equals: nil, timeout: 10),
                      "the field should be omitted once no pane overlay remains")
    }

    // the dead-state guard: a pane the detail deck never lays out gets no backing size, so its surface would
    // never be created and the slot would sit active with no program. Hiding the split while the LEFT pane
    // holds focus is exactly that state for the right pane.
    func testPaneOverlayOnHiddenSplitIsRejected() throws {
        let id = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(id)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "opening the split should succeed")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the split should be up")

        // a new split focuses the right pane, and a hidden split shows whichever pane is focused — so focus
        // must move left first or hiding would leave the RIGHT pane the visible one.
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.focus","target":"\#(id)","args":{"pane":"left"}}"#)["ok"] as? Bool,
                       true, "focusing the left pane should succeed")
        XCTAssertTrue(try pollSplitFocused(id, expected: false, timeout: 10), "the left pane should hold focus")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(id)","args":{"mode":"off"}}"#)["ok"] as? Bool,
                       true, "hiding the split should succeed")
        XCTAssertTrue(pollActiveSessionSplit(false, timeout: 10), "the split should be hidden")

        let rejected = try sendCommand(
            #"{"cmd":"session.overlay.open","target":"\#(id)","args":{"command":"cat","pane":"right"}}"#)
        XCTAssertEqual(rejected["ok"] as? Bool, false, "opening on the unrendered pane should fail: \(rejected)")
        XCTAssertEqual(rejected["error"] as? String, "pane not visible", "\(rejected)")
        XCTAssertTrue(pollPaneOverlays(id: id, equals: nil, timeout: 5), "a rejected open must not occupy a slot")

        // the guard is per-pane, not a blanket refusal: the hidden split renders the LEFT pane, which still
        // accepts an overlay.
        let accepted = try sendCommand(
            #"{"cmd":"session.overlay.open","target":"\#(id)","args":{"command":"cat","pane":"left"}}"#)
        XCTAssertEqual(accepted["ok"] as? Bool, true, "the rendered pane should still accept an overlay: \(accepted)")
        XCTAssertTrue(pollPaneOverlays(id: id, equals: ["left"], timeout: 10), "the left pane overlay should be up")
    }

    // ⌘W over a pane overlay DISMISSES the overlay, not the session under it — the cover ladder's last rung.
    // Without it ⌘W falls through to the destructive default and takes the session with it.
    func testCloseSessionShortcutClosesPaneOverlayInsteadOfClosingSession() throws {
        let id = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(id)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "opening the split should succeed")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the split should be up")

        // the ⌘W rung reads `focusedOverlayPane`, which resolves `.right` only while the split SURFACE exists,
        // so the right pane's shell must be live before its overlay opens.
        let ready = markerDir.appendingPathComponent("cmdw-split-ready")
        var readyValue: String?
        for _ in 0..<8 where readyValue == nil {
            let typed = try sendCommand(typeRequest(text: "printf SPLITUP > '\(ready.path)'\n", target: id,
                                                    select: false, pane: "right"))
            // the split surface is built lazily, so an early probe can arrive before it exists; any other
            // error is a real failure.
            guard typed["ok"] as? Bool == true else {
                XCTAssertTrue((typed["error"] as? String ?? "").contains("not realized"),
                              "typing into the split pane should succeed: \(typed)")
                usleep(300_000)
                continue
            }
            readyValue = pollMarker(ready, timeout: 3)
        }
        XCTAssertEqual(readyValue, "SPLITUP", "the right pane's shell should be live before its overlay opens")

        let marker = markerDir.appendingPathComponent("cmdw-pane-overlay")
        let json = try! JSONSerialization.data(withJSONObject: [
            "cmd": "session.overlay.open", "target": id,
            "args": ["command": "sh -c 'printf UP > \(marker.path); cat'", "pane": "right"]])
        XCTAssertEqual(try sendCommand(String(data: json, encoding: .utf8)!)["ok"] as? Bool, true,
                       "opening the right pane overlay should succeed")
        XCTAssertEqual(pollMarker(marker, timeout: 15), "UP", "the pane overlay's program should run")
        XCTAssertTrue(pollPaneOverlays(id: id, equals: ["right"], timeout: 10), "the right pane overlay should be up")
        usleep(800_000) // let the overlay surface attach and take first responder before the shortcut

        app.activate() // set up entirely over the socket, so ensure the app is frontmost before ⌘W
        app.typeKey("w", modifierFlags: .command)

        XCTAssertTrue(pollPaneOverlays(id: id, equals: nil, timeout: 10), "⌘W should close the pane overlay")
        // discriminating: `paneOverlays` also reads absent for a CLOSED session, so the survival checks are
        // what separate "dismissed the cover" from "closed the session under it".
        XCTAssertNotNil(try sessionNodeIfPresent(id: id), "⌘W must not close the session behind the pane overlay")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "the session's sidebar row should survive the dismiss")
    }

    // the pane arm of the overlay lifecycle, the session-wide `testOverlayAutoClosesWhenCommandExits` +
    // `testOverlayResultReportsExitCode` pair at pane scope: the program's exit frees THAT slot unaided and
    // its status survives for `session.overlay.result --pane`, without ever writing the session-wide slot.
    func testPaneOverlayAutoClosesOnExitAndReportsItsOwnStatus() throws {
        let id = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(id)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "opening the split should succeed")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the split should be up")

        let marker = markerDir.appendingPathComponent("pane-overlay-exit")
        let json = try! JSONSerialization.data(withJSONObject: [
            "cmd": "session.overlay.open", "target": id,
            "args": ["command": "sh -c 'printf RAN > \(marker.path); exit 7'", "pane": "right"]])
        XCTAssertEqual(try sendCommand(String(data: json, encoding: .utf8)!)["ok"] as? Bool, true,
                       "opening the right pane overlay should succeed")
        XCTAssertEqual(pollMarker(marker, timeout: 15), "RAN", "the pane overlay's program should run")
        XCTAssertTrue(pollPaneOverlays(id: id, equals: nil, timeout: 12),
                      "the pane overlay should auto-close when its program exits (no press-any-key prompt)")

        XCTAssertEqual(pollOverlayExitCode(target: id, pane: "right", timeout: 15), 7,
                       "session.overlay.result --pane right should report the program's own status")
        // discriminating: a pane overlay must not write the session-wide slot, or a script polling one kind
        // would read the other's status.
        let sessionWide = try sendCommand(#"{"cmd":"session.overlay.result","target":"\#(id)"}"#)
        XCTAssertEqual(sessionWide["ok"] as? Bool, false, "the session-wide slot must stay empty: \(sessionWide)")
        XCTAssertEqual(sessionWide["error"] as? String, "no overlay result", "\(sessionWide)")
    }

    // `closePrimaryPane` MOVES the right pane's overlay into the LEFT slot without rebuilding its surface, so
    // that surface's own exit/status callbacks must resolve the slot they NOW sit in. Pinned end-to-end: with
    // a pane captured at creation the program's exit would close nothing (leaving the promoted pane under a
    // dead overlay forever) and file the status where `--pane left` cannot read it.
    func testPromotedPaneOverlayStillAutoClosesAndReportsOnItsNewPane() throws {
        let id = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(id)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "opening the split should succeed")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the split should be up")

        // the overlay outlives the promotion by waiting on a file the test creates, so the exit is ordered
        // AFTER the pane move rather than racing it.
        let up = markerDir.appendingPathComponent("promoted-overlay-up")
        let release = markerDir.appendingPathComponent("promoted-overlay-release")
        let ovlCmd = "sh -c 'printf UP > \(up.path); " +
            "while [ ! -e \(release.path) ]; do sleep 0.2; done; exit 9'"
        let json = try! JSONSerialization.data(withJSONObject:
            ["cmd": "session.overlay.open", "target": id, "args": ["command": ovlCmd, "pane": "right"]])
        XCTAssertEqual(try sendCommand(String(data: json, encoding: .utf8)!)["ok"] as? Bool, true,
                       "opening the right pane overlay should succeed")
        XCTAssertEqual(pollMarker(up, timeout: 15), "UP", "the right pane overlay's program should run")

        // inject rather than type: focus-independent, so the exit drives closePrimaryPane without the covered
        // pane needing first responder.
        let typeJSON = try! JSONSerialization.data(withJSONObject:
            ["cmd": "session.type", "target": id, "args": ["text": "exit\n", "pane": "left"]])
        XCTAssertEqual(try sendCommand(String(data: typeJSON, encoding: .utf8)!)["ok"] as? Bool, true,
                       "typing exit into the main pane should succeed")
        XCTAssertTrue(pollActiveSessionSplit(false, timeout: 12), "the main pane's exit should promote the survivor")
        XCTAssertTrue(pollPaneOverlays(id: id, equals: ["left"], timeout: 12),
                      "the surviving pane's overlay should follow it into the left slot")

        FileManager.default.createFile(atPath: release.path, contents: Data())
        XCTAssertTrue(pollPaneOverlays(id: id, equals: nil, timeout: 15),
                      "the promoted overlay's own exit must free the slot it now occupies")
        XCTAssertEqual(pollOverlayExitCode(target: id, pane: "left", timeout: 15), 9,
                       "its status must be readable on the pane it was promoted onto")
    }

    // the COVERED side of the per-pane cover gate, the complement of the sibling-interactive test: while a
    // pane overlay is up the real keyboard must reach the OVERLAY and never the pane underneath it, and on
    // close the bounded `openPaneOverlays` focus retry must hand the keyboard back to that pane.
    func testPaneOverlayOwnsTheKeyboardOverItsPaneAndReturnsItOnClose() throws {
        let id = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(id)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "opening the split should succeed")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the split should be up")

        // a fresh split focuses the RIGHT pane; capture its identity by injection, focus-independently.
        let rightTTY = markerDir.appendingPathComponent("covered-pane-tty")
        let rightValue = try XCTUnwrap(typeUntilMarker("tty > '\(rightTTY.path)'\n", target: id, file: rightTTY,
                                                       select: false, pane: "right"),
                                       "the right pane should report its tty")

        let ovlMarker = markerDir.appendingPathComponent("covering-overlay-keys")
        let ovlCmd = "sh -c 'IFS= read -r x; printf %s \"$x\" > \(ovlMarker.path); cat'"
        let json = try! JSONSerialization.data(withJSONObject:
            ["cmd": "session.overlay.open", "target": id, "args": ["command": ovlCmd, "pane": "right"]])
        XCTAssertEqual(try sendCommand(String(data: json, encoding: .utf8)!)["ok"] as? Bool, true,
                       "opening the right pane overlay should succeed")
        XCTAssertTrue(pollPaneOverlays(id: id, contains: "right", timeout: 10), "the right pane overlay should be up")
        usleep(1_500_000) // let the overlay surface attach and finish its one-shot focus grab

        // one probe, two oracles: the overlay's `read` capturing the literal text proves it owns the
        // keyboard, and the redirect target never appearing proves the covered shell never ran it.
        app.activate()
        let leaked = markerDir.appendingPathComponent("covered-pane-leak")
        let probe = "tty > '\(leaked.path)'"
        app.typeText(probe)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(pollMarker(ovlMarker, timeout: 12), probe,
                       "keyboard input must reach the overlay covering the focused pane")
        XCTAssertNil(pollMarker(leaked, timeout: 2),
                     "the pane under its own overlay must not take first responder or run the probe")

        let close = try sendCommand(#"{"cmd":"session.overlay.close","target":"\#(id)","args":{"pane":"right"}}"#)
        XCTAssertEqual(close["ok"] as? Bool, true, "closing the pane overlay should succeed: \(close)")
        XCTAssertTrue(pollPaneOverlays(id: id, equals: nil, timeout: 10), "the pane overlay should be gone")

        let afterTTY = markerDir.appendingPathComponent("uncovered-pane-tty")
        let afterValue = try XCTUnwrap(keyboardTypeUntilMarker("tty > '\(afterTTY.path)'", file: afterTTY),
                                       "closing the overlay must return the keyboard to its pane")
        XCTAssertEqual(afterValue, rightValue, "focus must return to the pane the overlay covered, not the sibling")
    }

    // `--wait` holds a pane overlay open after its program exits, exactly as at session scope — libghostty's
    // press-any-key prompt keeps the surface, so the slot must NOT auto-close.
    func testPaneOverlayWaitHoldsTheSlotAfterItsProgramExits() throws {
        let id = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(id)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "opening the split should succeed")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the split should be up")

        let marker = markerDir.appendingPathComponent("pane-overlay-wait")
        let json = try! JSONSerialization.data(withJSONObject: [
            "cmd": "session.overlay.open", "target": id,
            "args": ["command": "sh -c 'printf RAN > \(marker.path)'", "pane": "right", "wait": true]])
        XCTAssertEqual(try sendCommand(String(data: json, encoding: .utf8)!)["ok"] as? Bool, true,
                       "opening the waiting right pane overlay should succeed")
        XCTAssertEqual(pollMarker(marker, timeout: 15), "RAN", "the pane overlay's program should run")

        // the inverse of the auto-close assertion above: given the same window to vanish in, it must not.
        XCTAssertFalse(pollPaneOverlays(id: id, equals: nil, timeout: 8),
                       "--wait must hold the pane overlay open after its program exits")
        let closed = try sendCommand(#"{"cmd":"session.overlay.close","target":"\#(id)","args":{"pane":"right"}}"#)
        XCTAssertEqual(closed["ok"] as? Bool, true, "the held pane overlay should still close on request: \(closed)")
    }

    /// Drain the run loop for a beat so any SwiftUI relayout the last command triggered — and the
    /// `didResizeSubviews` capture that would follow it — has landed before a divider read.
    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }

    /// The session's `splitRatio` from a fresh `tree`. `SplitRatioAccessor` writes it from the LIVE
    /// NSSplitView, so it reports where the divider actually sits, not merely what was last requested.
    private func liveSplitRatio(id: String) throws -> Double {
        try XCTUnwrap(sessionNode(id: id)["splitRatio"] as? Double, "a split session should report a splitRatio")
    }

    /// Polls `tree` until the session's `paneOverlays` holds `pane`, whatever else it holds.
    private func pollPaneOverlays(id: String, contains pane: String, timeout: TimeInterval) -> Bool {
        poll(until: currentPaneOverlays(id: id)?.contains(pane) == true, timeout: timeout)
    }

    /// Polls `tree` until the session's `paneOverlays` equals `expected` exactly, nil asserting the field is
    /// absent. The ORDERED equality is what proves one slot cannot shadow the other.
    private func pollPaneOverlays(id: String, equals expected: [String]?, timeout: TimeInterval) -> Bool {
        poll(until: currentPaneOverlays(id: id) == expected, timeout: timeout)
    }

    /// The session's `paneOverlays` from a fresh `tree`; nil when the field is omitted or the session is gone.
    private func currentPaneOverlays(id: String) -> [String]? {
        (try? sessionNodeIfPresent(id: id))?["paneOverlays"] as? [String]
    }

    /// Creates a session via `session.new` and returns its id as a `UUID`. `session.new` focuses the new
    /// session, so the returned session becomes the active one.
    private func newSession() throws -> UUID {
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let idString = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String,
                                     "session.new should return the new id")
        return try XCTUnwrap(UUID(uuidString: idString), "session.new id should be a UUID: \(idString)")
    }

    /// Polls `session.overlay.result` of `target` — the session-wide overlay, or `pane`'s when given — until
    /// the program has exited and its exit code is reported (result errors "overlay still running" while up),
    /// returning the code, or nil on timeout. A reported code proves the program actually ran.
    private func pollOverlayExitCode(target: String, pane: String? = nil, timeout: TimeInterval) -> Int? {
        let args = pane.map { #","args":{"pane":"\#($0)"}"# } ?? ""
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let res = try? sendCommand(#"{"cmd":"session.overlay.result","target":"\#(target)"\#(args)}"#),
               res["ok"] as? Bool == true {
                return (res["result"] as? [String: Any])?["exitCode"] as? Int
            }
            usleep(200_000)
        }
        return nil
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
}
