import Foundation

/// Pure tree math over a flat ordered session list obeying the contiguity invariant: a parent is
/// immediately followed by its whole subtree in depth-first preorder. Operates on the lightweight `Node`
/// value type (not `Session`) so it is unit-testable without `@MainActor`. Later reparent/drag work builds
/// on `preorder` to repair contiguity after a move; everything else reads the existing order as-is.
public enum SessionTree {
    /// A minimal id/parentID pair mirroring `Session.id`/`Session.parentID` for tree math.
    public struct Node: Equatable, Sendable {
        public let id: UUID
        public let parentID: UUID?

        public init(id: UUID, parentID: UUID?) {
            self.id = id
            self.parentID = parentID
        }
    }

    /// Half-open index range of `id`'s node plus its entire subtree (the contiguous block), or nil if the
    /// id is absent. The block starts at the node itself.
    public static func subtreeRange(of id: UUID, in order: [Node]) -> Range<Int>? {
        guard let start = order.firstIndex(where: { $0.id == id }) else { return nil }
        var idsInBlock: Set<UUID> = [id]
        var end = start + 1
        while end < order.count, let parentID = order[end].parentID, idsInBlock.contains(parentID) {
            idsInBlock.insert(order[end].id)
            end += 1
        }
        return start..<end
    }

    /// Ids of every descendant of `id` (excludes `id`), in tree order.
    public static func descendantIDs(of id: UUID, in order: [Node]) -> [UUID] {
        guard let range = subtreeRange(of: id, in: order) else { return [] }
        return range.dropFirst().map { order[$0].id }
    }

    /// True if `candidate` is `ancestor` or a descendant of it — the reparent cycle guard.
    public static func isSelfOrDescendant(_ candidate: UUID, of ancestor: UUID, in order: [Node]) -> Bool {
        candidate == ancestor || descendantIDs(of: ancestor, in: order).contains(candidate)
    }

    /// The array index just past the last element of `parent`'s subtree — the insert slot for a new
    /// last-child. For a nil parent (top-level append) returns `order.count`.
    public static func appendChildIndex(parent: UUID?, in order: [Node]) -> Int {
        guard let parent else { return order.count }
        return subtreeRange(of: parent, in: order)?.upperBound ?? order.count
    }

    /// The chain of ancestor ids from the direct parent up to the root (nearest first), for expand-reveal.
    public static func ancestorIDs(of id: UUID, in order: [Node]) -> [UUID] {
        var byID: [UUID: Node] = [:]
        for node in order { byID[node.id] = node }
        var result: [UUID] = []
        var current = byID[id]?.parentID
        while let parentID = current {
            result.append(parentID)
            current = byID[parentID]?.parentID
        }
        return result
    }

    /// Reorders `id` one step (`up`/`down`/`top`/`bottom`) WITHIN its own sibling group (the nodes sharing
    /// its parentID), carrying its whole subtree, and returns the repaired full preorder of ids. A flat
    /// index move would let a nested row cross into a neighbouring subtree and break contiguity; scoping to
    /// siblings keeps the invariant. Nil (no change) when `id` is absent or already at that group's end.
    public static func reorderSibling(_ id: UUID, _ direction: ReorderDirection, in order: [Node]) -> [UUID]? {
        guard let node = order.first(where: { $0.id == id }) else { return nil }
        let siblings = order.filter { $0.parentID == node.parentID }.map(\.id)
        guard let index = siblings.firstIndex(of: id),
              let destination = direction.destinationIndex(from: index, count: siblings.count) else { return nil }
        var reordered = siblings
        reordered.remove(at: index)
        reordered.insert(id, at: destination)
        // the sibling subtree blocks tile one contiguous region (all of the parent's subtree bar the parent
        // itself, or the whole array for top-level roots); reorder the blocks and splice the region back.
        guard let first = siblings.first, let last = siblings.last,
              let firstRange = subtreeRange(of: first, in: order),
              let lastRange = subtreeRange(of: last, in: order) else { return nil }
        var blocks: [UUID: [UUID]] = [:]
        for sibling in siblings {
            guard let range = subtreeRange(of: sibling, in: order) else { return nil }
            blocks[sibling] = range.map { order[$0].id }
        }
        var result = order[..<firstRange.lowerBound].map(\.id)
        for sibling in reordered { result.append(contentsOf: blocks[sibling] ?? []) }
        result.append(contentsOf: order[lastRange.upperBound...].map(\.id))
        return result
    }

    /// Reorders `order` into canonical depth-first preorder given each node's parentID, preserving the
    /// existing relative order of siblings. Used to REPAIR contiguity after a reparent/move builds the new
    /// parentID set; returns ids in the corrected order. Roots keep their current relative order.
    public static func preorder(_ order: [Node]) -> [UUID] {
        var childrenByParent: [UUID?: [Node]] = [:]
        for node in order { childrenByParent[node.parentID, default: []].append(node) }
        var result: [UUID] = []
        func visit(_ node: Node) {
            result.append(node.id)
            for child in childrenByParent[node.id] ?? [] { visit(child) }
        }
        for root in childrenByParent[nil] ?? [] { visit(root) }
        return result
    }
}
