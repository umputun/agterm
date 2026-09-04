import AppKit
import XCTest

/// The split ratio as the user sees it, through the pty: `stty size` in each pane reports the rows the
/// surface was last sized to, so an even content-space ratio reads as equal row counts whatever the titlebar
/// inset, and a pane laid out under the titlebar (#539) reads as extra rows. The reporter's 1000x432 frame
/// is seeded through the app's defaults: the frame persists only on `willClose`, which `terminate()` skips.
final class SplitRatioUITests: ControlAPITestCase {
    private static let width = 1000
    private static let height = 432
    private static let debugBundleID = "com.umputun.agterm.debug"
    /// The compact-mode safe-area band the split spans, measured by the probe log in the #539 trace.
    private static let titlebarInset: CGFloat = 32

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

    /// Two oracles, 539 first so a drift failure cannot mask it. 539: right after the reveal an even split
    /// has equal rows; the reporter's stale host is 31pt taller, which gives the top pane one or two extra.
    /// Drift: a 1-point resize and restore at the same window size leaves the persisted ratio and both pty
    /// sizes unchanged.
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
        XCTAssertEqual(revealed.topRows, revealed.bottomRows,
                       "an even split revealed from the background should have equal rows (#539): \(revealed)")
        XCTAssertEqual(revealed.ratio ?? -1, 0.5, accuracy: 0.004, "the stored ratio should survive the reveal")

        try resizeWindow(width: Self.width, height: Self.height + 1)
        try resizeWindow(width: Self.width, height: Self.height)
        let resized = try ptySizes(tag: "resized", target: splitID.uuidString)
        attachScreenshot("restored split after a 1-point resize and restore")
        XCTAssertEqual(resized.ratio ?? -1, 0.5, accuracy: 0.004, "the ratio drifted across a same-size resize")
        XCTAssertEqual(revealed, resized, "pty sizes changed across a same-size resize")
    }

    /// A fresh top/bottom split is seeded with the default ratio, reads it back, renders even, and holds it
    /// across two 1-point resize cycles: the control for the reveal-keyed re-arm.
    func testFreshTopBottomSplitIsEvenAndHoldsAcrossWindowResize() throws {
        let id = try activeSessionID()
        try resizeWindow(width: Self.width, height: Self.height)
        try openTopBottomSplit(id)
        let fresh = try ptySizes(tag: "fresh", target: id)
        attachScreenshot("fresh top/bottom split, compact toolbar")
        XCTAssertEqual(fresh.ratio ?? -1, 0.5, accuracy: 0.004, "a fresh split should read back the default ratio")
        XCTAssertEqual(fresh.topRows, fresh.bottomRows, "a fresh split should be even: \(fresh)")
        try resizeWindow(width: Self.width, height: Self.height + 1)
        try resizeWindow(width: Self.width, height: Self.height)
        let once = try ptySizes(tag: "once", target: id)
        try resizeWindow(width: Self.width, height: Self.height + 1)
        try resizeWindow(width: Self.width, height: Self.height)
        let twice = try ptySizes(tag: "twice", target: id)
        XCTAssertEqual(fresh, once, "pty sizes changed across the first same-size resize")
        XCTAssertEqual(once, twice, "pty sizes changed across the second same-size resize")
        XCTAssertEqual(twice.ratio ?? -1, 0.5, accuracy: 0.004, "the ratio drifted across the resizes")
    }

    /// The ratio is a fraction of the pane area below the titlebar, so 0.5 is even in every toolbar mode.
    /// Compact is the default and covered above; the captures carry the divider position per mode.
    func testEvenSplitRendersEvenInNormalAndHiddenToolbarModes() throws {
        for mode in ["normal", "hidden"] {
            try relaunch(withSettings: #"{"toolbarMode":"\#(mode)"}"#)
            let id = try activeSessionID()
            try resizeWindow(width: Self.width, height: Self.height)
            try openTopBottomSplit(id)
            let sizes = try ptySizes(tag: mode, target: id)
            attachScreenshot("fresh top/bottom split, \(mode) toolbar")
            XCTAssertEqual(sizes.ratio ?? -1, 0.5, accuracy: 0.004, "\(mode): the default ratio should read back")
            XCTAssertEqual(sizes.topRows, sizes.bottomRows, "\(mode): an even split should have equal rows: \(sizes)")
        }
    }

    /// A divider drag captures the live ratio into the session, and it persists across a relaunch. The drag starts on the
    /// divider's screen position derived from the content-space ratio; a thin divider has a grab band of a
    /// few points, so the start is retried at small offsets until the read-back moves.
    func testDividerDragPersistsTheRatio() throws {
        let id = try activeSessionID()
        try resizeWindow(width: Self.width, height: Self.height)
        try openTopBottomSplit(id)
        let before = try ptySizes(tag: "before-drag", target: id)
        XCTAssertEqual(before.ratio ?? -1, 0.5, accuracy: 0.004, "the fresh split should start at the default")

        let window = app.windows.firstMatch
        let dividerY = Self.titlebarInset + 0.5 * (CGFloat(Self.height) - Self.titlebarInset)
        var dragged: Double?
        for offset in [0, -2, 2, -4, 4] {
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: (dividerY + CGFloat(offset)) / CGFloat(Self.height)))
            let end = start.withOffset(CGVector(dx: 0, dy: 60))
            start.click(forDuration: 0.2, thenDragTo: end, withVelocity: 120, thenHoldForDuration: 0.2)
            if poll(until: ((try? sessionNode(id: id)["splitRatio"] as? Double) ?? 0.5) > 0.55, timeout: 2) {
                dragged = try sessionNode(id: id)["splitRatio"] as? Double
                break
            }
        }
        let ratio = try XCTUnwrap(dragged, "dragging the divider down 60 points should move the read-back past 0.55")
        let after = try ptySizes(tag: "after-drag", target: id)
        attachScreenshot("top/bottom split after dragging the divider down")
        XCTAssertGreaterThan(after.topRows, before.topRows, "the top pane should gain rows from the drag: \(after)")

        // the drag's save is debounced; give it time to land before the relaunch restores from disk
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        try relaunch(withSettings: "{}")
        XCTAssertTrue(try pollSplit(id, timeout: 10), "the split should restore")
        let restored = try ptySizes(tag: "restored-drag", target: id)
        XCTAssertEqual(restored.ratio ?? -1, ratio, accuracy: 0.004, "the dragged ratio should survive a relaunch")
        XCTAssertEqual(restored.topRows, after.topRows, "the restored top pane should keep its dragged rows: \(restored)")
    }

    private func openTopBottomSplit(_ id: String) throws {
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(id)","args":{"mode":"on","axis":"horizontal"}}"#)["ok"] as? Bool,
                       true, "top/bottom split should open")
        XCTAssertTrue(try pollSplit(id, timeout: 10), "the split should show")
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
