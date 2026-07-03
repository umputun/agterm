import Foundation

/// A bounded most-recent-first list of unique ids. `push` moves an id to the front (no
/// duplicates); the front is the most recently used. Backs the Ctrl-Tab session switcher's
/// order — `items[0]` is the current session, `items[1]` the previous one.
public struct RecencyStack<ID: Hashable>: Equatable {
    public private(set) var items: [ID] = []
    public let limit: Int

    /// Seeds the list from `items`, keeping the first occurrence of each id (the list is unique by
    /// contract, but a persisted/hand-edited seed may not be) and truncating to `limit`.
    public init(limit: Int = 100, items: [ID] = []) {
        self.limit = limit
        var seen = Set<ID>()
        self.items = Array(items.filter { seen.insert($0).inserted }.prefix(limit))
    }

    /// Move `id` to the front. No-op if it's already there.
    public mutating func push(_ id: ID) {
        if items.first == id { return }
        items.removeAll { $0 == id }
        items.insert(id, at: 0)
        if items.count > limit { items = Array(items.prefix(limit)) }
    }

    public mutating func remove(_ id: ID) {
        items.removeAll { $0 == id }
    }

    /// Up to `n` most-recent ids that are still in `valid`, most-recent first. Stale ids (not in
    /// `valid`) are skipped, so a closed session never appears even before it's removed.
    public func top(_ n: Int, in valid: Set<ID>) -> [ID] {
        var out: [ID] = []
        for id in items where valid.contains(id) {
            out.append(id)
            if out.count == n { break }
        }
        return out
    }

    public var isEmpty: Bool { items.isEmpty }
}
