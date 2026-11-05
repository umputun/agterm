import os
import WebKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class LogFollowerTests: XCTestCase {
    private var directory: URL!
    private var store: AppStore!
    private var session: Session!
    private var log: URL!
    private var overlay: HtmlOverlay!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-log-follower-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = AppStore(persistence: PersistenceStore(directory: directory.appendingPathComponent("state")))
        let workspace = store.addWorkspace(name: "work")
        session = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        log = directory.appendingPathComponent("app.log")
        try write("a\n")
        overlay = HtmlOverlay(source: .text(path: log.path, line: nil), textLog: TextLog(tail: 50, follow: true))
        XCTAssertNil(store.openHtmlOverlay(session.id, pane: nil, overlay: overlay, sizePercent: nil))
    }

    override func tearDown() async throws {
        store.closeSession(session.id)
        try? FileManager.default.removeItem(at: directory)
    }

    private func follower(following: Bool = false, interval: Duration = .seconds(60),
                          read: @escaping LogFollower.Reader = { TextProbe.loadLog(path: $0, tail: $1, unchangedFrom: $2) }) -> LogFollower {
        LogFollower(path: log.path, log: TextLog(tail: 50, follow: following), following: following, pageID: overlay.id,
                    store: store, webView: nil, world: .defaultClient, interval: interval, read: read)
    }

    private func write(_ text: String) throws {
        try Data(text.utf8).write(to: log)
    }

    private func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private var report: TextLogReport? { session.htmlOverlay?.logState?.report }

    func testAnAppendIsPickedUpAndReported() async throws {
        let follower = follower()
        await follower.tick()
        try append("b\n")

        await follower.tick()

        XCTAssertEqual(follower.snapshot?.text, "a\nb\n")
        XCTAssertEqual(report, TextLogReport(lines: 2))
    }

    func testACopyTruncatedLogShowsWhatFollowsTheTruncation() async throws {
        let follower = follower()
        try write("a\nb\nc\n")
        await follower.tick()
        let handle = try FileHandle(forWritingTo: log)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("d\n".utf8))
        try handle.close()

        await follower.tick()

        XCTAssertEqual(follower.snapshot?.text, "d\n")
    }

    func testARotatedLogIsFollowedByItsNewFile() async throws {
        let follower = follower()
        await follower.tick()
        try FileManager.default.moveItem(at: log, to: directory.appendingPathComponent("app.log.1"))
        try write("fresh\n")

        await follower.tick()

        XCTAssertEqual(follower.snapshot?.text, "fresh\n")
    }

    func testAMissingFileWaitsKeepingTheLastTextUntilItReappears() async throws {
        let follower = follower()
        await follower.tick()
        try FileManager.default.removeItem(at: log)

        await follower.tick()
        XCTAssertEqual(follower.snapshot?.text, "a\n")
        XCTAssertEqual(report, TextLogReport(lines: 1, waiting: true))

        try write("back\n")
        await follower.tick()
        XCTAssertEqual(follower.snapshot?.text, "back\n")
        XCTAssertEqual(report, TextLogReport(lines: 1))
    }

    func testBinaryDataKeepsTheLastTextAndMarksItUnreadable() async throws {
        let follower = follower()
        await follower.tick()
        try append("b\u{0}\n")

        await follower.tick()

        XCTAssertEqual(follower.snapshot?.text, "a\n")
        XCTAssertEqual(report, TextLogReport(lines: 1, unreadable: true))
    }

    func testAPauseDropsAReadInFlight() async throws {
        let gate = DispatchSemaphore(value: 0)
        let follower = follower(following: true) { path, tail, stamp in
            gate.wait()
            return TextProbe.loadLog(path: path, tail: tail, unchangedFrom: stamp)
        }
        follower.stop()
        try append("b\n")
        let tick = Task { await follower.tick() }
        try await Task.sleep(for: .milliseconds(50))

        follower.setFollowing(false)
        gate.signal()
        await tick.value

        XCTAssertNil(follower.snapshot)
    }

    func testAUserScrollPauseDropsAReadInFlightBeforeTheModelComesBack() async throws {
        let gate = DispatchSemaphore(value: 0)
        let follower = follower(following: true) { path, tail, stamp in
            gate.wait()
            return TextProbe.loadLog(path: path, tail: tail, unchangedFrom: stamp)
        }
        follower.stop()
        try append("b\n")
        let tick = Task { await follower.tick() }
        try await Task.sleep(for: .milliseconds(50))

        follower.scrolled(following: false, top: 80)
        gate.signal()
        await tick.value

        XCTAssertNil(follower.snapshot)
        XCTAssertFalse(follower.following)
        XCTAssertEqual(session.htmlOverlay?.logState?.following, false)
    }

    func testAnUnchangedFileIsCheckedWithoutReadingIt() async throws {
        let skipped = OSAllocatedUnfairLock(initialState: 0)
        let follower = follower { path, tail, stamp in
            let result = TextProbe.loadLog(path: path, tail: tail, unchangedFrom: stamp)
            if case .success(nil) = result { skipped.withLock { $0 += 1 } }
            return result
        }
        await follower.tick()

        await follower.tick()
        await follower.tick()

        XCTAssertEqual(skipped.withLock { $0 }, 2)
        XCTAssertEqual(follower.snapshot?.text, "a\n")
    }

    func testARebuildHoldsTicksUntilTheRendererIsReady() async throws {
        let follower = follower()
        await follower.tick()
        follower.loadDocument(fresh: false)
        try append("b\n")

        await follower.tick()
        XCTAssertEqual(follower.snapshot?.text, "a\n")

        follower.rendererReady()
        await follower.tick()
        XCTAssertEqual(follower.snapshot?.text, "a\nb\n")
    }

    func testFollowOffBeforeTheFirstDocumentStillBuildsIt() async throws {
        let follower = follower(following: true)
        follower.stop()

        follower.loadDocument(fresh: true)
        follower.setFollowing(false)
        let deadline = Date().addingTimeInterval(5)
        while follower.snapshot == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }

        XCTAssertEqual(follower.snapshot?.text, "a\n")
    }

    func testAPageThatLeftItsSlotReadsNothing() async throws {
        let follower = follower()
        await follower.tick()
        XCTAssertTrue(store.closeOverlay(session.id))
        try append("b\n")

        await follower.tick()

        XCTAssertEqual(follower.snapshot?.text, "a\n")
    }

    func testStopEndsTheTicks() async throws {
        let follower = follower(following: true, interval: .milliseconds(20))
        follower.onScreen = false
        follower.onScreen = true
        let deadline = Date().addingTimeInterval(5)
        while follower.snapshot == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(follower.snapshot?.text, "a\n")

        follower.stop()
        try append("b\n")
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(follower.snapshot?.text, "a\n")
    }

    func testOffScreenStopsTheTicksAndComingBackReadsAtOnce() async throws {
        let follower = follower(following: true, interval: .seconds(60))
        follower.onScreen = false
        try append("b\n")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(follower.snapshot)

        follower.onScreen = true
        let deadline = Date().addingTimeInterval(5)
        while follower.snapshot == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }

        XCTAssertEqual(follower.snapshot?.text, "a\nb\n")
    }

    func testAScrollThatChangesFollowingReachesTheModel() {
        let follower = follower(following: true)
        follower.stop()

        follower.scrolled(following: false, top: 120)

        XCTAssertEqual(follower.anchor, 120)
        XCTAssertEqual(session.htmlOverlay?.logState?.following, false)
    }
}
