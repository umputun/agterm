import Foundation
import XCTest

/// Control-channel e2e for the Settings ▸ Agent Status ▸ Navigation toggles. Both are GUI-only over the
/// control channel, so the tests seed `settings.json` and relaunch.
@MainActor
final class AttentionNavigationUITests: ControlAPITestCase {
    func testSessionGoNextAttentionStopsOnActiveWhenIncluded() throws {
        try relaunch(withSettings: #"{"attentionIncludesActive":true}"#)
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        XCTAssertEqual(((tree["result"] as? [String: Any])?["tree"] as? [String: Any])?["attentionIncludesActive"] as? Bool,
                       true, "the tree should read back the seeded setting: \(tree)")

        let first = try activeSessionID()
        let active = try newSessionID()
        let blocked = try newSessionID()
        XCTAssertTrue(pollSessionCount(3, timeout: 10), "both new sessions should land")
        try setStatus(active, "active")
        try setStatus(blocked, "blocked")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(first)"}"#)["ok"] as? Bool, true)

        XCTAssertEqual(try nextAttentionID(), active.lowercased(), "next-attention should stop on the active session")
        XCTAssertEqual(try nextAttentionID(), blocked.lowercased(), "then on the blocked one")
        XCTAssertEqual(try nextAttentionID(), active.lowercased(), "and wrap back to the active one")
    }

    func testCrossWindowSettingReachesEveryWindowStore() throws {
        try relaunch(withSettings: #"{"attentionNavigationAcrossWindows":true}"#)
        XCTAssertEqual(try acrossWindows(in: nil), true, "the launch window should read back the seeded setting")

        let created = try sendCommand(#"{"cmd":"window.new"}"#)
        let second = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "window.new should return an id")
        XCTAssertTrue(poll(until: (try? acrossWindows(in: second)) == true, timeout: 10),
                      "a window opened later should get the setting too")
    }

    private func acrossWindows(in window: String?) throws -> Bool? {
        let request = window.map { #"{"cmd":"tree","args":{"window":"\#($0)"}}"# } ?? #"{"cmd":"tree"}"#
        let tree = try sendCommand(request)
        return ((tree["result"] as? [String: Any])?["tree"] as? [String: Any])?["attentionNavigationAcrossWindows"] as? Bool
    }

    private func newSessionID() throws -> String {
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        return try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new should return an id")
    }

    private func setStatus(_ id: String, _ status: String) throws {
        let response = try sendCommand(#"{"cmd":"session.status","target":"\#(id)","args":{"status":"\#(status)"}}"#)
        XCTAssertEqual(response["ok"] as? Bool, true, "setting \(status) should succeed: \(response)")
    }

    private func nextAttentionID() throws -> String? {
        let response = try sendCommand(#"{"cmd":"session.go","args":{"to":"next-attention"}}"#)
        XCTAssertEqual(response["ok"] as? Bool, true, "next-attention should succeed: \(response)")
        return ((response["result"] as? [String: Any])?["id"] as? String)?.lowercased()
    }
}
