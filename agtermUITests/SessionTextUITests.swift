import Foundation
import XCTest

// session.text UI e2e; the `ControlAPITestCase` base supplies the socket/app harness helpers.
@MainActor
final class SessionTextUITests: ControlAPITestCase {
    // the marker is the OUTPUT, not the typed line: `echo <tag>-$((6*7))` prints `<tag>-42`, a string the
    // typed line does NOT contain, so a match cannot be the echoed input.
    func testSessionTextReturnsBuffer() throws {
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let result = try XCTUnwrap(created["result"] as? [String: Any], "session.new should carry a result")
        let newID = try XCTUnwrap(result["id"] as? String, "session.new should return the new id")

        let tag = "AGTERM-TEXT-\(UUID().uuidString.prefix(8))"
        let output = "\(tag)-42"
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

    func testSessionTextAllIncludesScrollback() throws {
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let result = try XCTUnwrap(created["result"] as? [String: Any], "session.new should carry a result")
        let newID = try XCTUnwrap(result["id"] as? String, "session.new should return the new id")

        // 400 lines far exceed any viewport, so tag-1-X is guaranteed to scroll out of the visible screen.
        let tag = "SCR-\(UUID().uuidString.prefix(8))"
        let typed = try sendCommand(typeRequest(text: "printf '\(tag)-%s-X\\n' $(seq 1 400)\n", target: newID, select: true))
        XCTAssertEqual(typed["ok"] as? Bool, true, "session.type should succeed: \(typed)")

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

    // the right pane is fed via the real keyboard, deliberately NOT `session.type --pane right` (covered by
    // SessionTypePaneUITests), so this also proves the focus→keyboard first-responder routing.
    func testSessionTextPaneSelectsCorrectPane() throws {
        let split = try sendCommand(#"{"cmd":"session.split","target":"active","args":{"mode":"on"}}"#)
        XCTAssertEqual(split["ok"] as? Bool, true, "split on should succeed: \(split)")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the active session should report split:true")
        let activeID = try activeSessionID()

        // a no-pane session.type always injects into the main pane, whichever pane holds focus.
        let leftMarker = "LEFT-\(UUID().uuidString.prefix(8))"
        XCTAssertNotNil(try pollPaneText(target: activeID, pane: "left", contains: leftMarker, retype: {
            _ = try self.sendCommand(self.typeRequest(text: "echo \(leftMarker)\n", target: activeID, select: false))
        }), "--pane left should read the marker typed into the main pane")

        let rightMarker = "RIGHT-\(UUID().uuidString.prefix(8))"
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.focus","target":"\#(activeID)","args":{"pane":"right"}}"#)["ok"] as? Bool,
                       true, "focus right should succeed")
        app.activate()
        XCTAssertNotNil(try pollPaneText(target: activeID, pane: "right", contains: rightMarker, retype: {
            self.app.typeText("echo \(rightMarker)")
            self.app.typeKey(.return, modifierFlags: [])
        }), "--pane right should read the marker typed into the split pane")

        let leftText = try XCTUnwrap((try sendCommand(#"{"cmd":"session.text","target":"\#(activeID)","args":{"pane":"left"}}"#)["result"] as? [String: Any])?["text"] as? String)
        let rightText = try XCTUnwrap((try sendCommand(#"{"cmd":"session.text","target":"\#(activeID)","args":{"pane":"right"}}"#)["result"] as? [String: Any])?["text"] as? String)
        XCTAssertTrue(leftText.contains(leftMarker), "--pane left should contain the left marker: \(leftText)")
        XCTAssertFalse(leftText.contains(rightMarker), "--pane left must NOT contain the right pane's marker: \(leftText)")
        XCTAssertTrue(rightText.contains(rightMarker), "--pane right should contain the right marker: \(rightText)")
        XCTAssertFalse(rightText.contains(leftMarker), "--pane right must NOT contain the left pane's marker: \(rightText)")
    }

    // `right` is a valid pane value, so the CLI validate() passes and the SERVER is what rejects it.
    func testSessionTextSplitPaneWithoutSplitErrors() throws {
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let result = try XCTUnwrap(created["result"] as? [String: Any], "session.new should carry a result")
        let newID = try XCTUnwrap(result["id"] as? String, "session.new should return the new id")

        let response = try sendCommand(#"{"cmd":"session.text","target":"\#(newID)","args":{"pane":"right"}}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "session.text --pane right with no split should fail: \(response)")
        XCTAssertEqual(response["error"] as? String, "session has no split pane", "should report no split pane: \(response)")
    }

    // sendCommand speaks raw JSON, so it IS the CLI-bypassing client this server-side validation guards.
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

    // `--command "sleep 300"` execs sleep directly — no shell, no prompt, no output — so the viewport is
    // genuinely blank.
    func testSessionTextBlankScreenReturnsOkEmpty() throws {
        let created = try sendCommand(#"{"cmd":"session.new","args":{"command":"sleep 300"}}"#)
        let newID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new should return the new id")

        // a never-shown session realizes a beat after create, hence the poll.
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

    // the arithmetic ($((6*7)) → 42) proves the scratch's own shell RAN the line rather than echoing it.
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

        let off = try sendCommand(#"{"cmd":"session.scratch","target":"\#(activeID)","args":{"mode":"off"}}"#)
        XCTAssertEqual(off["ok"] as? Bool, true, "session.scratch off should succeed: \(off)")
        let hidden = try XCTUnwrap((try sendCommand(#"{"cmd":"session.text","target":"\#(activeID)","args":{"pane":"scratch","all":true}}"#)["result"] as? [String: Any])?["text"] as? String)
        XCTAssertTrue(hidden.contains("\(tag)-42"), "a hidden scratch's buffer must still be readable via --pane scratch, got: \(hidden)")

        let tag2 = "HIDDEN-\(UUID().uuidString.prefix(8))"
        let afterHiddenWrite = try pollPaneText(target: activeID, pane: "scratch", contains: "\(tag2)-42", retype: {
            _ = try self.sendCommand(self.typeRequest(text: "echo \(tag2)-$((6*7))\n", target: activeID,
                                                      select: false, pane: "scratch"))
        })
        XCTAssertNotNil(afterHiddenWrite, "session.type --pane scratch must reach the scratch even while it is hidden")
    }

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
