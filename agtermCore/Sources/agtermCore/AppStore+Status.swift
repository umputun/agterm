import Foundation

// MARK: - Agent status & attention

/// The outcome of a control-channel status write through `AppStore.applyControlStatus`.
public enum StatusWriteResult: Equatable, Sendable {
    /// `applied` is an accepted pane update, even when another pane's status keeps the row unchanged.
    case applied
    /// `skipped` is an `ifIdle` write that met a non-idle row and was dropped whole: no change, stamp or event.
    case skipped
    /// `refused` is never returned; it keeps downstream matches on the retired pane-precedence refusal compiling.
    case refused(owner: StatusPane)
}

/// The per-session agent-status indicator (the sidebar glyph driven by the control channel's `session.status`)
/// and the window-wide attention list derived from it. Split out of the main `AppStore` body for the file-size
/// budget, like `AppStore+AutoFollow`/`+Recency`/`+PendingClose`; the stored state lives on that main body.
extension AppStore {
    /// Applies a control-channel `session.status` write. The writing pane's activity is recorded first, then the row
    /// shows what the panes say together: a block holds against another pane's writes (`idle` included, which the
    /// bundled hooks emit unprompted from their own pane), and a pane's completed or idle shows another pane's
    /// retained `active` while one is still working. Every write but an `ifIdle` skip is accepted, so a write the
    /// row does not show still counts and its sound still plays. Panes are compared AFTER `normalizedPane`, so a
    /// promoted survivor's stale `.right` matches the `.left` it is stored as.
    @discardableResult
    public func applyControlStatus(_ indicator: AgentIndicator, forSession id: UUID,
                                   ifIdle: Bool = false) -> StatusWriteResult {
        guard let session = session(withID: id) else { return .applied }
        if ifIdle, session.agentIndicator.status != .idle { return .skipped }
        let writer = indicator.normalizedPane(hasSplit: session.hasSplit) ?? .left
        let before = session.paneActivity[writer] != nil
        session.paneActivity[writer] = indicator.status == .active ? indicator : nil
        let shown = session.agentIndicator
        let ending = indicator.status == .completed || indicator.status == .idle
        // another pane finishing here says nothing about the origin's ongoing work
        let originWorks = ending && shown.status == .active && session.remotePresentation?.statusBridged == true
        if (shown.status == .blocked && indicator.status != .blocked) || originWorks,
           (shown.normalizedPane(hasSplit: session.hasSplit) ?? .left) != writer {
            noteMirroredActivity(indicator.status == .active, pane: writer, of: session)
            if before != (session.paneActivity[writer] != nil) { publishStatus(of: session) }
            return .applied
        }
        setAgentIndicator(ending ? remainingActivity(of: session) ?? indicator : indicator, forSession: id)
        return .applied
    }

    /// clearStatus(by:) applies typing in `pane`. An interrupt ends that pane's retained activity whether or not the
    /// row shows it, or a cancelled turn would come back when the shown pane finishes. The shown status clears when
    /// `pane` owns it and `reset` allows, leaving what the other panes still run.
    public func clearStatus(by keystroke: StatusKeystroke, pane: StatusPane, reset: StatusReset, forSession id: UUID) {
        guard let session = session(withID: id) else { return }
        let dropped = keystroke == .interrupt && session.paneActivity.removeValue(forKey: pane) != nil
        if session.agentIndicator.clearedBy(pane: pane, keystroke: keystroke, reset: reset) {
            showRemainingActivity(of: session)
        } else if dropped {
            publishStatus(of: session)
        }
    }

    /// clearPaneStatus ends what `pane` reported when it goes away: its retained activity, and the shown status when
    /// it owns that, leaving what the other panes still run. Without it a pane-tagged block would outlive the only
    /// surface that could keystroke-clear it. A nil tag counts as `.left`.
    func clearPaneStatus(_ pane: StatusPane, of session: Session) {
        let dropped = session.paneActivity.removeValue(forKey: pane) != nil
        if session.agentIndicator.status != .idle, (session.agentIndicator.statusPane ?? .left) == pane {
            showRemainingActivity(of: session)
        } else if dropped {
            publishStatus(of: session)
        }
    }

    func showRemainingActivity(of session: Session) {
        setAgentIndicator(remainingActivity(of: session) ?? AgentIndicator(), forSession: session.id)
    }

    /// activePanes is the read-back of the panes still reporting work: the origin's list on a row showing its
    /// status, nil when that origin sends none, otherwise this store's own.
    func activePanes(of session: Session) -> [String]? {
        if session.remotePresentation?.statusBridged == true { return mirroredActivePanes(of: session)?.map(\.rawValue) }
        return StatusPane.allCases.filter { session.paneActivity[$0] != nil }.map(\.rawValue)
    }

    private func remainingActivity(of session: Session) -> AgentIndicator? {
        for pane in StatusPane.allCases {
            guard var activity = session.paneActivity[pane] else { continue }
            activity.statusPane = pane
            return activity
        }
        return nil
    }

    private func publishStatus(of session: Session) {
        presentationHub?.publish(.status(presentationStatus(of: session)), session: session.id)
    }

