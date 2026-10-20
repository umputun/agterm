import XCTest

/// Hide and show through the control channel, judged by REAL keyboard and mouse input: `session.type` writes
/// under a visible overlay too, so only keys the user types show which surface owns the keyboard.
@MainActor
final class ControlOverlayVisibilityUITests: ControlAPITestCase {
    func testAHiddenProgramOverlayGivesTheKeysToThePaneAndShowTakesThemBack() throws {
        let id = try activeSessionID()
        let sessionTTY = markerDir.appendingPathComponent("session-tty")
        let ttyValue = try XCTUnwrap(try typeUntilMarker("tty > '\(sessionTTY.path)'\n", target: id, file: sessionTTY,
                                                         select: false))
        let keys = markerDir.appendingPathComponent("overlay-keys")
        let pids = markerDir.appendingPathComponent("overlay-pids")
        try openProgram(id, command: "sh -c 'echo $$ >> \(pids.path); while IFS= read -r x; do printf \"%s\\n\" \"$x\" >> \(keys.path); done'")
        XCTAssertTrue(typeIntoCover("OVL1", marker: keys), "the overlay should own the keyboard before hiding")

        XCTAssertEqual(try visibility("hide", id)["text"] as? String, "hidden")
        XCTAssertTrue(poll(until: self.node(id)?["hiddenOverlays"] as? [String] == ["session"], timeout: 10))
        let afterHide = markerDir.appendingPathComponent("after-hide-tty")
        XCTAssertEqual(keyboardTypeUntilMarker("tty > '\(afterHide.path)'", file: afterHide), ttyValue,
                       "a hidden overlay hands the keyboard to the session's own terminal")

        XCTAssertEqual(try visibility("show", id)["text"] as? String, "shown")
        XCTAssertTrue(typeIntoCover("OVL2", marker: keys), "showing hands the keyboard back to the same program")
        XCTAssertEqual(try String(contentsOf: pids, encoding: .utf8).split(separator: "\n").count, 1,
                       "one program started and received both lines: hiding never restarted it")
    }

