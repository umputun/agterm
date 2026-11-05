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

    // regression: a log whose end turned binary lost its stamp and was read in full on every tick
    func testAnUnchangedBinaryEndIsCheckedWithoutReadingIt() async throws {
        let skipped = OSAllocatedUnfairLock(initialState: 0)
        let follower = follower { path, tail, stamp in
            let result = TextProbe.loadLog(path: path, tail: tail, unchangedFrom: stamp)
            if case .success(nil) = result { skipped.withLock { $0 += 1 } }
            return result
        }
        await follower.tick()
        try append("b\u{0}\n")
        await follower.tick()

        await follower.tick()

        XCTAssertEqual(skipped.withLock { $0 }, 1)
        XCTAssertEqual(follower.snapshot?.text, "a\n")
        XCTAssertEqual(report, TextLogReport(lines: 1, unreadable: true))
    }

    // regression: a pause from control kept the offset of an earlier user scroll, so a rebuild jumped there
    func testAPauseFromTheModelDropsAnEarlierScrollOffset() {
        let follower = follower(following: true)
        follower.stop()
        follower.scrolled(following: false, top: 120)
        follower.scrolled(following: true, top: 900)

        follower.setFollowing(false)

        XCTAssertNil(follower.anchor)
    }

    func testAPauseByScrollKeepsItsOffsetWhenTheModelEchoesIt() {
        let follower = follower(following: true)
        follower.stop()

        follower.scrolled(following: false, top: 320)
        follower.setFollowing(false)

        XCTAssertEqual(follower.anchor, 320)
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

    private func stamp(inode: UInt64 = 7, size: Int) -> BoundedFile.FileStamp {
        BoundedFile.FileStamp(device: 1, inode: inode, size: size, modifiedSeconds: size, modifiedNanoseconds: 0)
    }

    func testAShiftCountsTheLinesThatLeftTheFrontOfOneFile() {
        let old = LogTail.Snapshot(text: "a\nb\nc\n", lines: 3, clipped: false, startOffset: 10)
        let appended = LogTail.Snapshot(text: "a\nb\nc\nd\n", lines: 4, clipped: false, startOffset: 10)
        let evicted = LogTail.Snapshot(text: "c\nd\ne\n", lines: 3, clipped: false, startOffset: 14)
        let inside = LogTail.Snapshot(text: "\nd\n", lines: 2, clipped: true, startOffset: 15)
        let past = LogTail.Snapshot(text: "x\n", lines: 1, clipped: false, startOffset: 40)

        XCTAssertEqual(LogFollower.shift(from: old, stamp: stamp(size: 16), to: old, stamp: stamp(size: 16)), LogFollower.Shift())
        XCTAssertEqual(LogFollower.shift(from: old, stamp: stamp(size: 16), to: appended, stamp: stamp(size: 18)), LogFollower.Shift())
        XCTAssertEqual(LogFollower.shift(from: old, stamp: stamp(size: 16), to: evicted, stamp: stamp(size: 20)),
                       LogFollower.Shift(dropped: 2))
        XCTAssertEqual(LogFollower.shift(from: old, stamp: stamp(size: 16), to: inside, stamp: stamp(size: 20)),
                       LogFollower.Shift(dropped: 2, cut: true))
        XCTAssertEqual(LogFollower.shift(from: old, stamp: stamp(size: 16), to: past, stamp: stamp(size: 42)),
                       LogFollower.Shift(dropped: 3))
    }

    func testAShiftCountsCRLFAndALoneCRAsOneBreakEach() {
        let lone = LogTail.Snapshot(text: "a\rb\nc\n", lines: 2, clipped: false, startOffset: 0)
        let crlf = LogTail.Snapshot(text: "a\r\nb\n", lines: 2, clipped: false, startOffset: 0)
        let progress = LogTail.Snapshot(text: "a\rb\rc", lines: 1, clipped: false, startOffset: 0)
        let after = { (start: Int) in LogTail.Snapshot(text: "z\n", lines: 1, clipped: false, startOffset: start) }

        XCTAssertEqual(LogFollower.shift(from: lone, stamp: stamp(size: 6), to: after(2), stamp: stamp(size: 8)),
                       LogFollower.Shift(dropped: 1))
        XCTAssertEqual(LogFollower.shift(from: crlf, stamp: stamp(size: 5), to: after(3), stamp: stamp(size: 7)),
                       LogFollower.Shift(dropped: 1))
        XCTAssertEqual(LogFollower.shift(from: crlf, stamp: stamp(size: 5), to: after(2), stamp: stamp(size: 7)),
                       LogFollower.Shift(dropped: 0, cut: true))
        XCTAssertEqual(LogFollower.shift(from: progress, stamp: stamp(size: 5), to: after(9), stamp: stamp(size: 11)),
                       LogFollower.Shift(dropped: 3))
    }

    func testAShiftCallsAnotherFileOrAShrunkOneAReplacement() {
        let old = LogTail.Snapshot(text: "a\nb\n", lines: 2, clipped: false, startOffset: 10)
        let new = LogTail.Snapshot(text: "c\n", lines: 1, clipped: false, startOffset: 0)
        let later = LogTail.Snapshot(text: "b\nc\n", lines: 2, clipped: false, startOffset: 12)

        XCTAssertEqual(LogFollower.shift(from: old, stamp: stamp(size: 14), to: later, stamp: stamp(inode: 8, size: 16)),
                       LogFollower.Shift(replaced: true))
        XCTAssertEqual(LogFollower.shift(from: old, stamp: stamp(size: 14), to: new, stamp: stamp(size: 2)),
                       LogFollower.Shift(replaced: true))
        XCTAssertEqual(LogFollower.shift(from: old, stamp: nil, to: later, stamp: stamp(size: 16)), LogFollower.Shift(replaced: true))
    }

    func testAScrollThatChangesFollowingReachesTheModel() {
        let follower = follower(following: true)
        follower.stop()

        follower.scrolled(following: false, top: 120)

        XCTAssertEqual(follower.anchor, 120)
        XCTAssertEqual(session.htmlOverlay?.logState?.following, false)
    }
}
