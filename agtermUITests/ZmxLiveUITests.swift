import Foundation
import XCTest
import agtermCore

@MainActor
final class ZmxLiveUITests: ControlAPITestCase {
    override var seededSettings: [String: Any]? { ["restoreMode": "live"] }
    override var enablesZmxForUITest: Bool { true }

    override func tearDown() async throws {
        var cleanupError: Error?
        do { try reapTestDaemons() } catch { cleanupError = error }
        app?.terminate()
        try await super.tearDown()
        if let cleanupError { throw cleanupError }
    }

    func testBundledZmxBacksPrimaryAndSplitAndRunsLongCreationCommandOnce() throws {
        let sessionID = try activeSessionID()
        XCTAssertTrue(poll(until: self.isBacked(sessionID, expectedPanes: ["left"]), timeout: 20),
                      "the primary pane should report real zmx backing")

        let response = try sendCommand(
            #"{"cmd":"session.split","target":"\#(sessionID)","args":{"mode":"on"}}"#)
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertTrue(poll(until: self.isBacked(sessionID, expectedPanes: ["left", "right"]), timeout: 20),
                      "both panes and the session aggregate should report zmx backing")

        let marker = stateDir.appendingPathComponent("creation-command.txt")
        let padding = String(repeating: "x", count: 2_048)
        let command = "payload='\(padding)'; printf x >> '\(marker.path)'"
        XCTAssertGreaterThan(command.utf8.count, 1_024)
        let request = try JSONSerialization.data(withJSONObject: [
            "cmd": "session.new",
            "args": ["command": command],
        ])
        let created = try sendCommand(String(decoding: request, as: UTF8.self))
        XCTAssertEqual(created["ok"] as? Bool, true)
        XCTAssertTrue(poll(until: (try? String(contentsOf: marker, encoding: .utf8)) == "x", timeout: 20),
                      "the create-only payload should bypass the pty input cap")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "x",
                       "the create-only payload must run exactly once")
    }

    private func isBacked(_ sessionID: String, expectedPanes: Set<String>) -> Bool {
        guard let response = try? sendCommand(#"{"cmd":"tree"}"#),
              let tree = (response["result"] as? [String: Any])?["tree"] as? [String: Any],
              let workspaces = tree["workspaces"] as? [[String: Any]],
              let session = workspaces.flatMap({ $0["sessions"] as? [[String: Any]] ?? [] })
                  .first(where: { ($0["id"] as? String)?.caseInsensitiveCompare(sessionID) == .orderedSame }),
              session["backedByZmx"] as? Bool == true,
              let surfaces = session["surfaces"] as? [[String: Any]] else { return false }
        let backed = Set(surfaces.compactMap { surface -> String? in
            guard surface["backedByZmx"] as? Bool == true else { return nil }
            return surface["kind"] as? String
        })
        return expectedPanes.isSubset(of: backed)
    }

    private struct DaemonRow {
        /// Mirrors ZmxDaemonObservation and ZmxDaemonState. Parsing through them rather than raw strings
        /// is what makes a renamed value fail the reap instead of silently reading as not alive.
        enum Observation: String { case running, unreadable, absent }
        enum State: String { case claimed, orphan, unknown, conflicted, pendingClose, foreign }

        let daemon: String
        let observation: Observation
        let state: State
        let sessionID: String?
        let pane: String?

        var isAlive: Bool { observation == .running || observation == .unreadable }

        /// `ControlZmxError.killRefusal` accepts only a running, claimed row, so anything else is
        /// unreapable and belongs in the report rather than in a kill that is certain to be refused.
        var killTarget: (sessionID: String, pane: String)? {
            guard observation == .running, state == .claimed, let sessionID, let pane else { return nil }
            return (sessionID, pane)
        }
    }

    /// Ends this run's daemons through the app's own `zmx.kill` instead of signalling them from the test
    /// runner, which cannot signal what the app spawned: zmx reports that `kill(2)` EPERM as
    /// `PermissionDenied` and every run leaks its daemons. `session.close` is not a substitute because
    /// `paneFinalizer` discards the kill result, so it can drop the model while the daemon survives.
    private func reapTestDaemons() throws {
        guard let stateDir else { return }
        let namespace = ZmxSupport.socketDirectory(forStateDirectory: stateDir.path)
        let dailyDriver = ZmxSupport.socketDirectory(forStateDirectory: PersistenceStore.defaultDirectory.path)
        guard namespace != dailyDriver else {
            throw cleanupFailure("refusing to reap: the test namespace resolved to the default one")
        }

        var killErrors: [String] = []
        // right before left: killing the primary promotes the split, since closePrimaryPane assigns
        // paneIdentity from splitPaneIdentity, so a right entry captured before that stops resolving
        let alive = try daemonRows("zmx.list before cleanup", namespace: namespace).filter(\.isAlive)
        for row in alive.sorted(by: { ($0.pane ?? "") > ($1.pane ?? "") }) {
            guard let target = row.killTarget else { continue }
            let request = try JSONSerialization.data(withJSONObject: [
                "cmd": "zmx.kill",
                "target": target.sessionID,
                "args": ["pane": target.pane, "force": true],
            ])
            let response = try sendCommand(String(decoding: request, as: UTF8.self))
            if response["ok"] as? Bool != true {
                killErrors.append("\(row.daemon): \(response["error"] ?? response)")
            }
        }

        var remaining = try daemonRows("zmx.list after cleanup", namespace: namespace).filter(\.isAlive)
        let deadline = Date().addingTimeInterval(20)
        while !remaining.isEmpty, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            remaining = try daemonRows("zmx.list after cleanup", namespace: namespace).filter(\.isAlive)
        }
        guard remaining.isEmpty else {
            let names = remaining.map { "\($0.daemon) (\($0.state.rawValue)/\($0.observation.rawValue))" }.joined(separator: ", ")
            let errors = killErrors.isEmpty ? "" : "; kill errors: " + killErrors.joined(separator: ", ")
            throw cleanupFailure("daemons still alive after zmx.kill: \(names)\(errors)")
        }
    }

