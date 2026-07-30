import Foundation
import Observation

extension Notification.Name {
    /// Posted by `AppStore.autoFollowFire` after an idle auto-follow moves a window's selection to a blocked
    /// session; `userInfo` carries the target id and its pre-selection indicator. Host-free agtermCore cannot
    /// call the app-target's `focusActiveSession`, so the app-side observer resolves the owning window and,
    /// only when it is key, moves first responder in — selection alone doesn't, per the eager deck.
    public static let agtermAutoFollowed = Notification.Name("agterm.autoFollowed")

    /// Posted by `AppStore.setSidebarVisible` whenever a window's sidebar visibility changes. `window.list`
    /// is served from a cache refreshed after every control command and on frontmost changes, but a GUI-only
    /// toggle (⌃⌘S / toolbar / menu / palette) is neither, so `ControlServer` observes this to refresh it.
    /// The live `tree` reads it directly and needs no refresh.
    public static let agtermSidebarVisibilityChanged = Notification.Name("agterm.sidebarVisibilityChanged")
}

// MARK: - Auto-follow attention

/// After `autoFollowTimeout` of input idleness the window jumps its selection to the oldest blocked session,
/// pulling the user to whatever agent is waiting. The stored state lives on the main `AppStore` body —
/// Observation can't add stored properties in an extension.
extension AppStore {
    /// The `userInfo` key carrying the auto-followed session's `UUID`. `nonisolated` so both the poster and
    /// the app-target observer reach it without actor hops.
    public nonisolated static let autoFollowSessionIDKey = "sessionID"

    /// The `userInfo` key carrying the destination's pre-selection `AgentIndicator`, paired with
    /// `autoFollowSessionIDKey` so an `autoReset` status can still route focus after selection clears it.
    public nonisolated static let autoFollowIndicatorKey = "indicator"

    /// Records user interaction (a keystroke or a manual selection). Stamps `lastActivityAt` UNCONDITIONALLY
    /// so the idle metric is independent of the feature being enabled, then arms the `autoFollowFire`
    /// debouncer when a timeout is configured, cancelling any pending fire when not. Only USER entry points
    /// may call it — auto-follow's OWN `selectSession` would keep resetting its idle timer.
    public func noteUserActivity() {
        lastActivityAt = Date()
        guard let timeout = autoFollowTimeout else {
            autoFollowDebouncer.cancel()
            return
        }
        armAutoFollow(after: timeout)
    }

    /// Suppresses auto-follow while a non-terminal editor or overlay owns first responder (inline rename,
    /// command palette), balanced by `resumeAutoFollow`. Counted, so overlapping suppressors hold to the LAST.
    public func suppressAutoFollow() { autoFollowSuppressionCount += 1 }

    /// Lifts one suppression, clamped at zero so an unbalanced extra resume can't wedge the gate. Does NOT
    /// re-arm the debouncer (`autoFollowFire`'s no-reschedule contract); the next keystroke or change does.
    public func resumeAutoFollow() { autoFollowSuppressionCount = max(0, autoFollowSuppressionCount - 1) }

    /// The single debouncer-arming seam: schedule `autoFollowFire` after `delay`, weakly so a pending fire
    /// never keeps the store alive.
    private func armAutoFollow(after delay: TimeInterval) {
        autoFollowDebouncer.schedule(after: delay) { [weak self] in self?.autoFollowFire() }
    }

    /// Enables or disables auto-follow and reconciles the debouncer + status observation. A nil `timeout`
    /// DISABLES: pending fire dropped, and the status observer tears itself down (its coalesced re-arm stops
    /// re-registering once the timeout is nil, so the tracker dies on the next change). Off→on starts
    /// observing the attention set AND arms from the CURRENT state, so a user already idle with a block
    /// waiting is pulled after the grace. A changed timeout or `stayOnActive` while enabled re-arms (the
    /// observer stays registered) so the next fire re-evaluates: a changed grace uses the new delay, and
    /// `stayOnActive` turned OFF must stop an `active` current from suppressing a waiting block — it changes
    /// the fire DECISION, never the delay. Called by the Settings fan-out from
    /// `AppSettings.AutoFollowAttention`.
    public func setAutoFollow(timeout: TimeInterval?, stayOnActive: Bool) {
        let previousTimeout = autoFollowTimeout
        let previousStayOnActive = autoFollowStayOnActive
        autoFollowStayOnActive = stayOnActive
        autoFollowTimeout = timeout
        guard let timeout else {
            autoFollowDebouncer.cancel()
            return
        }
        // a bare stayOnActive flip has no pending fire to piggyback on, so it must arm one itself.
        if previousTimeout != timeout || previousStayOnActive != stayOnActive { armAutoFollow(after: timeout) }
        if previousTimeout == nil { observeAttentionForAutoFollow() }
    }

