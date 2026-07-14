import Foundation

extension AppStore {
    /// Picks the next selection after CLOSING the active session at `location`: the most-recently-active
    /// surviving session, else the positional `reselectionTarget`. The MRU scope is deliberately narrowed
    /// to the closing session's own workspace ∩ `navigableSessions` — an unscoped survivor could yank the
    /// user into a different workspace, or silently drop the active focus/flagged filter, which is more
    /// disorienting than the positional neighbor it replaces. Once the close leaves that workspace with no
    /// navigable session at all, "stay in this workspace" has nothing left to mean, so the scope widens to
    /// the whole navigable set rather than falling straight to a positional jump into the first workspace.
    /// The scope is built from the TREE, so a session already removed there cannot come back even when it
    /// survives in `sessionRecency` (the soft-close paths keep it there on purpose, for undo).
    func closeReselectionTarget(after location: (workspaceIndex: Int, sessionIndex: Int)) -> UUID? {
        let navigable = Set(navigableSessions.map(\.id))
        let inWorkspace = Set(workspaces[location.workspaceIndex].sessions.map(\.id))
        let sameWorkspace = inWorkspace.intersection(navigable)
        let scope = sameWorkspace.isEmpty ? navigable : sameWorkspace
        if let recent = sessionRecency.top(1, in: scope).first { return recent }
        return reselectionTarget(after: location)
    }
}
