import Darwin
import XCTest

/// Control-channel e2e for the window commands (window.new/list/select/close/resize/move/zoom) and
/// the title-bar double-click / drag gestures, plus the window-scoped `tree`/list oracles. Subclass
/// of `ControlAPITestCase`.
@MainActor
final class ControlWindowUITests: ControlAPITestCase {
    // MARK: - Window commands

    // window.new opens a second window and window.list reflects it: the new window is present + open,
    // and the list keeps the active-flag invariant (exactly one of the two windows is active). Which
    // window is frontmost depends on AppKit key-window timing, so the test asserts the invariant rather
    // than which one — `window.select` flipping the active flag is covered by the captured-id test.
    func testWindowNewAndList() throws {
        // the seeded launch has exactly one window, and it's the active one.
        let initial = try windowList()
        XCTAssertEqual(initial.count, 1, "should start with the one seeded window: \(initial)")
        XCTAssertEqual(initial.first?["active"] as? Bool, true, "the seeded window should be active")
        let baselineWindows = app.windows.count

        let created = try sendCommand(#"{"cmd":"window.new","args":{"name":"second"}}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "window.new should succeed: \(created)")
        let result = try XCTUnwrap(created["result"] as? [String: Any], "window.new should carry a result")
        let newID = try XCTUnwrap(result["id"] as? String, "window.new should return the new id")

        // poll until the list shows two windows, the new one present + open, with exactly one active.
        let settled = pollWindowList(timeout: 10) { list in
            guard list.count == 2 else { return false }
            guard let made = list.first(where: { ($0["id"] as? String)?.lowercased() == newID.lowercased() }) else { return false }
            let activeCount = list.filter { ($0["active"] as? Bool) == true }.count
            return (made["open"] as? Bool) == true && activeCount == 1
        }
        XCTAssertTrue(settled, "the new window should appear open with exactly one active window in window.list")

        // an ACTUAL on-screen window must materialize, not just the library JSON open flag — window.new
        // pre-loads the new store (so window.list always shows open:true), but the spawned SwiftUI window
        // self-dismisses if its claim is dropped. polling app.windows guards that regression.
        let appeared = pollAppWindows(atLeast: baselineWindows + 1, timeout: 10)
        XCTAssertTrue(appeared, "window.new must render a real on-screen window, got \(app.windows.count) (baseline \(baselineWindows))")
    }

    /// Polls until the app exposes at least `count` on-screen windows.
    private func pollAppWindows(atLeast count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.windows.count >= count { return true }
            usleep(200_000)
        }
        return false
    }

