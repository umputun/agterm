import Foundation
import Testing
@testable import agtermCore

@Suite(.serialized)
@MainActor
final class ControlEventStreamHubTests {
    private var peer: Int32 = -1

    deinit {
        if peer >= 0 { close(peer) }
    }

    /// Reserves, commits, and returns whether the reservation was taken.
    @discardableResult
    private func stream(_ hub: EventStreamHub, kinds: Set<ControlEventKind>? = nil,
                        cursor: UInt64 = 0) throws -> Bool {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, UnixSocket.streamType, 0, &pair) == 0)
        peer = pair[1]
        guard let id = hub.reserve(kinds: kinds) else { return false }
        hub.commit(id, descriptor: pair[0], cursor: cursor)
        return true
    }

    private func readLineFromPeer(timeout: TimeInterval = 2) throws -> String? {
        var wait = timeval(tv_sec: 0, tv_usec: __darwin_suseconds_t(timeout * 1_000_000))
        setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(peer, &buffer, buffer.count)
        guard count > 0 else { return nil }
        return String(decoding: buffer[0..<count], as: UTF8.self)
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    private func event(_ seq: UInt64, _ kind: ControlEventKind) -> ControlEvent {
        ControlEvent(seq: seq, ts: 0, kind: kind, payload: ControlEventPayload(name: "api"))
    }

    @Test func fanoutPushesOneJSONLinePerEvent() throws {
        let hub = EventStreamHub(limits: .init(maxLineBytes: 1024, maxPendingLines: 8, writeTimeoutSeconds: 1))
        try stream(hub, cursor: 0)

        hub.fanout(event(1, .status))

        let line = try #require(try readLineFromPeer())
        #expect(line.hasSuffix("\n"))
        #expect(try JSONDecoder().decode(ControlEvent.self, from: Data(line.utf8)) == event(1, .status))
    }

    @Test func kindsFilterSkipsNonMatchingSubscribers() throws {
        let hub = EventStreamHub(limits: .init(maxLineBytes: 1024, maxPendingLines: 8, writeTimeoutSeconds: 1))
        try stream(hub, kinds: [.message], cursor: 0)

        hub.fanout(event(1, .status))
        hub.fanout(event(2, .message))

        let line = try #require(try readLineFromPeer())
        #expect(try JSONDecoder().decode(ControlEvent.self, from: Data(line.utf8)).seq == 2)
    }

    @Test func framesStartAfterTheAnchorCursor() throws {
        let hub = EventStreamHub(limits: .init(maxLineBytes: 1024, maxPendingLines: 8, writeTimeoutSeconds: 1))
        try stream(hub, cursor: 1)

        hub.fanout(event(1, .status))
        hub.fanout(event(2, .status))

        let line = try #require(try readLineFromPeer())
        #expect(try JSONDecoder().decode(ControlEvent.self, from: Data(line.utf8)).seq == 2)
    }

    @Test func aPendingReservationBuffersUntilCommitAndDropsPreAnchorFrames() throws {
        let hub = EventStreamHub(limits: .init(maxLineBytes: 1024, maxPendingLines: 8, writeTimeoutSeconds: 1))
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, UnixSocket.streamType, 0, &pair) == 0)
        peer = pair[1]
        let reservation = try #require(hub.reserve(kinds: nil))

        // seq 1 lands inside the anchor window, seq 2 after it
        hub.fanout(event(1, .status))
        hub.fanout(event(2, .status))
        #expect(try readLineFromPeer(timeout: 0.2) == nil)

        hub.commit(reservation, descriptor: pair[0], cursor: 1)

        let line = try #require(try readLineFromPeer())
        #expect(try JSONDecoder().decode(ControlEvent.self, from: Data(line.utf8)).seq == 2)
    }

    @Test func peerHangupFreesTheSlot() throws {
        let hub = EventStreamHub(limits: .init(maxLineBytes: 1024, maxPendingLines: 8, writeTimeoutSeconds: 1))
        try stream(hub)
        close(peer)
        peer = -1

        #expect(waitUntil { hub.hasCapacity })
    }

    @Test func reserveRefusesPastTheCapAndReleaseFrees() throws {
        let hub = EventStreamHub(limits: .init(maxLineBytes: 1024, maxPendingLines: 8, writeTimeoutSeconds: 1))
        var reservations: [UUID] = []
        for _ in 0..<EventStreamHub.subscriberLimit {
            reservations.append(try #require(hub.reserve(kinds: nil)))
        }
        #expect(!hub.hasCapacity)
        #expect(hub.reserve(kinds: nil) == nil)

        hub.release(reservations.removeFirst())
        #expect(hub.reserve(kinds: nil) != nil)
        for id in reservations { hub.release(id) }
    }

    @Test func aPendingBufferPastTheCapDropsTheReservationAndCommitRefuses() throws {
        let hub = EventStreamHub(limits: .init(maxLineBytes: 1024, maxPendingLines: 2, writeTimeoutSeconds: 1))
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, UnixSocket.streamType, 0, &pair) == 0)
        peer = pair[1]
        let reservation = try #require(hub.reserve(kinds: nil))

        for seq in UInt64(1)...3 { hub.fanout(event(seq, .status)) }

        #expect(!hub.commit(reservation, descriptor: pair[0], cursor: 0))
        // no frame ever reached the peer: the hub adopted nothing
        #expect(try readLineFromPeer(timeout: 0.2) == nil)
        #expect(hub.hasCapacity)
        // the caller kept the descriptor: closing its end must not crash or hang
        close(pair[0])
    }

    @Test func stalledPeerIsDroppedNotWaitedOn() throws {
        let hub = EventStreamHub(limits: .init(maxLineBytes: 1024, maxPendingLines: 2, writeTimeoutSeconds: 1))
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, UnixSocket.streamType, 0, &pair) == 0)
        peer = pair[1]
        // a minimal send buffer: the writer cannot drain a volume of frames into it, so the
        // bounded queue provably overflows against this peer
        var small = 1024
        setsockopt(pair[0], SOL_SOCKET, SO_SNDBUF, &small, socklen_t(MemoryLayout<Int32>.size))
        let reservation = try #require(hub.reserve(kinds: nil))
        hub.commit(reservation, descriptor: pair[0], cursor: 0)

        for seq in UInt64(1)...200 { hub.fanout(event(seq, .status)) }

        #expect(waitUntil(5) { hub.hasCapacity })
    }
}
