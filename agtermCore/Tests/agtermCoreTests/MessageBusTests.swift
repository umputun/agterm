import Foundation
import Testing
@testable import agtermCore

@MainActor
struct MessageBusTests {
    private let paneA = UUID()
    private let paneB = UUID()

    private func recipient(_ pane: UUID) -> MessageRecipient {
        MessageRecipient(pane: pane, address: "S:\(pane.uuidString)")
    }

    @discardableResult
    private func send(_ bus: MessageBus, _ body: String, to panes: [UUID]) throws -> MessageSendResult {
        try bus.send(body, from: "S:sender", to: panes.map(recipient), now: 1)
    }

    @Test func messagesComeBackOldestFirstWithTheirMetadata() throws {
        let bus = MessageBus()
        let first = try send(bus, "one", to: [paneA])
        try send(bus, "two", to: [paneA])

        let batch = bus.read(pane: paneA)

        #expect(batch.messages.map(\.body) == ["one", "two"])
        #expect(batch.messages[0].id == first.messageID)
        #expect(batch.messages[0].from == "S:sender")
        #expect(batch.messages[0].to == "S:\(paneA.uuidString)")
        #expect(batch.messages[0].ts == 1)
        #expect(batch.remaining == 0)
    }

    @Test func aReadIsBoundedAndRepeatableUntilAcked() throws {
        let bus = MessageBus()
        for i in 0..<5 { try send(bus, "m\(i)", to: [paneA]) }

        let first = bus.read(pane: paneA, limit: 2)
        let again = bus.read(pane: paneA, limit: 2)

        #expect(first.messages.map(\.body) == ["m0", "m1"])
        #expect(first.remaining == 3)
        #expect(again == first)
    }

    @Test func aBatchNeverExceedsTheCapAndReadAndAckKeepsTheRest() throws {
        let bus = MessageBus()
        let queued = MessageBus.maxBatch + 8
        for i in 0..<queued { try send(bus, "m\(i)", to: [paneA]) }

        let read = bus.read(pane: paneA, limit: 100)
        #expect(read.messages.map(\.body) == (0..<MessageBus.maxBatch).map { "m\($0)" })
        #expect(read.remaining == 8)

        let taken = bus.readAndAck(pane: paneA, limit: 100)
        #expect(taken == read)
        #expect(bus.read(pane: paneA, limit: 100).messages.map(\.body) == (MessageBus.maxBatch..<queued).map { "m\($0)" })
    }

    @Test func ackRemovesOnlyTheNamedMessagesAndIsIdempotent() throws {
        let bus = MessageBus()
        let first = try send(bus, "one", to: [paneA])
        try send(bus, "two", to: [paneA])

        #expect(bus.ack(pane: paneA, ids: [first.messageID, UUID()]) == [first.messageID])
        #expect(bus.ack(pane: paneA, ids: [first.messageID]).isEmpty)
        #expect(bus.read(pane: paneA).messages.map(\.body) == ["two"])
    }

    @Test func ackIsScopedToTheReadersMailbox() throws {
        let bus = MessageBus()
        let sent = try send(bus, "both", to: [paneA, paneB])

        #expect(bus.ack(pane: paneA, ids: [sent.messageID]) == [sent.messageID])
        #expect(bus.pending(for: paneB) == 1)
    }

    @Test func readAndAckRemovesExactlyTheReturnedBatch() throws {
        let bus = MessageBus()
        for i in 0..<3 { try send(bus, "m\(i)", to: [paneA]) }

        let taken = bus.readAndAck(pane: paneA, limit: 2)

        #expect(taken.messages.map(\.body) == ["m0", "m1"])
        #expect(taken.remaining == 1)
        #expect(bus.read(pane: paneA).messages.map(\.body) == ["m2"])
        #expect(bus.readAndAck(pane: UUID()).messages.isEmpty)
    }

    @Test func aFullMailboxRefusesThatRecipientOnly() throws {
        let bus = MessageBus()
        for _ in 0..<MessageBus.maxMessages { try send(bus, "x", to: [paneA]) }

        let result = try send(bus, "late", to: [paneA, paneB])

        #expect(result.rejected == [MessageRejection(address: "S:\(paneA.uuidString)", reason: .mailboxFull)])
        #expect(result.delivered == ["S:\(paneB.uuidString)"])
        #expect(bus.pending(for: paneA) == MessageBus.maxMessages)
        #expect(bus.pending(for: paneB) == 1)
    }

    @Test func theMailboxByteBudgetRefusesTheMessageThatWouldExceedIt() throws {
        let bus = MessageBus()
        let chunk = String(repeating: "a", count: MessageBus.maxBodyBytes)
        let fits = MessageBus.maxMailboxBytes / MessageBus.maxBodyBytes
        for _ in 0..<fits { try send(bus, chunk, to: [paneA]) }

        let result = try send(bus, "b", to: [paneA])

        #expect(result.rejected.map(\.reason) == [.mailboxFull])
        #expect(bus.pending(for: paneA) == fits)
    }

    @Test func anOversizedBodyIsRefusedForEveryone() {
        let bus = MessageBus()
        let body = String(repeating: "é", count: MessageBus.maxBodyBytes / 2 + 1)

        #expect(throws: MessageBusError.bodyTooLarge(body.utf8.count)) { try send(bus, body, to: [paneA]) }
        #expect(bus.pending(for: paneA) == 0)
    }

    @Test func anEmptyRecipientListDeliversNothing() throws {
        let result = try send(MessageBus(), "x", to: [])
        #expect(result.delivered.isEmpty)
        #expect(result.rejected.isEmpty)
    }

    @Test func disposeEmptiesOnlyThatPane() throws {
        let bus = MessageBus()
        try send(bus, "both", to: [paneA, paneB])

        bus.dispose(pane: paneA)

        #expect(bus.pending(for: paneA) == 0)
        #expect(bus.read(pane: paneA).messages.isEmpty)
        #expect(bus.pending(for: paneB) == 1)
    }
}