    /// Re-arms whenever the window's attention set changes while enabled, so a block that LANDS (or an
    /// `active` session that finishes) while the user is ALREADY idle gets the same grace a keystroke buys.
    /// Mirrors `DockBadgeController.apply`: re-registers on each change via a coalesced, deferred re-arm that
    /// self-tears-down when disabled.
    private func observeAttentionForAutoFollow() {
        withObservationTracking {
            _ = attentionSessions // the observable inputs: workspaces + each agentIndicator
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.scheduleAutoFollowRearm() } }
        }
    }

    /// Defers a single re-arm to the next runloop turn, coalescing the trackers one status change fires (the
    /// `DockBadgeController.scheduleRefresh` pattern). A nil timeout returns without re-registering.
    private func scheduleAutoFollowRearm() {
        guard !autoFollowRearmScheduled else { return }
        autoFollowRearmScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.autoFollowRearmScheduled = false
            guard let timeout = self.autoFollowTimeout else { return } // disabled: let the tracker die
            self.armAutoFollow(after: timeout)
            self.observeAttentionForAutoFollow()
        }
    }

    /// The pure auto-follow decision: which session the window should jump to, or nil to stay put. Suppresses
    /// when the current session is already `blocked` (you're on it) or, under `stayOnActive`, `active` (don't
    /// leave a running agent); skips a blocked session already `autoFollowConsumed` (pulled to once and left,
    /// muted until it re-enters blocked); else the oldest remaining `blocked` by `statusChangedAt` (FIFO), a
    /// missing stamp sorting last. `blocked` is the caller-supplied window-wide blocked set.
    func autoFollowTarget(current: Session?, blocked: [Session], stayOnActive: Bool) -> UUID? {
        if current?.agentIndicator.status == .blocked { return nil }
        if stayOnActive, current?.agentIndicator.status == .active { return nil }
        return blocked.filter { !$0.autoFollowConsumed }
            .min { ($0.statusChangedAt ?? .distantFuture) < ($1.statusChangedAt ?? .distantFuture) }?.id
    }

    /// Fires one auto-follow step: filters `attentionSessions` to `.blocked`, consults `autoFollowTarget` and
    /// selects any target. No target = no-op and NO reschedule — being parked on the blocked session is the
    /// suppressor until a keystroke re-arms the timer. The selection does NOT note activity, which would reset
    /// the idle timer on the app's own jump. Marks the target `autoFollowConsumed` so a later idle fire won't
    /// pull back until it re-enters blocked; `internal` for tests. Posts `.agtermAutoFollowed` after select.
    func autoFollowFire() {
        // suppressed (a rename field or palette owns first responder): no-op so the jump can't interrupt a
        // rename; no reschedule — the next keystroke or attention change re-arms once resumeAutoFollow lifts.
        guard autoFollowSuppressionCount == 0 else { return }
        let blocked = attentionSessions.filter { $0.agentIndicator.status == .blocked }
        guard let target = autoFollowTarget(current: activeSession, blocked: blocked,
                                            stayOnActive: autoFollowStayOnActive) else { return }
        let indicator = selectSession(target)
        // setAgentIndicator clears this flag when the session re-enters blocked, un-muting it.
        session(withID: target)?.autoFollowConsumed = true
        var userInfo: [String: Any] = [Self.autoFollowSessionIDKey: target]
        if let indicator { userInfo[Self.autoFollowIndicatorKey] = indicator }
        NotificationCenter.default.post(name: .agtermAutoFollowed, object: nil, userInfo: userInfo)
    }

    /// Milliseconds since `lastActivityAt`, or nil before any; clamped to >= 0 against clock skew. The idle
    /// metric the control `tree` exposes; `asOf` is injectable for deterministic tests.
    func idleMs(asOf now: Date = Date()) -> Int? {
        guard let lastActivityAt else { return nil }
        return max(0, Int(now.timeIntervalSince(lastActivityAt) * 1000))
    }

    /// The auto-follow timeout in milliseconds, nil when disabled — the projection `tree` (this store) and
    /// `window.list` (`WindowLibrary` per open store) share, so the `* 1000` scaling lives in one place.
    var autoFollowMs: Int? { autoFollowTimeout.map { Int($0 * 1000) } }
}
