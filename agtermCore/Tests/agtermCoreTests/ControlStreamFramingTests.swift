import Foundation
import Testing
@testable import agtermCore

@Suite(.serialized)
final class ControlStreamFramingTests {
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

    deinit {
        if peer >= 0 { close(peer) }
    }

    private func makeOwner(maxLineBytes: Int = 1024, maxPendingLines: Int = 8,
                           writeTimeoutSeconds: Int = 1) throws -> ControlStreamOwner {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, UnixSocket.streamType, 0, &pair) == 0)
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
        #expect(write(peer, bytes, bytes.count) == bytes.count)
    }

    private func readFromPeer(timeout: Int = 2) -> String {
        var wait = timeval(tv_sec: timeout, tv_usec: 0)
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

    @Test func linesTravelBothWays() throws {
        let owner = try makeOwner()
        let recorder = Recorder()
        start(owner, recorder)

        writeToPeer("one\ntwo\nthr")
        writeToPeer("ee\n")
        #expect(owner.send(Data("reply\n".utf8)))

        #expect(waitUntil { recorder.lines.count == 3 })
        #expect(recorder.lines == ["one", "two", "three"])
        #expect(readFromPeer() == "reply\n")
        owner.shutdown()
    }

    @Test func anIdleStreamOutlivesTheRequestReceiveTimeout() throws {
        let owner = try makeOwner()
        let recorder = Recorder()
        start(owner, recorder)

        Thread.sleep(forTimeInterval: 0.4)

        #expect(recorder.closes == 0)
        #expect(owner.send(Data("still here\n".utf8)))
        #expect(readFromPeer() == "still here\n")
        owner.shutdown()
    }

    @Test func aPeerThatStopsReadingIsDroppedWithoutBlockingTheSender() throws {
        let owner = try makeOwner(maxPendingLines: 4, writeTimeoutSeconds: 1)
        let recorder = Recorder()
        start(owner, recorder)
        let line = Data(repeating: UInt8(ascii: "x"), count: 256 * 1024) + Data("\n".utf8)

        let began = Date()
        var refused = false
        for _ in 0..<64 where !refused { refused = !owner.send(line) }

        #expect(refused, "a full queue has to say so")
        #expect(Date().timeIntervalSince(began) < 0.5, "send only queues; it must never wait on the peer")
        #expect(waitUntil(4) { recorder.closes == 1 }, "the blocked write has to time out and close")
    }

    @Test func thePeerClosingEndsTheStreamOnce() throws {
        let owner = try makeOwner()
        let recorder = Recorder()
        start(owner, recorder)

        close(peer)
        peer = -1

        #expect(waitUntil { recorder.closes == 1 })
        #expect(!owner.send(Data("late\n".utf8)))
        owner.shutdown()
        Thread.sleep(forTimeInterval: 0.1)
        #expect(recorder.closes == 1)
    }

    @Test func shutdownClosesTheStreamOnce() throws {
        let owner = try makeOwner()
        let recorder = Recorder()
        start(owner, recorder)

        owner.shutdown()
        owner.shutdown()

        #expect(waitUntil { recorder.closes == 1 })
        #expect(readFromPeer(timeout: 1) == "", "the peer sees end of stream")
        #expect(!owner.send(Data("late\n".utf8)))
    }

    @Test func anOversizeLineIsRefusedEvenWhenItsNewlineArrivesInTheSameRead() throws {
        let owner = try makeOwner(maxLineBytes: 64)
        let recorder = Recorder()
        start(owner, recorder)

        writeToPeer(String(repeating: "y", count: 200) + "\nshort\n")

        #expect(waitUntil { recorder.closes == 1 })
        #expect(recorder.lines.isEmpty)
    }

    // a shutdown racing the peer's close once ran shutdown(2) on a descriptor number already reused
    @Test func aShutdownRacingThePeersCloseNeverTouchesAReusedDescriptor() throws {
        for _ in 0..<200 {
            let owner = try makeOwner()
            let recorder = Recorder()
            start(owner, recorder)
            let closing = peer
            peer = -1

            let racer = Thread { owner.shutdown() }
            racer.start()
            close(closing)
            #expect(waitUntil { recorder.closes == 1 })

            var victim: [Int32] = [-1, -1]
            try #require(socketpair(AF_UNIX, UnixSocket.streamType, 0, &victim) == 0)
            owner.shutdown()
            var poller = pollfd(fd: victim[1], events: Int16(POLLIN | POLLHUP), revents: 0)
            #expect(poll(&poller, 1, 5) == 0, "a socket opened after the close must stay untouched")
            close(victim[0])
            close(victim[1])
        }
    }

    @Test func aLineOverTheLimitClosesTheStream() throws {
        let owner = try makeOwner(maxLineBytes: 64)
        let recorder = Recorder()
        start(owner, recorder)

        writeToPeer(String(repeating: "y", count: 200))

        #expect(waitUntil { recorder.closes == 1 })
        #expect(recorder.lines.isEmpty)
    }
}
