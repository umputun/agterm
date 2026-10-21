import XCTest
@testable import agterm
import agtermCore

@MainActor
final class RemotePageChannelTests: XCTestCase {
    private var launcher: FakePageLauncher!
    private var channels: [RemotePageChannel] = []

    override func setUp() async throws {
        try await super.setUp()
        launcher = FakePageLauncher(files: [
            "/docs/index.html": ("text/html", Data("<p>index</p>".utf8)),
            "/docs/big.bin": ("application/octet-stream", Data((0..<300 * 1024).map { UInt8($0 % 251) })),
        ])
    }

    override func tearDown() async throws {
        for channel in channels { channel.close("test over") }
        channels.removeAll()
        launcher.closeAll()
        try await super.tearDown()
    }

    private func channel() -> RemotePageChannel {
        let channel = RemotePageChannel()
        channels.append(channel)
        channel.start(["ssh", "-T", "origin", "page-serve", "tok"], launcher: launcher)
        return channel
    }

    private final class Marker {}

    private var origin: FakePageOrigin { launcher.origins[0] }

    private func read(_ resource: HtmlPageResource) async throws -> Data {
        var data = Data()
        for try await chunk in resource.chunks { data.append(chunk) }
        return data
    }

    private func untilOrigin(_ condition: ([PageServeFrame]) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(origin.received) {
            guard Date() < deadline else { return XCTFail("the origin never received the expected frames: \(origin.received)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func resources(_ frames: [PageServeFrame]) -> [Int] {
        frames.compactMap { if case .resource(let id, _) = $0 { id } else { nil } }
    }

    private func cancels(_ frames: [PageServeFrame]) -> [Int] {
        frames.compactMap { if case .cancel(let id) = $0 { id } else { nil } }
    }

    func testAFetchStreamsTheFileInOrder() async throws {
        let channel = channel()

        let resource = try await channel.fetch("/docs/big.bin", current: { true })
        let data = try await read(resource)

        XCTAssertEqual(resource.mimeType, "application/octet-stream")
        XCTAssertEqual(data, launcher.files["/docs/big.bin"]?.1)
        XCTAssertEqual(resources(origin.received), [1])
    }

    func testAStalledConsumerStopsTheReaderUntilItPulls() async throws {
        let channel = channel()
        let resource = try await channel.fetch("/docs/big.bin", current: { true })

        try await Task.sleep(for: .milliseconds(500))
        let stalled = origin.written
        XCTAssertLessThan(stalled, 300, "the reader must stop taking chunks the page has not consumed")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(origin.written, stalled)

        let data = try await read(resource)
        XCTAssertEqual(data.count, 300 * 1024)
    }

    func testCancellingAStalledTransferFreesItsBufferedChunks() async throws {
        let channel = channel()
        let consumer = Task { () -> Error? in
            do {
                let resource = try await channel.fetch("/docs/big.bin", current: { true })
                try await Task.sleep(for: .seconds(30))
                _ = try await read(resource)
                return nil
            } catch {
                return error
            }
        }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertLessThan(origin.written, 300)

        consumer.cancel()
        _ = await consumer.value

        let next = try await channel.fetch("/docs/index.html", current: { true })
        let data = try await read(next)
        XCTAssertEqual(data, Data("<p>index</p>".utf8))
        XCTAssertEqual(cancels(origin.received), [1])
    }

    func testAResourceDroppedUnreadCancelsItsTransfer() async throws {
        let channel = channel()
        _ = try await channel.fetch("/docs/big.bin", current: { true })

        try await untilOrigin { self.cancels($0) == [1] }
        let next = try await channel.fetch("/docs/index.html", current: { true })
        let data = try await read(next)
        XCTAssertEqual(data, Data("<p>index</p>".utf8))
    }

    func testCancelBeforeHeadSendsCancelAndKeepsTheSlotUntilTheOriginEndsIt() async throws {
        launcher.held = ["/docs/held.bin"]
        launcher.holdCancels = true
        let channel = channel()
        let limit = ControlServer.pageServeResourceLimit
        var waiting: [Task<Void, Error>] = []
        for _ in 0..<limit {
            waiting.append(Task { _ = try await channel.fetch("/docs/held.bin", current: { true }) })
        }
        try await untilOrigin { self.resources($0).count == limit }

        waiting[0].cancel()
        do {
            try await waiting[0].value
            XCTFail("a cancelled fetch must throw")
        } catch is CancellationError {}
        try await untilOrigin { self.cancels($0) == [1] }

        let next = Task { try await self.read(try await channel.fetch("/docs/index.html", current: { true })) }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(resources(origin.received).count, limit)

        origin.answerCancels()
        let data = try await next.value
        XCTAssertEqual(data, Data("<p>index</p>".utf8))

        for _ in 0..<2 {
            waiting.append(Task { _ = try await channel.fetch("/docs/held.bin", current: { true }) })
        }
        try await untilOrigin { self.resources($0).count >= limit + 2 }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(resources(origin.received).count, limit + 2)
        for task in waiting { task.cancel() }
    }

    func testCancelWhileQueuedHereSendsNothing() async throws {
        launcher.held = ["/docs/held.bin"]
        let channel = channel()
        let limit = ControlServer.pageServeResourceLimit
        var admitted: [Task<Void, Error>] = []
        for _ in 0..<limit {
            admitted.append(Task { _ = try await channel.fetch("/docs/held.bin", current: { true }) })
        }
        try await untilOrigin { self.resources($0).count == limit }
        let queued = Task { _ = try await channel.fetch("/docs/index.html", current: { true }) }
        try await Task.sleep(for: .milliseconds(200))

        queued.cancel()
        do {
            try await queued.value
            XCTFail("a cancelled fetch must throw")
        } catch is CancellationError {}

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(resources(origin.received).count, limit)
        XCTAssertTrue(cancels(origin.received).isEmpty)
        for task in admitted { task.cancel() }
    }

    func testClosingFailsPendingHeadAndBridgeCalls() async throws {
        launcher.held = ["/docs/held.bin"]
        launcher.reply = nil
        let channel = channel()
        let fetch = Task { _ = try await channel.fetch("/docs/held.bin", current: { true }) }
        let bridge = Task { _ = try await channel.bridge(Data(#"{"cmd":"tree"}"#.utf8)) }
        try await untilOrigin { frames in frames.count == 2 }

        channel.close("test")

        for task in [fetch, bridge] {
            do {
                try await task.value
                XCTFail("a pending call must fail when the channel closes")
            } catch {
                XCTAssertEqual(error as? RemotePageChannel.Failure, .closed)
            }
        }
    }

    func testAnAnswerForALoadThePageLeftIsDropped() async throws {
        let channel = channel()
        var current = true
        let resource = try await channel.fetch("/docs/big.bin", current: { current })
        current = false

        do {
            _ = try await read(resource)
            XCTFail("a stale answer must not complete")
        } catch {}
        try await untilOrigin { self.cancels($0) == [1] }
    }

    func testABridgeReplyComesBackAsTheOriginSentIt() async throws {
        launcher.reply = #"{"ok":true,"result":{"extra":{"nested":"kept"}}}"#
        let channel = channel()

        let reply = try await channel.bridge(Data(#"{"cmd":"tree"}"#.utf8))

        XCTAssertEqual(reply, #"{"ok":true,"result":{"extra":{"nested":"kept"}}}"#)
        let (value, error) = HtmlOverlayBridge.reply(raw: reply)
        XCTAssertNil(error)
        XCTAssertEqual(((value as? [String: Any])?["extra"] as? [String: Any])?["nested"] as? String, "kept")
    }

    func testFailuresBeforeHeadKeepTheChannelUsable() async throws {
        let channel = channel()

        for _ in 0..<(ControlServer.pageServeResourceLimit * 2) {
            weak var released: Marker?
            do {
                let marker = Marker()
                released = marker
                _ = try await channel.fetch("/docs/missing.html", current: { _ = marker; return true })
                XCTFail("a missing file must fail")
            } catch {
                XCTAssertEqual(error as? RemotePageChannel.Failure, .refused("no such file"))
            }
            XCTAssertNil(released, "a failed request keeps nothing")
        }

        let next = try await channel.fetch("/docs/index.html", current: { true })
        let data = try await read(next)
        XCTAssertEqual(data, Data("<p>index</p>".utf8))
    }

    func testAnOversizedBridgeRequestFailsAloneAndTheChannelStays() async throws {
        launcher.reply = #"{"ok":true,"result":{"text":"ok"}}"#
        let channel = channel()
        let oversized = Data(#"{"cmd":"notify","args":{"body":"\#(String(repeating: "x", count: PageServeCodec.maxFrameBytes))"}}"#.utf8)

        do {
            _ = try await channel.bridge(oversized)
            XCTFail("an oversized request must fail")
        } catch {
            XCTAssertEqual(error as? RemotePageChannel.Failure, .tooLarge)
        }

        let reply = try await channel.bridge(Data(#"{"cmd":"tree"}"#.utf8))
        XCTAssertEqual(reply, #"{"ok":true,"result":{"text":"ok"}}"#)
        XCTAssertFalse(launcher.helpers[0].terminated)
    }

    func testHelperExitClosesTheChannelOnce() async throws {
        let channel = channel()
        var closes = 0
        channel.onClose = { closes += 1 }

        launcher.helpers[0].exit()
        launcher.helpers[0].exit()

        XCTAssertEqual(closes, 1)
        XCTAssertTrue(launcher.helpers[0].terminated)
    }
}

extension RemotePageChannel.Failure: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.closed, .closed): return true
        case (.tooLarge, .tooLarge): return true
        case (.refused(let left), .refused(let right)): return left == right
        default: return false
        }
    }
}
