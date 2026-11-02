import XCTest

@MainActor
final class ControlSessionInfoUITests: ControlAPITestCase {
    func testSessionInfoSetsReadsBackRejectsAndClears() throws {
        let created = try sendCommand(#"{"cmd":"session.new","args":{"name":"info-probe"}}"#)
        let id = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new: \(created)")

        let set = try sendCommand(
            #"{"cmd":"session.info","target":"\#(id)","args":{"mode":"set","text":"**3** ^[ok](color: \"green\")","markdown":true,"hideAfter":600}}"#)
        XCTAssertEqual(set["ok"] as? Bool, true, "\(set)")
        var node = try sessionNode(id: id)
        XCTAssertEqual(node["info"] as? String, #"**3** ^[ok](color: "green")"#)
        XCTAssertEqual(node["infoMarkdown"] as? Bool, true)
        XCTAssertEqual(node["infoHideAfter"] as? Double, 600)

        let refused = try sendCommand(
            #"{"cmd":"session.info","target":"\#(id)","args":{"mode":"set","text":"^[x](color: \"pink\")","markdown":true}}"#)
        XCTAssertEqual(refused["ok"] as? Bool, false, "\(refused)")
        node = try sessionNode(id: id)
        XCTAssertEqual(node["info"] as? String, #"**3** ^[ok](color: "green")"#, "a refused set leaves the line standing")

        let cleared = try sendCommand(#"{"cmd":"session.info","target":"\#(id)","args":{"mode":"clear"}}"#)
        XCTAssertEqual(cleared["ok"] as? Bool, true, "\(cleared)")
        node = try sessionNode(id: id)
        XCTAssertNil(node["info"])
        XCTAssertNil(node["infoMarkdown"])
        XCTAssertNil(node["infoHideAfter"])
    }
}
