import XCTest

@MainActor
final class ControlSessionGoUITests: ControlAPITestCase {
    func testSessionGoSelectsAPositionAndRefusesOnePastTheEnd() throws {
        let firstID = UUID(uuidString: "EEEE0000-0000-0000-0000-000000000011")!
        let secondID = UUID(uuidString: "FFFF0000-0000-0000-0000-000000000012")!
        let snapshot = """
        {"version":1,"selectedSessionID":"\(firstID.uuidString)","workspaces":[\
        {"id":"\(UUID().uuidString)","name":"workspace 1","sessions":[\
        {"id":"\(firstID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"}]},\
        {"id":"\(UUID().uuidString)","name":"workspace 2","sessions":[\
        {"id":"\(secondID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"}]}]}
        """
        try relaunch(withSnapshot: snapshot)

        let second = try sendCommand(#"{"cmd":"session.go","args":{"to":"2"}}"#)
        XCTAssertEqual(((second["result"] as? [String: Any])?["id"] as? String)?.lowercased(),
                       secondID.uuidString.lowercased(), "\(second)")
        XCTAssertTrue(pollActiveSessionID(secondID, timeout: 10))

        let pastEnd = try sendCommand(#"{"cmd":"session.go","args":{"to":"3"}}"#)
        XCTAssertEqual(pastEnd["ok"] as? Bool, false, "\(pastEnd)")
        XCTAssertEqual(pastEnd["error"] as? String, "no session at position 3: 2 navigable")
        XCTAssertTrue(pollActiveSessionID(secondID, timeout: 2), "a missed position should keep the selection")
    }
}
