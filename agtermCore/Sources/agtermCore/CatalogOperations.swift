import Foundation

/// CatalogReceipt answers a structural command sent with an operation id: `applied` at a revision, `noop`,
/// `refused` with the error, or `fenced` when a lookup reached the id before the command did. `unknown` is a
/// lookup's miss on a table that may have dropped the id's entry: fenced against a late arrival, but whether it
/// ran before is lost.
public struct CatalogReceipt: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case applied, noop, refused, fenced, unknown
    }

    public var opID: String
    public var epoch: String
    public var outcome: Outcome
    /// rev is the revision an applied operation's changes reached, nil only for a marker its command saved
    /// before finishing.
    public var rev: Int?
    public var error: String?

    /// isValidOpID accepts 1 to 128 letters, digits, `.`, `_`, `:` and `-`, so an id echoed in an error cannot carry a
    /// control sequence.
    public static func isValidOpID(_ opID: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "._:-").union(.alphanumerics)
        return (1...128).contains(opID.count) && opID.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }

    public init(opID: String, epoch: String, outcome: Outcome, rev: Int? = nil, error: String? = nil) {
        self.opID = opID
        self.epoch = epoch
        self.outcome = outcome
        self.rev = rev
        self.error = error
    }
}

/// CatalogPosition is a point in a catalog's history: an epoch and a revision within it.
public struct CatalogPosition: Codable, Equatable, Sendable {
    public var epoch: String
    public var rev: Int

    public init(epoch: String, rev: Int) {
        self.epoch = epoch
        self.rev = rev
    }
}

/// CatalogOperationTable is the server's record of recent operations, saved with the catalog so an operation
/// that committed before a restart is still answered after it. Bounded: the oldest entries fall off.
public struct CatalogOperationTable: Codable, Equatable, Sendable {
    public static let capacity = 512

    public private(set) var entries: [CatalogReceipt] = []
    /// lastDrop is where the catalog stood when the table last dropped entries.
    public private(set) var lastDrop: CatalogPosition?

    public init() {}

    public func receipt(_ opID: String) -> CatalogReceipt? {
        entries.last { $0.opID == opID }
    }

    /// record keeps `receipt` as its id's newest entry, the catalog standing at `position`.
    public mutating func record(_ receipt: CatalogReceipt, at position: CatalogPosition) {
        entries.removeAll { $0.opID == receipt.opID }
        entries.append(receipt)
        guard entries.count > Self.capacity else { return }
        entries.removeFirst(entries.count - Self.capacity)
        lastDrop = position
    }

    /// mayHaveDropped is whether an operation sent at `sent` could have had its entry dropped: a drop at or after it
    /// in that epoch, or a drop in any other, since epochs are unordered. A nil `sent` counts any drop.
    public func mayHaveDropped(since sent: CatalogPosition?) -> Bool {
        guard let lastDrop else { return false }
        guard let sent else { return true }
        return lastDrop.epoch != sent.epoch || lastDrop.rev >= sent.rev
    }

    /// adopt moves every applied entry from an earlier epoch to `epoch` at `rev`, a revision a viewer reaches with
    /// that epoch's first snapshot; an old epoch's revisions compare with nothing in a new one.
    public mutating func adopt(epoch: String, rev: Int) {
        for index in entries.indices where entries[index].outcome == .applied && entries[index].epoch != epoch {
            entries[index].epoch = epoch
            entries[index].rev = rev
        }
    }
}
