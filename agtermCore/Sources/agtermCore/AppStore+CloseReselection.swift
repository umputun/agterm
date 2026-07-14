import Foundation

extension AppStore {
    /// Picks the next selection after CLOSING the active session at `location`: the most-recently-active
    /// surviving session, else the positional `reselectionTarget`. The MRU scope is deliberately narrowed
    /// to the closing session's own workspace ∩ `navigableSessions` — an unscoped survivor could yank the
    /// user into a different workspace, or silently drop the active focus/flagged filter, which is more
    /// disorienting than the positional neighbor it replaces. The scope is built from the TREE, so a
    /// session already removed there cannot come back even when it survives in `sessionRecency` (the
    /// soft-close paths keep it there on purpose, for undo).
    func closeReselectionTarget(after location: (workspaceIndex: Int, sessionIndex: Int)) -> UUID? {
        // reselectionTarget force-indexes workspaces[location.workspaceIndex]; it traps on a stale index,
        // so this branch must resolve the last-resort fallback itself instead of delegating.
        guard workspaces.indices.contains(location.workspaceIndex) else {
            return workspaces.lazy.compactMap(\.sessions.first).first?.id
        }
        let inWorkspace = Set(workspaces[location.workspaceIndex].sessions.map(\.id))
        let scope = inWorkspace.intersection(navigableSessions.map(\.id))
        if let recent = sessionRecency.top(1, in: scope).first { return recent }
        return reselectionTarget(after: location)
    }
}
