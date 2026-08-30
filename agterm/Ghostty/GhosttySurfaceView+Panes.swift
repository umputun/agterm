import agtermCore

extension GhosttySurfaceView {
    // MARK: - Pane role

    /// `TerminalSurface` conformance: the model calls this when the primary pane exits and this split (right)
    /// pane is promoted to the session's sole pane. Clearing `isSplitPane` routes subsequent
    /// `applyPwd`/`applyTitle` reports to the main `session.currentCwd`/`oscTitle`, not `splitCwd`/`splitTitle`.
    func promoteToPrimaryPane() {
        setPaneRole(.primary)
    }

    /// `PaneRoleMutableSurface`: changes live routing only; the stable token and child environment stay baked.
    func setPaneRole(_ role: SwappablePaneRole) {
        isSplitPane = role == .split
    }

    /// `TerminalSurface.paneToken`: this surface's stable spawn identity, read straight back from the baked
    /// `AGTERM_PANE_ID` env value the shell also carries (empty for a surface spawned without a pane — the
    /// overlay / quick terminal). Distinct from the LIVE role (`isSplitPane`), which promotion flips; the
    /// token never changes, so `Session.paneRole(forToken:)` maps a status hook's `--pane-id` to the
    /// surface's CURRENT slot even after a promote + re-split (#199).
    var paneToken: String { env["AGTERM_PANE_ID"] ?? "" }
}
