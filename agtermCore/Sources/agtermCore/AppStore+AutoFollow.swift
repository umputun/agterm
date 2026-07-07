import Foundation
import Observation

extension Notification.Name {
    /// Posted by `AppStore.autoFollowFire` right after an idle auto-follow moves a window's selection to a
    /// blocked session, carrying the target session id under `AppStore.autoFollowSessionIDKey`. agtermCore
    /// is host-free and cannot call the app-target's `focusActiveSession`, so it posts this instead; the
    /// app-side observer resolves the owning window and — only when that window is key — moves first
    /// responder into the newly selected session (selection alone does not move it, since the eager deck
    /// keeps the prior surface as first responder).
    public static let agtermAutoFollowed = Notification.Name("agterm.autoFollowed")

    /// Posted by `AppStore.setSidebarVisible` whenever a window's sidebar visibility actually changes.
    /// `window.list` is served from a background-thread cache refreshed after every control command and on
    /// frontmost changes, but a GUI-only sidebar toggle (⌃⌘S / toolbar / menu / palette) is neither — so
    /// the app-target `ControlServer` observes this to refresh the cache, keeping `window.list`'s
    /// `sidebarVisible` honest (the live `tree` reads it directly and needs no refresh).
    public static let agtermSidebarVisibilityChanged = Notification.Name("agterm.sidebarVisibilityChanged")
}

// MARK: - Auto-follow attention

/// After the user has been idle from input for `autoFollowTimeout`, the window jumps its selection to the
/// oldest blocked session, pulling the user to whatever agent is waiting for input. The activity stamp,
/// the pure target decision, the fire path, and the idle metric live here; the stored state lives on the
/// main `AppStore` body (Observation can't add stored properties in an extension).
extension AppStore {
    /// The `userInfo` key carrying the auto-followed session's `UUID` in an `.agtermAutoFollowed`
    /// notification. `nonisolated` so the app-target observer (reading it off the notification on the main
    /// queue) and the poster below both reach it without actor hops.
    public nonisolated static let autoFollowSessionIDKey = "sessionID"

    /// Records user interaction with this window (a keystroke or a manual selection). Stamps
    /// `lastActivityAt` UNCONDITIONALLY so the idle metric is independent of the feature being enabled,
    /// then — only when a timeout is configured — arms the debouncer to fire `autoFollowFire` after the
    /// idle window; when disabled it cancels any pending fire. Auto-follow's OWN `selectSession` must NOT
    /// call this (only user entry points do), else the jump would keep resetting its own idle timer.
    public func noteUserActivity() {
        lastActivityAt = Date()
        guard let timeout = autoFollowTimeout else {
            autoFollowDebouncer.cancel()
            return
        }
        armAutoFollow(after: timeout)
    }

    /// Suppresses auto-follow for this window while a non-terminal editor or transient overlay owns first
    /// responder — the app calls this when the sidebar inline-rename field opens or a command palette opens.
    /// Balanced by `resumeAutoFollow` when it closes. Bracketing (rather than a bare bool) lets the several
    /// suppressors overlap: a nested suppressor keeps the jump suppressed until the LAST one lifts.
    public func suppressAutoFollow() { autoFollowSuppressionCount += 1 }

    /// Lifts one auto-follow suppression (the paired call to `suppressAutoFollow` when the editor/overlay
    /// closes). Clamped at zero so an unbalanced extra resume can't drive the count negative and wedge the
    /// gate. Does NOT re-arm the debouncer — matching `autoFollowFire`'s no-reschedule contract; the next
    /// keystroke or attention change re-arms normally.
    public func resumeAutoFollow() { autoFollowSuppressionCount = max(0, autoFollowSuppressionCount - 1) }

    /// The single debouncer-arming seam the activity stamp, the enable/grace-change path, and the
    /// status-change re-arm all share: schedule `autoFollowFire` after `delay`. `[weak self]` so a pending
    /// fire never keeps the store alive.
    private func armAutoFollow(after delay: TimeInterval) {
        autoFollowDebouncer.schedule(after: delay) { [weak self] in self?.autoFollowFire() }
    }

    /// Enables or disables auto-follow for this window and reconciles the debouncer + status observation.
    /// A nil `timeout` DISABLES: it drops any pending fire and lets the status observer tear itself down
    /// (its coalesced re-arm returns without re-registering once the timeout is nil, so the live tracker
    /// dies on the next change). A non-nil `timeout` ENABLES: on the off→on transition it starts observing
    /// the window's attention set AND arms the debouncer from the CURRENT state, so a user already idle with
    /// a block waiting is pulled after the grace window; a timeout OR stayOnActive CHANGE while already
    /// enabled re-arms the debouncer (the observer stays registered) so the next fire re-evaluates from the
    /// new config — a changed grace re-arms to the new delay, and a changed stayOnActive re-decides for a
    /// block already waiting (turning the toggle OFF must stop an active current suppressing that block).
    /// `stayOnActive` is stored either way (it affects the fire DECISION, and a change to it re-arms so the
    /// decision is re-run — it never changes the delay). Called by the Settings fan-out (public); the
    /// resolved `timeout`/`stayOnActive` come from `AppSettings.AutoFollowAttention`.
    public func setAutoFollow(timeout: TimeInterval?, stayOnActive: Bool) {
        let previousTimeout = autoFollowTimeout
        let previousStayOnActive = autoFollowStayOnActive
        autoFollowStayOnActive = stayOnActive
        autoFollowTimeout = timeout
        guard let timeout else {
            autoFollowDebouncer.cancel() // disable: drop the pending fire; the observer self-tears-down
            return
        }
        // (re-)arm on the off->on enable, a changed grace, OR a changed stayOnActive: each can change the
        // outcome of the next fire for a block already waiting while the user is idle (a bare stayOnActive
        // flip has no pending fire to piggyback on, so it must arm one itself).
        if previousTimeout != timeout || previousStayOnActive != stayOnActive { armAutoFollow(after: timeout) }
        if previousTimeout == nil { observeAttentionForAutoFollow() } // start tracking on the off->on edge
    }

