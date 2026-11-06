import Foundation

extension AppStore {
    /// Picks the next selection after CLOSING the active session at `location`: the most-recently-active
    /// surviving session, else a positional walk.
    /// The MRU scope narrows to the closing session's own workspace ∩ the VISIBLE set (`navigableSessions`,
    /// so both the flagged list and the focus filter apply) — an unscoped survivor could yank the user into
    /// another workspace, and a pick the sidebar isn't rendering would strand the selection. Exhausting a
    /// scope widens through three levels: that workspace's visible sessions, everything visible, the whole
    /// tree. With no recency in scope a positional walk picks. While any narrowing is applied it is
    /// `removedID`'s neighbour in the saved flagged order under the flat and plain layouts, else the flattened
    /// in-scope walk over the widened scope, never `reselectionTarget`. `narrowed` keys on the MODE, so it
    /// stays true after the widening.
    /// A pick outside the marked set meets each caller's `disableFocusIfSelectionOutsideSet`. The scope is
    /// built from the TREE, so a session already removed cannot come back even while it survives in
    /// `sessionRecency` (the soft-close paths keep it there for undo).
    func closeReselectionTarget(after location: (workspaceIndex: Int, sessionIndex: Int), removing removedID: UUID) -> UUID? {
        let visible = Set(navigableSessions.map(\.id))
        let everything = Set(workspaces.flatMap(\.sessions).map(\.id))
        let inWorkspace = Set(workspaces[location.workspaceIndex].sessions.map(\.id))
        let sameWorkspace = inWorkspace.intersection(visible)
        // the whole-tree level is what makes "widen when exhausted" mean widen: without it an emptied
        // visible scope falls to a positional jump into the first workspace.
        let scope = sameWorkspace.isEmpty ? (visible.isEmpty ? everything : visible) : sameWorkspace
        if let recent = sessionRecency.top(1, in: scope).first { return recent }
        // reachable with no recency at all, e.g. the first close after a restore.
        let narrowed = sidebarMode == .flagged || focusEnabled
        if narrowed, let inScope = nearestInSavedFlaggedOrder(to: removedID, scope: scope) {
            return inScope
        }
        if narrowed, let inScope = nearestInScopeTarget(after: location, scope: scope) {
            return inScope
        }
        return reselectionTarget(after: location)
    }

    // the flat and plain lists show the saved order, so their positional neighbour is found there; the
    // removed id is still in the order here, since the deletion paths drop it only after reselecting
    private func nearestInSavedFlaggedOrder(to removedID: UUID, scope: Set<UUID>) -> UUID? {
        guard sidebarMode == .flagged, flaggedLayout != .tree,
              let slot = flaggedOrder.firstIndex(of: removedID) else { return nil }
        return flaggedOrder[(slot + 1)...].first(where: scope.contains)
            ?? flaggedOrder[..<slot].last(where: scope.contains)
    }

    /// `reselectionTarget`'s walk restricted to `scope`, over the tree FLATTENED in sidebar order: the
    /// in-scope session that shifted into the removed slot, else the nearest one before it. It spans
    /// workspaces because the scope can — the flagged sidebar's sessions come from every workspace, so the
    /// adjacent row there may live elsewhere; a same-workspace scope collapses it back.
    private func nearestInScopeTarget(after location: (workspaceIndex: Int, sessionIndex: Int),
                                      scope: Set<UUID>) -> UUID? {
        let sessions = workspaces[location.workspaceIndex].sessions
        let before = workspaces[..<location.workspaceIndex].reduce(0) { $0 + $1.sessions.count }
        let removedSlot = before + min(location.sessionIndex, sessions.count)
        let flattened = workspaces.flatMap(\.sessions)
        if let next = flattened[removedSlot...].first(where: { scope.contains($0.id) }) { return next.id }
        return flattened[..<removedSlot].last { scope.contains($0.id) }?.id
    }
}