    /// Every daemon in this test's namespace. The endpoint and inventory checks are the safety boundary
    /// and still fail closed; past them a row is reported rather than dropped, so an unreapable daemon
    /// surfaces in the post-kill deadline instead of being filtered out of both passes.
    private func daemonRows(_ context: String, namespace: String) throws -> [DaemonRow] {
        let response = try sendCommand(#"{"cmd":"zmx.list"}"#)
        guard response["ok"] as? Bool == true,
              let zmx = (response["result"] as? [String: Any])?["zmx"] as? [String: Any] else {
            throw cleanupFailure("\(context) failed: \(response)")
        }
        guard zmx["inventoryComplete"] as? Bool == true else {
            throw cleanupFailure("\(context): the inventory is incomplete")
        }
        guard let endpoint = zmx["endpoint"] as? [String: Any],
              endpoint["socketDirectory"] as? String == namespace else {
            throw cleanupFailure("\(context): the endpoint is not this test's namespace")
        }
        guard let entries = zmx["entries"] as? [[String: Any]] else {
            throw cleanupFailure("\(context): the inventory carries no entries array")
        }
        return try entries.map { entry in
            guard let daemon = entry["daemon"] as? String, let rawObservation = entry["observation"] as? String,
                  let rawState = entry["state"] as? String else {
                throw cleanupFailure("\(context): an entry lacks daemon, observation or state: \(entry)")
            }
            guard let observation = DaemonRow.Observation(rawValue: rawObservation),
                  let state = DaemonRow.State(rawValue: rawState) else {
                throw cleanupFailure("\(context): \(daemon) reports observation \(rawObservation) and state "
                    + "\(rawState), one of which this test does not know")
            }
            let sessionID = entry["sessionID"] as? String
            let pane = entry["pane"] as? String
            guard state != .claimed || (sessionID != nil && pane != nil) else {
                throw cleanupFailure("\(context): claimed daemon \(daemon) carries no sessionID or pane")
            }
            return DaemonRow(daemon: daemon, observation: observation, state: state, sessionID: sessionID, pane: pane)
        }
    }

    private func cleanupFailure(_ message: String) -> Error {
        NSError(domain: "ZmxLiveUITests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
