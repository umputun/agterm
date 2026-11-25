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

    func testACommandSessionClosesWhenItsCommandExitsAndHoldsWithWait() throws {
        _ = try activeSessionID()
        let closing = try sendCommand(String(decoding: try JSONSerialization.data(withJSONObject: [
            "cmd": "session.new", "args": ["command": "sleep 1"],
        ]), as: UTF8.self))
        let closingID = try XCTUnwrap((closing["result"] as? [String: Any])?["id"] as? String)
        XCTAssertTrue(poll(until: (try? self.sessionNodeIfPresent(id: closingID)) == nil, timeout: 20),
                      "a Live --command session should close when its command exits, as it does outside Live")

        let holding = try sendCommand(String(decoding: try JSONSerialization.data(withJSONObject: [
            "cmd": "session.new", "args": ["command": "echo held-output; sleep 1", "wait": true],
        ]), as: UTF8.self))
        let holdingID = try XCTUnwrap((holding["result"] as? [String: Any])?["id"] as? String)
        let held = try heldText(holdingID)
        XCTAssertTrue(held.contains("held-output"), "--wait should hold the exited command's output, got: \(held)")
        XCTAssertNotNil(try sessionNodeIfPresent(id: holdingID))
    }

    func testAWaitCommandKeepsScrollbackPastOneScreenAfterExit() throws {
        _ = try activeSessionID()
        let command = "echo first-held-line; seq 1 300; printf '\\033[?1000h\\033[?1006h\\033[?2004h'; echo last-held-line"
        let created = try sendCommand(String(decoding: try JSONSerialization.data(withJSONObject: [
            "cmd": "session.new", "args": ["command": command, "wait": true],
        ]), as: UTF8.self))
        let sessionID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String)
        let held = try heldText(sessionID)
        XCTAssertTrue(held.contains("first-held-line"), "scrollback above the screen should survive exit, got: \(held)")
        XCTAssertTrue(held.contains("last-held-line"), "the final screen should survive exit, got: \(held)")
    }

    func testAWaitCommandKeepsScrollbackOnceThePaneIsAttached() throws {
        _ = try activeSessionID()
        let release = stateDir.appendingPathComponent("release-scrollback")
        let command = "echo pane-attached-marker; while [ ! -e '\(release.path)' ]; do sleep 0.05; done; "
            + "echo first-held-line; seq 1 300; printf '\\033[?1000h\\033[?1006h\\033[?2004h'; echo last-held-line"
        let created = try sendCommand(String(decoding: try JSONSerialization.data(withJSONObject: [
            "cmd": "session.new", "args": ["command": command, "wait": true],
        ]), as: UTF8.self))
        let sessionID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String)
        XCTAssertTrue(poll(until: self.paneText(sessionID).contains("pane-attached-marker"), timeout: 20))
        XCTAssertTrue(FileManager.default.createFile(atPath: release.path, contents: Data()))
        let held = try heldText(sessionID)
        XCTAssertTrue(held.contains("first-held-line"), "scrollback above the screen should survive exit, got: \(held)")
        XCTAssertTrue(held.contains("last-held-line"), "the final screen should survive exit, got: \(held)")
    }

    func testALiveParentWhoseShellExitsRespawnsAndTakesInput() throws {
        let parent = try activeSessionID()
        let created = try sendCommand(#"{"cmd":"session.companion.new","target":"\#(parent)","args":{"noSelect":true}}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "\(created)")
        let marker = stateDir.appendingPathComponent("live-respawn.marker")

        XCTAssertEqual(try sendCommand(typeRequest(text: "exit\n", target: parent, select: false))["ok"] as? Bool, true)
        RunLoop.current.run(until: Date().addingTimeInterval(3))

        XCTAssertNotNil(try sessionNodeIfPresent(id: parent), "a Live parent with companions survives its shell's exit")
        XCTAssertEqual(try typeUntilMarker("echo alive > '\(marker.path)'\n", target: parent, file: marker, select: false), "alive")
        XCTAssertTrue(poll(until: self.isBacked(parent, expectedPanes: ["left"]), timeout: 20),
                      "the respawned Live pane is daemon-backed again")
    }

    func testRestartReplacesTheShellEndsItsProgramAndKeepsThePane() throws {
        let sessionID = try activeSessionID()
        XCTAssertTrue(poll(until: self.isBacked(sessionID, expectedPanes: ["left"]), timeout: 20))
        let paneID = try XCTUnwrap(paneID(sessionID, kind: "left"))
        let programPid = stateDir.appendingPathComponent("program.pid")
        let verdict = stateDir.appendingPathComponent("program.gone")

        let first = try restart(sessionID, paneID: paneID, command: "sh -c 'echo $$ > \(programPid.path); exec sleep 600'")
        XCTAssertTrue(poll(until: FileManager.default.fileExists(atPath: programPid.path), timeout: 20),
                      "the restarted shell should run the line")
        let pid = try String(contentsOf: programPid, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)

        let second = try restart(sessionID, paneID: paneID,
                                 command: "kill -0 \(pid) 2>/dev/null; echo $? > \(verdict.path); echo $AGTERM_PANE_ID >> \(verdict.path)")
        XCTAssertTrue(poll(until: (try? String(contentsOf: verdict, encoding: .utf8))?.contains(paneID) == true, timeout: 20))
        XCTAssertEqual(try String(contentsOf: verdict, encoding: .utf8), "1\n\(paneID)\n",
                       "the program the first shell ran must be gone, and the new shell keeps the pane id")
        XCTAssertEqual(first.newPid, second.oldPid)
        XCTAssertNotEqual(second.oldPid, second.newPid)
        XCTAssertEqual(self.paneID(sessionID, kind: "left"), paneID)
        XCTAssertTrue(isBacked(sessionID, expectedPanes: ["left"]))
    }

    func testRestartRunsInAHiddenSplitAndRefusesAnUnknownPaneID() throws {
        let sessionID = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(sessionID)","args":{"mode":"on"}}"#)["ok"] as? Bool, true)
        XCTAssertTrue(poll(until: self.isBacked(sessionID, expectedPanes: ["left", "right"]), timeout: 20))
        let paneID = try XCTUnwrap(paneID(sessionID, kind: "right"))
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(sessionID)","args":{"mode":"off"}}"#)["ok"] as? Bool, true)
        let marker = stateDir.appendingPathComponent("hidden.txt")

        _ = try restart(sessionID, paneID: paneID, command: "printf x > \(marker.path)")
        XCTAssertTrue(poll(until: (try? String(contentsOf: marker, encoding: .utf8)) == "x", timeout: 20),
                      "a pane the deck does not lay out should still start its new shell")
        XCTAssertEqual(self.paneID(sessionID, kind: "right"), paneID)

        let unknown = UUID().uuidString
        let request = try JSONSerialization.data(withJSONObject: [
            "cmd": "session.restart", "target": sessionID,
            "args": ["command": "true", "paneID": unknown, "pane": "right"],
        ])
        let refused = try sendCommand(String(decoding: request, as: UTF8.self))
        XCTAssertEqual(refused["error"] as? String, "unknown pane id: \(unknown)")
    }

    func testRestartWithoutACommandRunsTheLastRestartedProgramAgain() throws {
        let sessionID = try activeSessionID()
        XCTAssertTrue(poll(until: self.isBacked(sessionID, expectedPanes: ["left"]), timeout: 20))
        let paneID = try XCTUnwrap(paneID(sessionID, kind: "left"))
        let marker = stateDir.appendingPathComponent("replay runs.txt")
        let work = stateDir.appendingPathComponent("work dir", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let script = "pwd -P >> '\(marker.path)'; sleep 600; :"
        _ = try restart(sessionID, paneID: paneID, command: "cd '\(work.path)' && sh -c \"\(script)\"")
        XCTAssertTrue(poll(until: (try? String(contentsOf: marker, encoding: .utf8))?.hasSuffix("/work dir\n") == true, timeout: 20))
        let ran = try String(contentsOf: marker, encoding: .utf8)

        let request = try JSONSerialization.data(withJSONObject: [
            "cmd": "session.restart", "target": sessionID, "args": ["paneID": paneID],
        ])
        let response = try sendCommand(String(decoding: request, as: UTF8.self))

        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        let receipt = try XCTUnwrap((response["result"] as? [String: Any])?["restart"] as? [String: Any])
        XCTAssertEqual(receipt["replayedArgv"] as? [String], ["sh", "-c", script])
        XCTAssertTrue(poll(until: (try? String(contentsOf: marker, encoding: .utf8)) == ran + ran, timeout: 20),
                      "the replay should run the restarted program where it was running, quoting intact")
        XCTAssertEqual(self.paneID(sessionID, kind: "left"), paneID)
    }

    private func restart(_ sessionID: String, paneID: String, command: String) throws -> (oldPid: Int, newPid: Int) {
        let request = try JSONSerialization.data(withJSONObject: [
            "cmd": "session.restart", "target": sessionID, "args": ["command": command, "paneID": paneID],
        ])
        let response = try sendCommand(String(decoding: request, as: UTF8.self))
        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let receipt = try XCTUnwrap(result["restart"] as? [String: Any])
        XCTAssertEqual(receipt["paneID"] as? String, paneID)
        return (try XCTUnwrap(receipt["oldPid"] as? Int), try XCTUnwrap(receipt["newPid"] as? Int))
    }

    private func paneText(_ sessionID: String) -> String {
        let response = try? sendCommand(#"{"cmd":"session.text","target":"\#(sessionID)","args":{"pane":"left"}}"#)
        return ((response?["result"] as? [String: Any])?["text"] as? String) ?? ""
    }

    private func heldText(_ sessionID: String) throws -> String {
        var text = ""
        let exited = poll(until: {
            let response = try? self.sendCommand(#"{"cmd":"session.text","target":"\#(sessionID)","args":{"all":true}}"#)
            text = ((response?["result"] as? [String: Any])?["text"] as? String) ?? ""
            return text.contains("Process exited")
        }(), timeout: 20)
        XCTAssertTrue(exited, "the --wait pane should reach the exit prompt, got: \(text)")
        return text
    }

    private func paneID(_ sessionID: String, kind: String) -> String? {
        guard let response = try? sendCommand(#"{"cmd":"tree"}"#),
              let tree = (response["result"] as? [String: Any])?["tree"] as? [String: Any],
              let workspaces = tree["workspaces"] as? [[String: Any]],
              let session = workspaces.flatMap({ $0["sessions"] as? [[String: Any]] ?? [] })
                  .first(where: { ($0["id"] as? String)?.caseInsensitiveCompare(sessionID) == .orderedSame }),
              let surfaces = session["surfaces"] as? [[String: Any]] else { return nil }
        return surfaces.first { $0["kind"] as? String == kind }?["paneID"] as? String
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
}
