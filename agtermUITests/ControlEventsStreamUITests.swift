import XCTest

/// End-to-end coverage for the `events.stream` push transport: the real app, the real `agtermctl
/// events`, and an event arriving on the open connection without the CLI asking again.
@MainActor
final class ControlEventsStreamUITests: ControlAPITestCase {
    func testEventsStreamPushesAFramedEventToTheCLI() throws {
        let cli = Process()
        cli.executableURL = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("agterm.app/Contents/MacOS/agtermctl")
        cli.arguments = ["events", "--json", "--socket", socketPath]
        cli.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("AGTERM_") }
        let out = Pipe()
        cli.standardOutput = out
        let err = Pipe()
        cli.standardError = err
        try cli.run()

        let lines = LineCollector()
        out.fileHandleForReading.readabilityHandler = { handle in
            lines.append(handle.availableData)
            if !cli.isRunning { handle.readabilityHandler = nil }
        }
        let errors = LineCollector()
        err.fileHandleForReading.readabilityHandler = { handle in
            errors.append(handle.availableData)
        }
        defer {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            if cli.isRunning { cli.terminate() }
            cli.waitUntilExit()
        }

        // let the CLI's stream connect and anchor before the event fires: a from-now anchor
        // deliberately replays nothing, so an event landing before it is opened is invisible
        Thread.sleep(forTimeInterval: 1.5)

        let seeded = try activeSessionID()
        let set = try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"blocked"}}"#)
        XCTAssertEqual(set["ok"] as? Bool, true, "session.status blocked should succeed: \(set)")

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !lines.hasLine(containing: "\"kind\":\"status\"") {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(lines.hasLine(containing: "\"kind\":\"status\""),
                      "the status event should reach the CLI as one framed line; "
                          + "stdout: \(lines.joined) stderr: \(errors.joined)")
    }
}

/// Accumulates a CLI's stdout into complete newline-delimited lines for an assertion.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var complete: [String] = []

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            complete.append(line)
        }
        lock.unlock()
    }

    func hasLine(containing needle: String) -> Bool {
        lock.withLock { complete.contains { $0.contains(needle) } }
    }

    var joined: String {
        lock.withLock { complete.joined(separator: "\n") }
    }
}
