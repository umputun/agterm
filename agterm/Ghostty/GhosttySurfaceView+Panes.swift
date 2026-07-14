extension GhosttySurfaceView {
    // MARK: - Pane role

    /// `TerminalSurface` conformance: the model calls this when the primary pane exits and this split
    /// (right) pane is promoted to the session's sole pane. Clears `isSplitPane` so subsequent
    /// `applyPwd`/`applyTitle` reports route to `session.currentCwd`/`oscTitle` (the main fields) rather
    /// than `splitCwd`/`splitTitle`.
    func promoteToPrimaryPane() {
        isSplitPane = false
    }

    /// `TerminalSurface.paneToken`: this surface's stable spawn identity, read straight back from the baked
    /// `AGTERM_PANE_ID` env value the shell also carries (empty for a surface spawned without a pane — the
    /// overlay / quick terminal). Distinct from the LIVE role (`isSplitPane`), which promotion flips; the
    /// token never changes, so `Session.paneRole(forToken:)` maps a status hook's `--pane-id` to the
    /// surface's CURRENT slot even after a promote + re-split (#199).
    var paneToken: String { env["AGTERM_PANE_ID"] ?? "" }
}
