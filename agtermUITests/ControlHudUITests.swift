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
        try assertOK(openHud(message: "gathering options…", detail: "scanning the repository", spinner: true))

        let hud = try XCTUnwrap(pollHud(session, message: "gathering options…"), "tree should expose the hud")
        XCTAssertEqual(hud["detail"] as? String, "scanning the repository")
        XCTAssertEqual(hud["spinner"] as? Bool, true)
        XCTAssertNotNil(hud["sizePercent"] as? Int, "the panel's measured share of the pane should be reported")

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

        try assertOK(openHud(message: "pinned to the top", position: "top"))
        let requested = try XCTUnwrap(pollHud(session, message: "pinned to the top"),
                                      "a second hud should replace the first")
        XCTAssertEqual(requested["position"] as? String, "top")
    }

    func testHudUpdateRewritesTheReadBackInPlace() throws {
        let session = try activeSessionID()
        try assertOK(openHud(message: "computing", detail: "step one", position: "bottom"))
        XCTAssertNotNil(pollHud(session, message: "computing"), "the hud should open before the update")

        try assertOK(sendCommand(request(command: "session.hud.update", target: session,
                                         args: ["message": "almost done", "spinner": true])))

        let updated = try XCTUnwrap(pollHud(session, message: "almost done"), "the update should change the message")
        XCTAssertNil(updated["detail"], "an update replaces the whole spec, so an omitted detail is dropped")
        XCTAssertEqual(updated["spinner"] as? Bool, true)
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

    private func openHud(message: String, detail: String? = nil, spinner: Bool = false,
                         position: String? = nil) throws -> [String: Any] {
        var args: [String: Any] = ["message": message]
        if let detail { args["detail"] = detail }
        if spinner { args["spinner"] = true }
        if let position { args["position"] = position }
        return try sendCommand(request(command: "session.hud.open", args: args))
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
