import XCTest
@testable import agterm

@MainActor
final class LiveResetRelauncherTests: XCTestCase {
    private var dir: URL!
    private var record: URL!
    private var fakeOpen: URL!
    private var oldApp: Process?

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-relauncher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        record = dir.appendingPathComponent("record")
        fakeOpen = dir.appendingPathComponent("fake-open.sh")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(record.path)'\n".write(to: fakeOpen, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOpen.path)
    }

    override func tearDown() async throws {
        if let oldApp, oldApp.isRunning { oldApp.terminate() }
        try? FileManager.default.removeItem(at: dir)
        try await super.tearDown()
    }

    private func startOldApp(seconds: String) throws -> pid_t {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = [seconds]
        try process.run()
        oldApp = process
        return process.processIdentifier
    }

    private func recordedArguments(within seconds: TimeInterval) -> [String]? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let text = try? String(contentsOf: record, encoding: .utf8), !text.isEmpty {
                return text.split(separator: "\n").map(String.init)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return nil
    }

    func testLaunchWaitsForChildExit() throws {
        let pid = try startOldApp(seconds: "1")
        let relauncher = LiveResetRelauncher(open: fakeOpen.path)

        XCTAssertTrue(relauncher.spawn(pid: pid, bundle: URL(fileURLWithPath: "/Applications/Agterm.app"), stateDirectory: "/tmp/state"))

        XCTAssertNil(recordedArguments(within: 0.3), "the launch must wait for the old pid to exit")
        oldApp?.waitUntilExit()
        XCTAssertEqual(recordedArguments(within: 3), ["-n", "/Applications/Agterm.app", "--env", "AGTERM_STATE_DIR=/tmp/state"])
    }

    func testLaunchWithoutAStateDirectoryPassesNoEnv() throws {
        let pid = try startOldApp(seconds: "0.2")
        let relauncher = LiveResetRelauncher(open: fakeOpen.path)

        XCTAssertTrue(relauncher.spawn(pid: pid, bundle: URL(fileURLWithPath: "/Applications/Agterm.app"), stateDirectory: nil))

        XCTAssertEqual(recordedArguments(within: 3), ["-n", "/Applications/Agterm.app"])
    }

    func testNoLaunchOnTimeout() throws {
        let pid = try startOldApp(seconds: "5")
        let relauncher = LiveResetRelauncher(open: fakeOpen.path, maxWaits: 2)

        XCTAssertTrue(relauncher.spawn(pid: pid, bundle: URL(fileURLWithPath: "/Applications/Agterm.app"), stateDirectory: nil))

        XCTAssertNil(recordedArguments(within: 1.5))
        oldApp?.terminate()
        oldApp?.waitUntilExit()
        XCTAssertNil(recordedArguments(within: 1), "a waiter that gave up must not launch once the pid finally exits")
    }

    func testSpawnFailureIsReported() {
        let relauncher = LiveResetRelauncher(shell: dir.appendingPathComponent("missing-shell").path, open: fakeOpen.path)
        XCTAssertFalse(relauncher.spawn(pid: getpid(), bundle: URL(fileURLWithPath: "/Applications/Agterm.app"), stateDirectory: nil))
    }
}
