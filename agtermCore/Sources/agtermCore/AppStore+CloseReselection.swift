import Foundation

extension AppStore {
    /// Picks the next selection after CLOSING the active session at `location`: the most-recently-active
    /// surviving session, else the positional `reselectionTarget`. The MRU scope is deliberately narrowed
    /// to the closing session's own workspace — an unscoped survivor could yank the user into a different
    /// workspace, which is more disorienting than the positional neighbor it replaces. Once the close leaves
    /// that workspace with nothing in scope, "stay in this workspace" has nothing left to mean, so the scope
    /// widens rather than falling straight to a positional jump into the first workspace.
    ///
    /// The `.flagged` sidebar filter DOES scope the pick (landing on a session the flagged view isn't even
    /// rendering would be worse — so it scopes the positional fallback too), and it survives the widening
    /// because `flaggedSessions` is cross-workspace by definition. The FOCUS filter deliberately does NOT scope it — unlike flagged mode, focus is a
    /// property of the TREE, not of the selection: `setFocusedWorkspace` never moves the active session, so
    /// focus can sit on a workspace the closing session doesn't even belong to. Scoping by it (i.e. using
    /// `navigableSessions`, which folds focus in) would make ⌘W in that state jump into the FOCUSED workspace,
    /// and would make closing the focused workspace's last session widen into an EMPTY set and fall through to
    /// the positional first-workspace jump — the exact disorientation this helper exists to remove. Landing
    /// outside the focused workspace is already handled: every caller runs `autoUnfocusIfOutsideFocus` on the
    /// pick, which drops the filter to reveal the target.
    ///
    /// The scope is built from the TREE, so a session already removed there cannot come back even when it
    /// survives in `sessionRecency` (the soft-close paths keep it there on purpose, for undo).
    func closeReselectionTarget(after location: (workspaceIndex: Int, sessionIndex: Int)) -> UUID? {
        let filtered = sidebarMode == .flagged
            ? Set(flaggedSessions.map(\.id))
            : Set(workspaces.flatMap(\.sessions).map(\.id))
        let inWorkspace = Set(workspaces[location.workspaceIndex].sessions.map(\.id))
        let sameWorkspace = inWorkspace.intersection(filtered)
        let scope = sameWorkspace.isEmpty ? filtered : sameWorkspace
        if let recent = sessionRecency.top(1, in: scope).first { return recent }
        // `reselectionTarget` walks the tree positionally, so in `.flagged` mode it can land on an
        // unflagged sibling the sidebar isn't rendering (reachable when no scoped session has ever been
        // activated — e.g. the first close after restoring a snapshot with no persisted recency). Keep the
        // fallback inside the filter, but keep it POSITIONAL: the nearest in-scope neighbor, so the worst
        // case really is the old neighbor behavior scoped to the flagged set. When the close took the LAST
        // flagged session anywhere, `scope` is empty and there is nothing left to keep it inside — the
        // positional pick then stands, since leaving no session selected would leave no terminal.
        if sidebarMode == .flagged, let inScope = nearestInScopeTarget(after: location, scope: scope) {
            return inScope
        }
        return reselectionTarget(after: location)
    }

    /// `reselectionTarget`'s walk restricted to `scope`, over the tree FLATTENED in sidebar order: the
    /// in-scope session that shifted into the removed slot, else the nearest one before it. The walk spans
    /// workspaces because the scope can: once the closing workspace holds nothing in scope the scope has
    /// widened to the whole flagged set, and the flagged sidebar renders that set as one flat cross-workspace
    /// list — so the adjacent row there is the neighboring FLAGGED row, which may live in another workspace.
    /// While the scope is still same-workspace it holds only that workspace's ids, so the flat walk collapses
    /// to the in-workspace one.
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
