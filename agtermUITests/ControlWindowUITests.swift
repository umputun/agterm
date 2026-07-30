import Darwin
import XCTest

/// Control-channel e2e for the window commands (window.new/list/select/close/resize/move/zoom) and
/// the title-bar double-click / drag gestures, plus the window-scoped `tree`/list oracles. Subclass
/// of `ControlAPITestCase`.
@MainActor
final class ControlWindowUITests: ControlAPITestCase {
    // MARK: - Window commands

    // which window ends up frontmost depends on AppKit key-window timing, so this asserts the
    // exactly-one-active invariant rather than which one.
    func testWindowNewAndList() throws {
        let initial = try windowList()
        XCTAssertEqual(initial.count, 1, "should start with the one seeded window: \(initial)")
        XCTAssertEqual(initial.first?["active"] as? Bool, true, "the seeded window should be active")
        let baselineWindows = app.windows.count

        let created = try sendCommand(#"{"cmd":"window.new","args":{"name":"second"}}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "window.new should succeed: \(created)")
        let result = try XCTUnwrap(created["result"] as? [String: Any], "window.new should carry a result")
        let newID = try XCTUnwrap(result["id"] as? String, "window.new should return the new id")

        let settled = pollWindowList(timeout: 10) { list in
            guard list.count == 2 else { return false }
            guard let made = list.first(where: { ($0["id"] as? String)?.lowercased() == newID.lowercased() }) else { return false }
            let activeCount = list.filter { ($0["active"] as? Bool) == true }.count
            return (made["open"] as? Bool) == true && activeCount == 1
        }
        XCTAssertTrue(settled, "the new window should appear open with exactly one active window in window.list")

        // window.new pre-loads the store, so window.list shows open:true even when the spawned SwiftUI
        // window self-dismisses on a dropped claim — only polling app.windows catches that.
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

    // a relative right+down check, robust to screen-coordinate/menu-bar offsets.
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

    // must always leave the app OUT of full screen, or later tests wedge on a separate Space.
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

        // the native transition animates ~1s, hence the longer settle.
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.fullscreen"}"#)["ok"] as? Bool, true)
        deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let s = window.frame.size
            if s.width > normal.width + 50 || s.height > normal.height + 50 { break }
            usleep(200_000)
        }
        XCTAssertTrue(window.frame.size.width > normal.width + 50 || window.frame.size.height > normal.height + 50,
                      "window should fill the screen after window.fullscreen: normal=\(normal) now=\(window.frame.size)")

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

    // asserted entirely over the control channel: a miniaturized window is off-screen, so an XCUIElement
    // query against it hangs on event synthesis instead of failing. The restore rides `addTeardownBlock`
    // (registered BEFORE the minimize) because `continueAfterFailure = false` unwinds through an ObjC
    // exception that skips a Swift `defer`.
    func testWindowMinimizeAndRestore() throws {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session")
        let id = try XCTUnwrap(try windowList().first?["id"] as? String, "the seeded window should have an id")
        let before = try XCTUnwrap(try windowList().first?["geometry"] as? [String: Any],
                                   "an open window should report its geometry")

        addTeardownBlock { _ = try? self.sendCommand(#"{"cmd":"window.minimize","args":{"mode":"off"}}"#) }

        XCTAssertEqual(try sendCommand(#"{"cmd":"window.minimize","args":{"mode":"on"}}"#)["ok"] as? Bool, true)
        XCTAssertTrue(pollWindowList(timeout: 10) { $0.first?["minimized"] as? Bool == true },
                      "window.list should report minimized:true after window.minimize on")

        // NSWindow.screen is nil while miniaturized, so this fails without the overlap-based screen fallback.
        let whileMinimized = try XCTUnwrap(try windowList().first?["geometry"] as? [String: Any],
                                           "a minimized window must still report its geometry")
        for key in ["x", "y", "width", "height", "display"] {
            XCTAssertEqual(whileMinimized[key] as? Int, before[key] as? Int,
                           "\(key) should survive minimizing: before=\(before) now=\(whileMinimized)")
        }

        XCTAssertEqual(try sendCommand(#"{"cmd":"window.minimize","args":{"mode":"on"}}"#)["ok"] as? Bool, true)
        XCTAssertEqual(try windowList().first?["minimized"] as? Bool, true, "a repeated `on` must stay minimized")

        XCTAssertEqual(try sendCommand(#"{"cmd":"window.select","target":"\#(id)"}"#)["ok"] as? Bool, true)
        XCTAssertTrue(pollWindowList(timeout: 10) { $0.first?["minimized"] as? Bool == false },
                      "window.select should un-minimize the window it raises")

        XCTAssertEqual(try sendCommand(#"{"cmd":"window.minimize","target":"\#(id)","args":{"mode":"off"}}"#)["ok"] as? Bool,
                       true)
        XCTAssertEqual(try windowList().first?["minimized"] as? Bool, false)
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 10),
                      "the restored window should be interactive again")
    }

    // a parked window must not be left frontmost — one sitting in the Dock swallows every untargeted
    // command. It also guards the ordering: WindowAccessor presents a new window on the next main-queue
    // turn as well as synchronously, so parking it too early is silently undone.
    func testWindowNewMinimizedStaysParked() throws {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session")
        let launchID = try XCTUnwrap(try windowList().first?["id"] as? String, "the seeded window should have an id")

        let created = try sendCommand(#"{"cmd":"window.new","args":{"name":"parked","minimized":true}}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "window.new --minimized should succeed: \(created)")
        let newID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "window.new returns an id")
        addTeardownBlock { _ = try? self.sendCommand(#"{"cmd":"window.minimize","target":"\#(newID)","args":{"mode":"off"}}"#) }

        let list = try windowList()
        let made = try XCTUnwrap(list.first { ($0["id"] as? String)?.lowercased() == newID.lowercased() },
                                 "the new window should be listed: \(list)")
        XCTAssertEqual(made["minimized"] as? Bool, true, "window.new --minimized should report minimized: \(made)")
        XCTAssertEqual(made["active"] as? Bool, false, "a parked window must not be left frontmost: \(made)")
        XCTAssertEqual(list.first { ($0["id"] as? String)?.lowercased() == launchID.lowercased() }?["active"] as? Bool,
                       true, "the visible window should keep frontmost: \(list)")

        // the sleep outlasts WindowAccessor's deferred present and the UI-test schedule.
        usleep(1_500_000)
        XCTAssertEqual(try windowList().first { ($0["id"] as? String)?.lowercased() == newID.lowercased() }?["minimized"] as? Bool,
                       true, "the parked window must not be dragged back out of the Dock")
    }

    // `activeWindowID` only falls back when the frontmost window's store is gone, and a minimized window
    // keeps its store; AppKit keys another window only while the app is active, so the handoff can be left
    // to neither.
    func testMinimizingFrontmostHandsOffActive() throws {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session")
        let launchID = try XCTUnwrap(try windowList().first?["id"] as? String, "the seeded window should have an id")

        let created = try sendCommand(#"{"cmd":"window.new","args":{"name":"second"}}"#)
        let newID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "window.new returns an id")
        XCTAssertTrue(pollWindowList(timeout: 10) { list in
            list.first { ($0["id"] as? String)?.lowercased() == newID.lowercased() }?["active"] as? Bool == true
        }, "the new window should be frontmost before we park it")
        // no wait before parking: `bringForwardForUITests` latches on its delay-0 tick, enqueued in the
        // same `viewDidMoveToWindow` that registers the window, so it has run before `window.new` replies.
        addTeardownBlock { _ = try? self.sendCommand(#"{"cmd":"window.minimize","target":"\#(newID)","args":{"mode":"off"}}"#) }
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.minimize","target":"\#(newID)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true)

        let handedOff = pollWindowList(timeout: 10) { list in
            let parked = list.first { ($0["id"] as? String)?.lowercased() == newID.lowercased() }
            let remaining = list.first { ($0["id"] as? String)?.lowercased() == launchID.lowercased() }
            return parked?["minimized"] as? Bool == true && remaining?["active"] as? Bool == true
        }
        let finalList = (try? windowList()) ?? []
        XCTAssertTrue(handedOff,
                      "minimizing the frontmost window should make the still-visible one active: \(finalList)")
    }

    // ⌘M mutates the state with no control command in play, so the read-back stays honest only because
    // `ControlServer` observes NSWindow.didMiniaturize. The click happens while the window is still on
    // screen, so no element query touches a miniaturized one.
    func testMenuMinimizeReadsBackOverControl() throws {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session")
        XCTAssertEqual(try windowList().first?["minimized"] as? Bool, false, "should start un-minimized")

        addTeardownBlock { _ = try? self.sendCommand(#"{"cmd":"window.minimize","args":{"mode":"off"}}"#) }

        app.menuBars.menuBarItems["Window"].click()
        app.menuBars.menuItems["Minimize"].click()
        XCTAssertTrue(pollWindowList(timeout: 10) { $0.first?["minimized"] as? Bool == true },
                      "a ⌘M minimize must reach window.list's minimized flag")

        XCTAssertEqual(try sendCommand(#"{"cmd":"window.minimize","args":{"mode":"off"}}"#)["ok"] as? Bool, true)
        XCTAssertTrue(pollWindowList(timeout: 10) { $0.first?["minimized"] as? Bool == false },
                      "window.minimize off should restore it")
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 10),
                      "the restored window should be interactive again")
    }

    // window.new must not reply until its NSWindow has attached: the store loads synchronously (so the
    // library reports open:true at once) while the NSWindow lands two SwiftUI render passes later.
    func testWindowNewIsUsableImmediately() throws {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session")
        let created = try sendCommand(#"{"cmd":"window.new","args":{"name":"immediate"}}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "window.new should succeed: \(created)")
        let result = try XCTUnwrap(created["result"] as? [String: Any], "window.new should carry a result")
        let newID = try XCTUnwrap(result["id"] as? String, "window.new should return the new id")

        // no polling and no intervening command: window.list is served from the cache, so a node built
        // before the attach would still be missing geometry here.
        let list = try windowList()
        let made = try XCTUnwrap(list.first { ($0["id"] as? String)?.lowercased() == newID.lowercased() },
                                 "the new window should be listed: \(list)")
        XCTAssertNotNil(made["geometry"] as? [String: Any],
                        "window.new should report the new window's geometry without another command: \(made)")

        let resized = try sendCommand(#"{"cmd":"window.resize","target":"\#(newID)","args":{"width":900,"height":650}}"#)
        XCTAssertEqual(resized["ok"] as? Bool, true, "resize right after window.new should succeed: \(resized)")
    }

    // 14pt below the top edge, horizontally centred: clears the top resize strip, lands in the titlebar
    // band (compact 30 / normal 48) and in the empty header Spacer — clear of the traffic lights and the
    // toolbar buttons, so the click falls through to the `WindowControlArea` layer. Re-resolved at each
    // interaction so it stays in the header after a zoom grows the window.
    private func emptyHeaderPoint(_ window: XCUIElement) -> XCUICoordinate {
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 14))
    }

    // drives the real cursor, unlike testWindowZoom's control command.
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

    // the "None" pin (Desktop & Dock ▸ "Do Nothing") is applied by ControlAPITestCase.setUp, keyed on
    // this test's name.
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
        // let any (erroneous) zoom land before asserting the frame never changed.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(window.frame.size.width, normal.width, accuracy: 8,
                       "with 'None' set, a header double-click must not zoom (width): normal=\(normal) now=\(window.frame.size)")
        XCTAssertEqual(window.frame.size.height, normal.height, accuracy: 8,
                       "with 'None' set, a header double-click must not zoom (height): normal=\(normal) now=\(window.frame.size)")
    }

    // the `WindowControlArea` drag/zoom layer sits BEHIND the header; the toolbar buttons render in front
    // and must keep their own clicks.
    func testHeaderButtonsStillReceiveClicksOverControlArea() throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "window should exist")
        let cover = app.descendants(matching: .any).matching(identifier: "quick-terminal").firstMatch

        emptyHeaderPoint(window).doubleClick()
        XCTAssertFalse(cover.waitForExistence(timeout: 2), "double-clicking the header must not open the quick terminal")

        let button = app.buttons["quick-terminal-toggle"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "quick-terminal toolbar button should exist")
        button.click()
        XCTAssertTrue(cover.waitForExistence(timeout: 5), "clicking quick-terminal-toggle should open the quick terminal cover")
    }

    // the resize + move pin a known on-screen frame, so the drag stays on screen and the delta is unambiguous.
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

    func testClosedWindowTargetingErrors() throws {
        let created = try sendCommand(#"{"cmd":"window.new"}"#)
        let result = try XCTUnwrap(created["result"] as? [String: Any], "window.new should carry a result")
        let windowB = try XCTUnwrap(result["id"] as? String, "window.new should return the new id")
        XCTAssertTrue(pollWindowList(timeout: 10) { $0.count == 2 }, "the second window should appear")

        let openTree = try sendCommand(#"{"cmd":"tree","args":{"window":"\#(windowB)"}}"#)
        XCTAssertEqual(openTree["ok"] as? Bool, true, "tree --window B should succeed while open: \(openTree)")

        // window.close drives performClose → willCloseNotification → surface teardown → library.closeWindow;
        // under full-suite CPU contention that can be delayed, so the open flag gets a long settle.
        let closed = try sendCommand(#"{"cmd":"window.close","target":"\#(windowB)"}"#)
        XCTAssertEqual(closed["ok"] as? Bool, true, "window.close should succeed: \(closed)")
        let settled = pollWindowList(timeout: 30) { list in
            list.first(where: { ($0["id"] as? String)?.lowercased() == windowB.lowercased() })?["open"] as? Bool == false
        }
        XCTAssertTrue(settled, "window B should be marked closed after window.close")

        let response = try sendCommand(#"{"cmd":"tree","args":{"window":"\#(windowB)"}}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "targeting a closed window should fail: \(response)")
        XCTAssertEqual(response["error"] as? String, "window not open — window.select it first",
                       "should return the closed-window error: \(response)")
    }

    func testWindowTargetingRoutesToTheRightTree() throws {
        let initial = try windowList()
        let windowA = try XCTUnwrap(initial.first?["id"] as? String, "the seeded window id")

        let created = try sendCommand(#"{"cmd":"window.new"}"#)
        let result = try XCTUnwrap(created["result"] as? [String: Any], "window.new should carry a result")
        let windowB = try XCTUnwrap(result["id"] as? String, "window.new should return the new id")
        XCTAssertTrue(pollWindowList(timeout: 10) { $0.count == 2 }, "the second window should appear")

        let added = try sendCommand(#"{"cmd":"session.new","args":{"window":"\#(windowB)"}}"#)
        XCTAssertEqual(added["ok"] as? Bool, true, "session.new --window B should succeed: \(added)")

        XCTAssertTrue(pollTreeSessionCount(window: windowB, expected: 2, timeout: 10),
                      "the new session should land in window B's tree")
        XCTAssertTrue(pollTreeSessionCount(window: windowA, expected: 1, timeout: 5),
                      "window A's tree should be unchanged")
    }

    func testCapturedIDResolvesWhileAnotherWindowFrontmost() throws {
        let initial = try windowList()
        let windowA = try XCTUnwrap(initial.first?["id"] as? String, "the seeded window id")

        let created = try sendCommand(#"{"cmd":"window.new"}"#)
        let result = try XCTUnwrap(created["result"] as? [String: Any], "window.new should carry a result")
        let windowB = try XCTUnwrap(result["id"] as? String, "window.new should return the new id")
        XCTAssertTrue(pollWindowList(timeout: 10) { $0.count == 2 }, "the second window should appear")

        let added = try sendCommand(#"{"cmd":"session.new","args":{"window":"\#(windowB)"}}"#)
        let addedResult = try XCTUnwrap(added["result"] as? [String: Any], "session.new should carry a result")
        let sessionID = try XCTUnwrap(addedResult["id"] as? String, "session.new should return the new session id")

        // window B is frontmost right after window.new, so A has to be raised.
        XCTAssertTrue(selectWindowUntilActive(windowA, timeout: 15),
                      "window A should become active")

        let selected = try sendCommand(#"{"cmd":"session.select","target":"\#(sessionID)"}"#)
        XCTAssertEqual(selected["ok"] as? Bool, true, "selecting the captured id with no --window should succeed: \(selected)")
        XCTAssertEqual((selected["result"] as? [String: Any])?["id"] as? String, sessionID,
                       "select should resolve to the captured B-session id: \(selected)")

        XCTAssertTrue(pollTreeActiveSession(window: windowB, sessionID: sessionID, timeout: 10),
                      "the captured session should be active in window B's tree")
    }

    func testCapturedWorkspaceIDResolvesCrossWindow() throws {
        let created = try sendCommand(#"{"cmd":"window.new"}"#)
        let windowB = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "window.new should return the new id")
        XCTAssertTrue(pollWindowList(timeout: 10) { $0.count == 2 }, "the second window should appear")

        let madeWs = try sendCommand(#"{"cmd":"workspace.new","args":{"window":"\#(windowB)","name":"betaws"}}"#)
        let workspaceID = try XCTUnwrap((madeWs["result"] as? [String: Any])?["id"] as? String,
                                        "workspace.new should return the new workspace id")

        let selected = try sendCommand(#"{"cmd":"workspace.select","target":"\#(workspaceID)"}"#)
        XCTAssertEqual(selected["ok"] as? Bool, true, "selecting the captured workspace id cross-window should succeed: \(selected)")
        XCTAssertEqual((selected["result"] as? [String: Any])?["id"] as? String, workspaceID,
                       "select should resolve to the captured B-workspace id: \(selected)")
    }

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

    func testRemainingWindowBecomesActiveAfterClosingFrontmost() throws {
        let created = try sendCommand(#"{"cmd":"window.new"}"#)
        let windowB = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "window.new should return the new id")
        XCTAssertTrue(pollWindowList(timeout: 10) { $0.count == 2 }, "the second window should appear")

        XCTAssertEqual(try sendCommand(#"{"cmd":"window.close","target":"\#(windowB)"}"#)["ok"] as? Bool, true)

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
    /// The flag flips only on the async `didBecomeKey`/`didBecomeMain`, which macOS can drop under
    /// XCUITest; re-selecting recovers a dropped activation, and `app.activate()` comes first because a
    /// window cannot become key while the app is inactive.
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
