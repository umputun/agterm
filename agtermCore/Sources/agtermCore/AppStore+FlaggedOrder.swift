import Foundation

/// FlaggedOrderPlacement says which side of the anchor a flagged-order move puts the moved block.
public enum FlaggedOrderPlacement: Sendable {
    case before
    case after
}

extension AppStore {
    /// flaggedSessions is every flagged session in tree order: the flagged tree's rows and what membership
    /// readers count.
    public var flaggedSessions: [Session] {
        workspaces.flatMap(\.sessions).filter(\.flagged)
    }

    /// orderedFlaggedSessions is the flat and plain layouts' rows: saved ids still flagged and in the tree,
    /// then any flagged session the order lacks, in tree order.
    public var orderedFlaggedSessions: [Session] {
        let flagged = flaggedSessions
        var unplaced = Dictionary(uniqueKeysWithValues: flagged.map { ($0.id, $0) })
        let saved = flaggedOrder.compactMap { unplaced.removeValue(forKey: $0) }
        return saved + flagged.filter { unplaced[$0.id] != nil }
    }

    /// moveFlagged puts `ids`, kept in their current order, just before or after `anchor`. Every id and the
    /// anchor must be flagged sessions of this store and the anchor not among the ids; an invalid or unchanged
    /// move returns false. Ids parked in a pending close keep their slots. Saves and signals a tree change
    /// only on a real move.
    @discardableResult
    public func moveFlagged(_ ids: [UUID], to placement: FlaggedOrderPlacement, of anchor: UUID) -> Bool {
        let live = orderedFlaggedSessions.map(\.id)
        let moving = Set(ids)
        guard !moving.isEmpty, !moving.contains(anchor), moving.isSubset(of: live),
              let reordered = SidebarDrop.reorderedFlagged(live, moving: moving, placement: placement, anchor: anchor)
        else { return false }
        flaggedOrder = writingLiveOrder(reordered)
        scheduleTreeChanged()
        save()
        return true
    }

    var flaggedOrderReadback: [String]? {
        let ids = orderedFlaggedSessions.map(\.id.uuidString)
        return ids.isEmpty ? nil : ids
    }

    // recorded when the session arrives rather than derived from the tree later, so a session placed earlier
    // in the tree by a later arrival cannot jump ahead of one that arrived before it
    func appendFlaggedArrivals() {
        let known = Set(flaggedOrder)
        let arrivals = flaggedSessions.map(\.id).filter { !known.contains($0) }
        if !arrivals.isEmpty { flaggedOrder.append(contentsOf: arrivals) }
    }

    func dropFromFlaggedOrder(_ ids: some Sequence<UUID>) {
        let gone = Set(ids)
        guard flaggedOrder.contains(where: gone.contains) else { return }
        flaggedOrder.removeAll { gone.contains($0) }
    }

    // a snapshot written before the order existed carries none and restores in tree order
    func restoreFlaggedOrder(_ saved: [UUID]?) {
        let flagged = Set(flaggedSessions.map(\.id))
        var seen = Set<UUID>()
        flaggedOrder = (saved ?? []).filter { flagged.contains($0) && seen.insert($0).inserted }
        appendFlaggedArrivals()
    }

    // parked ids keep their slots so a pending-close undo returns them in place
    private func writingLiveOrder(_ liveOrder: [UUID]) -> [UUID] {
        let live = Set(liveOrder)
        var remaining = liveOrder[...]
        var written: [UUID] = []
        for id in flaggedOrder {
            written.append(live.contains(id) ? remaining.removeFirst() : id)
        }
        return written + remaining
    }
}