    /// Re-arms the auto-follow debouncer whenever the window's attention set changes while enabled, so a
    /// block that LANDS (or an `active` session that finishes) while the user is ALREADY idle gets the same
    /// idle grace a keystroke would buy. Mirrors `DockBadgeController.apply`: reads the observable inputs
    /// inside `withObservationTracking` and re-registers itself on the next change via a coalesced, deferred
    /// re-arm. Self-tears-down when disabled — the re-arm returns without re-registering once the timeout is
    /// nil, so the live tracker dies on the next change.
    private func observeAttentionForAutoFollow() {
        withObservationTracking {
            _ = attentionSessions // read the observable inputs (workspaces + each agentIndicator); value unused
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.scheduleAutoFollowRearm() } }
        }
    }

    /// Defers a single re-arm to the next runloop turn, coalescing the several trackers a status change can
    /// fire into one (the `DockBadgeController.scheduleRefresh` pattern). Re-arms the debouncer from the
    /// current state and re-registers the observer — but only while still enabled; a nil timeout (disabled)
    /// returns without re-registering, so the observation chain ends and the tracker is not renewed.
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

    /// The pure auto-follow decision (host-free, unit-tested): which session the window should jump to, or
    /// nil to stay put. Suppresses when the current session is already `blocked` (you're on it) or — when
    /// `stayOnActive` is on — `active` (don't leave a running agent); otherwise returns the oldest `blocked`
    /// session by `statusChangedAt` ascending (FIFO), or nil when `blocked` is empty. A missing stamp sorts
    /// last, so a stamped session is always preferred. `blocked` is the window-wide blocked set the caller
    /// supplies.
    func autoFollowTarget(current: Session?, blocked: [Session], stayOnActive: Bool) -> UUID? {
        if current?.agentIndicator.status == .blocked { return nil }
        if stayOnActive, current?.agentIndicator.status == .active { return nil }
        return blocked.min { ($0.statusChangedAt ?? .distantFuture) < ($1.statusChangedAt ?? .distantFuture) }?.id
    }

    /// Fires one auto-follow step: computes the window-wide blocked set (the non-idle `attentionSessions`
    /// filtered to `.blocked`), consults `autoFollowTarget`, and selects the target when there is one. A
    /// no-op (no target) does nothing and does NOT reschedule — being parked on the blocked session is
    /// itself the suppressor until a keystroke clears it and re-arms the timer. Selection here deliberately
    /// does NOT note activity (that would reset the idle timer on the app's own jump). `internal` so tests
    /// can drive it directly. Posts `.agtermAutoFollowed` after the select so the app target can move first
    /// responder into the target (selection alone doesn't, per the eager deck) when its window is key.
    func autoFollowFire() {
        // a non-terminal editor/overlay (sidebar inline rename, command palette) owns first responder:
        // no-op so the jump can't interrupt a rename or reshuffle a palette's target. no reschedule — the
        // next keystroke or attention change re-arms once the editor closes and resumeAutoFollow lifts this.
        guard autoFollowSuppressionCount == 0 else { return }
        let blocked = attentionSessions.filter { $0.agentIndicator.status == .blocked }
        guard let target = autoFollowTarget(current: activeSession, blocked: blocked,
                                            stayOnActive: autoFollowStayOnActive) else { return }
        selectSession(target)
        NotificationCenter.default.post(name: .agtermAutoFollowed, object: nil,
                                        userInfo: [Self.autoFollowSessionIDKey: target])
    }

    /// Milliseconds since the last user activity (`lastActivityAt`), or nil before any activity. Clamped to
    /// >= 0 so a clock skew can't yield a negative idle. The live idle metric the control `tree` exposes;
    /// `asOf` is injectable for deterministic tests.
    func idleMs(asOf now: Date = Date()) -> Int? {
        guard let lastActivityAt else { return nil }
        return max(0, Int(now.timeIntervalSince(lastActivityAt) * 1000))
    }

    /// The configured auto-follow timeout in milliseconds, or nil when disabled. The control projection of
    /// `autoFollowTimeout` shared by the `tree` (this store) and `window.list` (`WindowLibrary` per open
    /// store), so the `* 1000` scaling lives in one place.
    var autoFollowMs: Int? { autoFollowTimeout.map { Int($0 * 1000) } }
}
