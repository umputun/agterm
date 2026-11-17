import XCTest

@MainActor
final class ControlUpdateUITests: ControlAPITestCase {
    func testUpdateCheckIsRefusedWithoutAFeedAndVersionOmitsTheSchedule() throws {
        let check = try sendCommand(#"{"cmd":"update.check"}"#)
        XCTAssertEqual(check["ok"] as? Bool, false, "a feedless build should refuse: \(check)")
        XCTAssertEqual(check["error"] as? String, "update checks are off: this build has no update feed")

        let addressed = try sendCommand(#"{"cmd":"update.check","args":{"window":"w1"}}"#)
        XCTAssertEqual(addressed["error"] as? String, "update.check takes no target or --window")

        let version = try XCTUnwrap(try sendCommand(#"{"cmd":"version"}"#)["result"] as? [String: Any])
        XCTAssertNotNil(version["app"], "version still names the app: \(version)")
        XCTAssertNil(version["updates"], "a feedless build reports no update schedule: \(version)")
    }
}
