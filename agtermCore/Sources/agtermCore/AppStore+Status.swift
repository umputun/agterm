import Foundation

// MARK: - Agent status & attention

/// The per-session agent-status indicator (the sidebar glyph driven by the control channel's
/// `session.status`) and the window-wide attention list derived from it. Split out of the main `AppStore`
/// body to keep it under the file-size budget, mirroring the `AppStore+AutoFollow`/`+Recency`/`+PendingClose`
/// split. The stored state lives on the main body; these operate over it.
extension AppStore {
    /// Sets a session's agent status indicator (the sidebar status glyph). The single mutation point
    /// for the control channel's `session.status`. Stamps `statusChangedAt` with the current time on any
    /// non-idle status (the attention list's newest-first sort key) and clears it on idle. Clears the
    /// session's `autoFollowConsumed` on a transition INTO blocked, re-arming idle auto-follow for the
    /// fresh episode. No-op for an unknown id. Not persisted (the indicator is ephemeral), so it never
    /// triggers a `save()`.
    public func setAgentIndicator(_ indicator: AgentIndicator, forSession id: UUID) {
        guard let session = session(withID: id) else { return }
        let wasBlocked = session.agentIndicator.status == .blocked
        var indicator = indicator
        // normalize a `.right` tag to `.left` when the session has NO split. A promoted survivor's
        // shell keeps its baked `AGTERM_PANE=right`, so the agent-status hook re-emits `--pane right` after
        // promotion even though there is no right pane — left unnormalized that re-creates the
        // `split:false` + `statusPane:"right"` contradiction the round-3 re-tag fixed, and the sole
        // (`.left`-role-aware) pane could never keystroke-clear it. A hidden-but-LIVE split keeps
        // `hasSplit`, so `.right` stays valid there. `.left`/`.scratch` are untouched.
        // gated on `hasSplit`, NOT `splitSurface == nil`: `toggleSplit`/restore set `hasSplit`
        // synchronously while the deck creates `splitSurface` a render pass later, so a scripted
        // `session.split` + immediate `session.status --pane right` lands in that realization window —
        // there `.right` is the correct forward tag and must NOT be rewritten. `splitSurface != nil`
        // implies `hasSplit` (only `closeSplit`/`closePrimaryPane` clear it, tearing the surface down
        // with it), so `!hasSplit` still covers every genuinely splitless session.
        if indicator.statusPane == .right, !session.hasSplit {
            indicator.statusPane = .left
        }
        session.agentIndicator = indicator
        session.statusChangedAt = indicator.status == .idle ? nil : Date()
        // a fresh block episode (entering blocked from a non-blocked status) re-arms idle auto-follow for
        // this session, so it can pull the user here once more; a re-asserted blocked-over-blocked is not a
        // new episode and stays muted (see Session.autoFollowConsumed).
        if !wasBlocked, indicator.status == .blocked { session.autoFollowConsumed = false }
    }

    /// The window-wide non-idle sessions, the single source of truth for the titlebar attention icon
    /// and the `.attention` palette. Spans ALL workspaces (`workspaces.flatMap(\.sessions)`) and
    /// deliberately IGNORES the focus/flagged sidebar filter (unlike `navigableSessions`) — the point
    /// is window-wide visibility even when the sidebar is hidden. Sorted by `attentionRank` ascending
    /// (blocked → active → completed) then `statusChangedAt` DESCENDING (newest change first; a nil
    /// stamp sorts last within its rank group).
    public var attentionSessions: [Session] {
        workspaces.flatMap(\.sessions)
            .filter { $0.agentIndicator.status != .idle }
            .sorted { lhs, rhs in
                let lrank = lhs.agentIndicator.status.attentionRank
                let rrank = rhs.agentIndicator.status.attentionRank
                if lrank != rrank { return lrank < rrank }
                switch (lhs.statusChangedAt, rhs.statusChangedAt) {
                case let (l?, r?): return l > r // newest change first within the rank group
                case (_?, nil): return true     // a stamped session sorts before an unstamped one
                case (nil, _?): return false
                case (nil, nil): return false
                }
            }
    }
}
