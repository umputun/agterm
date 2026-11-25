import Foundation
import XCTest
import agtermCore

/// Daemon cleanup for the suites that opt into the real zmx path (`enablesZmxForUITest`): each must reap
/// its exact test daemons in teardown so none leak into later tests.
extension ControlAPITestCase {
    fileprivate struct DaemonRow {
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
    func reapTestDaemons() throws {
        guard let stateDir else { return }
        let namespace = ZmxSupport.socketDirectory(forStateDirectory: stateDir.path)
        let dailyDriver = ZmxSupport.socketDirectory(forStateDirectory: PersistenceStore.defaultDirectory.path)
        guard namespace != dailyDriver else {
            throw cleanupFailure("refusing to reap: the test namespace resolved to the default one")
        }

        // a parent that still has companions respawns its shell under the same daemon name, so every companion
        // ends first: terminal ones by their daemons, page ones (no daemon) by closing them
        let alive = try daemonRows("zmx.list before cleanup", namespace: namespace).filter(\.isAlive)
        let companionIDs = Set(try companionNodes().compactMap { $0["id"] as? String })
        var killErrors = try kill(alive.filter { companionIDs.contains($0.sessionID ?? "") })
        for page in try companionNodes() where page["content"] as? String == "page" {
            guard let id = page["id"] as? String else { continue }
            let response = try sendCommand(#"{"cmd":"session.close","target":"\#(id)"}"#)
            if response["ok"] as? Bool != true { killErrors.append("page \(id): \(response["error"] ?? response)") }
        }
        let stranded = Set(try companionNodes().compactMap { $0["parent"] as? String })
        killErrors += stranded.sorted().map { "\($0): companions left after their kills, parent not killed" }
        killErrors += try kill(alive.filter { !companionIDs.contains($0.sessionID ?? "") && !stranded.contains($0.sessionID ?? "") })

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

    /// Kills each claimed row through the app, right before left: killing a primary promotes its split, so a
    /// right entry captured before that stops resolving.
    fileprivate func kill(_ rows: [DaemonRow]) throws -> [String] {
        var errors: [String] = []
        for row in rows.sorted(by: { ($0.pane ?? "") > ($1.pane ?? "") }) {
            guard let target = row.killTarget else { continue }
            let request = try JSONSerialization.data(withJSONObject: [
                "cmd": "zmx.kill",
                "target": target.sessionID,
                "args": ["pane": target.pane, "force": true],
            ])
            let response = try sendCommand(String(decoding: request, as: UTF8.self))
            if response["ok"] as? Bool != true { errors.append("\(row.daemon): \(response["error"] ?? response)") }
        }
        return errors
    }

    fileprivate func companionNodes() throws -> [[String: Any]] {
        try treeWorkspaceNodes().flatMap { $0["sessions"] as? [[String: Any]] ?? [] }.filter { $0["parent"] != nil }
    }

    /// Every daemon in this test's namespace. The endpoint and inventory checks are the safety boundary
    /// and still fail closed; past them a row is reported rather than dropped, so an unreapable daemon
    /// surfaces in the post-kill deadline instead of being filtered out of both passes.
    fileprivate func daemonRows(_ context: String, namespace: String) throws -> [DaemonRow] {
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

    fileprivate func cleanupFailure(_ message: String) -> Error {
        NSError(domain: "ZmxTestDaemons", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
