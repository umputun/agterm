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

    private struct PaneDaemon {
        let sessionID: String
        let pane: String
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

        // right before left: the split attached through the session the primary's daemon leads
        for daemon in try liveDaemons("zmx.list before cleanup", namespace: namespace)
            .sorted(by: { $0.pane > $1.pane }) {
            let request = try JSONSerialization.data(withJSONObject: [
                "cmd": "zmx.kill",
                "target": daemon.sessionID,
                "args": ["pane": daemon.pane, "force": true],
            ])
            let response = try sendCommand(String(decoding: request, as: UTF8.self))
            guard response["ok"] as? Bool == true else {
                throw cleanupFailure("zmx.kill \(daemon.sessionID):\(daemon.pane) refused: \(response)")
            }
        }

        var remaining = try liveDaemons("zmx.list after cleanup", namespace: namespace)
        let deadline = Date().addingTimeInterval(20)
        while !remaining.isEmpty, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            remaining = try liveDaemons("zmx.list after cleanup", namespace: namespace)
        }
        guard remaining.isEmpty else {
            throw cleanupFailure("\(remaining.count) daemon(s) still running after zmx.kill")
        }
    }

    /// The running daemons this test owns. Fails closed rather than reaping anything it cannot name: an
    /// incomplete inventory, an endpoint outside this test's namespace, or a running row that is not a
    /// claimed pane all abort the cleanup instead of widening it.
    private func liveDaemons(_ context: String, namespace: String) throws -> [PaneDaemon] {
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
        return try (zmx["entries"] as? [[String: Any]] ?? [])
            .filter { $0["observation"] as? String == "running" }
            .map { entry in
                guard entry["state"] as? String == "claimed",
                      let sessionID = entry["sessionID"] as? String,
                      let pane = entry["pane"] as? String else {
                    throw cleanupFailure("\(context): running daemon \(entry["daemon"] ?? "?") is unclaimed")
                }
                return PaneDaemon(sessionID: sessionID, pane: pane)
            }
    }

    private func cleanupFailure(_ message: String) -> Error {
        NSError(domain: "ZmxLiveUITests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
