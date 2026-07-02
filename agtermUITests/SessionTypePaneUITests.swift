import Foundation
import XCTest

// session.type --pane UI e2e: pane-addressed text injection into a split. A `ControlAPITestCase`
// subclass like `SessionTextUITests`, reusing the shared harness (sendCommand / typeRequest /
// pollActiveSessionSplit / activeSessionID). The read-back oracle is `session.text --pane`, whose own
// pane routing is proven independently in `SessionTextUITests.testSessionTextPaneSelectsCorrectPane`.
@MainActor
final class SessionTypePaneUITests: ControlAPITestCase {
    // session.type --pane right injects into the SPLIT pane's pty while the default (no pane) keeps
    // injecting into the main pane — each marker must come back from its own pane's buffer and NOT the
    // other's, proving the two injections hit different surfaces. Markers are echo OUTPUT tags typed as
    // `$((6*7))` arithmetic so a match proves the shell in that pane RAN the line, not merely echoed it.
    func testSessionTypePaneRightReachesSplitPane() throws {
        let split = try sendCommand(#"{"cmd":"session.split","target":"active","args":{"mode":"on"}}"#)
        XCTAssertEqual(split["ok"] as? Bool, true, "split on should succeed: \(split)")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the active session should report split:true")
        let activeID = try activeSessionID()

        let leftTag = "TYPEL-\(UUID().uuidString.prefix(8))"
        let rightTag = "TYPER-\(UUID().uuidString.prefix(8))"

        // default (no pane) lands in the main pane; --pane right lands in the split pane. Re-inject per
        // attempt: a freshly-spawned pane's shell may not be ready for its first keystrokes (the
        // typeUntilMarker readiness idiom), and an `echo` line is idempotent.
        let leftText = try pollPaneText(target: activeID, pane: "left", contains: "\(leftTag)-42", retype: {
            _ = try self.sendCommand(self.typeRequest(text: "echo \(leftTag)-$((6*7))\n", target: activeID, select: false))
        })
        XCTAssertNotNil(leftText, "the default (no pane) injection should land in the main pane")

        // NB: no inner `ok == true` assert here (unlike a one-shot check) — the base class sets
        // continueAfterFailure = false, so a transient ok:false on a not-yet-ready split would abort the
        // whole test instead of letting the retry loop ride it out. Success is asserted once, below, via
        // the marker actually landing (the left closure omits the inner assert for the same reason).
        let rightText = try pollPaneText(target: activeID, pane: "right", contains: "\(rightTag)-42", retype: {
            _ = try self.sendCommand(self.typeRequest(text: "echo \(rightTag)-$((6*7))\n",
                                                      target: activeID, select: false, pane: "right"))
        })
        XCTAssertNotNil(rightText, "--pane right should land in the split pane")

        // cross-check: each pane's buffer carries ONLY its own marker.
        XCTAssertFalse(try XCTUnwrap(leftText).contains("\(rightTag)-42"),
                       "the main pane must NOT contain the split pane's marker: \(leftText ?? "")")
        XCTAssertFalse(try XCTUnwrap(rightText).contains("\(leftTag)-42"),
                       "the split pane must NOT contain the main pane's marker: \(rightText ?? "")")
    }

    // session.type --pane right on a non-split session errors. The request is sent directly over the socket
    // (sendCommand bypasses the CLI entirely), so the SERVER itself rejects it (no split pane to type into)
    // — mirroring session.text.
    func testSessionTypePaneRightWithoutSplitErrors() throws {
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let newID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new should return the new id")

        let response = try sendCommand(typeRequest(text: "echo nope\n", target: newID, select: true, pane: "right"))
        XCTAssertEqual(response["ok"] as? Bool, false, "session.type --pane right with no split should fail: \(response)")
        XCTAssertEqual(response["error"] as? String, "session has no split pane", "should report no split pane: \(response)")
    }

    // pane validation is enforced SERVER-SIDE, not only in the CLI `validate()`: a raw socket client
    // bypasses the CLI, so an unknown pane value must error here too (sendCommand is that raw client).
    func testSessionTypeRejectsInvalidPaneServerSide() throws {
        let response = try sendCommand(#"{"cmd":"session.type","target":"active","args":{"text":"x","pane":"middle"}}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "session.type pane:middle should fail server-side: \(response)")
        XCTAssertEqual(response["error"] as? String, "invalid pane: middle", "should report the invalid pane: \(response)")
    }
}
