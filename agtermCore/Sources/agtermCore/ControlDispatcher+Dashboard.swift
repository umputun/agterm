extension ControlDispatcher {
    /// The dashboard overlay is host-free-validated here: an open needs at least one id (or `--mru`) and at
    /// most one font flag, `--close` takes no id/`--mru`/font flag, a `--font-size` must be finite and
    /// positive, `--mru` cannot be combined with explicit ids (but composes with the font flags), and every
    /// id parses as a `DashboardTarget` — a malformed pane suffix fails the whole command here, while a
    /// well-formed ref naming no live pane is an app-side miss.
    /// The 9-cell cap is NOT applied here — the cell unit is a session+pane, so a split session expands to
    /// two cells and the cap counts PANES, which needs the store. That expansion + cap, the dropped-pane
    /// report, target resolution (incl. the `--mru` recency lookup), the surface reparent, and the
    /// per-window controller all live app-side behind `ControlActions.setDashboard`
    /// (`ControlServer.setDashboard`); this forwards the ids as raw strings once their grammar is checked.
    func dispatchDashboard(_ request: ControlRequest) -> ControlResponse {
        let args = request.args
        let targets = args?.targets ?? []
        let fontSize = args?.fontSize
        let autoSize = args?.autoSize ?? false
        let mru = args?.mru ?? false

        if args?.close == true {
            guard targets.isEmpty, !mru, fontSize == nil, !autoSize else {
                return ControlResponse(ok: false, error: "dashboard --close takes no ids, --mru, or font options")
            }
            return actions.setDashboard(targets: [], window: args?.window, close: true, fontMode: .untouched, mru: false)
        }

        if fontSize != nil, autoSize {
            return ControlResponse(ok: false, error: "dashboard: --font-size is mutually exclusive with --auto-size")
        }
        if let fontSize, !fontSize.isFinite || fontSize <= 0 {
            return ControlResponse(ok: false, error: "dashboard --font-size must be a positive number")
        }
        let fontMode: DashboardFontMode = autoSize ? .auto : (fontSize.map(DashboardFontMode.fixed) ?? .untouched)
        if mru {
            guard targets.isEmpty else {
                return ControlResponse(ok: false, error: "dashboard --mru cannot be combined with explicit session ids")
            }
            return actions.setDashboard(targets: [], window: args?.window, close: false, fontMode: fontMode, mru: true)
        }
        guard !targets.isEmpty else {
            return ControlResponse(ok: false, error: "dashboard requires at least one session id")
        }
        // grammar only: a malformed pane suffix fails the command here, while a well-formed ref that
        // resolves to nothing is app-side and joins the `unresolved` note instead.
        if let malformed = targets.first(where: { DashboardTarget(rawValue: $0) == nil }) {
            return ControlResponse(
                ok: false,
                error: "dashboard: invalid session id '\(malformed)' — use <id>, <id>:left, or <id>:right")
        }
        return actions.setDashboard(targets: targets, window: args?.window, close: false, fontMode: fontMode, mru: false)
    }
}
