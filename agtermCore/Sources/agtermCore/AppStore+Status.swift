import Foundation

// MARK: - Agent status & attention

/// The outcome of a control-channel status write, which `AppStore.applyControlStatus` may refuse.
public enum StatusWriteResult: Equatable, Sendable {
    case applied
    /// The write was dropped whole — no status change, no `statusChangedAt` restamp, no control event — because
    /// `owner` holds a blocked status this pane may not replace.
    case refused(owner: StatusPane)
}

/// The per-session agent-status indicator (the sidebar glyph driven by the control channel's `session.status`)
/// and the window-wide attention list derived from it. Split out of the main `AppStore` body for the file-size
/// budget, like `AppStore+AutoFollow`/`+Recency`/`+PendingClose`; the stored state lives on that main body.
extension AppStore {
    /// Applies a control-channel `session.status` write under the pane-precedence rule: while a session is
    /// blocked, a write from a DIFFERENT pane is refused unless it is itself `blocked` — a second pane really
    /// needing input. Without it one pane's ordinary `active`/`completed` erases the other's block and the
    /// session drops out of the attention list, which is the whole failure with an agent per pane. `idle` is
    /// NOT exempt: the bundled hooks emit it unprompted — Codex's `session-start`
    /// (`agterm-codex-status.sh`) and the shell integration's `precmd` after any matched agent exits — each
    /// tagged with its own pane, so exempting it would let starting an agent in one pane wipe the other's
    /// block. The owning pane clears its own status through any of them, and the GUI Clear Status paths
    /// bypass this rule entirely. Same-pane writes are unrestricted, so a single pane behaves exactly as
    /// before. Panes are compared AFTER `normalizedPane`, so a promoted survivor's stale `.right` matches the
    /// `.left` it is stored as.
    @discardableResult
    public func applyControlStatus(_ indicator: AgentIndicator, forSession id: UUID) -> StatusWriteResult {
        if let session = session(withID: id), session.agentIndicator.status == .blocked,
           indicator.status != .blocked {
            let owner = session.agentIndicator.normalizedPane(hasSplit: session.hasSplit) ?? .left
            let writer = indicator.normalizedPane(hasSplit: session.hasSplit) ?? .left
            if owner != writer { return .refused(owner: owner) }
        }
        setAgentIndicator(indicator, forSession: id)
        return .applied
    }

    /// Sets a session's agent status indicator (the sidebar status glyph) — the single mutation point for the
    /// control channel's `session.status`. Stamps `statusChangedAt` on any non-idle status (the attention
    /// list's newest-first sort key) and clears it on idle. Clears the session's `autoFollowConsumed` on a
    /// transition INTO blocked, re-arming idle auto-follow for the fresh episode. No-op for an unknown id.
    /// Not persisted (the indicator is ephemeral), so it never triggers a `save()`.
    public func setAgentIndicator(_ indicator: AgentIndicator, forSession id: UUID) {
        guard let session = session(withID: id) else { return }
        let previous = session.agentIndicator
        let wasBlocked = session.agentIndicator.status == .blocked
        var indicator = indicator
        // the fold itself is `AgentIndicator.normalizedPane`; gated on `hasSplit`, NOT `splitSurface == nil`:
        // `toggleSplit`/restore set `hasSplit` synchronously while the deck creates `splitSurface` a render
        // pass later, so a scripted `session.split` + immediate `session.status --pane right` lands in that
        // realization window, where `.right` is the correct forward tag and must NOT be rewritten.
        // `splitSurface != nil` implies `hasSplit` (only `closeSplit`/`closePrimaryPane` clear it, tearing the
        // surface down with it), so `!hasSplit` still covers every genuinely splitless session.
        indicator.statusPane = indicator.normalizedPane(hasSplit: session.hasSplit)
        session.agentIndicator = indicator
        session.statusChangedAt = indicator.status == .idle ? nil : Date()
        // a re-asserted blocked-over-blocked is not a new episode and stays muted (Session.autoFollowConsumed).
        if !wasBlocked, indicator.status == .blocked { session.autoFollowConsumed = false }
        guard previous != indicator else { return }
        emitControlEvent(
            .status,
            workspace: workspace(forSession: id)?.id,
            session: id,
            payload: ControlEventPayload(
                name: session.displayName,
                status: indicator.status.rawValue,
                pane: indicator.statusPane?.rawValue,
                blink: indicator.blink,
                color: indicator.color,
                shape: indicator.shape?.rawValue
            )
        )
    }

    /// The window-wide non-idle sessions, the single source of truth for the titlebar attention icon and the
    /// `.attention` palette. Spans ALL workspaces (`workspaces.flatMap(\.sessions)`) and deliberately IGNORES
    /// the focus/flagged sidebar filter (unlike `navigableSessions`) — the point is window-wide visibility even
    /// when the sidebar is hidden. Sorted by `attentionRank` ascending (blocked → active → completed) then
    /// `statusChangedAt` DESCENDING (newest first; a nil stamp sorts last within its rank group).
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
