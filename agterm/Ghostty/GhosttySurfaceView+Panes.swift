import agtermCore

extension GhosttySurfaceView {
    // MARK: - Pane role

    /// `TerminalSurface` conformance: the model calls this when the primary pane exits and this split (right)
    /// pane is promoted to the session's sole pane. Clearing `isSplitPane` routes subsequent
    /// `applyPwd`/`applyTitle` reports to the main `session.currentCwd`/`oscTitle`, not `splitCwd`/`splitTitle`.
    func promoteToPrimaryPane() {
        isSplitPane = false
    }

    /// Which of the owner's pane slots this surface fills, for the per-pane visual config. A scratch has no
    /// `session` (only `watermarkSession`), and the live `isSplitPane` — not the surface's identity — decides
    /// left vs right, so a promoted split reads the main pane's slot. Nil for a sessionless overlay / quick
    /// terminal, which carry neither link.
    var paneSlot: StatusPane? {
        if session == nil { return watermarkSession != nil ? .scratch : nil }
        return isSplitPane ? .right : .left
    }

    /// This surface's theme override, nil when it follows the app-wide theme: a pane's from the owning
    /// session's slot, a sessionless overlay's from its own `--theme`.
    var paneThemeOverride: ThemeOverride? {
        guard let pane = paneSlot else { return overlayTheme }
        return (session ?? watermarkSession)?.themeOverride(for: pane)
    }

    /// `TerminalSurface.paneToken`: this surface's stable spawn identity, read straight back from the baked
    /// `AGTERM_PANE_ID` env value the shell also carries (empty for a surface spawned without a pane — the
    /// overlay / quick terminal). Distinct from the LIVE role (`isSplitPane`), which promotion flips; the
    /// token never changes, so `Session.paneRole(forToken:)` maps a status hook's `--pane-id` to the
    /// surface's CURRENT slot even after a promote + re-split (#199).
    var paneToken: String { env["AGTERM_PANE_ID"] ?? "" }
}
