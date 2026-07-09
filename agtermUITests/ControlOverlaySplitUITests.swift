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

    // session.overlay.resize switches an open overlay between floating and full in place. Overlay geometry
    // is a Metal surface (not in the AX tree), so this asserts the COMMAND PATH: resize succeeds while the
    // overlay is up (a percent AND --full) and the overlay stays up across it, errors with no overlay, and
    // the dispatcher rejects missing/conflicting/out-of-range size args server-side; a raw JSON client (like
    // this test) skips the CLI's validate() entirely, so the dispatcher is the real enforcement boundary.
    // The visual re-flow is verified manually.
    func testOverlayResizeSwitchesFloatingAndFull() throws {
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let result = try XCTUnwrap(created["result"] as? [String: Any], "session.new should carry a result")
        let id = try XCTUnwrap(result["id"] as? String, "session.new should return the new id")

        // resizing with no overlay open errors.
        let noOverlay = try sendCommand(#"{"cmd":"session.overlay.resize","target":"\#(id)","args":{"sizePercent":60}}"#)
        XCTAssertEqual(noOverlay["ok"] as? Bool, false, "resize with no overlay should fail: \(noOverlay)")
        XCTAssertEqual(noOverlay["error"] as? String, "no overlay", "\(noOverlay)")

        // open a full overlay (cat is long-lived), then resize it to floating and back to full.
        let open = try sendCommand(#"{"cmd":"session.overlay.open","target":"\#(id)","args":{"command":"cat"}}"#)
        XCTAssertEqual(open["ok"] as? Bool, true, "overlay open should succeed: \(open)")
        XCTAssertTrue(pollSessionOverlay(id: id, expected: true, timeout: 10), "the overlay should be up")

        let toFloating = try sendCommand(#"{"cmd":"session.overlay.resize","target":"\#(id)","args":{"sizePercent":60}}"#)
        XCTAssertEqual(toFloating["ok"] as? Bool, true, "resize to floating should succeed: \(toFloating)")
        // the overlay stays up across the resize (in-place re-flow, never a re-spawn).
        XCTAssertTrue(pollSessionOverlay(id: id, expected: true, timeout: 5), "the overlay stays up after resize")

        let toFull = try sendCommand(#"{"cmd":"session.overlay.resize","target":"\#(id)","args":{"full":true}}"#)
        XCTAssertEqual(toFull["ok"] as? Bool, true, "resize back to full should succeed: \(toFull)")

        // the dispatcher rejects the bad arg combos server-side.
        let neither = try sendCommand(#"{"cmd":"session.overlay.resize","target":"\#(id)"}"#)
        XCTAssertEqual(neither["ok"] as? Bool, false, "resize with neither arg should fail: \(neither)")
        let both = try sendCommand(#"{"cmd":"session.overlay.resize","target":"\#(id)","args":{"sizePercent":50,"full":true}}"#)
        XCTAssertEqual(both["ok"] as? Bool, false, "resize with both args should fail: \(both)")
        let oob = try sendCommand(#"{"cmd":"session.overlay.resize","target":"\#(id)","args":{"sizePercent":150}}"#)
        XCTAssertEqual(oob["ok"] as? Bool, false, "resize with out-of-range percent should fail: \(oob)")

        let close = try sendCommand(#"{"cmd":"session.overlay.close","target":"\#(id)"}"#)
        XCTAssertEqual(close["ok"] as? Bool, true, "overlay close should succeed: \(close)")
    }

    // session.overlay.open --background-color: a valid #rrggbb opens the overlay (the colored surface is
    // a Metal layer, not in the AX tree, so the color is verified manually — this asserts the arm accepts
    // and applies it via the lifecycle), and a malformed color is rejected before the overlay opens.
    func testOverlayOpenWithBackgroundColorAndRejectsBadColor() throws {
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let result = try XCTUnwrap(created["result"] as? [String: Any], "session.new should carry a result")
        let id = try XCTUnwrap(result["id"] as? String, "session.new should return the new id")

        // a malformed color is rejected up front; no overlay opens.
        let bad = try sendCommand(#"{"cmd":"session.overlay.open","target":"\#(id)","args":{"command":"cat","color":"purple"}}"#)
        XCTAssertEqual(bad["ok"] as? Bool, false, "a malformed color should be rejected: \(bad)")
        XCTAssertEqual(bad["error"] as? String, "invalid color: purple (#rrggbb)", "\(bad)")
        XCTAssertTrue(pollSessionOverlay(id: id, expected: false, timeout: 5), "the rejected open must not open an overlay")

        // a valid color opens the overlay (cat is long-lived so it stays up); close tears it down.
        // ##"…"## delimiters so the "#2a1a3a" value's leading "# doesn't close a #"…"# raw string.
        let open = try sendCommand(##"{"cmd":"session.overlay.open","target":"\##(id)","args":{"command":"cat","color":"#2a1a3a"}}"##)
        XCTAssertEqual(open["ok"] as? Bool, true, "overlay open with a valid color should succeed: \(open)")
        XCTAssertTrue(pollSessionOverlay(id: id, expected: true, timeout: 10), "the colored overlay should be up")

        let close = try sendCommand(#"{"cmd":"session.overlay.close","target":"\#(id)"}"#)
        XCTAssertEqual(close["ok"] as? Bool, true, "overlay close should succeed: \(close)")
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

    // a cover (overlay or scratch) is modal within its session: a sidebar click restores keyboard focus to
    // the terminal (so the sidebar never keeps it), but it must restore focus to the cover ON TOP, not to
    // the pane BEHIND it. clicking the covered session's own row otherwise hands first responder to the
    // pane and the cover's program silently stops receiving input.
    //
    // each test captures TWO keyboard lines: the first, typed BEFORE the click, proves the cover already
    // holds first responder (so the cover's own bounded auto-focus retry — 40 x 0.05s — has finished and
    // cannot re-grab focus later and mask a steal). the second, typed after the click, is the assertion.
    // without the pre-click line the test can pass on a buggy build: the click steals focus to the pane,
    // then an auto-focus retry still in flight takes it back before the line is typed.
    func testSidebarClickKeepsFocusOnOverlayNotPaneBehind() throws {
        let id = try activeSessionID()
        let pre = markerDir.appendingPathComponent("overlay-pre-click")
        let post = markerDir.appendingPathComponent("overlay-post-click")
        // two blocking reads then `cat` to hold the shell; retyping is NOT idempotent (each `read`
        // consumes exactly one line), so the markers are polled rather than re-typed.
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

    /// Creates a session via `session.new` and returns its id as a `UUID`. `session.new` focuses the new
    /// session, so the returned session becomes the active one.
    private func newSession() throws -> UUID {
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let idString = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String,
                                     "session.new should return the new id")
        return try XCTUnwrap(UUID(uuidString: idString), "session.new id should be a UUID: \(idString)")
    }

    /// Polls `session.overlay.result` of `target` until the overlay program has exited and its exit code is
    /// reported (result errors "overlay still running" while up), returning the code, or nil on timeout.
    /// A reported exit code proves the overlay's program actually ran (used to assert a background overlay runs).
    private func pollOverlayExitCode(target: String, timeout: TimeInterval) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let res = try? sendCommand(#"{"cmd":"session.overlay.result","target":"\#(target)"}"#),
               res["ok"] as? Bool == true {
                return (res["result"] as? [String: Any])?["exitCode"] as? Int
            }
            usleep(200_000)
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
