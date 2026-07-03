import Foundation
import XCTest

// session.text UI e2e. A `ControlAPITestCase` subclass (was an extension over `ControlAPIUITests`), so
// it reuses the shared harness helpers (sendCommand / typeRequest / app / pollActiveSessionSplit /
// activeSessionID) without duplicating scaffolding.
@MainActor
final class SessionTextUITests: ControlAPITestCase {
    // session.text returns the session's terminal buffer in result.text. Type a command whose OUTPUT (not
    // the echoed command line) is a unique marker — `echo <tag>-$((6*7))` prints `<tag>-42`, a string the
    // typed line itself does NOT contain (it has `$((6*7))`) — so a match proves command output was
    // captured, not merely the typed input echoed back. Poll until the rendered output lands (async).
    func testSessionTextReturnsBuffer() throws {
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let result = try XCTUnwrap(created["result"] as? [String: Any], "session.new should carry a result")
        let newID = try XCTUnwrap(result["id"] as? String, "session.new should return the new id")

        let tag = "AGTERM-TEXT-\(UUID().uuidString.prefix(8))"
        let output = "\(tag)-42" // the shell evaluates $((6*7)); this string is absent from the typed line
        let typed = try sendCommand(typeRequest(text: "echo \(tag)-$((6*7))\n", target: newID, select: true))
        XCTAssertEqual(typed["ok"] as? Bool, true, "session.type should succeed: \(typed)")

        var text: String?
        for _ in 0..<40 {
            let response = try sendCommand(#"{"cmd":"session.text","target":"\#(newID)"}"#)
            XCTAssertEqual(response["ok"] as? Bool, true, "session.text should succeed: \(response)")
            if let t = (response["result"] as? [String: Any])?["text"] as? String, t.contains(output) {
                text = t
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertNotNil(text, "session.text should return a buffer containing the command OUTPUT \(output)")
    }

    // session.text --lines N keeps only the LAST N lines of the full buffer (the GhosttySurfaceView trim:
    // strip one trailing newline, split on \n, suffix(N)). Print 50 distinctly-tagged numbered lines, then
    // read --lines 5: assert exactly 5 lines come back, the LAST printed line (tag-50) is present, and an
    // EARLY line (tag-1) is NOT — proving the suffix trim, which no other test exercises.
    func testSessionTextLinesReturnsLastN() throws {
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let result = try XCTUnwrap(created["result"] as? [String: Any], "session.new should carry a result")
        let newID = try XCTUnwrap(result["id"] as? String, "session.new should return the new id")

        // printf repeats its format over the seq args → tag-1-X, tag-2-X, … tag-50-X, each on its own line.
        let tag = "LN-\(UUID().uuidString.prefix(8))"
        let typed = try sendCommand(typeRequest(text: "printf '\(tag)-%s-X\\n' $(seq 1 50)\n", target: newID, select: true))
        XCTAssertEqual(typed["ok"] as? Bool, true, "session.type should succeed: \(typed)")

        var text: String?
        for _ in 0..<40 {
            let response = try sendCommand(#"{"cmd":"session.text","target":"\#(newID)","args":{"lines":5}}"#)
            XCTAssertEqual(response["ok"] as? Bool, true, "session.text --lines 5 should succeed: \(response)")
            if let t = (response["result"] as? [String: Any])?["text"] as? String, t.contains("\(tag)-50-X") {
                text = t
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        let t = try XCTUnwrap(text, "--lines 5 should eventually contain the last printed line \(tag)-50-X")
        XCTAssertEqual(t.components(separatedBy: "\n").count, 5, "--lines 5 should return exactly 5 lines: \(t)")
        XCTAssertTrue(t.contains("\(tag)-50-X"), "the last printed line should be within the last 5: \(t)")
        XCTAssertFalse(t.contains("\(tag)-1-X"), "an early line must be trimmed away by --lines 5: \(t)")
    }

    // session.text --all reads the whole SCREEN (visible + scrollback); the default read is the VIEWPORT
    // only. Print far more lines than fit on screen, then assert --all returns an EARLY line that scrolled
    // out of the viewport while the default read does NOT — a swapped VIEWPORT/SCREEN region would fail this
    // (the default read is never otherwise distinguished from --all over the socket).
    func testSessionTextAllIncludesScrollback() throws {
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let result = try XCTUnwrap(created["result"] as? [String: Any], "session.new should carry a result")
        let newID = try XCTUnwrap(result["id"] as? String, "session.new should return the new id")

        // 400 lines far exceed any viewport, so tag-1-X is guaranteed to scroll out of the visible screen.
        let tag = "SCR-\(UUID().uuidString.prefix(8))"
        let typed = try sendCommand(typeRequest(text: "printf '\(tag)-%s-X\\n' $(seq 1 400)\n", target: newID, select: true))
        XCTAssertEqual(typed["ok"] as? Bool, true, "session.type should succeed: \(typed)")

        // poll --all until the last printed line lands (proves the output fully rendered to scrollback).
        var allText: String?
        for _ in 0..<60 {
            let response = try sendCommand(#"{"cmd":"session.text","target":"\#(newID)","args":{"all":true}}"#)
            XCTAssertEqual(response["ok"] as? Bool, true, "session.text --all should succeed: \(response)")
            if let t = (response["result"] as? [String: Any])?["text"] as? String, t.contains("\(tag)-400-X") {
                allText = t
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        let all = try XCTUnwrap(allText, "--all should eventually contain the last printed line \(tag)-400-X")
        XCTAssertTrue(all.contains("\(tag)-1-X"), "--all (SCREEN) should include the early scrolled-out line: head of \(all.prefix(200))")

        let viewportResp = try sendCommand(#"{"cmd":"session.text","target":"\#(newID)"}"#)
        XCTAssertEqual(viewportResp["ok"] as? Bool, true, "session.text (viewport) should succeed: \(viewportResp)")
        let viewport = try XCTUnwrap((viewportResp["result"] as? [String: Any])?["text"] as? String, "viewport read should carry text")
        XCTAssertFalse(viewport.contains("\(tag)-1-X"), "the default (VIEWPORT) read must NOT include the scrolled-out line \(tag)-1-X")
        XCTAssertTrue(viewport.contains("\(tag)-400-X"), "the default (VIEWPORT) read should still show the most recent line")
    }

    // session.text --pane left|right reads the matching pane of a split. The LEFT marker goes in over the
    // socket (a no-pane session.type injects into the main pane); the RIGHT pane is fed via the real
    // keyboard after focusing it — deliberately NOT via `session.type --pane right` (that route has its own
    // e2e in SessionTypePaneUITests), so this test also proves the focus→keyboard first-responder routing.
    // Assert each pane read returns its OWN marker and NOT the other's — the --pane success mappings
    // (left→surface, right→splitSurface) are otherwise only hit on the error path.
    func testSessionTextPaneSelectsCorrectPane() throws {
        let split = try sendCommand(#"{"cmd":"session.split","target":"active","args":{"mode":"on"}}"#)
        XCTAssertEqual(split["ok"] as? Bool, true, "split on should succeed: \(split)")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the active session should report split:true")
        let activeID = try activeSessionID()

        // LEFT (main) pane: a no-pane session.type injects into session.surface (the main pane), so this
        // marker lands in the left pane regardless of which pane holds focus.
        let leftMarker = "LEFT-\(UUID().uuidString.prefix(8))"
        XCTAssertNotNil(try pollPaneText(target: activeID, pane: "left", contains: leftMarker, retype: {
            _ = try self.sendCommand(self.typeRequest(text: "echo \(leftMarker)\n", target: activeID, select: false))
        }), "--pane left should read the marker typed into the main pane")

        // RIGHT (split) pane: focus it and type via the real keyboard, which routes to the focused pane's
        // first responder.
        let rightMarker = "RIGHT-\(UUID().uuidString.prefix(8))"
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.focus","target":"\#(activeID)","args":{"pane":"right"}}"#)["ok"] as? Bool,
                       true, "focus right should succeed")
        app.activate()
        XCTAssertNotNil(try pollPaneText(target: activeID, pane: "right", contains: rightMarker, retype: {
            self.app.typeText("echo \(rightMarker)")
            self.app.typeKey(.return, modifierFlags: [])
        }), "--pane right should read the marker typed into the split pane")

        // cross-check: each pane read carries ONLY its own marker (the two reads hit different surfaces).
        let leftText = try XCTUnwrap((try sendCommand(#"{"cmd":"session.text","target":"\#(activeID)","args":{"pane":"left"}}"#)["result"] as? [String: Any])?["text"] as? String)
        let rightText = try XCTUnwrap((try sendCommand(#"{"cmd":"session.text","target":"\#(activeID)","args":{"pane":"right"}}"#)["result"] as? [String: Any])?["text"] as? String)
        XCTAssertTrue(leftText.contains(leftMarker), "--pane left should contain the left marker: \(leftText)")
        XCTAssertFalse(leftText.contains(rightMarker), "--pane left must NOT contain the right pane's marker: \(leftText)")
        XCTAssertTrue(rightText.contains(rightMarker), "--pane right should contain the right marker: \(rightText)")
        XCTAssertFalse(rightText.contains(leftMarker), "--pane right must NOT contain the left pane's marker: \(rightText)")
    }

    // session.text --pane right on a non-split session errors. `right` is a valid pane value so it passes
    // the CLI validate() and the request reaches the server, which rejects it (no split pane to read).
    func testSessionTextSplitPaneWithoutSplitErrors() throws {
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let result = try XCTUnwrap(created["result"] as? [String: Any], "session.new should carry a result")
        let newID = try XCTUnwrap(result["id"] as? String, "session.new should return the new id")

        let response = try sendCommand(#"{"cmd":"session.text","target":"\#(newID)","args":{"pane":"right"}}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "session.text --pane right with no split should fail: \(response)")
        XCTAssertEqual(response["error"] as? String, "session has no split pane", "should report no split pane: \(response)")
    }

    // session.text arg validation is enforced SERVER-SIDE, not only in the CLI `validate()`: a raw socket
    // client bypasses the CLI, so `lines <= 0` and `all` + `lines` together must error here too (an unchecked
    // `lines: 0` would otherwise fall through to the full buffer). sendCommand speaks raw JSON, so it is the
    // bypassing client.
    func testSessionTextRejectsInvalidArgsServerSide() throws {
        let zero = try sendCommand(#"{"cmd":"session.text","target":"active","args":{"lines":0}}"#)
        XCTAssertEqual(zero["ok"] as? Bool, false, "session.text lines:0 should fail server-side: \(zero)")
        XCTAssertEqual(zero["error"] as? String, "--lines must be greater than 0", "should report the lines bound: \(zero)")

        let negative = try sendCommand(#"{"cmd":"session.text","target":"active","args":{"lines":-1}}"#)
        XCTAssertEqual(negative["ok"] as? Bool, false, "session.text lines:-1 should fail server-side: \(negative)")

        let both = try sendCommand(#"{"cmd":"session.text","target":"active","args":{"all":true,"lines":5}}"#)
        XCTAssertEqual(both["ok"] as? Bool, false, "session.text all+lines should fail server-side: \(both)")
        XCTAssertEqual(both["error"] as? String, "use either --all or --lines, not both", "should report mutual exclusion: \(both)")
    }

    // A genuinely BLANK screen reads ok with an EMPTY string, not an error (readScreenText returns "" for an
    // empty read, nil only for a failed one). `session new --command "sleep 300"` execs sleep directly — no
    // shell, so no prompt and no output — leaving the viewport blank; session.text returns ok + "".
    func testSessionTextBlankScreenReturnsOkEmpty() throws {
        let created = try sendCommand(#"{"cmd":"session.new","args":{"command":"sleep 300"}}"#)
        let newID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new should return the new id")

        // poll for the surface to realize (a never-shown session realizes a beat after create).
        var response: [String: Any] = [:]
        for _ in 0..<40 {
            response = try sendCommand(#"{"cmd":"session.text","target":"\#(newID)"}"#)
            if response["ok"] as? Bool == true { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        XCTAssertEqual(response["ok"] as? Bool, true, "session.text on a blank screen should be ok, not an error: \(response)")
        let text = try XCTUnwrap((response["result"] as? [String: Any])?["text"] as? String, "a blank read still carries a text field: \(response)")
        XCTAssertTrue(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "a blank screen should read as empty, got: \(text)")
    }

    // `--pane scratch` reads (and `session.type --pane scratch` writes) the scratch terminal whether or not
    // it is on screen, since its surface is kept alive when hidden. Open the scratch, echo a marker into it,
    // read it back, then HIDE it and prove the buffer is still readable AND still writable via --pane scratch.
    // The arithmetic ($((6*7)) -> 42) proves the scratch's own shell RAN the line, not merely echoed it.
    func testSessionScratchPaneReadsAndWritesEvenWhenHidden() throws {
        let activeID = try activeSessionID()

        let on = try sendCommand(#"{"cmd":"session.scratch","target":"\#(activeID)","args":{"mode":"on"}}"#)
        XCTAssertEqual(on["ok"] as? Bool, true, "session.scratch on should succeed: \(on)")

        let tag = "SCRATCH-\(UUID().uuidString.prefix(8))"
        let shown = try pollPaneText(target: activeID, pane: "scratch", contains: "\(tag)-42", retype: {
            _ = try self.sendCommand(self.typeRequest(text: "echo \(tag)-$((6*7))\n", target: activeID,
                                                      select: false, pane: "scratch"))
        })
        XCTAssertNotNil(shown, "session.text --pane scratch should read the scratch's own buffer while it is shown")

        // hide the scratch (keep-alive) and confirm its buffer is STILL readable via --pane scratch.
        let off = try sendCommand(#"{"cmd":"session.scratch","target":"\#(activeID)","args":{"mode":"off"}}"#)
        XCTAssertEqual(off["ok"] as? Bool, true, "session.scratch off should succeed: \(off)")
        let hidden = try XCTUnwrap((try sendCommand(#"{"cmd":"session.text","target":"\#(activeID)","args":{"pane":"scratch","all":true}}"#)["result"] as? [String: Any])?["text"] as? String)
        XCTAssertTrue(hidden.contains("\(tag)-42"), "a hidden scratch's buffer must still be readable via --pane scratch, got: \(hidden)")

        // and it must still be WRITABLE while hidden: type a fresh marker via --pane scratch and read it back.
        let tag2 = "HIDDEN-\(UUID().uuidString.prefix(8))"
        let afterHiddenWrite = try pollPaneText(target: activeID, pane: "scratch", contains: "\(tag2)-42", retype: {
            _ = try self.sendCommand(self.typeRequest(text: "echo \(tag2)-$((6*7))\n", target: activeID,
                                                      select: false, pane: "scratch"))
        })
        XCTAssertNotNil(afterHiddenWrite, "session.type --pane scratch must reach the scratch even while it is hidden")
    }

    // --pane scratch on a session that never opened a scratch errors on both read and write, server-side.
    func testSessionScratchPaneWithoutScratchErrors() throws {
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let newID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new should return the new id")

        let read = try sendCommand(#"{"cmd":"session.text","target":"\#(newID)","args":{"pane":"scratch"}}"#)
        XCTAssertEqual(read["ok"] as? Bool, false, "reading a nonexistent scratch should fail: \(read)")
        XCTAssertEqual(read["error"] as? String, "session has no scratch terminal")

        let write = try sendCommand(#"{"cmd":"session.type","target":"\#(newID)","args":{"text":"x","select":false,"pane":"scratch"}}"#)
        XCTAssertEqual(write["ok"] as? Bool, false, "typing into a nonexistent scratch should fail: \(write)")
        XCTAssertEqual(write["error"] as? String, "session has no scratch terminal")
    }
}
