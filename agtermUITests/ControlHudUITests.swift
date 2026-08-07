import XCTest

/// End-to-end coverage for `session.hud.*` over the real control socket: the store takes the session's
/// overlay slot, the app spawns the bundled painter into it, and `tree` reports the panel through its own
/// `hud` node. The read-back contract these pin is the one a polling script depends on — a HUD is never a
/// program overlay, `position` always carries its effective value, and `overlay result` refuses the slot.
@MainActor
final class ControlHudUITests: ControlAPITestCase {
    /// `XCUIApplication.terminate()` kills the app without running surface teardown, so a HUD left up would
    /// leave the painter spinning on a body file nothing deletes. Closing it first keeps the runner's
    /// machine clean; the assertions have all run by then.
    override func tearDown() async throws {
        _ = try? sendCommand(request(command: "session.hud.close"))
        try await super.tearDown()
    }

    func testHudOpenReportsItsMessageAndNeverAProgramOverlay() throws {
        let session = try activeSessionID()
        try assertOK(openHud(message: "gathering options…", detail: "scanning the repository", spinner: "braille"))

        let hud = try XCTUnwrap(pollHud(session, message: "gathering options…"), "tree should expose the hud")
        XCTAssertEqual(hud["detail"] as? String, "scanning the repository")
        XCTAssertEqual(hud["spinner"] as? String, "braille")
        XCTAssertNotNil(hud["sizePercent"] as? Int, "the panel's measured share of the pane should be reported")
        let height = try XCTUnwrap(hud["heightPercent"] as? Int, "both axes should be reported")
        let width = try XCTUnwrap(hud["sizePercent"] as? Int)
        XCTAssertLessThan(height, width, "two lines of text must not produce a panel as tall as it is wide")

        let node = try sessionNode(id: session)
        XCTAssertEqual(node["overlay"] as? Bool, false, "a hud must never read back as a program overlay")
        XCTAssertNil(node["overlaySizePercent"], "the hud's size belongs in hud, not on the slot")
    }

    func testPositionReadsBackAsCenterWhenOmittedAndAsRequestedWhenSet() throws {
        let session = try activeSessionID()
        try assertOK(openHud(message: "no position given"))
        let defaulted = try XCTUnwrap(pollHud(session, message: "no position given"))
        XCTAssertEqual(defaulted["position"] as? String, "center",
                       "an omitted position must report its effective value, not be omitted")

        try assertOK(openHud(message: "pinned to a corner", position: "top-right"))
        let requested = try XCTUnwrap(pollHud(session, message: "pinned to a corner"),
                                      "a second hud should replace the first")
        XCTAssertEqual(requested["position"] as? String, "top-right")

        // the bare spelling is still accepted end to end, and normalizes to the anchor it names
        try assertOK(openHud(message: "pinned by the alias", position: "top"))
        let aliased = try XCTUnwrap(pollHud(session, message: "pinned by the alias"))
        XCTAssertEqual(aliased["position"] as? String, "top-center",
                       "an alias must read back as its canonical anchor, not as the spelling that was sent")
    }

    func testTextColorReadsBackAndAnUpdateRecolorsInPlace() throws {
        let session = try activeSessionID()
        try assertOK(openHud(message: "coloring", textColor: "#e0e0e0"))
        let opened = try XCTUnwrap(pollHud(session, message: "coloring"))
        XCTAssertEqual(opened["textColor"] as? String, "#e0e0e0")

        try assertOK(sendCommand(request(command: "session.hud.update", target: session,
                                         args: ["message": "recolored", "textColor": "#7ec07e"])))

        let updated = try XCTUnwrap(pollHud(session, message: "recolored"))
        XCTAssertEqual(updated["textColor"] as? String, "#7ec07e",
                       "unlike the background, the text color tracks the latest update")
    }

    func testTextColorIsOmittedWhenTheCallerSetNone() throws {
        let session = try activeSessionID()
        try assertOK(openHud(message: "plain"))
        let node = try XCTUnwrap(pollHud(session, message: "plain"))
        XCTAssertNil(node["textColor"], "a panel on the terminal foreground reports no color")
    }

    func testHudUpdateRewritesTheReadBackInPlace() throws {
        let session = try activeSessionID()
        try assertOK(openHud(message: "computing", detail: "step one", position: "bottom"))
        XCTAssertNotNil(pollHud(session, message: "computing"), "the hud should open before the update")

        try assertOK(sendCommand(request(command: "session.hud.update", target: session,
                                         args: ["message": "almost done", "spinner": "dot"])))

        let updated = try XCTUnwrap(pollHud(session, message: "almost done"), "the update should change the message")
        XCTAssertNil(updated["detail"], "an update replaces the whole spec, so an omitted detail is dropped")
        XCTAssertEqual(updated["spinner"] as? String, "dot", "an update may switch style in place")
        XCTAssertEqual(updated["position"] as? String, "center",
                       "an update without a position falls back to the default, it does not carry the old one")
        XCTAssertEqual(try sessionNode(id: session)["overlay"] as? Bool, false,
                       "an updated hud is still not a program overlay")
    }

