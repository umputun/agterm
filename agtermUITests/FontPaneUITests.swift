import Foundation
import XCTest

// font --pane e2e: the font commands can target a specific pane (`left`|`right`|`scratch`), mirroring
// `session type`/`session text`. The split pane's font is NOT persisted (its surface's onFontSizeChange is
// unwired by design), so the persisted MAIN-pane size is the oracle: `font dec --pane right` must return ok
// (proving it reached the realized split surface) while leaving the main pane's persisted size untouched,
// and the default (no --pane) must still shrink the main pane. The error cases (no split, invalid pane) go
// straight over the socket so the SERVER, not just the CLI `validate()`, enforces them. A `ControlAPITestCase`
// subclass like `SessionTypePaneUITests`, reusing the shared harness.
@MainActor
final class FontPaneUITests: ControlAPITestCase {
    // font dec --pane right decrements the split surface, NOT the main/left one (the reported bug). The main
    // pane's persisted size is the only readable font oracle, so the proof is: --pane right returns ok
    // (the split surface exists and got the action) while the main pane's size stays put, and the default
    // font dec then DOES shrink the main pane — so the two panes are addressed independently.
    func testFontPaneRightTargetsSplitNotMain() throws {
        let split = try sendCommand(#"{"cmd":"session.split","target":"active","args":{"mode":"on"}}"#)
        XCTAssertEqual(split["ok"] as? Bool, true, "split on should succeed: \(split)")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the active session should report split:true")
        let id = try activeSessionID()

        // baseline captured AFTER the split is shown, so any post-split reflow of the main pane already
        // settled — its point size doesn't change with pane width, so this stays constant hereafter.
        let baseline = try XCTUnwrap(pollFirstSessionFontSize(timeout: 10),
                                     "the main pane should report a persisted font size on launch")

        // ride out split-surface realization: a freshly shown split may not be realized for the first
        // request, which returns "session not realized" (continueAfterFailure = false forbids asserting in
        // the retry loop, so fontUntilOk swallows the transient failures and returns the settled response).
        let firstRight = try fontUntilOk(cmd: "font.dec", target: id, pane: "right")
        XCTAssertEqual(firstRight["ok"] as? Bool, true,
                       "font dec --pane right should reach the realized split surface: \(firstRight)")
        for _ in 0..<3 {
            let response = try sendCommand(fontRequest(cmd: "font.dec", target: id, pane: "right"))
            XCTAssertEqual(response["ok"] as? Bool, true, "font dec --pane right should stay ok: \(response)")
        }

        // the main pane's persisted size must be untouched by the split-pane changes — the bug was that
        // font always hit the main/left surface. Wait past the debounced save, then assert no drift (a
        // buggy 4-point drop would fail; the split's font simply isn't persisted, so it can't move).
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let afterRight = try XCTUnwrap(firstSessionFontSize(), "the main pane size should still be readable")
        XCTAssertEqual(afterRight, baseline, accuracy: 0.5,
                       "font --pane right must not change the main pane's persisted size")

        // the default (no --pane) still targets the main pane, so its persisted size drops below baseline.
        for _ in 0..<4 {
            let response = try sendCommand(fontRequest(cmd: "font.dec", target: id, pane: nil))
            XCTAssertEqual(response["ok"] as? Bool, true, "default font dec should hit the main pane: \(response)")
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        let decreased = try XCTUnwrap(pollFirstSessionFontSize(below: baseline - 0.5, timeout: 8),
                                      "the default (no --pane) font dec should shrink the main pane's persisted size")
        XCTAssertLessThan(decreased, baseline)
    }

    // font --pane right on a non-split session errors. Sent straight over the socket (bypassing the CLI), so
    // the SERVER itself rejects it — mirroring session.type/session.text.
    func testFontPaneRightWithoutSplitErrors() throws {
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let newID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new should return the new id")

        let response = try sendCommand(fontRequest(cmd: "font.dec", target: newID, pane: "right"))
        XCTAssertEqual(response["ok"] as? Bool, false, "font --pane right with no split should fail: \(response)")
        XCTAssertEqual(response["error"] as? String, "session has no split pane", "should report no split pane: \(response)")
    }

    // pane validation is enforced SERVER-SIDE, not only in the CLI `validate()`: a raw socket client bypasses
    // the CLI, so an unknown pane value must error here too (sendCommand is that raw client).
    func testFontRejectsInvalidPaneServerSide() throws {
        let response = try sendCommand(#"{"cmd":"font.dec","target":"active","args":{"pane":"middle"}}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "font pane:middle should fail server-side: \(response)")
        XCTAssertEqual(response["error"] as? String, "invalid pane: middle", "should report the invalid pane: \(response)")
    }

    // MARK: - helpers

    /// Build a `font.*` request line, adding `args.pane` only when a pane is given (a bare font request
    /// carries no args, matching the CLI's compact form).
    private func fontRequest(cmd: String, target: String, pane: String?) -> String {
        var obj: [String: Any] = ["cmd": cmd, "target": target]
        if let pane { obj["args"] = ["pane": pane] }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8)!
    }

    /// Send a font request, retrying while the split surface finishes realizing ("session not realized"),
    /// and return the settled response (ok, or the last failure if it never realized).
    private func fontUntilOk(cmd: String, target: String, pane: String?) throws -> [String: Any] {
        var last: [String: Any] = [:]
        for _ in 0..<20 {
            last = try sendCommand(fontRequest(cmd: cmd, target: target, pane: pane))
            if last["ok"] as? Bool == true { return last }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return last
    }

    /// Polls the snapshot until the first session's persisted `fontSize` drops below `threshold`, returning
    /// it, or nil on timeout.
    private func pollFirstSessionFontSize(below threshold: Double, timeout: TimeInterval) -> Double? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let size = firstSessionFontSize(), size < threshold { return size }
            usleep(200_000)
        }
        return nil
    }
}
