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
        // parked on a blocked session -> stay put, regardless of another older/newer block
        #expect(store.autoFollowTarget(current: current, blocked: [current, other], stayOnActive: false) == nil)
        #expect(store.autoFollowTarget(current: current, blocked: [current, other], stayOnActive: true) == nil)
    }

    @Test func autoFollowTargetSuppressesActiveOnlyWhenStayOnActive() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let current = store.addSession(toWorkspace: ws.id, cwd: "/cur")!
        store.setAgentIndicator(AgentIndicator(status: .active), forSession: current.id)
        let blocked = addBlocked(store, to: ws.id, cwd: "/b", at: 100)
        // opt-in on: don't leave a running agent
        #expect(store.autoFollowTarget(current: current, blocked: [blocked], stayOnActive: true) == nil)
        // opt-in off: an active current does not suppress
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
        unstamped.statusChangedAt = nil // a missing stamp is treated as newest, so the stamped one wins
        #expect(store.autoFollowTarget(current: nil, blocked: [unstamped, stamped], stayOnActive: false) == stamped.id)
    }

    // MARK: - autoFollowFire (window-wide filter + select)

    @Test func autoFollowFireSelectsOldestBlockedAcrossWorkspaces() {
        let store = makeStore()
        let here = store.addWorkspace(name: "here")
        let away = store.addWorkspace(name: "away")
        let idle = store.addSession(toWorkspace: here.id, cwd: "/idle")!
        let older = addBlocked(store, to: away.id, cwd: "/older", at: 100) // window-wide: another workspace
        _ = addBlocked(store, to: here.id, cwd: "/newer", at: 200)
        store.selectSession(idle.id)
        store.autoFollowFire()
        #expect(store.selectedSessionID == older.id) // jumps to the oldest blocked, crossing workspaces
    }

    @Test func autoFollowFireSuppressedWhenParkedOnBlocked() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let current = addBlocked(store, to: ws.id, cwd: "/cur", at: 50)
        _ = addBlocked(store, to: ws.id, cwd: "/other", at: 200)
        store.selectSession(current.id)
        store.autoFollowFire()
        #expect(store.selectedSessionID == current.id) // stays; being on a blocked session is the suppressor
    }

    @Test func autoFollowFireNoOpWhenNoBlocked() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.setAgentIndicator(AgentIndicator(status: .active), forSession: b.id)
        store.selectSession(a.id)
        store.autoFollowFire()
        #expect(store.selectedSessionID == a.id) // no blocked session -> no jump
    }

    @Test func autoFollowFireAdvancesAfterCurrentCleared() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let idle = store.addSession(toWorkspace: ws.id, cwd: "/idle")!
        let older = addBlocked(store, to: ws.id, cwd: "/older", at: 100)
        let newer = addBlocked(store, to: ws.id, cwd: "/newer", at: 200)
        store.selectSession(idle.id)
        store.autoFollowFire()
        #expect(store.selectedSessionID == older.id) // first fire -> oldest
        store.setAgentIndicator(AgentIndicator(), forSession: older.id) // typing a reply clears the block
        store.autoFollowFire()
        #expect(store.selectedSessionID == newer.id) // next fire advances to the next oldest
    }

    @Test func autoFollowFireDoesNotNoteActivity() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let idle = store.addSession(toWorkspace: ws.id, cwd: "/idle")!
        _ = addBlocked(store, to: ws.id, cwd: "/b", at: 100)
        store.selectSession(idle.id)
        store.autoFollowFire()
        #expect(store.lastActivityAt == nil) // the app's own jump must not stamp activity (no self-reset)
    }

    @Test func selectSessionAloneDoesNotNoteActivity() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.selectSession(a.id)
        store.selectSession(b.id)
        // selectSession is the shared seam auto-follow also drives; it must stay silent so the app's own
        // jump never resets the idle timer. only the user entry points (which pair it with noteUserActivity)
        // count -- Task 4 wires those, not selectSession itself.
        #expect(store.lastActivityAt == nil)
        // a user-initiated selection (the AppActions nav wrappers / sidebar row click) additionally calls
        // noteUserActivity, which DOES stamp -- this is what buys the idle grace.
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
        #expect(store.selectedSessionID == idle.id) // suppressed: the armed jump no-ops, selection stays put
        store.resumeAutoFollow() // editor/overlay closed
        store.autoFollowFire()
        #expect(store.selectedSessionID == blocked.id) // resumed: the next fire follows the waiting block
    }

    @Test func autoFollowSuppressionNestsAndClampsAtZero() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let idle = store.addSession(toWorkspace: ws.id, cwd: "/idle")!
        let blocked = addBlocked(store, to: ws.id, cwd: "/b", at: 100)
        store.selectSession(idle.id)
        store.suppressAutoFollow() // two overlapping suppressors (e.g. a palette opened over a rename)
        store.suppressAutoFollow()
        store.resumeAutoFollow() // one lifts; the other still holds
        store.autoFollowFire()
        #expect(store.selectedSessionID == idle.id) // still suppressed while any suppressor holds
        store.resumeAutoFollow() // both lifted
        store.resumeAutoFollow() // an extra unbalanced resume clamps at zero (no underflow wedging the gate)
        store.autoFollowFire()
        #expect(store.selectedSessionID == blocked.id) // fully resumed -> follows the block
    }

    // MARK: - noteUserActivity + idleMs

    @Test func noteUserActivityStampsLastActivity() {
        let store = makeStore()
        #expect(store.lastActivityAt == nil)
        #expect(store.idleMs() == nil) // nil before any activity
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
        store.autoFollowDebouncer.flush() // drive the scheduled fire deterministically
        #expect(store.selectedSessionID == blocked.id)
    }

    @Test func noteUserActivityWithoutTimeoutCancelsFire() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let idle = store.addSession(toWorkspace: ws.id, cwd: "/idle")!
        _ = addBlocked(store, to: ws.id, cwd: "/b", at: 100)
        store.selectSession(idle.id)
        store.autoFollowTimeout = 100
        store.noteUserActivity() // schedules a fire
        store.autoFollowTimeout = nil
        store.noteUserActivity() // disabled now -> cancels the pending fire
        store.autoFollowDebouncer.flush() // nothing pending
        #expect(store.selectedSessionID == idle.id) // no jump when disabled
    }

    // MARK: - setAutoFollow lifecycle + status-change arming

    @Test func setAutoFollowEnableStoresStateAndArmsFromCurrent() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let idle = store.addSession(toWorkspace: ws.id, cwd: "/idle")!
        let blocked = addBlocked(store, to: ws.id, cwd: "/b", at: 100)
        store.selectSession(idle.id)
        store.setAutoFollow(timeout: 100, stayOnActive: false) // enable arms a fire from the current state
        #expect(store.autoFollowTimeout == 100)
        #expect(store.autoFollowStayOnActive == false)
        store.autoFollowDebouncer.flush() // drive the enable's arm deterministically
        #expect(store.selectedSessionID == blocked.id) // already-idle user is pulled to the waiting block
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
        #expect(store.selectedSessionID == active.id) // stayOnActive suppresses leaving a running agent
    }

    @Test func setAutoFollowDisableCancelsPendingFire() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let idle = store.addSession(toWorkspace: ws.id, cwd: "/idle")!
        _ = addBlocked(store, to: ws.id, cwd: "/b", at: 100)
        store.selectSession(idle.id)
        store.setAutoFollow(timeout: 100, stayOnActive: false) // arms a fire
        store.setAutoFollow(timeout: nil, stayOnActive: false) // disable cancels it
        #expect(store.autoFollowTimeout == nil)
        store.autoFollowDebouncer.flush() // nothing pending after cancel
        #expect(store.selectedSessionID == idle.id) // no jump once disabled
    }

    @Test func autoFollowFireSelfTriggerTerminates() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let completed = store.addSession(toWorkspace: ws.id, cwd: "/done")!
        let blocked = addBlocked(store, to: ws.id, cwd: "/b", at: 100)
        store.selectSession(completed.id) // select first, THEN stamp the one-time glyph so it rides selected
        store.setAgentIndicator(AgentIndicator(status: .completed, autoReset: true), forSession: completed.id)
        store.autoFollowFire()
        #expect(store.selectedSessionID == blocked.id) // jumps to the block
        // moving away cleared completed's autoReset glyph — the agentIndicator change the observer re-arms
        // on. that self-trigger must not loop: the next fire is now parked on the block, so it no-ops.
        #expect(completed.agentIndicator.status == .idle)
        store.autoFollowFire()
        #expect(store.selectedSessionID == blocked.id) // stays put -> the cycle terminates, no loop
    }

    @Test func statusChangeWhileEnabledArmsAutoFollow() async {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let idle = store.addSession(toWorkspace: ws.id, cwd: "/idle")!
        let s = store.addSession(toWorkspace: ws.id, cwd: "/s")! // idle at enable, so the observer tracks it
        store.selectSession(idle.id)
        store.setAutoFollow(timeout: 100, stayOnActive: false)
        store.autoFollowDebouncer.flush() // consume the enable's arm (no-op: nothing blocked yet)
        #expect(store.selectedSessionID == idle.id)
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: s.id) // a block LANDS while idle
        // the block landing re-arms the debouncer through a coalesced, deferred chain (observer onChange ->
        // scheduleAutoFollowRearm, currently two main-queue hops). drain-then-flush in a bounded loop until the
        // re-armed fire lands, so a deeper deferral chain can't silently break this (vs a fixed drain count
        // coupled to the depth). deterministic: each drain is a FIFO marker (no real sleep) and a flush before
        // the re-arm arms is a harmless no-op.
        for _ in 0..<20 {
            await drainMainQueue()
            store.autoFollowDebouncer.flush()
            if store.selectedSessionID == s.id { break }
        }
        #expect(store.selectedSessionID == s.id) // the status change armed the follow, which then jumped
    }

    @Test func setAutoFollowTimeoutChangeWhileEnabledRearms() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let idle = store.addSession(toWorkspace: ws.id, cwd: "/idle")!
        let blocked = addBlocked(store, to: ws.id, cwd: "/b", at: 100)
        store.selectSession(idle.id)
        store.setAutoFollow(timeout: 100, stayOnActive: false) // enable at a long grace
        store.setAutoFollow(timeout: 30, stayOnActive: false) // change the grace while still enabled -> re-arm
        #expect(store.autoFollowTimeout == 30)
        // the changed grace re-armed the debouncer from the current state (previousTimeout != nil, so the
        // status observer is NOT re-registered — only the debouncer re-arms); the flush drives that fire.
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
        store.setAutoFollow(timeout: 100, stayOnActive: true) // enable: an active current suppresses the block
        store.autoFollowDebouncer.flush()
        #expect(store.selectedSessionID == active.id) // stayOnActive keeps us on the running agent
        // toggle stayOnActive OFF at the SAME grace: no pending fire remains (the last one no-op'd), so the
        // config change alone must re-arm and re-decide, else the waiting block is never followed.
        store.setAutoFollow(timeout: 100, stayOnActive: false)
        store.autoFollowDebouncer.flush()
        #expect(store.selectedSessionID == blocked.id) // no longer suppressed -> follows the waiting block
    }

    @Test func setAutoFollowDisableStopsStatusRearm() async {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let idle = store.addSession(toWorkspace: ws.id, cwd: "/idle")!
        let s = store.addSession(toWorkspace: ws.id, cwd: "/s")! // idle at enable, so the observer tracks it
        store.selectSession(idle.id)
        store.setAutoFollow(timeout: 100, stayOnActive: false) // enable + start observing
        store.autoFollowDebouncer.flush() // consume the enable's arm (nothing blocked yet)
        store.setAutoFollow(timeout: nil, stayOnActive: false) // DISABLE before any block lands
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: s.id) // a block lands AFTER disable
        // disabled: the surviving observer tracker must self-tear-down WITHOUT re-arming. this is a non-event,
        // so it can't be polled for — instead drain generously (well past the re-arm's ~2-hop depth) to give
        // any stray re-arm every chance to fire, then confirm nothing armed: the flush stays a no-op and the
        // selection never moves. deterministic: each drain is a FIFO marker, no real sleep.
        for _ in 0..<20 { await drainMainQueue() }
        store.autoFollowDebouncer.flush() // nothing should be pending
        #expect(store.selectedSessionID == idle.id) // disabled: the one-shot tracker self-teardown means no re-arm
    }

    // MARK: - Control tree projection (idleMs live, autoFollowMs config) + the focus-bridge notification

    @Test func controlTreeProjectsIdleAndAutoFollowMs() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        _ = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        // before any activity + disabled: both live fields are nil.
        var tree = store.controlTree()
        #expect(tree.idleMs == nil)
        #expect(tree.autoFollowMs == nil)
        // a configured timeout projects as ms (the * 1000 scaling) and activity makes idleMs live (>= 0).
        store.autoFollowTimeout = 30
        store.lastActivityAt = Date()
        tree = store.controlTree()
        #expect(tree.autoFollowMs == 30_000)
        #expect((tree.idleMs ?? -1) >= 0)
        // disabling clears autoFollowMs back to nil.
        store.autoFollowTimeout = nil
        #expect(store.controlTree().autoFollowMs == nil)
    }

    @Test func autoFollowFirePostsFollowedNotification() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let idle = store.addSession(toWorkspace: ws.id, cwd: "/idle")!
        let blocked = addBlocked(store, to: ws.id, cwd: "/b", at: 100)
        store.selectSession(idle.id)
        // the app-target focus bridge relies on this post carrying the auto-followed session id: observe it
        // (queue nil so the synchronous post delivers inline, before the fire returns) and assert the id.
        let box = NotificationBox()
        let token = NotificationCenter.default.addObserver(forName: .agtermAutoFollowed, object: nil,
                                                           queue: nil) { note in
            box.sessionID = note.userInfo?[AppStore.autoFollowSessionIDKey] as? UUID
        }
        defer { NotificationCenter.default.removeObserver(token) }
        store.autoFollowFire()
        #expect(store.selectedSessionID == blocked.id)
        #expect(box.sessionID == blocked.id)
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
}
