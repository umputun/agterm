import XCTest

@MainActor
final class ControlSurfaceZoomUITests: ControlAPITestCase {
    func testSurfaceZoomRendersAndMouseExitPreservesSplitRatio() throws {
        let originalSessionID = try activeSessionID()
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "creating a second session should succeed: \(created)")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(originalSessionID)"}"#)["ok"] as? Bool, true,
                       "selecting the original session should succeed")

        let split = try sendCommand(#"{"cmd":"session.split","args":{"mode":"on"}}"#)
        XCTAssertEqual(split["ok"] as? Bool, true, "split on should succeed: \(split)")

        let resize = try sendCommand(#"{"cmd":"session.resize","args":{"ratio":0.33}}"#)
        XCTAssertEqual(resize["ok"] as? Bool, true, "split resize should succeed: \(resize)")
        XCTAssertTrue(pollSplitRatio(0.33, timeout: 10), "the split ratio should persist before zoom")

        let leftSurface = try activeSurfaceID(kind: "left")
        let zoom = try sendCommand(#"{"cmd":"surface.zoom","target":"\#(leftSurface)","args":{"mode":"show"}}"#)
        XCTAssertEqual(zoom["ok"] as? Bool, true, "surface zoom show should succeed: \(zoom)")

        let zoomExit = app.buttons["terminal-zoom-exit"]
        XCTAssertTrue(zoomExit.waitForExistence(timeout: 10),
                      "zoom should expose a mouse-friendly exit button")
        XCTAssertTrue(app.windows.firstMatch.buttons[XCUIIdentifierCloseWindow].exists,
                      "standard traffic-light close control should remain visible while zoomed")

        app.typeKey("j", modifierFlags: .command)
        XCTAssertEqual(try activeSessionFlag("scratch"), false,
                       "mutating shortcuts should not change hidden session state while zoomed")
        app.typeKey("\t", modifierFlags: .control)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(try currentActiveSessionID(), originalSessionID,
                       "Ctrl-Tab should not switch hidden sessions while zoomed")

        zoomExit.click()
        XCTAssertTrue(zoomExit.waitForNonExistence(timeout: 10), "clicking the zoom-out button should exit zoom")
        XCTAssertTrue(pollSplitRatio(0.33, timeout: 10), "zoom round-trip must not change the split ratio")
    }

    func testScratchOpenedWhileZoomedRealizesSurface() throws {
        let leftSurface = try activeSurfaceID(kind: "left")
        let zoom = try sendCommand(#"{"cmd":"surface.zoom","target":"\#(leftSurface)","args":{"mode":"show"}}"#)
        XCTAssertEqual(zoom["ok"] as? Bool, true, "surface zoom show should succeed: \(zoom)")
        XCTAssertTrue(app.buttons["terminal-zoom-exit"].waitForExistence(timeout: 10),
                      "zoom should be active before opening the scratch")

        let scratch = try sendCommand(#"{"cmd":"session.scratch","args":{"mode":"on"}}"#)
        XCTAssertEqual(scratch["ok"] as? Bool, true, "scratch on should succeed while zoomed: \(scratch)")
        // the deck keeps realizing surfaces behind the zoom layer: the scratch must become readable
        // (surface realized, shell spawned) without exiting zoom first.
        XCTAssertTrue(pollScratchReadable(timeout: 10),
                      "a control-opened scratch must realize its surface while the session is zoomed")

        XCTAssertEqual(try sendCommand(#"{"cmd":"surface.zoom","args":{"mode":"hide"}}"#)["ok"] as? Bool, true,
                       "zoom hide should succeed")
        // hide is idempotent for explicit targets too: hiding an already-un-zoomed surface is an ok no-op.
        let rehide = try sendCommand(#"{"cmd":"surface.zoom","target":"\#(leftSurface)","args":{"mode":"hide"}}"#)
        XCTAssertEqual(rehide["ok"] as? Bool, true, "explicit-target hide should be idempotent: \(rehide)")
    }

    func testQuickZoomEmitsAndAcceptsQuickTargetId() throws {
        XCTAssertEqual(try sendCommand(#"{"cmd":"quick","args":{"mode":"show"}}"#)["ok"] as? Bool, true,
                       "quick show should succeed")

        let zoom = try sendCommand(#"{"cmd":"surface.zoom","args":{"mode":"show"}}"#)
        XCTAssertEqual(zoom["ok"] as? Bool, true, "surface zoom show should succeed: \(zoom)")
        XCTAssertEqual((zoom["result"] as? [String: Any])?["id"] as? String, "quick",
                       "zooming with the quick terminal visible should target it: \(zoom)")

        // the API must accept the address it just emitted: hide the zoom by its returned id.
        let hide = try sendCommand(#"{"cmd":"surface.zoom","target":"quick","args":{"mode":"hide"}}"#)
        XCTAssertEqual(hide["ok"] as? Bool, true,
                       "the id surface.zoom emitted must be accepted back as a target: \(hide)")

        // zoom the quick terminal again and dismiss it with plain `quick hide`: dismissal must stay
        // unconditional for scripts — a zoomed quick terminal exits its zoom first, never an error.
        XCTAssertEqual(try sendCommand(#"{"cmd":"surface.zoom","args":{"mode":"show"}}"#)["ok"] as? Bool, true,
                       "re-zooming the quick terminal should succeed")
        let quickHide = try sendCommand(#"{"cmd":"quick","args":{"mode":"hide"}}"#)
        XCTAssertEqual(quickHide["ok"] as? Bool, true,
                       "quick hide must succeed while the quick terminal is zoomed: \(quickHide)")
        XCTAssertTrue(app.buttons["terminal-zoom-exit"].waitForNonExistence(timeout: 10),
                      "hiding the zoomed quick terminal should exit zoom")
    }

    func testZoomedSurfaceTreeReadBackAndScopedErrorPaths() throws {
        // unzoomed: the tree must OMIT zoomedSurface (nil closure result → key absent, not null).
        XCTAssertNil(try treeZoomedSurface(), "zoomedSurface should be absent while nothing is zoomed")

        // zoom the active session's left surface and read the SAME id back from the tree top level —
        // the record-then-restore leg of the write-only surface.zoom command.
        let leftSurface = try activeSurfaceID(kind: "left")
        let zoom = try sendCommand(#"{"cmd":"surface.zoom","target":"\#(leftSurface)","args":{"mode":"show"}}"#)
        XCTAssertEqual(zoom["ok"] as? Bool, true, "surface zoom show should succeed: \(zoom)")
        XCTAssertEqual(try treeZoomedSurface(), leftSurface,
                       "the tree's zoomedSurface must echo the zoomed surface's control id")

        XCTAssertEqual(try sendCommand(#"{"cmd":"surface.zoom","args":{"mode":"hide"}}"#)["ok"] as? Bool, true,
                       "zoom hide should succeed")
        XCTAssertNil(try treeZoomedSurface(), "zoomedSurface should clear on zoom exit")

        // error paths. a well-formed id whose session exists nowhere → no such surface.
        let ghost = "surface:00000000-0000-0000-0000-000000000000:left"
        let noSuch = try sendCommand(#"{"cmd":"surface.zoom","target":"\#(ghost)","args":{"mode":"show"}}"#)
        XCTAssertEqual(noSuch["ok"] as? Bool, false, "zooming an unknown surface should fail: \(noSuch)")
        XCTAssertEqual(noSuch["error"] as? String, "no such surface: \(ghost)")

        // a malformed target → invalid surface.
        let invalid = try sendCommand(#"{"cmd":"surface.zoom","target":"not-a-surface","args":{"mode":"show"}}"#)
        XCTAssertEqual(invalid["ok"] as? Bool, false, "a malformed target should fail: \(invalid)")
        XCTAssertEqual(invalid["error"] as? String, "invalid surface: not-a-surface")

        // a real surface addressed through a --window that does not own it → no such surface (scoped).
        let created = try sendCommand(#"{"cmd":"window.new","args":{"name":"zoom-err"}}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "window.new should succeed: \(created)")
        let otherWindow = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String,
                                        "window.new should return the new window id")
        let wrongWindow = try sendCommand(
            #"{"cmd":"surface.zoom","target":"\#(leftSurface)","args":{"mode":"show","window":"\#(otherWindow)"}}"#)
        XCTAssertEqual(wrongWindow["ok"] as? Bool, false,
                       "zooming a surface through a window that does not own it should fail: \(wrongWindow)")
        XCTAssertEqual(wrongWindow["error"] as? String, "no such surface: \(leftSurface)")

        // a known-but-CLOSED window → window not open (the resolver knows the id; there is no live store).
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.close","target":"\#(otherWindow)"}"#)["ok"] as? Bool, true,
                       "closing the helper window should succeed")
        let closed = try sendCommand(
            #"{"cmd":"surface.zoom","args":{"mode":"show","window":"\#(otherWindow)"}}"#)
        XCTAssertEqual(closed["ok"] as? Bool, false, "zooming in a closed window should fail: \(closed)")
        XCTAssertEqual(closed["error"] as? String, "window not open — window.select it first")
    }

    func testZoomingBackgroundTargetEndsItsSearch() throws {
        // open search on session A (session.search selects its target, so A is active with the bar up).
        let sessionA = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.search","target":"\#(sessionA)","args":{"text":"login"}}"#)["ok"] as? Bool,
                       true, "opening search on session A should succeed")
        XCTAssertTrue(app.textFields["search-field"].waitForExistence(timeout: 10),
                      "the search bar should be up on session A")

        // park the selection on a fresh session B, making A a BACKGROUND session with searchActive set.
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "creating session B should succeed: \(created)")

        // zoom A's surface by explicit id — the addressable path that does NOT select A first — then exit.
        let zoom = try sendCommand(#"{"cmd":"surface.zoom","target":"surface:\#(sessionA):left","args":{"mode":"show"}}"#)
        XCTAssertEqual(zoom["ok"] as? Bool, true, "zooming background session A's surface should succeed: \(zoom)")
        XCTAssertTrue(app.buttons["terminal-zoom-exit"].waitForExistence(timeout: 10), "zoom should be active")
        XCTAssertEqual(try sendCommand(#"{"cmd":"surface.zoom","args":{"mode":"hide"}}"#)["ok"] as? Bool, true,
                       "zoom hide should succeed")

        // zoom-enter must have ENDED A's search: re-selecting A shows no search bar (a surviving
        // searchActive would re-mount it the moment A becomes the active session).
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(sessionA)"}"#)["ok"] as? Bool, true,
                       "re-selecting session A should succeed")
        XCTAssertTrue(app.textFields["search-field"].waitForNonExistence(timeout: 10),
                      "zooming a background session's surface must end that session's search")
    }

    func testBackgroundWindowZoomExitDoesNotStealFrontmostFocus() throws {
        // zoom window A's left surface, then open window B on top: A becomes a BACKGROUND zoomed window.
        let windows = try XCTUnwrap(
            (try sendCommand(#"{"cmd":"window.list"}"#)["result"] as? [String: Any])?["windows"] as? [[String: Any]],
            "window.list should carry windows")
        let windowA = try XCTUnwrap(windows.first?["id"] as? String, "should have the seeded window id")
        let surfaceA = try activeSurfaceID(kind: "left")
        let zoom = try sendCommand(#"{"cmd":"surface.zoom","target":"\#(surfaceA)","args":{"mode":"show"}}"#)
        XCTAssertEqual(zoom["ok"] as? Bool, true, "surface zoom show should succeed: \(zoom)")

        let created = try sendCommand(#"{"cmd":"window.new","args":{"name":"zoom-focus"}}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "window.new should succeed: \(created)")
        let windowB = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String,
                                    "window.new should return the new window id")
        // wait for the second window to MATERIALIZE in the AX tree before driving it — a control-created
        // window can lag its window.list "active" flag (the multi-window suites' count-poll pattern).
        let appeared = Date().addingTimeInterval(10)
        while Date() < appeared, app.windows.count < 2 { usleep(200_000) }
        XCTAssertGreaterThanOrEqual(app.windows.count, 2, "the second window should materialize and take key")
        XCTAssertTrue(pollWindowActive(windowB, timeout: 12), "the new window should take key")

        // put the keyboard into window B's search field and prove it owns the keystrokes.
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.search"}"#)["ok"] as? Bool, true,
                       "opening search in the frontmost window should succeed")
        let searchField = app.textFields["search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 10), "the search bar should be up in window B")
        searchField.click()
        app.typeText("ab")
        XCTAssertTrue(pollFieldValue(searchField, equals: "ab", timeout: 8),
                      "the search field should own the keyboard before the background unzoom")

        // un-zoom BACKGROUND window A over the socket. Its zoom-exit focus return is scoped to window A,
        // so window B's field keeps the keyboard — a frontmost-targeted restore would steal it (the
        // regression this pins). Give a stray restore its full retry window before typing on.
        XCTAssertEqual(try sendCommand(#"{"cmd":"surface.zoom","args":{"mode":"hide","window":"\#(windowA)"}}"#)["ok"] as? Bool,
                       true, "hiding the background window's zoom should succeed")
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        app.typeText("cd")
        XCTAssertTrue(pollFieldValue(searchField, equals: "abcd", timeout: 8),
                      "a background window's zoom exit must not steal the frontmost window's keyboard focus")
    }

    /// Polls `window.list` until the window with `id` reports active (frontmost/key) — a window.new/select
    /// response can arrive before the window is actually key under XCUITest (the pollWindowActive shape).
    private func pollWindowActive(_ id: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let result = (try? sendCommand(#"{"cmd":"window.list"}"#))?["result"] as? [String: Any],
               let windows = result["windows"] as? [[String: Any]],
               windows.contains(where: { ($0["id"] as? String)?.lowercased() == id.lowercased() && $0["active"] as? Bool == true }) {
                return true
            }
            usleep(200_000)
        }
        return false
    }

    /// Polls the field's AX value until it equals `expected` — typed keystrokes land asynchronously.
    private func pollFieldValue(_ field: XCUIElement, equals expected: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if field.value as? String == expected { return true }
            usleep(200_000)
        }
        return field.value as? String == expected
    }

    /// Polls `session.text --pane scratch` until it succeeds — the control-observable proof that the
    /// scratch surface realized and its shell spawned (an unrealized scratch errors instead).
    private func pollScratchReadable(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let response = try? sendCommand(#"{"cmd":"session.text","args":{"pane":"scratch"}}"#),
               response["ok"] as? Bool == true {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    /// The tree's top-level `zoomedSurface`, or nil when omitted (nothing zoomed).
    private func treeZoomedSurface() throws -> String? {
        let treeResponse = try sendCommand(#"{"cmd":"tree"}"#)
        let result = try XCTUnwrap(treeResponse["result"] as? [String: Any], "tree should carry a result")
        let tree = try XCTUnwrap(result["tree"] as? [String: Any], "result should carry a tree")
        return tree["zoomedSurface"] as? String
    }

    private func activeSurfaceID(kind: String) throws -> String {
        let session = try activeSession()
        let surfaces = try XCTUnwrap(session["surfaces"] as? [[String: Any]],
                                     "active session should carry surfaces")
        if let surface = surfaces.first(where: { $0["kind"] as? String == kind }),
           let id = surface["id"] as? String {
            return id
        }
        XCTFail("active session should expose a \(kind) surface")
        return ""
    }

    private func activeSessionFlag(_ key: String) throws -> Bool {
        let session = try activeSession()
        return session[key] as? Bool ?? false
    }

    private func currentActiveSessionID() throws -> String {
        let session = try activeSession()
        return try XCTUnwrap(session["id"] as? String, "active session should expose an id")
    }

    private func activeSession() throws -> [String: Any] {
        let treeResponse = try sendCommand(#"{"cmd":"tree"}"#)
        let result = try XCTUnwrap(treeResponse["result"] as? [String: Any], "tree should carry a result")
        let tree = try XCTUnwrap(result["tree"] as? [String: Any], "result should carry a tree")
        let workspaces = try XCTUnwrap(tree["workspaces"] as? [[String: Any]], "tree should carry workspaces")
        for workspace in workspaces {
            let sessions = workspace["sessions"] as? [[String: Any]] ?? []
            for session in sessions where session["active"] as? Bool == true {
                return session
            }
        }
        XCTFail("tree should expose an active session")
        return [:]
    }

}
