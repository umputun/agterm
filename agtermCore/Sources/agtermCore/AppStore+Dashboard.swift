import Foundation

extension AppStore {
    /// Expand resolved targets into dashboard pane cells IN ORDER: a nil `pane` yields the session's
    /// `.primary` cell plus a `.split` cell when it `hasSplit` (both shells alive, shown OR hidden), and an
    /// explicit pane yields that cell alone. Unresolvable ids are skipped and repeated cells collapse, so a
    /// bare id alongside a pane ref for the same session cannot double-host one surface. UNCAPPED — the
    /// caller caps and reports the dropped-pane count, so the expansion has exactly ONE implementation,
    /// shared by `ControlServer.setDashboard` and `AppActions.toggleDashboard`.
    ///
    /// An explicit pane is trusted to exist: `ControlServer` checks availability first so it can name the
    /// offending token in its `unresolved` note, which this cannot.
    public func dashboardPaneCells(for targets: [ResolvedDashboardTarget]) -> [DashboardMember] {
        var members: [DashboardMember] = []
        var seen = Set<DashboardMember>()
        for target in targets {
            guard let session = session(withID: target.session) else { continue }
            var cells = [DashboardMember(session: target.session, surface: target.pane ?? .primary)]
            if target.pane == nil, session.hasSplit {
                cells.append(DashboardMember(session: target.session, surface: .split))
            }
            for cell in cells where seen.insert(cell).inserted { members.append(cell) }
        }
        return members
    }

    /// Expand `ids` into dashboard pane cells (see `dashboardPaneCells(for:)`) capped to `limit`, returning
    /// them plus the number of panes dropped past the cap. The single expansion + cap used by both the
    /// control `dashboard` command and the GUI `toggleDashboard`; `dropped` feeds the control path's
    /// "dropped N pane(s) beyond the N-cell limit" note.
    public func dashboardMembers(for ids: [UUID], limit: Int) -> (members: [DashboardMember], dropped: Int) {
        dashboardMembers(for: ids.map { ResolvedDashboardTarget(session: $0, pane: nil) }, limit: limit)
    }

    /// The resolved-target form of `dashboardMembers(for:limit:)` — the control `dashboard` path, where a
    /// target may name one pane.
    public func dashboardMembers(for targets: [ResolvedDashboardTarget],
                                 limit: Int) -> (members: [DashboardMember], dropped: Int) {
        let expanded = dashboardPaneCells(for: targets)
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