    // window.resize sets the active window's frame size; the on-screen window reflects it.
    func testWindowResize() throws {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session")
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "window should exist")
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.resize","args":{"width":1000,"height":700}}"#)["ok"] as? Bool, true)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let size = window.frame.size
            if abs(size.width - 1000) < 8, abs(size.height - 700) < 8 { return }
            usleep(150_000)
        }
        XCTFail("window did not resize to 1000x700, got \(window.frame.size)")
    }

    // window.move repositions the active window; moving right+down shifts the on-screen origin right+down
    // (a relative check, robust to screen-coordinate/menu-bar offsets).
    func testWindowMove() throws {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session")
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "window should exist")
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.move","args":{"x":80,"y":80}}"#)["ok"] as? Bool, true)
        usleep(700_000)
        let first = window.frame.origin
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.move","args":{"x":280,"y":240}}"#)["ok"] as? Bool, true)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let o = window.frame.origin
            if o.x > first.x + 100, o.y > first.y + 100 { return }
            usleep(150_000)
        }
        XCTFail("window did not move right+down: first=\(first) now=\(window.frame.origin)")
    }

    // window.zoom toggles the active window between its normal frame and a maximized (fill-screen) frame —
    // the control half of the double-click-header gesture. From a known small frame the first zoom clearly
    // enlarges; a second zoom restores it toward that frame.
    func testWindowZoom() throws {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session")
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "window should exist")
        // start from a known un-maximized size so the first zoom unambiguously grows the window.
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.resize","args":{"width":800,"height":600}}"#)["ok"] as? Bool, true)
        var deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !(abs(window.frame.size.width - 800) < 8 && abs(window.frame.size.height - 600) < 8) {
            usleep(150_000)
        }
        let normal = window.frame.size
        XCTAssertEqual(normal.width, 800, accuracy: 8, "window should settle near 800 wide before zoom, got \(normal)")

        XCTAssertEqual(try sendCommand(#"{"cmd":"window.zoom"}"#)["ok"] as? Bool, true)
        deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let s = window.frame.size
            if s.width > normal.width + 50 || s.height > normal.height + 50 { break }
            usleep(150_000)
        }
        XCTAssertTrue(window.frame.size.width > normal.width + 50 || window.frame.size.height > normal.height + 50,
                      "window should grow after window.zoom: normal=\(normal) now=\(window.frame.size)")

        // a second zoom restores the window toward its previous (normal) frame.
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.zoom"}"#)["ok"] as? Bool, true)
        deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let s = window.frame.size
            if abs(s.width - normal.width) < 40, abs(s.height - normal.height) < 40 { break }
            usleep(150_000)
        }
        XCTAssertEqual(window.frame.size.width, normal.width, accuracy: 40,
                       "window should restore toward \(normal) after a second window.zoom, got \(window.frame.size)")
    }

    // window.fullscreen toggles native macOS full screen for the active window — the control half of the
    // View ▸ Toggle Full Screen menu item / the green traffic-light button. From a known small frame the
    // first call fills the screen; a second call restores it. Asserts the command is wired end-to-end
    // (socket -> dispatcher -> WindowRegistry -> NSWindow.toggleFullScreen) and always leaves the app OUT
    // of full screen so it can't wedge later tests on a separate Space.
    func testWindowFullscreen() throws {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session")
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "window should exist")
        // start from a known un-maximized size so entering full screen unambiguously grows the window.
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.resize","args":{"width":800,"height":600}}"#)["ok"] as? Bool, true)
        var deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !(abs(window.frame.size.width - 800) < 8 && abs(window.frame.size.height - 600) < 8) {
            usleep(150_000)
        }
        let normal = window.frame.size
        XCTAssertEqual(normal.width, 800, accuracy: 8, "window should settle near 800 wide before fullscreen, got \(normal)")

        // enter full screen — the window fills the display (the native transition animates ~1s).
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.fullscreen"}"#)["ok"] as? Bool, true)
        deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let s = window.frame.size
            if s.width > normal.width + 50 || s.height > normal.height + 50 { break }
            usleep(200_000)
        }
        XCTAssertTrue(window.frame.size.width > normal.width + 50 || window.frame.size.height > normal.height + 50,
                      "window should fill the screen after window.fullscreen: normal=\(normal) now=\(window.frame.size)")

        // exit full screen — restores toward the previous frame and leaves the app un-fullscreened.
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.fullscreen"}"#)["ok"] as? Bool, true)
        deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let s = window.frame.size
            if abs(s.width - normal.width) < 60, abs(s.height - normal.height) < 60 { break }
            usleep(200_000)
        }
        XCTAssertEqual(window.frame.size.width, normal.width, accuracy: 60,
                       "window should restore toward \(normal) after exiting full screen, got \(window.frame.size)")
    }

    // A point 14pt below the top edge, horizontally centred: clears the top resize strip, lands inside the
    // titlebar band (compact 30 / normal 48), and sits in the empty header (a Spacer) — clear of the traffic
    // lights on the left and the toolbar buttons on the right, so the click falls through the decorative
    // regions' `.allowsHitTesting(false)` to the `WindowControlArea` layer behind the custom header.
    // Re-resolved at each interaction, so it stays in the header even after a zoom grows the window.
    private func emptyHeaderPoint(_ window: XCUIElement) -> XCUICoordinate {
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 14))
    }

    // The double-click-header GESTURE (the actual mouse event, not the window.zoom control command) must
    // zoom the window. Mirrors testWindowZoom's settle logic but drives the real cursor: resize to a known
    // small frame, double-click the empty header centre, assert the window grows, then double-click again
    // and assert it restores.
    func testDoubleClickHeaderZoomsAndRestores() throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "window should exist")
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.resize","args":{"width":800,"height":600}}"#)["ok"] as? Bool, true)
        var deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !(abs(window.frame.size.width - 800) < 8 && abs(window.frame.size.height - 600) < 8) {
            usleep(150_000)
        }
        let normal = window.frame.size
        XCTAssertEqual(normal.width, 800, accuracy: 8, "window should settle near 800 wide before the gesture, got \(normal)")

        emptyHeaderPoint(window).doubleClick()
        deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let s = window.frame.size
            if s.width > normal.width + 50 || s.height > normal.height + 50 { break }
            usleep(150_000)
        }
        XCTAssertTrue(window.frame.size.width > normal.width + 50 || window.frame.size.height > normal.height + 50,
                      "double-clicking the header should zoom (grow) the window: normal=\(normal) now=\(window.frame.size)")

        emptyHeaderPoint(window).doubleClick()
        deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let s = window.frame.size
            if abs(s.width - normal.width) < 40, abs(s.height - normal.height) < 40 { break }
            usleep(150_000)
        }
        XCTAssertEqual(window.frame.size.width, normal.width, accuracy: 40,
                       "a second header double-click should restore the window toward \(normal), got \(window.frame.size)")
    }

    // Locks in that the gesture HONORS the system setting rather than hardcoding zoom: pinned to "None"
    // (Desktop & Dock ▸ "Do Nothing") via setUp's env override, a header double-click must be a no-op —
    // the window's frame must not change. The complement of testDoubleClickHeaderZoomsAndRestores.
    // (the "None" pin is applied by ControlAPITestCase.setUp keyed on this test's name.)
    func testDoubleClickHeaderHonorsNoneSetting() throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "window should exist")
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.resize","args":{"width":800,"height":600}}"#)["ok"] as? Bool, true)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !(abs(window.frame.size.width - 800) < 8 && abs(window.frame.size.height - 600) < 8) {
            usleep(150_000)
        }
        let normal = window.frame.size
        XCTAssertEqual(normal.width, 800, accuracy: 8, "window should settle near 800 wide before the gesture, got \(normal)")

        emptyHeaderPoint(window).doubleClick()
        // give any (erroneous) zoom time to land, then assert the frame never changed.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(window.frame.size.width, normal.width, accuracy: 8,
                       "with 'None' set, a header double-click must not zoom (width): normal=\(normal) now=\(window.frame.size)")
        XCTAssertEqual(window.frame.size.height, normal.height, accuracy: 8,
                       "with 'None' set, a header double-click must not zoom (height): normal=\(normal) now=\(window.frame.size)")
    }

    // The `WindowControlArea` drag/zoom layer sits BEHIND the header; the toolbar buttons render in front
    // and must keep their own clicks. A double-click on the empty header must zoom (not reach a button);
    // a click on quick-terminal-toggle must still open the quick terminal cover despite the layer behind.
    func testHeaderButtonsStillReceiveClicksOverControlArea() throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "window should exist")
        let cover = app.descendants(matching: .any).matching(identifier: "quick-terminal").firstMatch

        // double-clicking the empty header zooms the window; it must NOT open the quick terminal.
        emptyHeaderPoint(window).doubleClick()
        XCTAssertFalse(cover.waitForExistence(timeout: 2), "double-clicking the header must not open the quick terminal")

        // the button itself still takes its click even though the control-area layer is behind the header.
        let button = app.buttons["quick-terminal-toggle"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "quick-terminal toolbar button should exist")
        button.click()
        XCTAssertTrue(cover.waitForExistence(timeout: 5), "clicking quick-terminal-toggle should open the quick terminal cover")
    }

    // A single-click-drag anywhere on the full custom header moves the window (performDrag), not just the
    // native top band. Resize + position to a known on-screen frame so the drag stays on screen and the
    // delta is unambiguous, record the origin, drag the empty header, and assert the window's origin moved.
    func testDragHeaderMovesWindow() throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "window should exist")
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.resize","args":{"width":800,"height":600}}"#)["ok"] as? Bool, true)
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.move","args":{"x":140,"y":140}}"#)["ok"] as? Bool, true)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, abs(window.frame.size.width - 800) > 8 { usleep(150_000) }
        let origin = window.frame.origin

        let from = emptyHeaderPoint(window)
        let to = from.withOffset(CGVector(dx: 90, dy: 70))
        from.click(forDuration: 0.3, thenDragTo: to, withVelocity: 180, thenHoldForDuration: 0.25)

        let settle = Date().addingTimeInterval(5)
        while Date() < settle {
            let o = window.frame.origin
            if abs(o.x - origin.x) > 20 || abs(o.y - origin.y) > 20 { break }
            usleep(150_000)
        }
        let moved = window.frame.origin
        XCTAssertTrue(abs(moved.x - origin.x) > 20 || abs(moved.y - origin.y) > 20,
                      "dragging the header should move the window: origin=\(origin) now=\(moved)")
    }

    // window.close marks the window closed, after which a session command targeting it returns the
    // "window not open" error. (--window routing into the second window is exercised first to prove
    // the round-trip, then the close flips it to the error path.)
    func testClosedWindowTargetingErrors() throws {
        let created = try sendCommand(#"{"cmd":"window.new"}"#)
        let result = try XCTUnwrap(created["result"] as? [String: Any], "window.new should carry a result")
        let windowB = try XCTUnwrap(result["id"] as? String, "window.new should return the new id")
        XCTAssertTrue(pollWindowList(timeout: 10) { $0.count == 2 }, "the second window should appear")

        // routing into the still-open window B works.
        let openTree = try sendCommand(#"{"cmd":"tree","args":{"window":"\#(windowB)"}}"#)
        XCTAssertEqual(openTree["ok"] as? Bool, true, "tree --window B should succeed while open: \(openTree)")

        // close window B, then wait until the index/list marks it closed. window.close drives AppKit's
        // performClose → willCloseNotification → per-window surface teardown → library.closeWindow, a
        // heavier round-trip than the other commands; under full-suite CPU contention the willClose handler
        // can be delayed past a tight budget, so allow a longer settle (the open flag is the deterministic
        // readiness signal — this waits for it, it isn't a blanket sleep).
        let closed = try sendCommand(#"{"cmd":"window.close","target":"\#(windowB)"}"#)
        XCTAssertEqual(closed["ok"] as? Bool, true, "window.close should succeed: \(closed)")
        let settled = pollWindowList(timeout: 30) { list in
            list.first(where: { ($0["id"] as? String)?.lowercased() == windowB.lowercased() })?["open"] as? Bool == false
        }
        XCTAssertTrue(settled, "window B should be marked closed after window.close")

        // a session command targeting the now-closed window returns the structured closed-window error.
        let response = try sendCommand(#"{"cmd":"tree","args":{"window":"\#(windowB)"}}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "targeting a closed window should fail: \(response)")
        XCTAssertEqual(response["error"] as? String, "window not open — window.select it first",
                       "should return the closed-window error: \(response)")
    }

    // --window targeting routes session.new + tree to the right window: a session added to window B with
    // --window lands in B's tree (now two sessions) and NOT in the frontmost (A) tree (still one).
    func testWindowTargetingRoutesToTheRightTree() throws {
        let initial = try windowList()
        let windowA = try XCTUnwrap(initial.first?["id"] as? String, "the seeded window id")

        let created = try sendCommand(#"{"cmd":"window.new"}"#)
        let result = try XCTUnwrap(created["result"] as? [String: Any], "window.new should carry a result")
        let windowB = try XCTUnwrap(result["id"] as? String, "window.new should return the new id")
        XCTAssertTrue(pollWindowList(timeout: 10) { $0.count == 2 }, "the second window should appear")

        // add a session to window B by id.
        let added = try sendCommand(#"{"cmd":"session.new","args":{"window":"\#(windowB)"}}"#)
        XCTAssertEqual(added["ok"] as? Bool, true, "session.new --window B should succeed: \(added)")

        // window B's tree now holds two sessions; window A's still holds one.
        XCTAssertTrue(pollTreeSessionCount(window: windowB, expected: 2, timeout: 10),
                      "the new session should land in window B's tree")
        XCTAssertTrue(pollTreeSessionCount(window: windowA, expected: 1, timeout: 5),
                      "window A's tree should be unchanged")
    }

    // an id captured from one window resolves with no --window even while another window is frontmost:
    // create window B + a session in it, raise window A to make it frontmost, then session.select the
    // captured B-session id with no --window — it resolves cross-window and selects it in B's store.
    func testCapturedIDResolvesWhileAnotherWindowFrontmost() throws {
        let initial = try windowList()
        let windowA = try XCTUnwrap(initial.first?["id"] as? String, "the seeded window id")

        let created = try sendCommand(#"{"cmd":"window.new"}"#)
        let result = try XCTUnwrap(created["result"] as? [String: Any], "window.new should carry a result")
        let windowB = try XCTUnwrap(result["id"] as? String, "window.new should return the new id")
        XCTAssertTrue(pollWindowList(timeout: 10) { $0.count == 2 }, "the second window should appear")

        // capture a session id created in window B.
        let added = try sendCommand(#"{"cmd":"session.new","args":{"window":"\#(windowB)"}}"#)
        let addedResult = try XCTUnwrap(added["result"] as? [String: Any], "session.new should carry a result")
        let sessionID = try XCTUnwrap(addedResult["id"] as? String, "session.new should return the new session id")

        // raise window A so it becomes frontmost (window B was frontmost right after window.new).
        XCTAssertTrue(selectWindowUntilActive(windowA, timeout: 15),
                      "window A should become active")

        // select the B-session by id with NO --window: it resolves cross-window to window B's store.
        let selected = try sendCommand(#"{"cmd":"session.select","target":"\#(sessionID)"}"#)
        XCTAssertEqual(selected["ok"] as? Bool, true, "selecting the captured id with no --window should succeed: \(selected)")
        XCTAssertEqual((selected["result"] as? [String: Any])?["id"] as? String, sessionID,
                       "select should resolve to the captured B-session id: \(selected)")

        // confirm it actually selected in window B's tree.
        XCTAssertTrue(pollTreeActiveSession(window: windowB, sessionID: sessionID, timeout: 10),
                      "the captured session should be active in window B's tree")
    }

    // a WORKSPACE id captured from window B resolves cross-window with no --window even while window A
    // is frontmost (exercises the cross-window workspace resolver arm, distinct from the session one).
    func testCapturedWorkspaceIDResolvesCrossWindow() throws {
        let created = try sendCommand(#"{"cmd":"window.new"}"#)
        let windowB = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "window.new should return the new id")
        XCTAssertTrue(pollWindowList(timeout: 10) { $0.count == 2 }, "the second window should appear")

        // create a workspace in window B and capture its id.
        let madeWs = try sendCommand(#"{"cmd":"workspace.new","args":{"window":"\#(windowB)","name":"betaws"}}"#)
        let workspaceID = try XCTUnwrap((madeWs["result"] as? [String: Any])?["id"] as? String,
                                        "workspace.new should return the new workspace id")

        // select the B-workspace by id with NO --window: it resolves cross-window to window B's store.
        let selected = try sendCommand(#"{"cmd":"workspace.select","target":"\#(workspaceID)"}"#)
        XCTAssertEqual(selected["ok"] as? Bool, true, "selecting the captured workspace id cross-window should succeed: \(selected)")
        XCTAssertEqual((selected["result"] as? [String: Any])?["id"] as? String, workspaceID,
                       "select should resolve to the captured B-workspace id: \(selected)")
    }

    // an unknown id with no --window is searched across ALL open windows and, found nowhere, returns
    // the structured not-found error (the cross-window resolver's miss path).
    func testCrossWindowUnknownIDErrors() throws {
        let created = try sendCommand(#"{"cmd":"window.new"}"#)
        _ = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "window.new should return the new id")
        XCTAssertTrue(pollWindowList(timeout: 10) { $0.count == 2 }, "the second window should appear")

        let bogus = UUID().uuidString
        let response = try sendCommand(#"{"cmd":"session.select","target":"\#(bogus)"}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "an id matching no open window should fail: \(response)")
        XCTAssertEqual(response["error"] as? String, "no such session: \(bogus)",
                       "should return the cross-window not-found error: \(response)")
    }

    // after closing the frontmost window, the remaining window becomes active — window.list reports
    // exactly one open window and it is flagged active (the frontmost invariant survives a close).
    func testRemainingWindowBecomesActiveAfterClosingFrontmost() throws {
        let created = try sendCommand(#"{"cmd":"window.new"}"#)
        let windowB = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "window.new should return the new id")
        XCTAssertTrue(pollWindowList(timeout: 10) { $0.count == 2 }, "the second window should appear")

        // close the just-created (frontmost) window B.
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.close","target":"\#(windowB)"}"#)["ok"] as? Bool, true)

        // exactly one window remains open, and the surviving (frontmost-or-first) window is active.
        let settled = pollWindowList(timeout: 30) { list in
            let open = list.filter { ($0["open"] as? Bool) == true }
            let active = list.filter { ($0["active"] as? Bool) == true }
            return open.count == 1 && active.count == 1 && (open.first?["id"] as? String) == (active.first?["id"] as? String)
        }
        XCTAssertTrue(settled, "the remaining open window should become the single active window after closing the frontmost")
    }

    // MARK: - Window oracles

    /// Sends `window.list` and returns the windows array.
    private func windowList() throws -> [[String: Any]] {
        let response = try sendCommand(#"{"cmd":"window.list"}"#)
        XCTAssertEqual(response["ok"] as? Bool, true, "window.list should succeed: \(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any], "window.list should carry a result")
        return try XCTUnwrap(result["windows"] as? [[String: Any]], "window.list should return windows")
    }

    /// Re-issues `window.select` for `id` while polling `window.list` for that window's `active` flag.
    /// `window.select` returns ok as soon as the window is OPEN, not when it has become key — and the
    /// `active` flag flips only on the async `didBecomeKey`/`didBecomeMain`, which macOS can drop or
    /// delay under XCUITest (a `makeKeyAndOrderFront` that doesn't take is never re-issued by a single
    /// select). Re-selecting (idempotent: raises again) recovers a dropped activation; `app.activate()`
    /// first so the app is the active application (a window can't become key while the app is inactive).
    private func selectWindowUntilActive(_ id: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            app.activate()
            _ = try? sendCommand(#"{"cmd":"window.select","target":"\#(id)"}"#)
            if pollWindowList(timeout: 2, { list in
                list.first(where: { ($0["id"] as? String)?.lowercased() == id.lowercased() })?["active"] as? Bool == true
            }) { return true }
        }
        return false
    }

    /// Polls `window.list` until `predicate` holds, or times out.
    private func pollWindowList(timeout: TimeInterval, _ predicate: ([[String: Any]]) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let list = try? windowList(), predicate(list) { return true }
            usleep(200_000)
        }
        return false
    }

    /// Polls `tree --window <window>` until its (single) workspace holds `expected` sessions.
    private func pollTreeSessionCount(window: String, expected: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let workspaces = try? windowTreeWorkspaces(window: window),
               (workspaces.first?["sessions"] as? [[String: Any]])?.count == expected {
                return true
            }
            usleep(200_000)
        }
        return false
    }

    /// Polls `tree --window <window>` until the session with `sessionID` is marked active.
    private func pollTreeActiveSession(window: String, sessionID: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let workspaces = try? windowTreeWorkspaces(window: window) {
                for ws in workspaces {
                    let sessions = ws["sessions"] as? [[String: Any]] ?? []
                    for s in sessions where (s["id"] as? String)?.lowercased() == sessionID.lowercased() {
                        if (s["active"] as? Bool) == true { return true }
                    }
                }
            }
            usleep(200_000)
        }
        return false
    }

    /// Sends `tree --window <window>` and returns its workspaces array.
    private func windowTreeWorkspaces(window: String) throws -> [[String: Any]] {
        let response = try sendCommand(#"{"cmd":"tree","args":{"window":"\#(window)"}}"#)
        let result = try XCTUnwrap(response["result"] as? [String: Any], "tree should carry a result")
        let tree = try XCTUnwrap(result["tree"] as? [String: Any], "result should carry a tree")
        return try XCTUnwrap(tree["workspaces"] as? [[String: Any]], "tree should list workspaces")
    }
}
