import Darwin
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ZmxDaemonForegroundTests: XCTestCase {
    func testAMissingSocketIsAbsent() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(ZmxDaemonForeground.probe(directory: directory.path, pane: UUID()), .absent)
    }

    func testAFileAtTheDaemonNameWithNoListenerIsUnknown() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pane = UUID()
        try Data().write(to: directory.appendingPathComponent(ZmxSupport.daemonName(for: pane)))

        XCTAssertEqual(ZmxDaemonForeground.probe(directory: directory.path, pane: pane), .unknown)
    }

    func testALookupFailingForAnotherReasonIsUnknown() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("not-a-directory")
        try Data().write(to: file)

        XCTAssertEqual(ZmxDaemonForeground.probe(directory: file.path, pane: UUID()), .unknown)
    }

    func testARunningDaemonReportsItsLeader() throws {
        let state = try makeDirectory()
        let daemons = LiveDaemons(stateDirectory: state)
        defer {
            daemons.stop()
            try? FileManager.default.removeItem(at: state)
        }
        let pane = UUID()
        try daemons.start(paneID: pane, command: ["/bin/sleep", "603"])

        var leader: pid_t?
        var probe = DaemonProbe.absent
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            leader = try? daemons.leaderPID(paneID: pane)
            probe = ZmxDaemonForeground.probe(directory: daemons.socketDirectory, pane: pane)
            if let leader, probe == .running(leader: leader) { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        let expected = try XCTUnwrap(leader)
        XCTAssertEqual(probe, .running(leader: expected))
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
