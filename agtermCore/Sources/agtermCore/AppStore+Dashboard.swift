import Foundation

extension AppStore {
    /// Expand session ids into dashboard pane cells IN ORDER — each resolved id yields its `.primary` cell,
    /// plus a `.split` cell when the session `hasSplit` (both shells alive, shown OR hidden) — so a split
    /// session becomes two cells. Ids that don't resolve to a session are skipped. UNCAPPED: the caller applies
    /// the cell cap and reports the dropped-pane count, so the expansion has exactly ONE implementation shared
    /// by `ControlServer.setDashboard` and `AppActions.toggleDashboard`.
    public func dashboardPaneCells(for ids: [UUID]) -> [DashboardMember] {
        var members: [DashboardMember] = []
        for id in ids {
            guard let session = session(withID: id) else { continue }
            members.append(DashboardMember(session: id, surface: .primary))
            if session.hasSplit { members.append(DashboardMember(session: id, surface: .split)) }
        }
        return members
    }

    /// Expand `ids` into dashboard pane cells (see `dashboardPaneCells(for:)`) and cap the result to `limit`
    /// cells, returning the capped cells plus the number of panes dropped past the cap. The single expansion +
    /// cap used by both the control `dashboard` command and the GUI `toggleDashboard`; `dropped` feeds the
    /// control path's "dropped N pane(s) beyond the N-cell limit" note.
    public func dashboardMembers(for ids: [UUID], limit: Int) -> (members: [DashboardMember], dropped: Int) {
        let expanded = dashboardPaneCells(for: ids)
        let capped = Array(expanded.prefix(limit))
        return (capped, expanded.count - capped.count)
    }

    /// The window's most-recently-used sessions (`recentSessions(limit:)`) expanded into capped dashboard pane
    /// cells — the GUI `toggleDashboard`'s MRU open. `limit` bounds BOTH the session pull and the pane cap;
    /// empty when the window has no recent sessions.
    public func dashboardMRUMembers(limit: Int) -> [DashboardMember] {
        dashboardMembers(for: recentSessions(limit: limit), limit: limit).members
    }
}
