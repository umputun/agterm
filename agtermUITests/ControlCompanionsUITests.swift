import XCTest

@MainActor
final class ControlCompanionsUITests: ControlAPITestCase {
    func testAGroupIsCreatedReadBackFoldedMovedAndClosedThroughAgtermctl() throws {
        let parent = try activeSessionID()
        let companion = try cliOutput(["session", "new", "--parent", parent, "--name", "logs", "--no-select"])
        let sibling = try cliOutput(["session", "new", "--parent", companion, "--no-select"])

        XCTAssertEqual(try sessionNode(id: companion)["parent"] as? String, parent)
        XCTAssertEqual(try sessionNode(id: sibling)["parent"] as? String, parent, "a companion target means its parent")
        XCTAssertNil(try sessionNode(id: parent)["parent"])

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.collapse","target":"\#(parent)"}"#)["ok"] as? Bool, true)
        XCTAssertEqual(try sessionNode(id: parent)["collapsed"] as? Bool, true)
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.expand","target":"\#(parent)"}"#)["ok"] as? Bool, true)
        XCTAssertNil(try sessionNode(id: parent)["collapsed"])

        let reordered = try sendCommand(#"{"cmd":"session.move","target":"\#(sibling)","args":{"to":"up"}}"#)
        XCTAssertEqual(reordered["ok"] as? Bool, true, "\(reordered)")
        XCTAssertTrue(pollSessionOrder([parent, sibling, companion].compactMap(UUID.init(uuidString:)), timeout: 5))
        let created = try sendCommand(#"{"cmd":"workspace.new","args":{"name":"other"}}"#)
        let other = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String)
        let refused = try sendCommand(#"{"cmd":"session.move","target":"\#(companion)","args":{"workspace":"\#(other)"}}"#)
        XCTAssertEqual(refused["error"] as? String, "a companion moves only among its siblings")
        let moved = try sendCommand(#"{"cmd":"session.move","target":"\#(parent)","args":{"workspace":"\#(other)"}}"#)
        XCTAssertEqual(moved["ok"] as? Bool, true, "\(moved)")
        XCTAssertTrue(pollSessionOrder(inWorkspace: 1, equals: [parent, sibling, companion].compactMap(UUID.init(uuidString:)), timeout: 5))
        XCTAssertEqual(try sessionNode(id: companion)["parent"] as? String, parent)
        XCTAssertEqual(try sessionNode(id: sibling)["parent"] as? String, parent)

        let closed = try sendCommand(#"{"cmd":"session.close","target":"\#(parent)"}"#)
        let result = try XCTUnwrap(closed["result"] as? [String: Any])
        XCTAssertEqual(result["affected"] as? Int, 3)
        XCTAssertEqual(Set(result["closed"] as? [String] ?? []), [parent, companion, sibling])
        XCTAssertNil(try sessionNodeIfPresent(id: companion))
    }

    func testOrdinarySessionCommandsActOnACompanion() throws {
        let parent = try activeSessionID()
        let companion = try cliOutput(["session", "new", "--parent", parent, "--no-select"])
        let marker = stateDir.appendingPathComponent("companion.marker")

        XCTAssertEqual(try typeUntilMarker("echo typed > \(marker.path)", target: companion, file: marker, select: false), "typed")
        for request in [
            #"{"cmd":"session.status","target":"\#(companion)","args":{"status":"blocked"}}"#,
            #"{"cmd":"notify","target":"\#(companion)","args":{"body":"done"}}"#,
            #"{"cmd":"session.split","target":"\#(companion)","args":{"mode":"on"}}"#,
            #"{"cmd":"session.rename","target":"\#(companion)","args":{"name":"side"}}"#,
            #"{"cmd":"session.flag","target":"\#(companion)","args":{"mode":"on"}}"#,
        ] {
            let reply = try sendCommand(request)
            XCTAssertEqual(reply["ok"] as? Bool, true, "\(request): \(reply)")
        }
        let node = try sessionNode(id: companion)
        XCTAssertEqual(node["status"] as? String, "blocked")
        XCTAssertEqual(node["name"] as? String, "side")
        XCTAssertEqual(node["flagged"] as? Bool, true)
        XCTAssertTrue(try pollSplit(companion, timeout: 5))

        let closed = try sendCommand(#"{"cmd":"session.close","target":"\#(companion)"}"#)
        XCTAssertEqual((closed["result"] as? [String: Any])?["closed"] as? [String], [companion])
        XCTAssertNotNil(try sessionNodeIfPresent(id: parent), "closing a companion leaves its parent")
    }

    func testAParentWhoseShellExitsRespawnsAndTakesInput() throws {
        let parent = try activeSessionID()
        _ = try cliOutput(["session", "new", "--parent", parent, "--no-select"])
        let marker = stateDir.appendingPathComponent("respawn.marker")

        XCTAssertEqual(try sendCommand(typeRequest(text: "exit\n", target: parent, select: false))["ok"] as? Bool, true)
        RunLoop.current.run(until: Date().addingTimeInterval(2))

        XCTAssertNotNil(try sessionNodeIfPresent(id: parent), "a parent with companions survives its shell's exit")
        XCTAssertEqual(try typeUntilMarker("echo alive > \(marker.path)", target: parent, file: marker, select: false), "alive")
    }

    func testACommandParentRespawnsAsAPlainShellInTheDirectoryItMovedTo() throws {
        let created = try sendCommand(#"{"cmd":"session.new","args":{"command":"/bin/zsh -l"}}"#)
        let parent = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String)
        _ = try cliOutput(["session", "new", "--parent", parent, "--no-select"])
        let moved = stateDir.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        let ready = stateDir.appendingPathComponent("ready.marker")
        XCTAssertNotNil(try typeUntilMarker("cd \(moved.path) && pwd > \(ready.path)", target: parent, file: ready, select: false))

        XCTAssertEqual(try sendCommand(typeRequest(text: "exit\n", target: parent, select: false))["ok"] as? Bool, true)
        RunLoop.current.run(until: Date().addingTimeInterval(2))

        let node = try XCTUnwrap(try sessionNodeIfPresent(id: parent))
        XCTAssertNil(node["foreground"], "the respawned pane runs a plain shell, not the creation command")
        let marker = stateDir.appendingPathComponent("cwd.marker")
        let cwd = try XCTUnwrap(try typeUntilMarker("pwd > \(marker.path)", target: parent, file: marker, select: false))
        XCTAssertTrue(cwd.hasSuffix("/moved"), "the plain shell starts where the command's shell had moved: \(cwd)")
    }

    private func cliOutput(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("agterm.app/Contents/MacOS/agtermctl")
        process.arguments = arguments + ["--socket", socketPath]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(process.terminationStatus, 0, text)
        return text
    }
}
