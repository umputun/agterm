import Foundation

extension AppStore {
    /// Up to `limit` most-recently-used session ids across all workspaces, most-recent first, skipping
    /// stale/closed ids (so it returns fewer than `limit` when fewer qualify). The `dashboard --mru` open
    /// reads it to populate the grid from the window's recent sessions.
    public func recentSessions(limit: Int) -> [UUID] {
        sessionRecency.top(limit, in: Set(workspaces.flatMap { $0.sessions.map(\.id) }))
    }
}