    func testHudCloseClearsBothTheHudAndTheOverlaySlot() throws {
        let session = try activeSessionID()
        try assertOK(openHud(message: "closing soon"))
        XCTAssertNotNil(pollHud(session, message: "closing soon"), "the hud should open before the close")

        try assertOK(sendCommand(request(command: "session.hud.close", target: session)))

        XCTAssertTrue(poll(until: hudNode(session) == nil, timeout: 10), "tree should omit hud once it is closed")
        let node = try sessionNode(id: session)
        XCTAssertEqual(node["overlay"] as? Bool, false, "the slot should be free again")
        XCTAssertNil(node["overlaySizePercent"])

        let second = try sendCommand(request(command: "session.hud.close", target: session))
        XCTAssertEqual(second["ok"] as? Bool, false, "closing an absent hud should report it: \(second)")
        XCTAssertEqual(second["error"] as? String, "no hud")
    }

    /// THE defining property, and the only place it can be observed: with a HUD up — and after a click on
    /// the panel — the real keyboard must still reach the session's own shell. Nothing below can see this;
    /// the deck predicates are pure functions with no view of first responder, so all of `HudDeckGatesTests`
    /// stays green while the painter holds the keyboard.
    ///
    /// `tty` is the oracle rather than an echoed marker: it names WHICH pty read the line, so a steal
    /// cannot pass by the session happening to echo something.
    func testTheSessionKeepsKeyboardFocusWhileAHudIsUpAndWhenTheHudIsClicked() throws {
        let session = try activeSessionID()

        // injected into the surface, so this capture is independent of focus and gives the expected answer
        let sessionTTY = markerDir.appendingPathComponent("hud-session-tty")
        try assertOK(sendCommand(typeRequest(text: "tty > '\(sessionTTY.path)'\n", target: session, select: false)))
        let expected = try XCTUnwrap(pollMarker(sessionTTY, timeout: 12), "the session should report its tty")

        // the click below aims at the window's centre, so the panel has to be tall enough to cover it: the
        // width takes the maximum and the HEIGHT only follows the message, so the message supplies the rows.
        let tall = Array(repeating: "gathering", count: 24).joined(separator: " ")
        try assertOK(openHud(message: tall, detail: Array(repeating: "scanning", count: 24).joined(separator: " "),
                             spinner: "bar", sizePercent: 80))
        XCTAssertNotNil(pollHud(session, message: tall), "the hud should be up before typing")

        let whileUp = markerDir.appendingPathComponent("hud-focus-while-up")
        XCTAssertEqual(keyboardTypeUntilMarker("tty > '\(whileUp.path)'", file: whileUp), expected,
                       "an open hud must not take first responder from the session")

        clickPanelCentre()

        let afterClick = markerDir.appendingPathComponent("hud-focus-after-click")
        XCTAssertEqual(keyboardTypeUntilMarker("tty > '\(afterClick.path)'", file: afterClick), expected,
                       "a click on the panel must reach the session, never make the painter first responder")
        XCTAssertNotNil(hudNode(session), "and the hud must still be up throughout")
    }

    func testOverlayResultRefusesAHudByName() throws {
        let session = try activeSessionID()
        try assertOK(openHud(message: "no program here"))
        XCTAssertNotNil(pollHud(session, message: "no program here"), "the hud should occupy the slot")

        let result = try sendCommand(request(command: "session.overlay.result", target: session))
        XCTAssertEqual(result["ok"] as? Bool, false, "overlay result must not answer for a hud: \(result)")
        XCTAssertEqual(result["error"] as? String, "no overlay result: the slot holds a hud",
                       "the refusal must name the hud rather than report a running program")
    }

    // MARK: - Helpers

    private func openHud(message: String, detail: String? = nil, spinner: String? = nil,
                         position: String? = nil, textColor: String? = nil,
                         sizePercent: Int? = nil) throws -> [String: Any] {
        var args: [String: Any] = ["message": message]
        if let detail { args["detail"] = detail }
        if let spinner { args["spinner"] = spinner }
        if let position { args["position"] = position }
        if let textColor { args["textColor"] = textColor }
        if let sizePercent { args["sizePercent"] = sizePercent }
        return try sendCommand(request(command: "session.hud.open", args: args))
    }

    /// The middle of the DETAIL area, where a centred panel sits — not the middle of the window, which the
    /// sidebar pushes left of it. The sidebar's own row gives its right edge without hardcoding a width.
    private func clickPanelCentre() {
        let window = app.windows.firstMatch
        let frame = window.frame
        let sidebarRight = app.staticTexts["session-row"].firstMatch.frame.maxX
        let offset = CGVector(dx: (sidebarRight + frame.maxX) / 2 - frame.minX, dy: frame.height / 2)
        window.coordinate(withNormalizedOffset: .zero).withOffset(offset).click()
    }

    private func assertOK(_ response: @autoclosure () throws -> [String: Any]) throws {
        let value = try response()
        XCTAssertEqual(value["ok"] as? Bool, true, "the hud command should succeed: \(value)")
    }

    private func hudNode(_ id: String) -> [String: Any]? {
        (try? sessionNodeIfPresent(id: id))?["hud"] as? [String: Any]
    }

    /// Polls until the session's `hud` node carries `message`, returning it. A replacing open keeps the slot
    /// occupied throughout, so matching on the message rather than on presence is what separates the new
    /// panel from the one it replaced.
    private func pollHud(_ id: String, message: String, timeout: TimeInterval = 10) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let hud = hudNode(id), hud["message"] as? String == message { return hud }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return nil
    }

    private func request(command: String, target: String? = nil, args: [String: Any]? = nil) -> String {
        var object: [String: Any] = ["cmd": command]
        if let target { object["target"] = target }
        if let args { object["args"] = args }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }
}
