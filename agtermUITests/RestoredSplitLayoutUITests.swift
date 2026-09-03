import AppKit
import XCTest

/// #539: a top/bottom split restored in the background and selected after launch lays its top pane out
/// under the compact titlebar until the window is resized. The pty is the oracle: a stale hosting view
/// sizes the surface taller than its pane, so `stty size` in a pane changes across a 1-point resize and
/// restore at the SAME window size only when the revealed layout was stale. The reporter's frame is seeded
/// through the app's defaults: the frame persists only on `willClose`, which `terminate()` skips.
final class RestoredSplitLayoutUITests: ControlAPITestCase {
    private static let width = 1000
    private static let height = 432
    private static let debugBundleID = "com.umputun.agterm.debug"

    private struct PtySizes: Equatable {
        let top: String
        let bottom: String
        let ratio: Double?

        // the ratio is asserted with a tolerance on its own; equality is the two pty sizes
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.top == rhs.top && lhs.bottom == rhs.bottom }

        var topRows: Int { rows(top) }
        var bottomRows: Int { rows(bottom) }
        private func rows(_ size: String) -> Int { Int(size.split(separator: " ").first ?? "") ?? -1 }
    }

    /// Two oracles, 539 first so a drift failure cannot mask it. 539: right after the reveal at an even
    /// split, the titlebar inset costs the top pane at least one row, so top rows < bottom rows; the
    /// reporter's stale host is 31pt taller, which makes top >= bottom. Drift: a 1-point resize and restore
    /// at the same window size leaves the persisted ratio and both pty sizes unchanged.
    func testRestoredBackgroundTopBottomSplitLaysOutAndHoldsItsRatio() throws {
        let splitID = UUID(uuidString: "53900000-0000-0000-0000-000000000001")!
        let helperID = UUID(uuidString: "53900000-0000-0000-0000-000000000002")!
        try seedWindowFrame()
        let snapshot = """
        {"version":1,"selectedSessionID":"\(helperID.uuidString)","workspaces":[\
        {"id":"\(UUID().uuidString)","name":"workspace 1","sessions":[\
        {"id":"\(splitID.uuidString)","customName":"split","cwd":"\(NSHomeDirectory())",\
        "isSplit":true,"hasSplit":true,"splitAxis":"horizontal","splitRatio":0.5},\
        {"id":"\(helperID.uuidString)","customName":"helper","cwd":"\(NSHomeDirectory())"}]}]}
        """
        try relaunch(withSnapshot: snapshot)
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "both sessions should restore")
        XCTAssertTrue(try pollSplit(splitID.uuidString, timeout: 10), "the split should restore")
        XCTAssertEqual(try sessionNode(id: helperID.uuidString)["active"] as? Bool, true,
                       "the helper session should be selected at launch, leaving the split in the background")
        try assertWindowSize(width: Self.width, height: Self.height, tolerance: 8,
                             "the seeded frame should restore before the split is revealed")

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(splitID.uuidString)"}"#)["ok"] as? Bool,
                       true, "selecting the split session should succeed")
        XCTAssertTrue(poll(until: (try? sessionNodeIfPresent(id: splitID.uuidString))??["active"] as? Bool == true,
                           timeout: 5), "the split session should become active")

        let revealed = try ptySizes(tag: "revealed", target: splitID.uuidString)
        // automatic captures are dropped on success, and a clean run is the one that must show the screen
        attachScreenshot("restored split revealed, before any resize")
        XCTAssertLessThan(revealed.topRows, revealed.bottomRows,
                          "the top pane should lose at least one row to the titlebar inset (#539): \(revealed)")
        XCTAssertEqual(revealed.ratio ?? -1, 0.5, accuracy: 0.004, "the stored ratio should survive the reveal")

        try resizeWindow(width: Self.width, height: Self.height + 1)
        try resizeWindow(width: Self.width, height: Self.height)
        let resized = try ptySizes(tag: "resized", target: splitID.uuidString)
        attachScreenshot("restored split after a 1-point resize and restore")
        XCTAssertEqual(resized.ratio ?? -1, 0.5, accuracy: 0.004, "the ratio drifted across a same-size resize")
        XCTAssertEqual(revealed, resized, "pty sizes changed across a same-size resize")
    }

    /// The visible-first control: a fresh top/bottom split with its ratio set through the control API holds
    /// it across two 1-point resize cycles, so a reveal-keyed fix must not disturb the path that already works.
    func testFreshTopBottomSplitRatioSurvivesWindowResize() throws {
        let id = try activeSessionID()
        try resizeWindow(width: Self.width, height: Self.height)
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(id)","args":{"mode":"on","axis":"horizontal"}}"#)["ok"] as? Bool,
                       true, "top/bottom split should open")
        XCTAssertTrue(try pollSplit(id, timeout: 10), "the split should show")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.resize","target":"\#(id)","args":{"ratio":0.5}}"#)["ok"] as? Bool,
                       true, "ratio 0.5 should apply")
        let set = try ptySizes(tag: "set", target: id)
        try resizeWindow(width: Self.width, height: Self.height + 1)
        try resizeWindow(width: Self.width, height: Self.height)
        let once = try ptySizes(tag: "once", target: id)
        try resizeWindow(width: Self.width, height: Self.height + 1)
        try resizeWindow(width: Self.width, height: Self.height)
        let twice = try ptySizes(tag: "twice", target: id)
        XCTAssertEqual(set.ratio ?? -1, 0.5, accuracy: 0.004, "session.resize should store 0.5")
        XCTAssertEqual(set, once, "pty sizes or ratio changed across the first same-size resize")
        XCTAssertEqual(once, twice, "pty sizes or ratio changed across the second same-size resize")
    }

    /// Persist the reporter's 1000x432 frame under the first launch's window id, which the relaunch reopens.
    private func seedWindowFrame() throws {
        let windowFile = stateDir.windowSnapshotFile()
        let windowID = try XCTUnwrap(UUID(uuidString: windowFile.deletingPathExtension().lastPathComponent),
                                     "the first launch should have written a per-window snapshot file")
        let key = "agterm-frame-\(windowID.uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.debugBundleID), "the app's defaults domain")
        defaults.set(NSStringFromRect(NSRect(x: 120, y: 120, width: Self.width, height: Self.height)), forKey: key)
        addTeardownBlock { UserDefaults(suiteName: Self.debugBundleID)?.removeObject(forKey: key) }
    }

    private func assertWindowSize(width: Int, height: Int, tolerance: CGFloat, _ message: String) throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "window should exist")
        let fits = poll(until: abs(window.frame.width - CGFloat(width)) <= tolerance
            && abs(window.frame.height - CGFloat(height)) <= tolerance, timeout: 5)
        XCTAssertTrue(fits, "\(message): expected \(width)x\(height), got \(window.frame.size)")
    }

    private func resizeWindow(width: Int, height: Int) throws {
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.resize","args":{"width":\#(width),"height":\#(height)}}"#)["ok"] as? Bool,
                       true, "window.resize to \(width)x\(height) should succeed")
        try assertWindowSize(width: width, height: height, tolerance: 0.5, "window should resize to \(width)x\(height)")
        // the surface's set_size follows the layout pass, so the pty is read only after that pass ran
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }

    /// `stty size` from both panes' shells, through the pty each surface last sized.
    private func ptySizes(tag: String, target: String) throws -> PtySizes {
        func read(_ pane: String) throws -> String {
            let file = markerDir.appendingPathComponent("\(tag)-\(pane)-stty")
            return try XCTUnwrap(typeUntilMarker("stty size > '\(file.path)'\n", target: target, file: file,
                                                 select: false, pane: pane),
                                 "the \(pane) pane should report its pty size (\(tag))")
        }
        let sizes = try PtySizes(top: read("top"), bottom: read("bottom"),
                                 ratio: sessionNode(id: target)["splitRatio"] as? Double)
        XCTContext.runActivity(named: "pty sizes \(tag)") { activity in
            let note = XCTAttachment(string: "top: \(sizes.top)\nbottom: \(sizes.bottom)\nsplitRatio: \(String(describing: sizes.ratio))")
            note.lifetime = .keepAlways
            activity.add(note)
        }
        return sizes
    }

    private func attachScreenshot(_ name: String) {
        // the window alone: a screen capture would publish whatever else is on the developer's display
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
