import Foundation
import Testing
@testable import agtermCore

@MainActor
@Suite(.serialized)
final class CatalogStreamTests {
    private final class Host: CatalogStreamHost {
        var catalogStreams: [CatalogStream] = []
        var catalogHeartbeat: Task<Void, Never>?
        var catalogHelloDeadline: TimeInterval = 60
        var clock = Date(timeIntervalSince1970: 1000)
        var answer: CatalogSubscription?
        var hellos: [CatalogHello] = []
        lazy var hub = CatalogHub(epoch: "e1", staleTimeout: 30, now: { [unowned self] in clock },
                                  source: { CatalogFixture.snapshot([]) })

        var catalogHubs: [CatalogHub] { [hub] }

        func catalogSubscription(for hello: CatalogHello) -> CatalogSubscription {
            hellos.append(hello)
            return answer ?? .serve(hub, CatalogFixture.versions)
        }
    }

    private let host = Host()
    private var viewer: Int32 = -1

    deinit {
        if viewer >= 0 { close(viewer) }
    }

    private func adopt() throws {
        var fds: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, UnixSocket.streamType, 0, &fds) == 0)
        viewer = fds[1]
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(viewer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        #if canImport(Darwin)
        var on: Int32 = 1
        setsockopt(viewer, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        host.adoptCatalogStream(descriptor: fds[0])
    }

    private func send(_ frame: CatalogFrame) throws {
        let line = try CatalogCodec.encode(frame)
        let sent = line.withUnsafeBytes { UnixSocket.write(viewer, $0.baseAddress!, line.count) }
        #expect(sent == line.count)
    }

    private func readFrame() async -> CatalogFrame? {
        let fd = viewer
        return await withCheckedContinuation { continuation in
            Thread {
                var bytes: [UInt8] = []
                var byte: UInt8 = 0
                while read(fd, &byte, 1) == 1 {
                    guard byte == UInt8(ascii: "\n") else {
                        bytes.append(byte)
                        continue
                    }
                    continuation.resume(returning: try? CatalogCodec.decode(Data(bytes)))
                    return
                }
                continuation.resume(returning: nil)
            }.start()
        }
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<3000 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
        return condition()
    }

    @Test func aHelloSubscribesTheViewerToTheHubItNames() async throws {
        try adopt()
        try send(.hello(CatalogHello(version: 1, window: "W1")))

        guard case .hello(let hello)? = await readFrame(), case .snapshot? = await readFrame() else {
            Issue.record("no opening")
            return
        }
        #expect(hello.epoch == "e1")
        #expect(hello.versions == CatalogFixture.versions)
        #expect(host.hellos.map(\.window) == ["W1"])
    }

    @Test func aRefusedHelloGetsTheReasonAndTheStreamCloses() async throws {
        host.answer = .refuse(reason: "window W1 is closed on box", final: false)
        try adopt()
        try send(.hello(CatalogHello(version: 1, window: "W1")))

        #expect(await readFrame() == .refused(reason: "window W1 is closed on box", final: false))
        #expect(await readFrame() == nil)
        #expect(await eventually { host.catalogStreams.isEmpty })
    }

    @Test func aStreamThatOpensWithoutHelloIsClosed() async throws {
        try adopt()
        try send(.ping)

        #expect(await readFrame() == nil)
        #expect(await eventually { host.catalogStreams.isEmpty })
    }

    @Test func aStreamThatSendsNoHelloIsClosedAtTheDeadline() async throws {
        host.catalogHelloDeadline = 0.2
        try adopt()

        #expect(await readFrame() == nil)
        #expect(host.hellos.isEmpty)
    }

    @Test func aViewerLeavingAPingUnansweredIsDroppedOnceItGoesStale() async throws {
        try adopt()
        try send(.hello(CatalogHello(version: 1)))
        _ = await readFrame()
        _ = await readFrame()

        host.beatCatalogStreams()
        #expect(await readFrame() == .ping)
        host.clock += 31
        host.beatCatalogStreams()

        #expect(await readFrame() == nil)
        #expect(await eventually { host.catalogStreams.isEmpty })
    }

    @Test func anAnsweredPingKeepsTheViewer() async throws {
        try adopt()
        try send(.hello(CatalogHello(version: 1)))
        _ = await readFrame()
        _ = await readFrame()

        host.beatCatalogStreams()
        #expect(await readFrame() == .ping)
        try send(.ack)
        try send(.ping)
        #expect(await readFrame() == .ack)
        host.clock += 31
        host.beatCatalogStreams()

        #expect(await readFrame() == .ping)
    }
}
