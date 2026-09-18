import XCTest
@testable import agterm

final class ControlStreamOwnerTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storedLines: [Data] = []
        private var storedCloses = 0

        func add(_ line: Data) { lock.withLock { storedLines.append(Data(line)) } }
        func closed() { lock.withLock { storedCloses += 1 } }
        var lines: [String] { lock.withLock { storedLines.map { String(decoding: $0, as: UTF8.self) } } }
        var closes: Int { lock.withLock { storedCloses } }
    }

    private var peer: Int32 = -1

    override func tearDown() {
        if peer >= 0 { close(peer) }
        peer = -1
        super.tearDown()
    }

    private func makeOwner(maxLineBytes: Int = 1024, maxPendingLines: Int = 8,
                           writeTimeoutSeconds: Int = 1) throws -> ControlStreamOwner {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        peer = pair[1]
        var short = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(pair[0], SOL_SOCKET, SO_RCVTIMEO, &short, socklen_t(MemoryLayout<timeval>.size))
        return ControlStreamOwner(descriptor: pair[0],
                                  limits: .init(maxLineBytes: maxLineBytes, maxPendingLines: maxPendingLines,
                                                writeTimeoutSeconds: writeTimeoutSeconds))
    }

    private func start(_ owner: ControlStreamOwner, _ recorder: Recorder) {
        owner.start(onLine: { recorder.add($0) }, onClose: { recorder.closed() })
    }

    private func writeToPeer(_ text: String) {
        let bytes = Array(text.utf8)
        XCTAssertEqual(write(peer, bytes, bytes.count), bytes.count)
    }

    private func readFromPeer(timeout: TimeInterval = 2) -> String {
        var wait = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(peer, &buffer, buffer.count)
        return count > 0 ? String(decoding: buffer[0..<count], as: UTF8.self) : ""
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    func testLinesTravelBothWays() throws {
        let owner = try makeOwner()
        let recorder = Recorder()
        start(owner, recorder)

        writeToPeer("one\ntwo\nthr")
        writeToPeer("ee\n")
        XCTAssertTrue(owner.send(Data("reply\n".utf8)))

        XCTAssertTrue(waitUntil { recorder.lines.count == 3 })
        XCTAssertEqual(recorder.lines, ["one", "two", "three"])
        XCTAssertEqual(readFromPeer(), "reply\n")
        owner.shutdown()
    }

    func testAnIdleStreamOutlivesTheRequestReceiveTimeout() throws {
        let owner = try makeOwner()
        let recorder = Recorder()
        start(owner, recorder)

        Thread.sleep(forTimeInterval: 0.4)

        XCTAssertEqual(recorder.closes, 0)
        XCTAssertTrue(owner.send(Data("still here\n".utf8)))
        XCTAssertEqual(readFromPeer(), "still here\n")
        owner.shutdown()
    }

    func testAPeerThatStopsReadingIsDroppedWithoutBlockingTheSender() throws {
        let owner = try makeOwner(maxPendingLines: 4, writeTimeoutSeconds: 1)
        let recorder = Recorder()
        start(owner, recorder)
        let line = Data(repeating: UInt8(ascii: "x"), count: 256 * 1024) + Data("\n".utf8)

        let began = Date()
        var refused = false
        for _ in 0..<64 where !refused { refused = !owner.send(line) }

        XCTAssertTrue(refused, "a full queue has to say so")
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.5, "send only queues; it must never wait on the peer")
        XCTAssertTrue(waitUntil(4) { recorder.closes == 1 }, "the blocked write has to time out and close")
    }

    func testThePeerClosingEndsTheStreamOnce() throws {
        let owner = try makeOwner()
        let recorder = Recorder()
        start(owner, recorder)

        close(peer)
        peer = -1

        XCTAssertTrue(waitUntil { recorder.closes == 1 })
        XCTAssertFalse(owner.send(Data("late\n".utf8)))
        owner.shutdown()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(recorder.closes, 1)
    }

    func testShutdownClosesTheStreamOnce() throws {
        let owner = try makeOwner()
        let recorder = Recorder()
        start(owner, recorder)

        owner.shutdown()
        owner.shutdown()

        XCTAssertTrue(waitUntil { recorder.closes == 1 })
        XCTAssertEqual(readFromPeer(timeout: 1), "", "the peer sees end of stream")
        XCTAssertFalse(owner.send(Data("late\n".utf8)))
    }

    func testAnOversizeLineIsRefusedEvenWhenItsNewlineArrivesInTheSameRead() throws {
        let owner = try makeOwner(maxLineBytes: 64)
        let recorder = Recorder()
        start(owner, recorder)

        writeToPeer(String(repeating: "y", count: 200) + "\nshort\n")

        XCTAssertTrue(waitUntil { recorder.closes == 1 })
        XCTAssertTrue(recorder.lines.isEmpty)
    }

    // a shutdown racing the peer's close once ran shutdown(2) on a descriptor number already reused
    func testAShutdownRacingThePeersCloseNeverTouchesAReusedDescriptor() throws {
        for _ in 0..<200 {
            let owner = try makeOwner()
            let recorder = Recorder()
            start(owner, recorder)
            let closing = peer
            peer = -1

            let racer = Thread { owner.shutdown() }
            racer.start()
            close(closing)
            XCTAssertTrue(waitUntil { recorder.closes == 1 })

            var victim: [Int32] = [-1, -1]
            XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &victim), 0)
            owner.shutdown()
            var poller = pollfd(fd: victim[1], events: Int16(POLLIN | POLLHUP), revents: 0)
            XCTAssertEqual(poll(&poller, 1, 5), 0, "a socket opened after the close must stay untouched")
            close(victim[0])
            close(victim[1])
        }
    }

    func testALineOverTheLimitClosesTheStream() throws {
        let owner = try makeOwner(maxLineBytes: 64)
        let recorder = Recorder()
        start(owner, recorder)

        writeToPeer(String(repeating: "y", count: 200))

        XCTAssertTrue(waitUntil { recorder.closes == 1 })
        XCTAssertTrue(recorder.lines.isEmpty)
    }
}
