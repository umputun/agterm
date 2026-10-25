import Foundation
import XCTest

/// Control-channel e2e for Settings ▸ Agent Status ▸ "Attention navigation includes active sessions". The
/// setting is GUI-only over the control channel, so the test seeds `settings.json` and relaunches.
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
