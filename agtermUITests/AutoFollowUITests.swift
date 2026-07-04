import Foundation
import XCTest

/// Control-channel e2e for the auto-follow-attention idle policy (Settings ▸ Agent Status ▸ "Auto-follow
/// blocked sessions"). The setting is GUI-only over the control channel, so each test SEEDS `settings.json`
/// with `autoFollowAttention: s5` (the 5 s minimum) into the isolated state dir and relaunches; the app
/// applies it to every window's store at launch (`SettingsModel.applyAutoFollow`). The session set and
/// statuses are then driven over the socket — `session.new`/`session.status`/`session.select` do NOT count
/// as user activity, so the setup never resets the per-window idle timer that fires the follow. The live
/// `tree` node's `active` flag (= the window's selected session) is the selection oracle: it reflects
/// `selectedSessionID` at query time, so it is immediate and has no snapshot-save debounce. Subclass of
/// `ControlAPITestCase` for the socket harness. No keystrokes are typed, so the idle window elapses; the
/// waits are generous per the ui-tests occlusion-timeout guidance.
@MainActor
final class AutoFollowUITests: ControlAPITestCase {
    // parked on a NON-blocked session with auto-follow armed at 5 s, a block landing on another session
    // pulls the window's selection to it once the idle window elapses (no keystrokes reset the timer).
    func testAutoFollowJumpsToBlockedAfterIdle() throws {
        try relaunch(withSettings: #"{"autoFollowAttention":"s5"}"#)

        // A = the restored seeded session; add B, then park the selection back on A (a non-blocked session,
        // since session.new leaves the new session B selected).
        let sessionA = try activeSessionID()
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let sessionB = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new should return an id")
        XCTAssertTrue(pollSessionCount(2, timeout: 10), "the new session should land")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(sessionA)"}"#)["ok"] as? Bool, true,
                       "selecting A should succeed")
        XCTAssertTrue(pollActiveNode(equals: sessionA, timeout: 10), "A should be the parked (non-blocked) selection")

        // block B over the socket (does not note activity, so the idle timer keeps running); after the 5 s
        // idle window the window auto-follows to the oldest blocked session, which is B.
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.status","target":"\#(sessionB)","args":{"status":"blocked"}}"#)["ok"] as? Bool,
                       true, "blocking B should succeed")
        XCTAssertTrue(pollActiveNode(equals: sessionB, timeout: 15),
                      "after the idle window the selection should auto-follow to the blocked session B")
    }

    // parking the selection ON a blocked session suppresses the follow: even with an OLDER blocked session
    // waiting elsewhere, the idle fire does not move away from the blocked session you are already on.
    func testAutoFollowSuppressedWhenParkedOnBlocked() throws {
        try relaunch(withSettings: #"{"autoFollowAttention":"s5"}"#)

        let sessionA = try activeSessionID()
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let sessionB = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new should return an id")
        XCTAssertTrue(pollSessionCount(2, timeout: 10), "the new session should land")

        // block B FIRST so B is the OLDER blocked (a broken suppress would jump to it), then block A and park
        // the selection on A — now A is both the selected AND a blocked session.
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.status","target":"\#(sessionB)","args":{"status":"blocked"}}"#)["ok"] as? Bool,
                       true, "blocking B should succeed")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.status","target":"\#(sessionA)","args":{"status":"blocked"}}"#)["ok"] as? Bool,
                       true, "blocking A should succeed")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(sessionA)"}"#)["ok"] as? Bool, true,
                       "selecting A should succeed")
        XCTAssertTrue(pollActiveNode(equals: sessionA, timeout: 10), "A should be the parked (blocked) selection")

        // across the whole idle window the selection must stay on A and never jump to the older blocked B.
        assertActiveNodeStays(sessionA, never: sessionB, during: 12)
    }

    // MARK: - Selection oracle (the live `tree` `active` flag = the window's selected session)

    /// The id (lowercased) of the session marked `active` (= selected) in the live control `tree`, or nil if
    /// none resolves. `ControlSessionNode.active` is `id == selectedSessionID`, so exactly one node is active.
    private func activeNodeID() -> String? {
        let resp: [String: Any]
        do {
            resp = try sendCommand(#"{"cmd":"tree"}"#)
        } catch {
            XCTFail("control tree query failed: \(error)")
            return nil
        }
        guard let result = resp["result"] as? [String: Any],
              let tree = result["tree"] as? [String: Any],
              let workspaces = tree["workspaces"] as? [[String: Any]] else { return nil }
        let sessions = workspaces.flatMap { ($0["sessions"] as? [[String: Any]]) ?? [] }
        return (sessions.first { ($0["active"] as? Bool) == true }?["id"] as? String)?.lowercased()
    }

    /// Polls the live tree until the `active` session equals `expected` (case-insensitive), or times out.
    private func pollActiveNode(equals expected: String, timeout: TimeInterval) -> Bool {
        let want = expected.lowercased()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if activeNodeID() == want { return true }
            usleep(200_000)
        }
        return activeNodeID() == want
    }

    /// Fails as soon as the `active` session becomes `forbidden` across `during` seconds, then asserts it
    /// still equals `expected` at the end — the deterministic "the follow did NOT happen" oracle. This is a
    /// NEGATIVE oracle: it also passes if auto-follow never armed at all, so the proof that arming/firing
    /// works lives in the sibling `testAutoFollowJumpsToBlockedAfterIdle` (a total never-arms regression
    /// fails there); here it establishes only that a live arm is SUPPRESSED while parked on a blocked session.
    private func assertActiveNodeStays(_ expected: String, never forbidden: String, during: TimeInterval) {
        let want = expected.lowercased()
        let banned = forbidden.lowercased()
        let deadline = Date().addingTimeInterval(during)
        while Date() < deadline {
            XCTAssertNotEqual(activeNodeID(), banned, "auto-follow must not move away from the parked blocked session")
            usleep(300_000)
        }
        XCTAssertEqual(activeNodeID(), want, "the selection should remain on the parked blocked session")
    }
}
