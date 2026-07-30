import Foundation

extension AppStore {
    /// Picks the next selection after CLOSING the active session at `location`: the most-recently-active
    /// surviving session, else a positional walk.
    /// The MRU scope narrows to the closing session's own workspace ∩ the VISIBLE set
    /// (`navigableSessions`, so both the flagged list and the focus filter apply) — an unscoped survivor
    /// could yank the user into another workspace, and a pick the sidebar isn't rendering would strand the
    /// selection.
    /// Exhausting a scope widens through three levels: that workspace's visible sessions, everything
    /// visible, then the whole tree.
    /// Only when the widened scope carries no recency does a positional walk decide, and while any
    /// narrowing is applied that is the flattened in-scope walk over the widened scope, not
    /// `reselectionTarget` — `narrowed` keys on the MODE, so it stays true after the widening.
    /// A pick outside the marked set meets each caller's `disableFocusIfSelectionOutsideSet`.
    /// The scope is built from the TREE, so a session already removed cannot come back even while it
    /// survives in `sessionRecency` (the soft-close paths keep it there for undo).
    func closeReselectionTarget(after location: (workspaceIndex: Int, sessionIndex: Int)) -> UUID? {
        let visible = Set(navigableSessions.map(\.id))
        let everything = Set(workspaces.flatMap(\.sessions).map(\.id))
        let inWorkspace = Set(workspaces[location.workspaceIndex].sessions.map(\.id))
        let sameWorkspace = inWorkspace.intersection(visible)
        // the whole-tree level is what makes "widen when exhausted" mean widen: without it an emptied
        // visible scope falls to a positional jump into the first workspace.
        let scope = sameWorkspace.isEmpty ? (visible.isEmpty ? everything : visible) : sameWorkspace
        if let recent = sessionRecency.top(1, in: scope).first { return recent }
        // under a narrowing the positional fallback runs over `scope`, which the widening above may have
        // grown to the whole tree — so it stays inside the visible set only while one survives there.
        // Reachable with no recency at all, e.g. the first close after a restore.
        let narrowed = sidebarMode == .flagged || focusEnabled
        if narrowed, let inScope = nearestInScopeTarget(after: location, scope: scope) {
            return inScope
        }
        return reselectionTarget(after: location)
    }

    /// `reselectionTarget`'s walk restricted to `scope`, over the tree FLATTENED in sidebar order: the
    /// in-scope session that shifted into the removed slot, else the nearest one before it.
    /// It spans workspaces because the scope can — the flagged sidebar renders one flat cross-workspace
    /// list, so the adjacent row there may live elsewhere; a same-workspace scope collapses it back.
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
