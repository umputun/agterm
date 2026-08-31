import Foundation
import XCTest
import agtermCore

@MainActor
final class ZmxLiveUITests: ControlAPITestCase {
    override var seededSettings: [String: Any]? { ["restoreMode": "live"] }
    override var enablesZmxForUITest: Bool { true }

    override func tearDown() async throws {
        app?.terminate()
        var cleanupError: Error?
        do { try killTestDaemons() } catch { cleanupError = error }
        try await super.tearDown()
        if let cleanupError { throw cleanupError }
    }

    func testBundledZmxBacksPrimaryAndSplitAndTypesInitialCommandOnce() throws {
        let sessionID = try activeSessionID()
        XCTAssertTrue(poll(until: self.isBacked(sessionID, expectedPanes: ["left"]), timeout: 20),
                      "the primary pane should report real zmx backing")

        let response = try sendCommand(
            #"{"cmd":"session.split","target":"\#(sessionID)","args":{"mode":"on"}}"#)
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertTrue(poll(until: self.isBacked(sessionID, expectedPanes: ["left", "right"]), timeout: 20),
                      "both panes and the session aggregate should report zmx backing")

        let marker = stateDir.appendingPathComponent("initial-input.txt")
        let request = try JSONSerialization.data(withJSONObject: [
            "cmd": "session.new",
            "args": ["command": "printf x >> \(marker.path)"],
        ])
        let created = try sendCommand(String(decoding: request, as: UTF8.self))
        XCTAssertEqual(created["ok"] as? Bool, true)
        XCTAssertTrue(poll(until: (try? String(contentsOf: marker, encoding: .utf8)) == "x", timeout: 20),
                      "initial_input should reach the daemon shell")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "x",
                       "initial_input must be delivered exactly once")
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

    private func killTestDaemons() throws {
        guard let stateDir else { return }
        let zmxDir = ZmxSupport.socketDirectory(forStateDirectory: stateDir.path)
        let names = try runZmx(["ls", "--short"], directory: zmxDir)
            .split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        guard !names.isEmpty else { return }
        _ = try runZmx(["kill"] + names + ["--force"], directory: zmxDir)
    }

    private func runZmx(_ arguments: [String], directory: String) throws -> String {
        let process = Process()
        process.executableURL = try zmxURL()
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["ZMX_DIR"] = directory
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ZmxLiveUITests", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: text])
        }
        return text
    }

    private func zmxURL() throws -> URL {
        if let products = ProcessInfo.processInfo.environment["BUILT_PRODUCTS_DIR"] {
            return URL(fileURLWithPath: products).appendingPathComponent("agterm.app/Contents/MacOS/zmx")
        }
        var directory = Bundle(for: type(of: self)).bundleURL
        while directory.path != "/", directory.lastPathComponent != "Debug" {
            directory.deleteLastPathComponent()
        }
        let url = directory.appendingPathComponent("agterm.app/Contents/MacOS/zmx")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw NSError(domain: "ZmxLiveUITests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "bundled zmx not found at \(url.path)"])
        }
        return url
    }
}
