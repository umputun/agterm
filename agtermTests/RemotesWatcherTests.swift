import XCTest
@testable import agterm
import agtermCore

@MainActor
final class RemotesWatcherTests: XCTestCase {
    private var dir: URL!
    private var reported: [Int] = []

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-remotes-watcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        reported = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        try await super.tearDown()
    }

    private var file: URL { dir.appendingPathComponent("remotes.conf") }

    private func makeWatcher(_ url: URL? = nil) -> RemotesWatcher {
        RemotesWatcher(url: url ?? file) { [weak self] in self?.reported.append($0) }
    }

    private func write(_ text: String, to url: URL? = nil) throws {
        try text.write(to: url ?? file, atomically: true, encoding: .utf8)
    }

    private func wait(_ what: String, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), what)
    }

    func testABrokenFileAtStartIsCountedButNotReported() throws {
        try write("studio\n-bad\n")

        let watcher = makeWatcher()

        XCTAssertEqual(watcher.entries.map(\.destination), ["studio"])
        XCTAssertEqual(watcher.issueCount, 1)
        XCTAssertTrue(reported.isEmpty)
    }

    func testOneReportPerCleanToBrokenEpisode() async throws {
        try write("studio\n")
        let watcher = makeWatcher()
        XCTAssertEqual(watcher.issueCount, 0)

        try write("studio\n-bad\n")
        await wait("the first bad line is counted") { watcher.issueCount == 1 }
        XCTAssertEqual(reported, [1])

        try write("studio\n-bad\n-worse\nstudio dup\n")
        await wait("more bad lines are counted") { watcher.issueCount == 3 }
        try write("studio\n-bad\n")
        await wait("fewer bad lines are counted") { watcher.issueCount == 1 }
        XCTAssertEqual(reported, [1], "a file that stays broken is not reported again")

        try write("studio\n")
        await wait("the file is clean") { watcher.issueCount == 0 }
        try write("-bad\n-worse\n")
        await wait("a new episode is counted") { watcher.issueCount == 2 }
        XCTAssertEqual(reported, [1, 2])
    }

    func testAFileThatCannotBeReadIsOneIssueAndNoEntries() async throws {
        try write("studio\n")
        let watcher = makeWatcher()

        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)

        await wait("the unreadable file is counted") { watcher.issueCount == 1 }
        XCTAssertTrue(watcher.entries.isEmpty)
        XCTAssertEqual(reported, [1])
    }

    func testASymlinkWhoseTargetAppearsLaterIsFollowed() async throws {
        let elsewhere = dir.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let target = elsewhere.appendingPathComponent("real.conf")
        try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: "elsewhere/real.conf")
        let watcher = makeWatcher()
        XCTAssertTrue(watcher.entries.isEmpty, "a dangling link lists nothing")

        try write("studio\n", to: target)

        await wait("the target created later is read") { watcher.entries.map(\.destination) == ["studio"] }
    }

    func testASymlinkWhoseTargetIsDeletedThenRecreatedIsFollowed() async throws {
        let elsewhere = dir.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let target = elsewhere.appendingPathComponent("real.conf")
        try write("studio\n", to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        let watcher = makeWatcher()
        XCTAssertEqual(watcher.entries.map(\.destination), ["studio"])

        try FileManager.default.removeItem(at: target)
        await wait("the deleted target lists nothing") { watcher.entries.isEmpty }
        let handle = FileManager.default.createFile(atPath: target.path, contents: Data("mini\n".utf8))
        XCTAssertTrue(handle)

        await wait("the recreated target is read") { watcher.entries.map(\.destination) == ["mini"] }
    }
}
