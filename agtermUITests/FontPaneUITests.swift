import Foundation
import XCTest

// the split pane's font is NOT persisted (its surface's onFontSizeChange is unwired by design), so the
// persisted MAIN-pane size is the oracle for what the split did NOT touch. The error cases go straight over
// the socket, so the SERVER — not just the CLI `validate()` — enforces them.
@MainActor
final class FontPaneUITests: ControlAPITestCase {
    // two oracles: the split's live font (tree `splitFontSize`) must DROP, and the main pane's persisted
    // size must stay put — the bug was that font always hit the main/left surface.
    func testFontPaneRightTargetsSplitNotMain() throws {
        let split = try sendCommand(#"{"cmd":"session.split","target":"active","args":{"mode":"on"}}"#)
        XCTAssertEqual(split["ok"] as? Bool, true, "split on should succeed: \(split)")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the active session should report split:true")
        let id = try activeSessionID()

        // captured AFTER the split is shown so any post-split reflow already settled; point size does not
        // track pane width, so it stays constant hereafter.
        let baseline = try XCTUnwrap(pollFirstSessionFontSize(timeout: 10),
                                     "the main pane should report a persisted font size on launch")
        let splitBaseline = try XCTUnwrap(pollSplitFontSize(target: id, timeout: 10),
                                          "the split pane should report a live font size once realized")

        // a freshly shown split may not be realized for the first request; continueAfterFailure = false
        // forbids asserting inside a retry loop, so fontUntilOk swallows the transient failures.
        let firstRight = try fontUntilOk(cmd: "font.dec", target: id, pane: "right")
        XCTAssertEqual(firstRight["ok"] as? Bool, true,
                       "font dec --pane right should reach the realized split surface: \(firstRight)")
        for _ in 0..<3 {
            let response = try sendCommand(fontRequest(cmd: "font.dec", target: id, pane: "right"))
            XCTAssertEqual(response["ok"] as? Bool, true, "font dec --pane right should stay ok: \(response)")
        }

        let splitAfter = try XCTUnwrap(pollSplitFontSize(target: id, below: splitBaseline - 0.5, timeout: 8),
                                       "font --pane right should shrink the split pane's live font size")
        XCTAssertLessThan(splitAfter, splitBaseline)

        // wait past the debounced save before asserting the main pane did not drift.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let afterRight = try XCTUnwrap(firstSessionFontSize(), "the main pane size should still be readable")
        XCTAssertEqual(afterRight, baseline, accuracy: 0.5,
                       "font --pane right must not change the main pane's persisted size")

        for _ in 0..<4 {
            let response = try sendCommand(fontRequest(cmd: "font.dec", target: id, pane: nil))
            XCTAssertEqual(response["ok"] as? Bool, true, "default font dec should hit the main pane: \(response)")
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        let decreased = try XCTUnwrap(pollFirstSessionFontSize(below: baseline - 0.5, timeout: 8),
                                      "the default (no --pane) font dec should shrink the main pane's persisted size")
        XCTAssertLessThan(decreased, baseline)
    }

    func testFontPaneRightWithoutSplitErrors() throws {
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let newID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new should return the new id")

        let response = try sendCommand(fontRequest(cmd: "font.dec", target: newID, pane: "right"))
        XCTAssertEqual(response["ok"] as? Bool, false, "font --pane right with no split should fail: \(response)")
        XCTAssertEqual(response["error"] as? String, "session has no split pane", "should report no split pane: \(response)")
    }

    // the scratch is lazily spawned on first show, so a fresh session's scratchSurface is nil.
    func testFontPaneScratchWithoutScratchErrors() throws {
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let newID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new should return the new id")

        let response = try sendCommand(fontRequest(cmd: "font.dec", target: newID, pane: "scratch"))
        XCTAssertEqual(response["ok"] as? Bool, false, "font --pane scratch with no scratch should fail: \(response)")
        XCTAssertEqual(response["error"] as? String, "session has no scratch terminal",
                       "should report no scratch terminal: \(response)")
    }

    func testFontRejectsInvalidPaneServerSide() throws {
        let response = try sendCommand(#"{"cmd":"font.dec","target":"active","args":{"pane":"middle"}}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "font pane:middle should fail server-side: \(response)")
        XCTAssertEqual(response["error"] as? String, "invalid pane: middle", "should report the invalid pane: \(response)")
    }

    // when the primary pane's shell exits, closePrimaryPane moves the split survivor into `surface` and nils
    // `splitSurface`, so the default WRITE and the tree's fontSize read-back must both land on the survivor
    // as the MAIN pane rather than following the split fields it no longer occupies.
    func testFontDefaultTargetsPromotedSplitSurvivor() throws {
        let id = try activeSessionID()

        let split = try sendCommand(#"{"cmd":"session.split","target":"\#(id)","args":{"mode":"on"}}"#)
        XCTAssertEqual(split["ok"] as? Bool, true, "split on should succeed: \(split)")
        XCTAssertTrue(pollActiveSessionSplit(true, timeout: 10), "the active session should report split:true")
        // let the split (right) surface realize so the survivor has a live font before the primary exits.
        _ = try XCTUnwrap(pollSplitFontSize(target: id, timeout: 10),
                          "the split pane should report a live font size once realized")

        XCTAssertTrue(try promoteSurvivorByExitingPrimary(target: id, timeout: 25),
                      "exiting the primary should promote the split survivor (session survives, split -> false)")

        let baseline = try XCTUnwrap(pollMainFontSize(target: id, timeout: 8),
                                     "fontSize must read the promoted survivor, which is now the main pane")

        for _ in 0..<4 {
            let response = try sendCommand(fontRequest(cmd: "font.dec", target: id, pane: nil))
            XCTAssertEqual(response["ok"] as? Bool, true, "default font dec should reach the promoted survivor: \(response)")
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }

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
