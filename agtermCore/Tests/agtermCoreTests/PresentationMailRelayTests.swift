import Foundation
import Testing
@testable import agtermCore

@MainActor
struct PresentationMailRelayTests {
    private let pane = UUID()

    private func send(_ bus: MessageBus) throws {
        _ = try bus.send("hi", from: nil, to: [MessageRecipient(pane: pane, address: "S:\(pane)")], now: 1)
    }

    private func nextMainTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    @Test func aBurstOfChangesFlushesOnceOnTheNextMainTurn() async throws {
        let bus = MessageBus()
        var flushes = 0
        let relay = PresentationMailRelay(bus: bus) { flushes += 1 }
        relay.start()
        relay.start()

        try send(bus)
        try send(bus)
        bus.dispose(pane: pane)
        #expect(flushes == 0)
        await nextMainTurn()
        #expect(flushes == 1)

        try send(bus)
        await nextMainTurn()
        #expect(flushes == 2)
    }

    @Test func aStoppedRelayDropsAPendingFlushAndHearsNothingMore() async throws {
        let bus = MessageBus()
        var flushes = 0
        let relay = PresentationMailRelay(bus: bus) { flushes += 1 }
        relay.start()

        try send(bus)
        relay.stop()
        await nextMainTurn()
        try send(bus)
        await nextMainTurn()

        #expect(flushes == 0)
    }
}
