import XCTest

@MainActor
final class EventSubscriptionUITests: ControlAPITestCase {
    func testEventSubscriptionEndToEnd() throws {
        let seededID = try activeSessionID()
        let anchor = try eventAnchor()

        try assertOK(##"{"cmd":"session.status","target":"\##(seededID)","args":{"status":"blocked","pane":"left","blink":true,"color":"#aabbcc"}}"##)
        try assertOK(##"{"cmd":"session.status","target":"\##(seededID)","args":{"status":"blocked","pane":"left","blink":true,"color":"#aabbcc"}}"##)
        try assertOK(#"{"cmd":"session.status","target":"\#(seededID)","args":{"status":"idle"}}"#)

        let statusRead = try readEvents(anchor: anchor, kinds: ["status"])
        try statusRead.items.forEach(assertCommonEnvelope)
        XCTAssertEqual(statusRead.items.compactMap { ($0["payload"] as? [String: Any])?["status"] as? String },
                       ["blocked", "idle"], "same-value status reassertion must not duplicate")
        let blockedPayload = try XCTUnwrap(statusRead.items.first?["payload"] as? [String: Any])
        XCTAssertFalse((blockedPayload["name"] as? String ?? "").isEmpty)
        XCTAssertEqual(blockedPayload["pane"] as? String, "left")
        XCTAssertEqual(blockedPayload["blink"] as? Bool, true)
        XCTAssertEqual(blockedPayload["color"] as? String, "#aabbcc")
        let idlePayload = try XCTUnwrap(statusRead.items.last?["payload"] as? [String: Any])
        XCTAssertNil(idlePayload["pane"])
        XCTAssertEqual(idlePayload["blink"] as? Bool, false)
        XCTAssertNil(idlePayload["color"])

        let second = try sendCommand(#"{"cmd":"session.new","args":{"name":"second"}}"#)
        let secondID = try XCTUnwrap((second["result"] as? [String: Any])?["id"] as? String)
        try assertOK(#"{"cmd":"session.status","target":"\#(seededID)","args":{"status":"completed","autoReset":true}}"#)
        app.staticTexts.matching(identifier: "session-row").element(boundBy: 0).click()
        let visitRead = try pollEvents(anchor: statusRead.anchor, kinds: ["status"], minimum: 2)
        XCTAssertEqual(visitRead.items.compactMap { ($0["payload"] as? [String: Any])?["status"] as? String }.suffix(2),
                       ["completed", "idle"])

        try assertOK(#"{"cmd":"notify","target":"\#(seededID)","args":{"title":"Done","body":"tests passed"}}"#)
        let notifyRead = try pollEvents(anchor: visitRead.anchor, kinds: ["notify"], minimum: 1)
        let notify = try XCTUnwrap(notifyRead.items.last)
        try assertCommonEnvelope(notify)
        let payload = try XCTUnwrap(notify["payload"] as? [String: Any])
        XCTAssertFalse((payload["name"] as? String ?? "").isEmpty)
        XCTAssertEqual(payload["title"] as? String, "Done")
        XCTAssertEqual(payload["body"] as? String, "tests passed")

        let lifecycleAnchor = notifyRead.anchor
        let created = try sendCommand(#"{"cmd":"session.new","args":{"name":"ephemeral"}}"#)
        let createdID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String)
        app.menuBars.menuBarItems["File"].click()
        let close = app.menuItems["Close Session"]
        XCTAssertTrue(close.waitForExistence(timeout: 2))
        XCTAssertTrue(close.isEnabled)
        close.click()
        app.menuBars.menuBarItems["File"].click()
        let reopen = app.menuItems["Reopen Closed Item"]
        XCTAssertTrue(reopen.waitForExistence(timeout: 2))
        XCTAssertTrue(reopen.isEnabled)
        reopen.click()
        let lifecycle = try pollEvents(anchor: lifecycleAnchor,
                                       kinds: ["session.created", "session.closed"], minimum: 3)
        try lifecycle.items.forEach(assertCommonEnvelope)
        let edges = lifecycle.items.filter { ($0["session"] as? String) == createdID }.compactMap { $0["kind"] as? String }
        XCTAssertEqual(edges, ["session.created", "session.closed", "session.created"])
        for event in lifecycle.items where (event["session"] as? String) == createdID {
            let lifecyclePayload = try XCTUnwrap(event["payload"] as? [String: Any])
            XCTAssertEqual(lifecyclePayload["name"] as? String, "ephemeral")
        }

        let treeAnchor = lifecycle.anchor
        try assertOK(#"{"cmd":"session.rename","target":"\#(createdID)","args":{"name":"burst one"}}"#)
        try assertOK(#"{"cmd":"session.rename","target":"\#(createdID)","args":{"name":"burst two"}}"#)
        let treeRead = try pollEvents(anchor: treeAnchor, kinds: ["tree.changed"], minimum: 1)
        XCTAssertEqual(treeRead.items.count, 1)
        let treeEvent = try XCTUnwrap(treeRead.items.first)
        try assertCommonEnvelope(treeEvent)
        XCTAssertEqual((treeEvent["payload"] as? [String: Any])?.count, 0)
        XCTAssertNil(treeEvent["workspace"])
        XCTAssertNil(treeEvent["session"])
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let noDuplicateTree = try readEvents(anchor: treeRead.anchor, kinds: ["tree.changed"])
        XCTAssertTrue(noDuplicateTree.items.isEmpty)

        let independent = try readEvents(anchor: anchor, kinds: nil)
        XCTAssertTrue(independent.items.contains { ($0["kind"] as? String) == "notify" })
        XCTAssertTrue(independent.items.contains { ($0["session"] as? String) == secondID })
        XCTAssertGreaterThanOrEqual(statusRead.anchor.after, anchor.after)
    }

    private typealias Anchor = (run: String, after: UInt64)
    private typealias EventRead = (anchor: Anchor, items: [[String: Any]])

    private func eventAnchor() throws -> Anchor {
        try readEvents(anchor: nil, kinds: nil).anchor
    }

    private func readEvents(anchor: Anchor?, kinds: [String]?) throws -> EventRead {
        var args: [String: Any] = [:]
        if let anchor { args["run"] = anchor.run; args["after"] = String(anchor.after) }
        if let kinds { args["kinds"] = kinds }
        var request: [String: Any] = ["cmd": "events.read"]
        if !args.isEmpty { request["args"] = args }
        let data = try JSONSerialization.data(withJSONObject: request)
        let response = try sendCommand(String(decoding: data, as: UTF8.self))
        XCTAssertEqual(response["ok"] as? Bool, true, "events.read should succeed: \(response)")
        let batch = try XCTUnwrap((response["result"] as? [String: Any])?["events"] as? [String: Any])
        return (
            (try XCTUnwrap(batch["run"] as? String), UInt64(try XCTUnwrap(batch["next"] as? NSNumber).uint64Value)),
            batch["items"] as? [[String: Any]] ?? []
        )
    }

    private func pollEvents(anchor: Anchor, kinds: [String], minimum: Int) throws -> EventRead {
        let deadline = Date().addingTimeInterval(5)
        var current = anchor
        var items: [[String: Any]] = []
        repeat {
            let page = try readEvents(anchor: current, kinds: kinds)
            current = page.anchor
            items.append(contentsOf: page.items)
            if items.count >= minimum { return (current, items) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        XCTFail("timed out waiting for \(minimum) events; got \(items)")
        return (current, items)
    }

    private func assertOK(_ request: String) throws {
        let response = try sendCommand(request)
        XCTAssertEqual(response["ok"] as? Bool, true, "request should succeed: \(response)")
    }

    private func assertCommonEnvelope(_ event: [String: Any]) throws {
        XCTAssertGreaterThan(try XCTUnwrap(event["seq"] as? NSNumber).uint64Value, 0)
        XCTAssertGreaterThan(try XCTUnwrap(event["ts"] as? NSNumber).doubleValue, 0)
        XCTAssertFalse((event["kind"] as? String ?? "").isEmpty)
        XCTAssertFalse((event["window"] as? String ?? "").isEmpty)
        _ = try XCTUnwrap(event["payload"] as? [String: Any])
        if (event["kind"] as? String) != "tree.changed" {
            XCTAssertFalse((event["workspace"] as? String ?? "").isEmpty)
            XCTAssertFalse((event["session"] as? String ?? "").isEmpty)
        }
    }
}
