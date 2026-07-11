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
    // font dec --pane right decrements the split surface, NOT the main/left one (the reported bug). Two
    // oracles: the split pane's live font (read back via tree's splitFontSize) must DROP, proving the
    // action landed on the split; and the main pane's persisted size must stay put, proving it didn't leak
    // to the main. The default font dec then DOES shrink the main pane — so the panes are addressed
    // independently.
    func testFontPaneRightTargetsSplitNotMain() throws {
        let split = try sendCommand(#"{"cmd":"session.split","target":"active","args":{"mode":"on"}}"#)
        XCTAssertEqual(split["ok"] as? Bool, true, "split on should succeed: \(split)")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the active session should report split:true")
        let id = try activeSessionID()

        // baseline captured AFTER the split is shown, so any post-split reflow of the main pane already
        // settled — its point size doesn't change with pane width, so this stays constant hereafter.
        let baseline = try XCTUnwrap(pollFirstSessionFontSize(timeout: 10),
                                     "the main pane should report a persisted font size on launch")
        // the split pane's live font baseline, read back from the tree once the split surface realizes.
        let splitBaseline = try XCTUnwrap(pollSplitFontSize(target: id, timeout: 10),
                                          "the split pane should report a live font size once realized")

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

        // POSITIVE proof the action landed on the split: its live font (tree read-back) dropped below its
        // baseline. This is what the main-pane-only oracle couldn't show.
        let splitAfter = try XCTUnwrap(pollSplitFontSize(target: id, below: splitBaseline - 0.5, timeout: 8),
                                       "font --pane right should shrink the split pane's live font size")
        XCTAssertLessThan(splitAfter, splitBaseline)

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

    // font --pane scratch on a session with no scratch terminal opened errors. The scratch is lazily
    // spawned on first show, so a fresh session's scratchSurface is nil — deterministic, mirroring
    // testFontPaneRightWithoutSplitErrors. This is the only e2e over the font scratch arm (the success
    // path shares fontUntilOk's realized-surface proof with the split case).
    func testFontPaneScratchWithoutScratchErrors() throws {
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let newID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new should return the new id")

        let response = try sendCommand(fontRequest(cmd: "font.dec", target: newID, pane: "scratch"))
        XCTAssertEqual(response["ok"] as? Bool, false, "font --pane scratch with no scratch should fail: \(response)")
        XCTAssertEqual(response["error"] as? String, "session has no scratch terminal",
                       "should report no scratch terminal: \(response)")
    }

    // pane validation is enforced SERVER-SIDE, not only in the CLI `validate()`: a raw socket client bypasses
    // the CLI, so an unknown pane value must error here too (sendCommand is that raw client).
    func testFontRejectsInvalidPaneServerSide() throws {
        let response = try sendCommand(#"{"cmd":"font.dec","target":"active","args":{"pane":"middle"}}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "font pane:middle should fail server-side: \(response)")
        XCTAssertEqual(response["error"] as? String, "invalid pane: middle", "should report the invalid pane: \(response)")
    }

    // the DEFAULT (and `--pane left`) font target follows a promoted split survivor. When the primary
    // pane's shell exits while a split is shown, closePrimaryPane tears the primary surface down (surface
    // == nil) and promotes the split shell to a single session. The default font WRITE resolves
    // addressableSurface (= surface ?? splitSurface), so it hits the survivor — and the tree's fontSize
    // read-back must resolve the SAME addressableSurface. This is the app-level guard for the read-side
    // wiring: a regression to reading bare `surface` would OMIT fontSize here, because the primary surface
    // is gone (the host-free AppStorePaneTests can't exercise ControlServer.buildTree's closure).
    func testFontDefaultTargetsPromotedSplitSurvivor() throws {
        let id = try activeSessionID()

        let split = try sendCommand(#"{"cmd":"session.split","target":"\#(id)","args":{"mode":"on"}}"#)
        XCTAssertEqual(split["ok"] as? Bool, true, "split on should succeed: \(split)")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the active session should report split:true")
        // let the split (right) surface realize so the survivor has a live font before the primary exits.
        _ = try XCTUnwrap(pollSplitFontSize(target: id, timeout: 10),
                          "the split pane should report a live font size once realized")

        // exit the primary -> onExit fires closePrimaryPane, promoting the split survivor to a single session.
        XCTAssertTrue(try promoteSurvivorByExitingPrimary(target: id, timeout: 25),
                      "exiting the primary should promote the split survivor (session survives, split -> false)")

        // fontSize MUST read the promoted survivor via addressableSurface: the primary surface is torn down,
        // so a read off bare `surface` would omit this field. Its presence proves the addressableSurface wiring.
        let baseline = try XCTUnwrap(pollMainFontSize(target: id, timeout: 8),
                                     "fontSize must read the promoted survivor via addressableSurface (surface is nil)")

        // the DEFAULT font dec (no --pane) targets addressableSurface = the survivor.
        for _ in 0..<4 {
            let response = try sendCommand(fontRequest(cmd: "font.dec", target: id, pane: nil))
            XCTAssertEqual(response["ok"] as? Bool, true, "default font dec should reach the promoted survivor: \(response)")
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }

        // the survivor's live font dropped, read back through fontSize — the default write and its read-back
        // both track the promoted survivor.
        let dropped = try XCTUnwrap(pollMainFontSize(target: id, below: baseline - 0.5, timeout: 8),
                                    "the default font dec must shrink the promoted survivor's fontSize read-back")
        XCTAssertLessThan(dropped, baseline)
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

    /// Reads session `id`'s node from the current control tree (searching every workspace), or nil when the
    /// session is absent.
    private func treeSessionNode(target id: String) throws -> [String: Any]? {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        guard let result = tree["result"] as? [String: Any],
              let t = result["tree"] as? [String: Any],
              let workspaces = t["workspaces"] as? [[String: Any]] else { return nil }
        for ws in workspaces {
            for session in (ws["sessions"] as? [[String: Any]] ?? [])
            where (session["id"] as? String)?.lowercased() == id.lowercased() {
                return session
            }
        }
        return nil
    }

    /// Reads session `id`'s `splitFontSize` from the control tree, or nil when absent (the split surface
    /// isn't realized) — the read-back for `font --pane right`.
    private func splitFontSize(target id: String) throws -> Double? {
        try treeSessionNode(target: id)?["splitFontSize"] as? Double
    }

    /// Reads session `id`'s main/default `fontSize` from the control tree — the live font of
    /// `addressableSurface` (the main pane, or the promoted split survivor) — or nil when that pane isn't
    /// realized. The read-back for `font --pane left` / the default.
    private func mainFontSize(target id: String) throws -> Double? {
        try treeSessionNode(target: id)?["fontSize"] as? Double
    }

    /// Polls the tree until session `id`'s `fontSize` is present (and below `threshold` when given),
    /// returning it, or nil on timeout.
    private func pollMainFontSize(target id: String, below threshold: Double? = nil,
                                  timeout: TimeInterval) throws -> Double? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let size = try mainFontSize(target: id), threshold.map({ size < $0 }) ?? true { return size }
            usleep(200_000)
        }
        return nil
    }

    /// True once session `id` has collapsed to a single (non-split) pane (`split == false` while the session
    /// still exists) — the promoted-survivor state after the primary pane's shell exits. The caller must
    /// confirm the split was shown first, so a plain non-split session isn't mistaken for a promotion.
    private func isPromotedSurvivor(target id: String) throws -> Bool {
        guard let node = try treeSessionNode(target: id) else { return false }
        return (node["split"] as? Bool) == false
    }

    /// Exits the PRIMARY (left) shell to promote the split survivor, waiting until the session collapses to
    /// a single pane. Re-injects `exit` only while NOT yet promoted (a dropped first keystroke leaves the
    /// primary alive, safe to retype), so a late retry can't also exit the survivor and close the session.
    private func promoteSurvivorByExitingPrimary(target id: String, timeout: TimeInterval) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try isPromotedSurvivor(target: id) { return true }
            let typed = try sendCommand(typeRequest(text: "exit\n", target: id, select: false, pane: "left"))
            XCTAssertEqual(typed["ok"] as? Bool, true, "typing exit into the left pane should succeed: \(typed)")
            for _ in 0..<20 {
                if try isPromotedSurvivor(target: id) { return true }
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            }
        }
        return false
    }

    /// Polls the tree until session `id`'s `splitFontSize` is present (and below `threshold` when given),
    /// returning it, or nil on timeout.
    private func pollSplitFontSize(target id: String, below threshold: Double? = nil,
                                   timeout: TimeInterval) throws -> Double? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let size = try splitFontSize(target: id), threshold.map({ size < $0 }) ?? true { return size }
            usleep(200_000)
        }
        return nil
    }
}
