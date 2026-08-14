import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreNavigationTests {
    @Test func navigateSessionStaysWithinFocusedWorkspace() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        _ = store.addSession(toWorkspace: personal.id, cwd: "/b")!
        store.selectSession(a.id)
        store.setFocusedWorkspace(work.id)
        store.navigateSession(.next) // a is the only in-focus session, so the wrap cycles to itself
        #expect(store.selectedSessionID == a.id)
        #expect(store.focusedWorkspaceIDs == [work.id] && store.focusEnabled)
    }

    /// Builds a two-workspace tree (work: a, b; personal: c, d) so flattened order is [a, b, c, d].
    static func makeNavTree() -> (store: AppStore, ids: [UUID]) {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: work.id, cwd: "/b")!
        let c = store.addSession(toWorkspace: personal.id, cwd: "/c")!
        let d = store.addSession(toWorkspace: personal.id, cwd: "/d")!
        return (store, [a.id, b.id, c.id, d.id])
    }

    @Test func navigateNextStepsForwardCrossingWorkspaces() {
        let (store, ids) = Self.makeNavTree()
        store.selectSession(ids[0])
        store.navigateSession(.next)
        #expect(store.selectedSessionID == ids[1])
        store.navigateSession(.next)
        #expect(store.selectedSessionID == ids[2])
        store.navigateSession(.next)
        #expect(store.selectedSessionID == ids[3])
    }

    @Test func navigatePreviousStepsBackwardCrossingWorkspaces() {
        let (store, ids) = Self.makeNavTree()
        store.selectSession(ids[3])
        store.navigateSession(.previous)
        #expect(store.selectedSessionID == ids[2])
        store.navigateSession(.previous)
        #expect(store.selectedSessionID == ids[1])
        store.navigateSession(.previous)
        #expect(store.selectedSessionID == ids[0])
    }

    @Test func navigateNextAtLastWrapsToFirst() {
        let (store, ids) = Self.makeNavTree()
        store.selectSession(ids.last!)
        store.navigateSession(.next)
        #expect(store.selectedSessionID == ids.first!)
    }

    @Test func navigatePreviousAtFirstWrapsToLast() {
        let (store, ids) = Self.makeNavTree()
        store.selectSession(ids.first!)
        store.navigateSession(.previous)
        #expect(store.selectedSessionID == ids.last!)
    }

    @Test func navigateFirstAndLastJumpToEnds() {
        let (store, ids) = Self.makeNavTree()
        store.selectSession(ids[1])
        store.navigateSession(.last)
        #expect(store.selectedSessionID == ids.last!)
        store.navigateSession(.first)
        #expect(store.selectedSessionID == ids.first!)
    }

    @Test func navigateWithNoSelectionLandsOnFirst() {
        let (store, ids) = Self.makeNavTree()
        store.selectSession(nil)
        store.navigateSession(.next)
        #expect(store.selectedSessionID == ids.first!)
        store.selectSession(nil)
        store.navigateSession(.previous)
        #expect(store.selectedSessionID == ids.first!)
    }

    @Test func navigateFirstAndLastWithNoSelectionLandOnEnds() {
        let (store, ids) = Self.makeNavTree()
        store.selectSession(nil)
        store.navigateSession(.last)
        #expect(store.selectedSessionID == ids.last!)
        store.selectSession(nil)
        store.navigateSession(.first)
        #expect(store.selectedSessionID == ids.first!)
    }

    @Test func navigateSingleSessionStaysSelected() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let only = store.addSession(toWorkspace: ws.id, cwd: "/only")!
        store.selectSession(only.id)
        for direction in [SessionNavigation.next, .previous, .first, .last] {
            store.navigateSession(direction)
            #expect(store.selectedSessionID == only.id)
        }
    }

    @Test func navigateEmptyTreeIsNoOp() {
        let store = makeStore()
        store.addWorkspace(name: "work")
        store.navigateSession(.next)
        #expect(store.selectedSessionID == nil)
        store.navigateSession(.first)
        #expect(store.selectedSessionID == nil)
    }

    @Test func navigateRoutesThroughSelectSession() {
        let (store, ids) = Self.makeNavTree()
        store.session(withID: ids[1])?.unseenCount = 5
        store.selectSession(ids[0])
        store.navigateSession(.next)
        #expect(store.selectedSessionID == ids[1])
        #expect(store.session(withID: ids[1])?.unseenCount == 0)
        // recency is most-recent first, so the navigation tops the prior selection.
        #expect(Array(store.sessionRecency.items.prefix(2)) == [ids[1], ids[0]])
    }

    @Test func sessionNavigationWireMapping() {
        #expect(SessionNavigation(wire: "next") == .next)
        #expect(SessionNavigation(wire: "prev") == .previous)
        #expect(SessionNavigation(wire: "previous") == .previous)
        #expect(SessionNavigation(wire: "first") == .first)
        #expect(SessionNavigation(wire: "last") == .last)
        #expect(SessionNavigation(wire: "next-attention") == .nextAttention)
        #expect(SessionNavigation(wire: "prev-attention") == .previousAttention)
        #expect(SessionNavigation(wire: "previous-attention") == .previousAttention)
        #expect(SessionNavigation(wire: "sideways") == nil)
    }

    @Test func navigateAttentionStepsThroughAttentionSessionsOnly() {
        let (store, ids) = Self.makeNavTree()
        store.session(withID: ids[1])?.agentIndicator = AgentIndicator(status: .blocked)
        store.session(withID: ids[3])?.agentIndicator = AgentIndicator(status: .completed)
        store.selectSession(ids[0])
        store.navigateSession(.nextAttention)
        #expect(store.selectedSessionID == ids[1])
        store.navigateSession(.nextAttention)
        #expect(store.selectedSessionID == ids[3])
    }

    @Test func navigateAttentionWrapsAround() {
        let (store, ids) = Self.makeNavTree()
        store.session(withID: ids[1])?.agentIndicator = AgentIndicator(status: .blocked)
        store.session(withID: ids[3])?.agentIndicator = AgentIndicator(status: .completed)
        store.selectSession(ids[3])
        store.navigateSession(.nextAttention)
        #expect(store.selectedSessionID == ids[1])
        store.navigateSession(.previousAttention)
        #expect(store.selectedSessionID == ids[3])
    }

    @Test func navigateAttentionSkipsActiveAndIdle() {
        let (store, ids) = Self.makeNavTree()
        store.session(withID: ids[1])?.agentIndicator = AgentIndicator(status: .active)
        store.session(withID: ids[2])?.agentIndicator = AgentIndicator(status: .blocked)
        store.selectSession(ids[0])
        store.navigateSession(.nextAttention)
        #expect(store.selectedSessionID == ids[2])
    }

    @Test func navigateAttentionWithSingleAttentionSessionStaysPut() {
        let (store, ids) = Self.makeNavTree()
        store.session(withID: ids[2])?.agentIndicator = AgentIndicator(status: .completed)
        store.selectSession(ids[2])
        store.navigateSession(.nextAttention)
        #expect(store.selectedSessionID == ids[2])
        store.navigateSession(.previousAttention)
        #expect(store.selectedSessionID == ids[2])
    }

    @Test func navigateAttentionWithNoAttentionSessionsIsNoOp() {
        let (store, ids) = Self.makeNavTree()
        store.selectSession(ids[0])
        store.navigateSession(.nextAttention)
        #expect(store.selectedSessionID == ids[0])
    }

    @Test func navigateAttentionWithNoSelectionLandsOnAnAttentionEnd() {
        let (store, ids) = Self.makeNavTree()
        store.session(withID: ids[1])?.agentIndicator = AgentIndicator(status: .blocked)
        store.session(withID: ids[3])?.agentIndicator = AgentIndicator(status: .completed)
        // a nil selection acts as before-first going forward, after-last going backward.
        store.selectSession(nil)
        store.navigateSession(.nextAttention)
        #expect(store.selectedSessionID == ids[1])
        store.selectSession(nil)
        store.navigateSession(.previousAttention)
        #expect(store.selectedSessionID == ids[3])
    }

    // MARK: - navigation scoping (filtered set)

    @Test func navigableSessionsReflectsFlaggedFocusAndUnfocused() {
        let (store, ids) = Self.makeNavTree()
        #expect(store.navigableSessions.map(\.id) == ids)
        let work = store.workspace(forSession: ids[0])!
        store.setFocusedWorkspace(work.id)
        #expect(store.navigableSessions.map(\.id) == [ids[0], ids[1]])
        // marking an id that names no workspace is REFUSED by the mutator, so the focus survives intact.
        store.setFocusedWorkspace(UUID())
        #expect(store.navigableSessions.map(\.id) == [ids[0], ids[1]])
        // an all-stale set is only reachable by writing the fields directly (a hand-edited file that
        // skipped the restore prune); `visibleWorkspaces` then falls back to the whole tree, and nav with it.
        store.focusedWorkspaceIDs = [UUID()]
        store.focusEnabled = true
        #expect(store.navigableSessions.map(\.id) == ids)
        store.clearFocus()
        store.setFlag(true, forSession: ids[1])
        store.setFlag(true, forSession: ids[2])
        store.setSidebarMode(.flagged)
        #expect(store.navigableSessions.map(\.id) == [ids[1], ids[2]])
    }

    @Test func navigateScopesToFocusedWorkspace() {
        let (store, ids) = Self.makeNavTree()
        let work = store.workspace(forSession: ids[0])!
        store.setFocusedWorkspace(work.id)
        store.selectSession(ids[0])
        store.navigateSession(.next)
        #expect(store.selectedSessionID == ids[1])
        store.navigateSession(.next)
        #expect(store.selectedSessionID == ids[0])
        store.navigateSession(.last)
        #expect(store.selectedSessionID == ids[1])
        store.navigateSession(.first)
        #expect(store.selectedSessionID == ids[0])
        #expect(store.focusedWorkspaceIDs == [work.id] && store.focusEnabled)
    }

    /// Builds a three-workspace tree (work: a, b; personal: c, d; archive: e, f) so the flattened order is
    /// [a, b, c, d, e, f] — enough to mark a NON-CONTIGUOUS pair and prove nav walks both and skips the gap.
    static func makeThreeWorkspaceNavTree() -> (store: AppStore, workspaces: [UUID], sessions: [UUID]) {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let archive = store.addWorkspace(name: "archive")
        let sessions = [
            store.addSession(toWorkspace: work.id, cwd: "/a")!.id, store.addSession(toWorkspace: work.id, cwd: "/b")!.id,
            store.addSession(toWorkspace: personal.id, cwd: "/c")!.id, store.addSession(toWorkspace: personal.id, cwd: "/d")!.id,
            store.addSession(toWorkspace: archive.id, cwd: "/e")!.id, store.addSession(toWorkspace: archive.id, cwd: "/f")!.id,
        ]
        return (store, [work.id, personal.id, archive.id], sessions)
    }

    @Test func navigateScopesToEveryMemberOfAMultiWorkspaceSet() {
        let (store, workspaces, ids) = Self.makeThreeWorkspaceNavTree()
        store.setFocusMembership(workspaces[0], member: true)
        store.setFocusMembership(workspaces[2], member: true) // archive — the UNMARKED personal sits between them
        store.setFocusEnabled(true)
        #expect(store.navigableSessions.map(\.id) == [ids[0], ids[1], ids[4], ids[5]])
        store.selectSession(ids[0])
        store.navigateSession(.next)
        #expect(store.selectedSessionID == ids[1])
        store.navigateSession(.next)
        #expect(store.selectedSessionID == ids[4])
        store.navigateSession(.next)
        #expect(store.selectedSessionID == ids[5])
        store.navigateSession(.next)
        #expect(store.selectedSessionID == ids[0])
        store.navigateSession(.previous)
        #expect(store.selectedSessionID == ids[5])
        store.navigateSession(.previous)
        #expect(store.selectedSessionID == ids[4])
        store.navigateSession(.last)
        #expect(store.selectedSessionID == ids[5])
        store.navigateSession(.first)
        #expect(store.selectedSessionID == ids[0])
        // every target was in-set, so the filter never trips disableFocusIfSelectionOutsideSet
        #expect(store.focusedWorkspaceIDs == [workspaces[0], workspaces[2]] && store.focusEnabled)
    }

    @Test func navigateAttentionScopesToEveryMemberOfAMultiWorkspaceSet() {
        let (store, workspaces, ids) = Self.makeThreeWorkspaceNavTree()
        // b and f sit in the marked workspaces, d in the unmarked one between them.
        store.session(withID: ids[1])?.agentIndicator = AgentIndicator(status: .blocked)
        store.session(withID: ids[3])?.agentIndicator = AgentIndicator(status: .blocked)
        store.session(withID: ids[5])?.agentIndicator = AgentIndicator(status: .completed)
        store.setFocusMembership(workspaces[0], member: true)
        store.setFocusMembership(workspaces[2], member: true)
        store.setFocusEnabled(true)
        store.selectSession(ids[0])
        store.navigateSession(.nextAttention)
        #expect(store.selectedSessionID == ids[1])
        store.navigateSession(.nextAttention)
        #expect(store.selectedSessionID == ids[5])
        store.navigateSession(.nextAttention)
        #expect(store.selectedSessionID == ids[1])
    }

    @Test func navigateScopesToFlaggedSet() {
        let (store, ids) = Self.makeNavTree()
        store.setFlag(true, forSession: ids[0])
        store.setFlag(true, forSession: ids[2])
        store.setSidebarMode(.flagged)
        store.selectSession(ids[0])
        store.navigateSession(.next)
        #expect(store.selectedSessionID == ids[2])
        store.navigateSession(.next)
        #expect(store.selectedSessionID == ids[0])
        store.navigateSession(.first)
        #expect(store.selectedSessionID == ids[0])
    }

    @Test func navigateAttentionScopesToFocusedWorkspace() {
        let (store, ids) = Self.makeNavTree()
        // b lands in the focused workspace, d outside it.
        store.session(withID: ids[1])?.agentIndicator = AgentIndicator(status: .blocked)
        store.session(withID: ids[3])?.agentIndicator = AgentIndicator(status: .completed)
        let work = store.workspace(forSession: ids[0])!
        store.setFocusedWorkspace(work.id)
        store.selectSession(ids[0])
        store.navigateSession(.nextAttention)
        #expect(store.selectedSessionID == ids[1])
        store.navigateSession(.nextAttention)
        #expect(store.selectedSessionID == ids[1])
    }

    @Test func navigateRestoresFullSetWhenFocusCleared() {
        let (store, ids) = Self.makeNavTree()
        let work = store.workspace(forSession: ids[0])!
        store.setFocusedWorkspace(work.id)
        store.selectSession(ids[1])
        store.navigateSession(.next)
        #expect(store.selectedSessionID == ids[0])
        store.clearFocus()
        store.selectSession(ids[1])
        store.navigateSession(.next)
        #expect(store.selectedSessionID == ids[2])
    }

    // MARK: - attentionSessions

    @Test func attentionSessionsFiltersOutIdle() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        _ = store.addSession(toWorkspace: ws.id, cwd: "/idle")
        let active = store.addSession(toWorkspace: ws.id, cwd: "/active")!
        store.setAgentIndicator(AgentIndicator(status: .active), forSession: active.id)
        #expect(store.attentionSessions.map(\.id) == [active.id])
    }

    @Test func attentionSessionsOrderBlockedActiveCompleted() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let completed = store.addSession(toWorkspace: ws.id, cwd: "/c")!
        let active = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let blocked = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        // set in a non-rank order, so insertion order alone cannot pass this
        store.setAgentIndicator(AgentIndicator(status: .completed), forSession: completed.id)
        store.setAgentIndicator(AgentIndicator(status: .active), forSession: active.id)
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: blocked.id)
        #expect(store.attentionSessions.map(\.id) == [blocked.id, active.id, completed.id])
    }

    @Test func attentionSessionsWithinRankOrderNewestFirstNilLast() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let oldest = store.addSession(toWorkspace: ws.id, cwd: "/old")!
        let newest = store.addSession(toWorkspace: ws.id, cwd: "/new")!
        let unstamped = store.addSession(toWorkspace: ws.id, cwd: "/none")!
        // all three share a rank, so only the statusChangedAt tie-break is under test
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: oldest.id)
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: newest.id)
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: unstamped.id)
        oldest.statusChangedAt = Date(timeIntervalSince1970: 100)
        newest.statusChangedAt = Date(timeIntervalSince1970: 200)
        unstamped.statusChangedAt = nil
        #expect(store.attentionSessions.map(\.id) == [newest.id, oldest.id, unstamped.id])
    }

    @Test func attentionSessionsTieBreakStableForEqualAndNilStamps() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let stampedA = store.addSession(toWorkspace: ws.id, cwd: "/sa")!
        let stampedB = store.addSession(toWorkspace: ws.id, cwd: "/sb")!
        let nilA = store.addSession(toWorkspace: ws.id, cwd: "/na")!
        let nilB = store.addSession(toWorkspace: ws.id, cwd: "/nb")!
        // two share a stamp and two share nil, exercising the comparator's equal and (nil, nil) branches;
        // within each tie group the stable sort keeps insertion order.
        for s in [stampedA, stampedB, nilA, nilB] { store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: s.id) }
        stampedA.statusChangedAt = Date(timeIntervalSince1970: 500)
        stampedB.statusChangedAt = Date(timeIntervalSince1970: 500)
        nilA.statusChangedAt = nil
        nilB.statusChangedAt = nil
        #expect(store.attentionSessions.map(\.id) == [stampedA.id, stampedB.id, nilA.id, nilB.id])
    }

    @Test func attentionSessionsSpanAllWorkspacesIgnoringFocusAndFlagged() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let other = store.addWorkspace(name: "other")
        let here = store.addSession(toWorkspace: work.id, cwd: "/here")!
        let away = store.addSession(toWorkspace: other.id, cwd: "/away")!
        store.setAgentIndicator(AgentIndicator(status: .active), forSession: here.id)
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: away.id)
        store.setFocusedWorkspace(work.id)
        #expect(store.attentionSessions.map(\.id) == [away.id, here.id])
        // nothing is flagged, so a flagged-aware list would come back empty here
        store.setSidebarMode(.flagged)
        #expect(store.attentionSessions.map(\.id) == [away.id, here.id])
    }

    @Test func attentionSessionsEmptyWhenAllIdle() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        _ = store.addSession(toWorkspace: ws.id, cwd: "/a")
        _ = store.addSession(toWorkspace: ws.id, cwd: "/b")
        #expect(store.attentionSessions.isEmpty)
    }

    /// Three workspaces (work: a, b; personal: c; scratch: d) so a step's landing session is unambiguous.
    static func makeWorkspaceNavTree() -> (store: AppStore, workspaces: [UUID], sessions: [UUID]) {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let scratch = store.addWorkspace(name: "scratch")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: work.id, cwd: "/b")!
        let c = store.addSession(toWorkspace: personal.id, cwd: "/c")!
        let d = store.addSession(toWorkspace: scratch.id, cwd: "/d")!
        return (store, [work.id, personal.id, scratch.id], [a.id, b.id, c.id, d.id])
    }

    @Test func navigateWorkspaceNextStepsForwardAndWraps() throws {
        let (store, workspaces, sessions) = Self.makeWorkspaceNavTree()
        store.selectSession(sessions[1]) // b, the SECOND session of work
        #expect(try #require(store.navigateWorkspace(.next)).workspaceID == workspaces[1])
        #expect(store.selectedSessionID == sessions[2], "lands on the target's FIRST session")
        #expect(try #require(store.navigateWorkspace(.next)).workspaceID == workspaces[2])
        #expect(try #require(store.navigateWorkspace(.next)).workspaceID == workspaces[0])
        #expect(store.selectedSessionID == sessions[0])
    }

    @Test func navigateWorkspacePreviousStepsBackwardAndWraps() throws {
        let (store, workspaces, sessions) = Self.makeWorkspaceNavTree()
        store.selectSession(sessions[1]) // b, so previous leaves work from its middle
        #expect(try #require(store.navigateWorkspace(.previous)).workspaceID == workspaces[2])
        #expect(store.selectedSessionID == sessions[3])
        #expect(try #require(store.navigateWorkspace(.previous)).workspaceID == workspaces[1])
        #expect(store.selectedSessionID == sessions[2])
    }

    @Test func navigateWorkspaceStaysWithinTheFocusFilter() {
        let (store, workspaces, sessions) = Self.makeWorkspaceNavTree()
        store.selectSession(sessions[0])
        store.setFocusedWorkspace(workspaces[0])
        #expect(store.navigateWorkspace(.next) == nil, "a sole marked workspace has nowhere to step")
        #expect(store.selectedSessionID == sessions[0])
    }

    @Test func navigateWorkspaceIsANoOpInFlaggedMode() {
        let (store, _, sessions) = Self.makeWorkspaceNavTree()
        store.selectSession(sessions[0])
        store.setFlag(true, forSession: sessions[0])
        store.setSidebarMode(.flagged)
        #expect(store.navigateWorkspace(.next) == nil)
        #expect(store.selectedSessionID == sessions[0])
    }

    // a lone visible workspace is a dead end only while it is ALREADY current — when the filter hid the
    // current one, entering the sole survivor is the whole point of the step
    @Test func navigateWorkspaceEntersTheSoleVisibleWorkspaceWhenCurrentIsHidden() throws {
        let (store, workspaces, _) = Self.makeWorkspaceNavTree()
        store.setFocusMembership(workspaces[0], member: true)
        store.setFocusEnabled(true)
        store.selectSession(nil)
        #expect(store.visibleWorkspaces.map(\.id) == [workspaces[0]])
        #expect(store.currentWorkspaceID == workspaces[2], "the fallback sits outside the visible set")

        #expect(store.canStepWorkspaces, "the menu item must not go dead on a reachable workspace")
        #expect(try #require(store.navigateWorkspace(.next)).workspaceID == workspaces[0])
        #expect(!store.canStepWorkspaces, "and once inside the sole workspace there is nowhere left to step")
    }

    @Test func navigateWorkspaceIsANoOpWithOneWorkspace() {
        let store = makeStore()
        let only = store.addWorkspace(name: "only")
        let a = store.addSession(toWorkspace: only.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: only.id, cwd: "/b")!
        store.selectSession(b.id)
        #expect(store.navigateWorkspace(.next) == nil)
        #expect(store.selectedSessionID == b.id, "a lone workspace must not yank the selection to its first session")
        #expect(a.id != b.id)
    }

    // issue #435 assumed collapsing a workspace steers navigation. it does not, and must not: the fold is a
    // display state, so a step lands the same way whether or not the target is folded
    @Test func navigateWorkspaceIgnoresCollapseState() throws {
        let (store, workspaces, sessions) = Self.makeWorkspaceNavTree()
        store.selectSession(sessions[0])
        store.setWorkspaceExpanded(workspaces[1], expanded: false)
        #expect(try #require(store.navigateWorkspace(.next)).workspaceID == workspaces[1])
        #expect(store.selectedSessionID == sessions[2])
    }

    // the collapse toggle folds what the ROW shows, and a reveal opens a row without persisting, so reading
    // the persisted flag there spends the keystroke re-persisting instead of folding
    @Test func currentWorkspaceCollapseFollowsTheSidebarRowNotThePersistedFlag() {
        let (store, workspaces, sessions) = Self.makeWorkspaceNavTree()
        store.selectSession(sessions[0])
        store.setWorkspaceExpanded(workspaces[0], expanded: false)
        #expect(store.isCurrentWorkspaceCollapsed, "persisted collapsed with no row open reads collapsed")

        store.noteSidebarExpansion([workspaces[0]]) // the reveal opens the row, persisting nothing
        #expect(store.workspaces[0].isExpanded == false, "the reveal must not touch the persisted flag")
        #expect(!store.isCurrentWorkspaceCollapsed, "an open row reads expanded, so the toggle folds it")

        store.noteSidebarExpansion([])
        #expect(store.isCurrentWorkspaceCollapsed)
    }

    // with no sidebar mounted there is no row to read, so the persisted intent is the only state there is
    @Test func currentWorkspaceCollapseFallsBackToThePersistedFlagWithNoSidebar() {
        let (store, workspaces, sessions) = Self.makeWorkspaceNavTree()
        store.selectSession(sessions[0])
        store.noteSidebarExpansion([workspaces[0]])
        store.setSidebarVisible(false)
        store.setWorkspaceExpanded(workspaces[0], expanded: false)
        #expect(store.isCurrentWorkspaceCollapsed, "a stale live set must not outvote the persisted flag")

        store.setWorkspaceExpanded(workspaces[0], expanded: true)
        #expect(!store.isCurrentWorkspaceCollapsed)
    }

    // an empty destination has no session to select, so the selection stays behind and only the current
    // workspace moves — `tree` has to name the workspace `workspace.go` reported, not the one it left
    @Test func treeReportsTheEmptyWorkspaceAStepLandedOnAsActive() throws {
        let (store, workspaces, sessions) = Self.makeWorkspaceNavTree()
        let empty = store.addWorkspace(name: "empty", revealNewWorkspace: false)
        store.selectSession(sessions[0])

        let step = try #require(store.selectWorkspace(empty.id))
        #expect(step.workspaceID == empty.id)
        #expect(step.indicator == nil, "an empty workspace selects nothing, so it carries no indicator")
        #expect(store.selectedSessionID == sessions[0], "the selection stays where it was")

        let tree = store.controlTree()
        #expect(tree.workspaces.first(where: { $0.active })?.id == empty.id.uuidString)
        #expect(tree.workspaces.first(where: { $0.id == workspaces[0].uuidString })?.active == false)
    }

    @Test func currentWorkspaceCollapseIsFalseWithNoCurrentWorkspace() {
        let store = makeStore()
        #expect(store.currentWorkspaceID == nil)
        #expect(!store.isCurrentWorkspaceCollapsed)
    }

    // `currentWorkspaceID` falls back to the LAST workspace, which the filter can leave off screen — the
    // step has to enter the visible set rather than no-op there
    @Test func navigateWorkspaceEntersTheVisibleSetWhenCurrentIsOutsideIt() throws {
        let (store, workspaces, _) = Self.makeWorkspaceNavTree()
        store.setFocusMembership(workspaces[0], member: true)
        store.setFocusMembership(workspaces[1], member: true)
        store.setFocusEnabled(true)
        store.selectSession(nil)
        #expect(store.visibleWorkspaces.map(\.id) == [workspaces[0], workspaces[1]])
        #expect(store.currentWorkspaceID == workspaces[2], "the fallback sits outside the visible set")
        #expect(try #require(store.navigateWorkspace(.next)).workspaceID == workspaces[0])

        let (other, otherWorkspaces, _) = Self.makeWorkspaceNavTree()
        other.setFocusMembership(otherWorkspaces[0], member: true)
        other.setFocusMembership(otherWorkspaces[1], member: true)
        other.setFocusEnabled(true)
        other.selectSession(nil)
        #expect(try #require(other.navigateWorkspace(.previous)).workspaceID == otherWorkspaces[1],
                "previous enters from the other end")
    }
}
