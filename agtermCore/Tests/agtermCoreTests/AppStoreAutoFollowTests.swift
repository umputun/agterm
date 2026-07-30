import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreAutoFollowTests {
    /// Adds a session to `workspace`, marks it `blocked`, and pins its `statusChangedAt` to a fixed time so
    /// FIFO ordering is deterministic (setAgentIndicator stamps `Date()`, which is then overridden).
    private func addBlocked(_ store: AppStore, to workspace: UUID, cwd: String, at time: TimeInterval) -> Session {
        let session = store.addSession(toWorkspace: workspace, cwd: cwd)!
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: session.id)
        session.statusChangedAt = Date(timeIntervalSince1970: time)
        return session
    }

    // MARK: - autoFollowTarget (pure decision)

    @Test func autoFollowTargetPicksOldestBlocked() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let older = addBlocked(store, to: ws.id, cwd: "/older", at: 100)
        let newer = addBlocked(store, to: ws.id, cwd: "/newer", at: 200)
        // order of the input array must not matter: min picks the earliest statusChangedAt (FIFO)
        #expect(store.autoFollowTarget(current: nil, blocked: [newer, older], stayOnActive: false) == older.id)
    }

    @Test func autoFollowTargetSuppressesWhenCurrentBlocked() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let current = addBlocked(store, to: ws.id, cwd: "/cur", at: 50)
        let other = addBlocked(store, to: ws.id, cwd: "/other", at: 200)
        #expect(store.autoFollowTarget(current: current, blocked: [current, other], stayOnActive: false) == nil)
        #expect(store.autoFollowTarget(current: current, blocked: [current, other], stayOnActive: true) == nil)
    }

    @Test func autoFollowTargetSuppressesActiveOnlyWhenStayOnActive() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let current = store.addSession(toWorkspace: ws.id, cwd: "/cur")!
        store.setAgentIndicator(AgentIndicator(status: .active), forSession: current.id)
        let blocked = addBlocked(store, to: ws.id, cwd: "/b", at: 100)
        #expect(store.autoFollowTarget(current: current, blocked: [blocked], stayOnActive: true) == nil)
        #expect(store.autoFollowTarget(current: current, blocked: [blocked], stayOnActive: false) == blocked.id)
    }

    @Test func autoFollowTargetEmptyBlockedIsNil() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let idle = store.addSession(toWorkspace: ws.id, cwd: "/idle")!
        #expect(store.autoFollowTarget(current: nil, blocked: [], stayOnActive: false) == nil)
        #expect(store.autoFollowTarget(current: idle, blocked: [], stayOnActive: false) == nil)
    }

    @Test func autoFollowTargetMissingStampSortsLast() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let stamped = addBlocked(store, to: ws.id, cwd: "/stamped", at: 500)
        let unstamped = store.addSession(toWorkspace: ws.id, cwd: "/unstamped")!
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: unstamped.id)
        unstamped.statusChangedAt = nil
        #expect(store.autoFollowTarget(current: nil, blocked: [unstamped, stamped], stayOnActive: false) == stamped.id)
    }

    // MARK: - autoFollowFire (window-wide filter + select)

    @Test func autoFollowFireSelectsOldestBlockedAcrossWorkspaces() {
        let store = makeStore()
        let here = store.addWorkspace(name: "here")
        let away = store.addWorkspace(name: "away")
        let idle = store.addSession(toWorkspace: here.id, cwd: "/idle")!
        let older = addBlocked(store, to: away.id, cwd: "/older", at: 100)
        _ = addBlocked(store, to: here.id, cwd: "/newer", at: 200)
        store.selectSession(idle.id)
        store.autoFollowFire()
        #expect(store.selectedSessionID == older.id)
    }

    @Test func autoFollowFireSuppressedWhenParkedOnBlocked() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let current = addBlocked(store, to: ws.id, cwd: "/cur", at: 50)
        _ = addBlocked(store, to: ws.id, cwd: "/other", at: 200)
        store.selectSession(current.id)
        store.autoFollowFire()
        #expect(store.selectedSessionID == current.id)
    }

    @Test func autoFollowFireNoOpWhenNoBlocked() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.setAgentIndicator(AgentIndicator(status: .active), forSession: b.id)
        store.selectSession(a.id)
        store.autoFollowFire()
        #expect(store.selectedSessionID == a.id)
    }

    @Test func autoFollowFireAdvancesAfterCurrentCleared() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let idle = store.addSession(toWorkspace: ws.id, cwd: "/idle")!
        let older = addBlocked(store, to: ws.id, cwd: "/older", at: 100)
        let newer = addBlocked(store, to: ws.id, cwd: "/newer", at: 200)
        store.selectSession(idle.id)
        store.autoFollowFire()
        #expect(store.selectedSessionID == older.id)
        store.setAgentIndicator(AgentIndicator(), forSession: older.id)
        store.autoFollowFire()
        #expect(store.selectedSessionID == newer.id)
    }

    @Test func autoFollowFireDoesNotNoteActivity() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let idle = store.addSession(toWorkspace: ws.id, cwd: "/idle")!
        _ = addBlocked(store, to: ws.id, cwd: "/b", at: 100)
        store.selectSession(idle.id)
        store.autoFollowFire()
        #expect(store.lastActivityAt == nil)
    }

    // MARK: - mute a block already followed (autoFollowConsumed)

    @Test func autoFollowTargetSkipsConsumedBlocked() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let older = addBlocked(store, to: ws.id, cwd: "/older", at: 100)
        let newer = addBlocked(store, to: ws.id, cwd: "/newer", at: 200)
        older.autoFollowConsumed = true
        #expect(store.autoFollowTarget(current: nil, blocked: [older, newer], stayOnActive: false) == newer.id)
        newer.autoFollowConsumed = true
        #expect(store.autoFollowTarget(current: nil, blocked: [older, newer], stayOnActive: false) == nil)
    }

    @Test func autoFollowFireMarksConsumedAndDoesNotReturn() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let idle = store.addSession(toWorkspace: ws.id, cwd: "/idle")!
        let x = addBlocked(store, to: ws.id, cwd: "/x", at: 100)
        store.selectSession(idle.id)
        store.autoFollowFire()
        #expect(store.selectedSessionID == x.id)
        #expect(x.autoFollowConsumed == true)
        store.selectSession(idle.id)
        store.autoFollowFire()
        #expect(store.selectedSessionID == idle.id)
    }

    @Test func autoFollowFireWalksEachBlockOnceThenStops() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let idle = store.addSession(toWorkspace: ws.id, cwd: "/idle")!
        let x = addBlocked(store, to: ws.id, cwd: "/x", at: 100)
        let z = addBlocked(store, to: ws.id, cwd: "/z", at: 200)
        store.selectSession(idle.id)
        store.autoFollowFire()
        #expect(store.selectedSessionID == x.id)
        store.selectSession(idle.id)
        store.autoFollowFire()
        #expect(store.selectedSessionID == z.id)
        store.selectSession(idle.id)
        store.autoFollowFire()
        #expect(store.selectedSessionID == idle.id)
    }

    @Test func autoFollowConsumedSurvivesBlockedReassert() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let idle = store.addSession(toWorkspace: ws.id, cwd: "/idle")!
        let x = addBlocked(store, to: ws.id, cwd: "/x", at: 100)
        store.selectSession(idle.id)
        store.autoFollowFire()
        #expect(x.autoFollowConsumed == true)
        store.selectSession(idle.id)
        // a hook re-asserts blocked OVER blocked (same value) -- not a new episode, so the mute holds
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: x.id)
        #expect(x.autoFollowConsumed == true)
        store.autoFollowFire()
        #expect(store.selectedSessionID == idle.id)
    }

    @Test func autoFollowFireReturnsAfterBlockReenters() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let idle = store.addSession(toWorkspace: ws.id, cwd: "/idle")!
        let x = addBlocked(store, to: ws.id, cwd: "/x", at: 100)
        store.selectSession(idle.id)
        store.autoFollowFire()
        store.selectSession(idle.id)
        store.autoFollowFire()
        #expect(store.selectedSessionID == idle.id)
        // blocked -> active -> blocked is a new episode, so it clears the mute
        store.setAgentIndicator(AgentIndicator(status: .active), forSession: x.id)
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: x.id)
        #expect(x.autoFollowConsumed == false)
        store.autoFollowFire()
        #expect(store.selectedSessionID == x.id)
    }

    @Test func selectSessionAloneDoesNotNoteActivity() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.selectSession(a.id)
        store.selectSession(b.id)
        // selectSession is the seam auto-follow itself drives, so it must not stamp; only the user entry
        // points, which pair it with noteUserActivity, buy the idle grace.
        #expect(store.lastActivityAt == nil)
        store.noteUserActivity()
        store.selectSession(a.id)
        #expect(store.lastActivityAt != nil)
    }

    // MARK: - suppression (non-terminal editor / palette owns first responder)

    @Test func autoFollowFireSuppressedWhileEditorActive() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let idle = store.addSession(toWorkspace: ws.id, cwd: "/idle")!
        let blocked = addBlocked(store, to: ws.id, cwd: "/b", at: 100)
        store.selectSession(idle.id)
        store.suppressAutoFollow() // a sidebar rename / command palette owns first responder
        store.autoFollowFire()
        #expect(store.selectedSessionID == idle.id)
        store.resumeAutoFollow()
        store.autoFollowFire()
        #expect(store.selectedSessionID == blocked.id)
    }

    @Test func autoFollowSuppressionNestsAndClampsAtZero() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let idle = store.addSession(toWorkspace: ws.id, cwd: "/idle")!
        let blocked = addBlocked(store, to: ws.id, cwd: "/b", at: 100)
        store.selectSession(idle.id)
        store.suppressAutoFollow() // two overlapping suppressors (e.g. a palette opened over a rename)
        store.suppressAutoFollow()
        store.resumeAutoFollow()
        store.autoFollowFire()
        #expect(store.selectedSessionID == idle.id)
        store.resumeAutoFollow()
        store.resumeAutoFollow() // an extra unbalanced resume must clamp at zero, not underflow the gate
        store.autoFollowFire()
        #expect(store.selectedSessionID == blocked.id)
    }

    // MARK: - noteUserActivity + idleMs

    @Test func noteUserActivityStampsLastActivity() {
        let store = makeStore()
        #expect(store.lastActivityAt == nil)
        #expect(store.idleMs() == nil)
        store.noteUserActivity()
        #expect(store.lastActivityAt != nil)
        #expect(store.idleMs() != nil)
    }

    @Test func idleMsComputesElapsedFromInjectedNow() {
        let store = makeStore()
        store.lastActivityAt = Date(timeIntervalSince1970: 1000)
        #expect(store.idleMs(asOf: Date(timeIntervalSince1970: 1002.5)) == 2500)
        #expect(store.idleMs(asOf: Date(timeIntervalSince1970: 1000)) == 0)
        // clock skew (now before last activity) clamps to zero rather than going negative
        #expect(store.idleMs(asOf: Date(timeIntervalSince1970: 999)) == 0)
    }

    @Test func noteUserActivityWithTimeoutSchedulesFire() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let idle = store.addSession(toWorkspace: ws.id, cwd: "/idle")!
        let blocked = addBlocked(store, to: ws.id, cwd: "/b", at: 100)
        store.selectSession(idle.id)
        store.autoFollowTimeout = 100 // long delay so only the manual flush drives the fire
        store.noteUserActivity()
        store.autoFollowDebouncer.flush()
        #expect(store.selectedSessionID == blocked.id)
    }

    @Test func noteUserActivityWithoutTimeoutCancelsFire() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let idle = store.addSession(toWorkspace: ws.id, cwd: "/idle")!
        _ = addBlocked(store, to: ws.id, cwd: "/b", at: 100)
        store.selectSession(idle.id)
        store.autoFollowTimeout = 100
        store.noteUserActivity()
        store.autoFollowTimeout = nil
        store.noteUserActivity()
        store.autoFollowDebouncer.flush()
        #expect(store.selectedSessionID == idle.id)
    }

    // MARK: - setAutoFollow lifecycle + status-change arming

    @Test func setAutoFollowEnableStoresStateAndArmsFromCurrent() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let idle = store.addSession(toWorkspace: ws.id, cwd: "/idle")!
        let blocked = addBlocked(store, to: ws.id, cwd: "/b", at: 100)
        store.selectSession(idle.id)
        store.setAutoFollow(timeout: 100, stayOnActive: false)
        #expect(store.autoFollowTimeout == 100)
        #expect(store.autoFollowStayOnActive == false)
        store.autoFollowDebouncer.flush()
        #expect(store.selectedSessionID == blocked.id)
    }

    @Test func setAutoFollowEnableStoresStayOnActive() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let active = store.addSession(toWorkspace: ws.id, cwd: "/active")!
        store.setAgentIndicator(AgentIndicator(status: .active), forSession: active.id)
        _ = addBlocked(store, to: ws.id, cwd: "/b", at: 100)
        store.selectSession(active.id)
        store.setAutoFollow(timeout: 100, stayOnActive: true)
        #expect(store.autoFollowStayOnActive == true)
        store.autoFollowDebouncer.flush()
        #expect(store.selectedSessionID == active.id)
    }

    @Test func setAutoFollowDisableCancelsPendingFire() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let idle = store.addSession(toWorkspace: ws.id, cwd: "/idle")!
        _ = addBlocked(store, to: ws.id, cwd: "/b", at: 100)
        store.selectSession(idle.id)
        store.setAutoFollow(timeout: 100, stayOnActive: false)
        store.setAutoFollow(timeout: nil, stayOnActive: false)
        #expect(store.autoFollowTimeout == nil)
        store.autoFollowDebouncer.flush()
        #expect(store.selectedSessionID == idle.id)
    }

    @Test func autoFollowFireSelfTriggerTerminates() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let completed = store.addSession(toWorkspace: ws.id, cwd: "/done")!
        let blocked = addBlocked(store, to: ws.id, cwd: "/b", at: 100)
        store.selectSession(completed.id) // select first, THEN stamp the one-time glyph so it rides selected
        store.setAgentIndicator(AgentIndicator(status: .completed, autoReset: true), forSession: completed.id)
        store.autoFollowFire()
        #expect(store.selectedSessionID == blocked.id)
        // moving away cleared completed's autoReset glyph, which is itself an indicator change the observer
        // re-arms on; that self-trigger must not loop.
        #expect(completed.agentIndicator.status == .idle)
        store.autoFollowFire()
        #expect(store.selectedSessionID == blocked.id)
    }

    @Test func statusChangeWhileEnabledArmsAutoFollow() async {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let idle = store.addSession(toWorkspace: ws.id, cwd: "/idle")!
        let s = store.addSession(toWorkspace: ws.id, cwd: "/s")! // idle at enable, so the observer tracks it
        store.selectSession(idle.id)
        store.setAutoFollow(timeout: 100, stayOnActive: false)
        store.autoFollowDebouncer.flush() // consume the enable's arm; nothing is blocked yet
        #expect(store.selectedSessionID == idle.id)
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: s.id)
        // the re-arm rides a coalesced, deferred chain (currently two main-queue hops), so drain-then-flush
        // in a bounded loop rather than a fixed drain count coupled to that depth.
        for _ in 0..<20 {
            await drainMainQueue()
            store.autoFollowDebouncer.flush()
            if store.selectedSessionID == s.id { break }
        }
        #expect(store.selectedSessionID == s.id)
    }

    @Test func setAutoFollowTimeoutChangeWhileEnabledRearms() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let idle = store.addSession(toWorkspace: ws.id, cwd: "/idle")!
        let blocked = addBlocked(store, to: ws.id, cwd: "/b", at: 100)
        store.selectSession(idle.id)
        store.setAutoFollow(timeout: 100, stayOnActive: false)
        store.setAutoFollow(timeout: 30, stayOnActive: false)
        #expect(store.autoFollowTimeout == 30)
        // previousTimeout != nil here, so the status observer is not re-registered — only the debouncer re-arms.
        store.autoFollowDebouncer.flush()
        #expect(store.selectedSessionID == blocked.id)
    }

    @Test func setAutoFollowStayOnActiveChangeWhileEnabledRearms() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let active = store.addSession(toWorkspace: ws.id, cwd: "/active")!
        store.setAgentIndicator(AgentIndicator(status: .active), forSession: active.id)
        let blocked = addBlocked(store, to: ws.id, cwd: "/b", at: 100)
        store.selectSession(active.id)
        store.setAutoFollow(timeout: 100, stayOnActive: true)
        store.autoFollowDebouncer.flush()
        #expect(store.selectedSessionID == active.id)
        // the SAME grace leaves no pending fire (the last one no-op'd), so the config change alone has to
        // re-arm and re-decide.
        store.setAutoFollow(timeout: 100, stayOnActive: false)
        store.autoFollowDebouncer.flush()
        #expect(store.selectedSessionID == blocked.id)
    }

    @Test func setAutoFollowDisableStopsStatusRearm() async {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let idle = store.addSession(toWorkspace: ws.id, cwd: "/idle")!
        let s = store.addSession(toWorkspace: ws.id, cwd: "/s")! // idle at enable, so the observer tracks it
        store.selectSession(idle.id)
        store.setAutoFollow(timeout: 100, stayOnActive: false)
        store.autoFollowDebouncer.flush() // consume the enable's arm; nothing is blocked yet
        store.setAutoFollow(timeout: nil, stayOnActive: false)
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: s.id)
        // a missing re-arm is a non-event that can't be polled for, so drain well past the re-arm's ~2-hop
        // depth to give any stray one every chance to fire before asserting nothing armed.
        for _ in 0..<20 { await drainMainQueue() }
        store.autoFollowDebouncer.flush()
        #expect(store.selectedSessionID == idle.id)
    }

    // MARK: - Control tree projection (idleMs live, autoFollowMs config) + the focus-bridge notification

    @Test func controlTreeProjectsIdleAndAutoFollowMs() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        _ = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        var tree = store.controlTree()
        #expect(tree.idleMs == nil)
        #expect(tree.autoFollowMs == nil)
        store.autoFollowTimeout = 30
        store.lastActivityAt = Date()
        tree = store.controlTree()
        #expect(tree.autoFollowMs == 30_000)
        #expect((tree.idleMs ?? -1) >= 0)
        store.autoFollowTimeout = nil
        #expect(store.controlTree().autoFollowMs == nil)
    }

    @Test func autoFollowFirePostsFollowedNotification() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let idle = store.addSession(toWorkspace: ws.id, cwd: "/idle")!
        let blocked = addBlocked(store, to: ws.id, cwd: "/b", at: 100)
        store.selectSession(idle.id)
        blocked.hasSplit = true
        let expectedIndicator = AgentIndicator(
            status: .blocked, autoReset: true, statusPane: .right
        )
        store.setAgentIndicator(expectedIndicator, forSession: blocked.id)
        blocked.statusChangedAt = Date(timeIntervalSince1970: 100)
        // the app-target focus bridge routes off the posted PRE-selection indicator, so the auto-reset clear
        // must not erase it.
        let box = NotificationBox()
        let token = NotificationCenter.default.addObserver(forName: .agtermAutoFollowed, object: nil,
                                                           queue: nil) { note in
            box.sessionID = note.userInfo?[AppStore.autoFollowSessionIDKey] as? UUID
            box.indicator = note.userInfo?[AppStore.autoFollowIndicatorKey] as? AgentIndicator
        }
        defer { NotificationCenter.default.removeObserver(token) }
        store.autoFollowFire()
        #expect(store.selectedSessionID == blocked.id)
        #expect(blocked.agentIndicator == AgentIndicator())
        #expect(box.sessionID == blocked.id)
        #expect(box.indicator == expectedIndicator)
    }

    /// Deterministically drains one round of `DispatchQueue.main.async` work by enqueuing a marker after
    /// the pending blocks and awaiting it (FIFO). No timed wait, so the drain stays flake-free.
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

/// A Sendable reference box so the `queue: nil` `.agtermAutoFollowed` observer (a `@Sendable` block) can
/// hand the captured session id back to the synchronous test body. The post is synchronous with no
/// suspension between register and read, so the single write races nothing.
private final class NotificationBox: @unchecked Sendable {
    var sessionID: UUID?
    var indicator: AgentIndicator?
}