    /// Sets a session's agent status indicator, the single mutation point for `session.status`. Stamps
    /// `statusChangedAt` on every set, idle and repeated values included. Idle also ends every pane's retained
    /// activity, so a direct clear cannot leave cancelled work to reappear. A transition into blocked re-arms
    /// idle auto-follow. No-op for an unknown id; never persisted.
    public func setAgentIndicator(_ indicator: AgentIndicator, forSession id: UUID) {
        guard let session = session(withID: id) else { return }
        // any write through here is a local one until `applyRemoteStatus` says otherwise right after it
        session.remotePresentation?.statusBridged = false
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
        if indicator.status == .idle { session.paneActivity.removeAll() }
        session.statusChangedAt = Date()
        // a re-asserted blocked-over-blocked is not a new episode and stays muted (Session.autoFollowConsumed).
        if !wasBlocked, indicator.status == .blocked { session.autoFollowConsumed = false }
        // ahead of the unchanged guard: a repeated write restamps `statusChangedAt`, which a viewer orders by
        publishStatus(of: session)
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
                shape: indicator.shape?.rawValue,
                previous: previous.status.rawValue
            )
        )
    }

    /// clearStatus ends a session's status by hand or by selection. By hand clears every pane's activity; a selection
    /// ends only the shown pane's, so another pane still working stays on the row. An attached row also asks its
    /// origin, whose answer is the same, so the glyph does not come back with the next snapshot.
    public func clearStatus(_ id: UUID, reason: PresentationClearReason = .manual) {
        guard let session = session(withID: id) else { return }
        if session.remotePresentation?.statusBridged == true {
            _ = sendToOrigin(.statusClear(PresentationStatusClear(reason: reason)), forSession: id)
        }
        endStatus(of: session, reason: reason)
    }

    /// applyPresenterClear is the origin's side of `status.clear`: a keystroke clears what its pane owns under this
    /// origin's `reset`, a selection clears an auto-reset status, a manual clear always clears. A clear naming no
    /// pane of the session, or a reason this build does not know, changes nothing.
    public func applyPresenterClear(_ clear: PresentationStatusClear, forSession id: UUID, reset: StatusReset) {
        guard let session = session(withID: id), session.agentIndicator.status != .idle, let reason = clear.reason else { return }
        switch reason {
        case .manual: endStatus(of: session, reason: .manual)
        case .select:
            guard session.agentIndicator.autoReset else { return }
            endStatus(of: session, reason: .select)
        case .viewed: return
        case .key, .submit, .interrupt:
            guard let keystroke = reason.keystroke, let pane = clear.pane.flatMap({ originPane($0, in: session) }) else { return }
            clearStatus(by: keystroke, pane: pane, reset: reset, forSession: id)
        }
    }

    private func endStatus(of session: Session, reason: PresentationClearReason) {
        if reason == .select {
            session.paneActivity[session.agentIndicator.statusPane ?? .left] = nil
            showRemainingActivity(of: session)
            return
        }
        session.paneActivity.removeAll()
        setAgentIndicator(AgentIndicator(), forSession: session.id)
    }

    /// applyPresenterSeen is the origin's side of `status.seen`: a viewed session loses its badge, and typing does
    /// when this origin's `badgeReset` says it does.
    public func applyPresenterSeen(_ seen: PresentationSeen, forSession id: UUID, badgeReset: StatusReset) {
        guard let reason = seen.reason else { return }
        switch reason {
        case .viewed: break
        case .key, .submit, .interrupt:
            guard let keystroke = reason.keystroke, badgeReset.clearsBadge(on: keystroke) else { return }
        case .select, .manual: return
        }
        clearUnseen(id)
    }

    private func originPane(_ pane: PresentationPane, in session: Session) -> StatusPane? {
        switch pane {
        case .scratch: return .scratch
        case .identity(let identity):
            if identity == session.paneIdentity { return .left }
            if session.hasSplit, identity == session.splitPaneIdentity { return .right }
            return identity == session.scratchDaemon?.identity ? .scratch : nil
        }
    }

    /// Marks each idle session `completed` so it rejoins the attention list until the usual keystroke, Clear
    /// Status or hook write clears it. No `autoReset`, or merely visiting the session would undo the mark; a
    /// non-idle session is skipped so a live `active` or `blocked` is never overwritten.
    public func markForAttention(_ sessionIDs: [UUID]) {
        for id in sessionIDs where session(withID: id)?.agentIndicator.status == .idle {
            setAgentIndicator(AgentIndicator(status: .completed), forSession: id)
        }
    }

    /// The window's non-idle sessions across ALL workspaces, ignoring the focus/flagged sidebar filter
    /// (unlike `navigableSessions`) so they stay visible with the sidebar hidden. Ordered by `attentionPrecedes`.
    public var attentionSessions: [Session] {
        workspaces.flatMap(\.sessions)
            .filter { $0.agentIndicator.status != .idle }
            .sorted(by: Self.attentionPrecedes)
    }

    /// Whether attention navigation lands on `session`: `needsAttention`, or `active` under
    /// `attentionIncludesActive`. Shared with `WindowLibrary.attentionStep`.
    func stopsAttentionNavigation(_ session: Session) -> Bool {
        let status = session.agentIndicator.status
        return status.needsAttention || (attentionIncludesActive && status == .active)
    }

    /// The attention order every attention list shares, so the per-window and cross-window lists cannot
    /// drift: `attentionRank` ascending (blocked → active → completed), then `statusChangedAt` DESCENDING
    /// (newest first; a nil stamp sorts last within its rank group).
    public static func attentionPrecedes(_ lhs: Session, _ rhs: Session) -> Bool {
        let lrank = lhs.agentIndicator.status.attentionRank
        let rrank = rhs.agentIndicator.status.attentionRank
        if lrank != rrank { return lrank < rrank }
        switch (lhs.statusChangedAt, rhs.statusChangedAt) {
        case let (l?, r?): return l > r
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return false
        }
    }
}
