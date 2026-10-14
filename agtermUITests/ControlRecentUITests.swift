import XCTest

@MainActor
final class ControlRecentUITests: ControlAPITestCase {
    func testClosedSessionReopensWithItsIdSplitFlagContextAndPin() throws {
        let created = try sendCommand(#"{"cmd":"session.new","args":{"name":"recent-probe"}}"#)
        let id = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new: \(created)")
        for line in [
            #"{"cmd":"session.split","target":"\#(id)","args":{"mode":"on"}}"#,
            #"{"cmd":"session.flag","target":"\#(id)","args":{"mode":"on"}}"#,
            #"{"cmd":"session.context","target":"\#(id)","args":{"mode":"set","text":"probe context"}}"#,
            #"{"cmd":"session.restore","target":"\#(id)","args":{"mode":"set","command":"echo pinned"}}"#,
            #"{"cmd":"session.close","target":"\#(id)"}"#,
        ] {
            let response = try sendCommand(line)
            XCTAssertEqual(response["ok"] as? Bool, true, "\(line): \(response)")
        }
        XCTAssertNil(try sessionNodeIfPresent(id: id))

        let listed = try sendCommand(#"{"cmd":"recent.list"}"#)
        let entries = try XCTUnwrap((listed["result"] as? [String: Any])?["recent"] as? [[String: Any]], "\(listed)")
        let entry = try XCTUnwrap(entries.first { ($0["sessionIDs"] as? [String]) == [id] }, "entry for \(id): \(entries)")
        let entryID = try XCTUnwrap(entry["id"] as? String)
        XCTAssertEqual(entry["kind"] as? String, "session")

        let opened = try sendCommand(#"{"cmd":"recent.open","target":"\#(entryID)"}"#)
        let open = try XCTUnwrap((opened["result"] as? [String: Any])?["recentOpen"] as? [String: Any], "\(opened)")
        XCTAssertEqual(open["complete"] as? Bool, true)

        let node = try sessionNode(id: id)
        XCTAssertEqual(node["hasSplit"] as? Bool, true)
        XCTAssertEqual(node["flagged"] as? Bool, true)
        XCTAssertEqual(node["context"] as? String, "probe context")
        XCTAssertEqual(node["restoreCommand"] as? String, "echo pinned")

        let after = try sendCommand(#"{"cmd":"recent.list"}"#)
        let remaining = try XCTUnwrap((after["result"] as? [String: Any])?["recent"] as? [[String: Any]])
        XCTAssertFalse(remaining.contains { $0["id"] as? String == entryID })
    }
}
