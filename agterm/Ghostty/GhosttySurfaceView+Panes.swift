extension GhosttySurfaceView {
    // MARK: - Pane role

    /// `TerminalSurface` conformance: the model calls this when the primary pane exits and this split
    /// (right) pane is promoted to the session's sole pane. Clears `isSplitPane` so subsequent
    /// `applyPwd`/`applyTitle` reports route to `session.currentCwd`/`oscTitle` (the main fields) rather
    /// than `splitCwd`/`splitTitle`.
    func promoteToPrimaryPane() {
        isSplitPane = false
    }
}
