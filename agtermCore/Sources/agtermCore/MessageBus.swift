import Foundation

/// BusMessage is one message queued in a pane's mailbox.
public struct BusMessage: Codable, Equatable, Sendable {
    public let id: UUID
    /// from is the sender's `SESSION:PANE-ID`, nil for a sender outside agterm.
    public let from: String?
    public let to: String
    /// ts shares the `ControlEvent.ts` clock.
    public let ts: Double
    public let body: String

    public init(id: UUID, from: String?, to: String, ts: Double, body: String) {
        self.id = id
        self.from = from
        self.to = to
        self.ts = ts
        self.body = body
    }
}

/// MessageRecipient is a resolved recipient: the pane's mailbox key and the address it is reported under.
public struct MessageRecipient: Equatable, Sendable {
    public let pane: UUID
    public let address: String

    public init(pane: UUID, address: String) {
        self.pane = pane
        self.address = address
    }
}

/// MessageRejection is a recipient a send could not reach.
public struct MessageRejection: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case mailboxFull = "mailbox full"
        case unknownPane = "unknown pane"
    }

    public let address: String
    public let reason: Reason

    public init(address: String, reason: Reason) {
        self.address = address
        self.reason = reason
    }
}

/// MessageSendResult reports each recipient of one send; every copy shares `messageID`.
public struct MessageSendResult: Equatable, Sendable {
    public let messageID: UUID
    public let delivered: [String]
    public let rejected: [MessageRejection]
}

/// MessageBatch is the oldest part of a mailbox; remaining counts the pending messages left out of it.
public struct MessageBatch: Equatable, Sendable {
    public let messages: [BusMessage]
    public let remaining: Int
}

public enum MessageBusError: Error, Equatable, Sendable {
    case bodyTooLarge(Int)
}

/// MessageBus holds the app run's per-pane mailboxes, keyed by pane token. It knows nothing of sessions or
/// roles: callers resolve addresses first, and dispose a pane's mailbox when the pane or its program goes.
@MainActor
public final class MessageBus {
    public static let shared = MessageBus()

    public static let maxBodyBytes = 64 * 1024
    public static let maxMessages = 256
    public static let maxMailboxBytes = 1024 * 1024
    public static let maxBatch = 32

    private var mailboxes: [UUID: [BusMessage]] = [:]

    public init() {}

    /// send queues one copy of `body` per recipient, refusing only the recipients whose mailbox it would
    /// overfill. A body over the limit refuses the whole send.
    public func send(_ body: String, from: String?, to recipients: [MessageRecipient], now: Double) throws(MessageBusError)
        -> MessageSendResult {
        let size = body.utf8.count
        guard size <= Self.maxBodyBytes else { throw .bodyTooLarge(size) }
        let id = UUID()
        var delivered: [String] = []
        var rejected: [MessageRejection] = []
        for recipient in recipients {
            let box = mailboxes[recipient.pane, default: []]
            guard box.count < Self.maxMessages, bytes(of: box) + size <= Self.maxMailboxBytes else {
                rejected.append(MessageRejection(address: recipient.address, reason: .mailboxFull))
                continue
            }
            mailboxes[recipient.pane, default: []].append(BusMessage(id: id, from: from, to: recipient.address, ts: now, body: body))
            delivered.append(recipient.address)
        }
        return MessageSendResult(messageID: id, delivered: delivered, rejected: rejected)
    }

    /// read returns the oldest messages without removing them, so a repeat read answers the same batch.
    public func read(pane: UUID, limit: Int = MessageBus.maxBatch) -> MessageBatch {
        let box = mailboxes[pane] ?? []
        let batch = Array(box.prefix(min(max(limit, 0), Self.maxBatch)))
        return MessageBatch(messages: batch, remaining: box.count - batch.count)
    }

    /// readAndAck returns the oldest messages and removes exactly those, in one step.
    public func readAndAck(pane: UUID, limit: Int = MessageBus.maxBatch) -> MessageBatch {
        let batch = read(pane: pane, limit: limit)
        if !batch.messages.isEmpty { mailboxes[pane]?.removeFirst(batch.messages.count) }
        return batch
    }

    /// ack removes the named messages from `pane`'s mailbox and answers the ids it removed.
    public func ack(pane: UUID, ids: [UUID]) -> [UUID] {
        guard let box = mailboxes[pane] else { return [] }
        let wanted = Set(ids)
        let removed = box.filter { wanted.contains($0.id) }.map(\.id)
        mailboxes[pane] = box.filter { !wanted.contains($0.id) }
        return removed
    }

    public func pending(for pane: UUID) -> Int { mailboxes[pane]?.count ?? 0 }

    public func dispose(pane: UUID) { mailboxes[pane] = nil }

    private func bytes(of box: [BusMessage]) -> Int { box.reduce(0) { $0 + $1.body.utf8.count } }
}