    func testAHiddenPaneOverlayLeavesItsPaneClickableAndTypable() throws {
        let id = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(id)","args":{"mode":"on"}}"#)["ok"] as? Bool, true)
        let rightTTY = markerDir.appendingPathComponent("right-tty")
        let rightValue = try XCTUnwrap(try typeUntilMarker("tty > '\(rightTTY.path)'\n", target: id, file: rightTTY,
                                                           select: false, pane: "right"))
        let keys = markerDir.appendingPathComponent("pane-overlay-keys")
        try openProgram(id, command: "sh -c 'while IFS= read -r x; do printf \"%s\\n\" \"$x\" >> \(keys.path); done'",
                        pane: "right")
        XCTAssertTrue(typeIntoCover("PANE1", marker: keys), "the pane overlay should own the keyboard before hiding")

        XCTAssertEqual(try visibility("hide", id, pane: "right")["text"] as? String, "hidden")
        XCTAssertTrue(poll(until: self.node(id)?["hiddenOverlays"] as? [String] == ["right"], timeout: 10))
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.6)).click()
        let afterClick = markerDir.appendingPathComponent("after-click-tty")
        XCTAssertEqual(keyboardTypeUntilMarker("tty > '\(afterClick.path)'", file: afterClick), rightValue,
                       "a click on the uncovered pane focuses its own shell")

        XCTAssertEqual(try visibility("toggle", id)["text"] as? String, "shown")
        XCTAssertTrue(typeIntoCover("PANE2", marker: keys), "showing the pane overlay hands it the keyboard again")
    }

    func testAHiddenPageReturnsTheKeysToThePaneAndKeepsItsIdentity() throws {
        let id = try activeSessionID()
        let sessionTTY = markerDir.appendingPathComponent("page-session-tty")
        let ttyValue = try XCTUnwrap(try typeUntilMarker("tty > '\(sessionTTY.path)'\n", target: id, file: sessionTTY,
                                                         select: false))
        let page = markerDir.appendingPathComponent("keys.html")
        // a token per load: a reload mints a new one, so an unchanged token proves the same document came back
        let script = "<script>const token = Math.random().toString(36).slice(2); let n = 0; document.title = token + ' 0'; "
            + "document.addEventListener('keydown', () => { n += 1; document.title = token + ' ' + n })</script>"
        try "<!doctype html><html><head><title>loading</title></head><body><p>key page</p>\(script)</body></html>"
            .write(to: page, atomically: true, encoding: .utf8)
        let open = try sendCommand(#"{"cmd":"session.overlay.open","target":"\#(id)","args":{"html":"\#(page.path)","javascript":true}}"#)
        XCTAssertEqual(open["ok"] as? Bool, true, "page open should succeed: \(open)")
        let pageID = try XCTUnwrap((open["result"] as? [String: Any])?["pageID"] as? String)
        let text = app.webViews.staticTexts["key page"]
        XCTAssertTrue(text.waitForExistence(timeout: 10), "the page should render")
        XCTAssertTrue(poll(until: self.pageState(id)?.count == 0, timeout: 10), "the page should report its load token")
        let token = try XCTUnwrap(pageState(id)?.token)
        text.click()
        XCTAssertTrue(pressUntilCountChanges(id, from: 0), "the page should own the keyboard before hiding")

        XCTAssertEqual(try visibility("hide", id)["text"] as? String, "hidden")
        XCTAssertTrue(poll(until: !text.isHittable, timeout: 10), "a hidden page is not on screen")
        let afterHide = markerDir.appendingPathComponent("page-after-hide-tty")
        XCTAssertEqual(keyboardTypeUntilMarker("tty > '\(afterHide.path)'", file: afterHide), ttyValue)

        let before = try XCTUnwrap(pageState(id)?.count)
        XCTAssertEqual(try visibility("show", id)["text"] as? String, "shown")
        XCTAssertTrue(poll(until: text.isHittable, timeout: 10), "a shown page is back on screen")
        XCTAssertEqual((node(id)?["htmlOverlays"] as? [[String: Any]])?.first?["id"] as? String, pageID)
        XCTAssertTrue(pressUntilCountChanges(id, from: before), "the shown page owns the keyboard again")
        XCTAssertEqual(pageState(id)?.token, token, "the same document came back: a reload mints a new token")
    }

    private func pageState(_ id: String) -> (token: String, count: Int)? {
        let parts = pageTitle(id)?.split(separator: " ") ?? []
        guard parts.count == 2, let count = Int(parts[1]) else { return nil }
        return (String(parts[0]), count)
    }

    private func pressUntilCountChanges(_ id: String, from count: Int) -> Bool {
        for _ in 0..<5 {
            app.typeKey("k", modifierFlags: [])
            if poll(until: (self.pageState(id)?.count ?? count) != count, timeout: 2) { return true }
        }
        return false
    }

    private func openProgram(_ id: String, command: String, pane: String? = nil) throws {
        var args: [String: Any] = ["command": command]
        if let pane { args["pane"] = pane }
        let json = try JSONSerialization.data(withJSONObject: ["cmd": "session.overlay.open", "target": id, "args": args])
        let open = try sendCommand(String(decoding: json, as: UTF8.self))
        XCTAssertEqual(open["ok"] as? Bool, true, "overlay open should succeed: \(open)")
        usleep(800_000)
    }

    private func typeIntoCover(_ line: String, marker: URL) -> Bool {
        for _ in 0..<6 {
            app.typeText(line)
            app.typeKey(.return, modifierFlags: [])
            if poll(until: (try? String(contentsOf: marker, encoding: .utf8))?.contains(line) == true, timeout: 2.5) {
                return true
            }
        }
        return false
    }

    private func visibility(_ verb: String, _ id: String, pane: String? = nil) throws -> [String: Any] {
        let paneArg = pane.map { #","args":{"pane":"\#($0)"}"# } ?? ""
        let response = try sendCommand(#"{"cmd":"session.overlay.\#(verb)","target":"\#(id)"\#(paneArg)}"#)
        XCTAssertEqual(response["ok"] as? Bool, true, "\(verb) should succeed: \(response)")
        return response["result"] as? [String: Any] ?? [:]
    }

    private func node(_ id: String) -> [String: Any]? {
        guard let tree = try? sendCommand(#"{"cmd":"tree"}"#),
              let result = tree["result"] as? [String: Any], let root = result["tree"] as? [String: Any],
              let workspaces = root["workspaces"] as? [[String: Any]] else { return nil }
        return workspaces.flatMap { $0["sessions"] as? [[String: Any]] ?? [] }
            .first { ($0["id"] as? String)?.lowercased() == id.lowercased() }
    }

    private func pageTitle(_ id: String) -> String? {
        (node(id)?["htmlOverlays"] as? [[String: Any]])?.first?["title"] as? String
    }
}
