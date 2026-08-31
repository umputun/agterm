import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreTests {
    @Test func emptyStoreHasNoSelectionOrActiveSession() {
        let store = makeStore()
        #expect(store.workspaces.isEmpty)
        #expect(store.selectedSessionID == nil)
        #expect(store.activeSession == nil)
    }

    @Test func sidebarVisibleDefaultsTrueAndToggles() {
        let store = makeStore()
        #expect(store.sidebarVisible)
        store.toggleSidebarVisible()
        #expect(!store.sidebarVisible)
        store.setSidebarVisible(true)
        #expect(store.sidebarVisible)
        store.setSidebarVisible(true)
        #expect(store.sidebarVisible)
    }

    @Test func defaultWorkspaceNameCountsUp() {
        let store = makeStore()
        #expect(store.defaultWorkspaceName == "workspace 1")
        store.addWorkspace(name: "work")
        #expect(store.defaultWorkspaceName == "workspace 2")
    }

    @Test func addWorkspaceAppends() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        #expect(store.workspaces.map(\.id) == [work.id, personal.id])
        #expect(store.workspaces.map(\.name) == ["work", "personal"])
    }

    @Test func addSessionAppendsAndSelects() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/tmp")
        let unwrapped = try! #require(session)
        #expect(store.workspaces[0].sessions.map(\.id) == [unwrapped.id])
        #expect(unwrapped.initialCwd == "/tmp")
        #expect(store.selectedSessionID == unwrapped.id)
        #expect(store.activeSession?.id == unwrapped.id)
    }

    @Test func addSessionWithoutSelectLeavesSelectionUntouched() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let first = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        #expect(store.selectedSessionID == first.id)
        // the control `session.new --no-select` path: appended, but selection and recency untouched
        let background = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/b", select: false))
        #expect(store.workspaces[0].sessions.map(\.id) == [first.id, background.id])
        #expect(store.selectedSessionID == first.id)
        #expect(store.activeSession?.id == first.id)
        #expect(store.sessionRecency.items == [first.id]) // the background add was not recorded
    }

    @Test func addSessionCarriesInitialCommand() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let withCmd = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/tmp", command: "ssh host"))
        #expect(withCmd.initialCommand == "ssh host")
        let plain = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/tmp"))
        #expect(plain.initialCommand == nil)
    }

    @Test func addSessionCarriesCommandWait() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let held = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/tmp", command: "make test", wait: true))
        #expect(held.commandWait == true)
        // default is false — a command session closes when its command exits.
        let plain = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/tmp", command: "make test"))
        #expect(plain.commandWait == false)
    }

    @Test func addSessionSeedsCustomName() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let named = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/tmp", name: "myhost"))
        #expect(named.customName == "myhost")
        #expect(named.displayName == "myhost")
        // blank/whitespace name clears to nil, leaving the auto basename (matches renameSession).
        let blank = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/tmp", name: "  "))
        #expect(blank.customName == nil)
        let plain = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/tmp"))
        #expect(plain.customName == nil)
    }

    @Test func addSessionToUnknownWorkspaceReturnsNil() {
        let store = makeStore()
        #expect(store.addSession(toWorkspace: UUID(), cwd: "/tmp") == nil)
        #expect(store.selectedSessionID == nil)
    }

    @Test func workspaceNamedFindsExactTrimmedMatch() {
        let store = makeStore()
        let servers = store.addWorkspace(name: "servers")
        store.addWorkspace(name: "other")
        #expect(store.workspace(named: "servers")?.id == servers.id)
        #expect(store.workspace(named: "  servers  ")?.id == servers.id) // input is trimmed
        #expect(store.workspace(named: "Servers") == nil)                // case-sensitive
        #expect(store.workspace(named: "missing") == nil)
        #expect(store.workspace(named: "   ") == nil)                    // blank
    }

    @Test func ensureWorkspaceReusesExistingElseCreates() {
        let store = makeStore()
        let existing = store.addWorkspace(name: "servers")
        let before = store.workspaces.count
        #expect(store.ensureWorkspace(named: "servers")?.id == existing.id)
        #expect(store.workspaces.count == before)
        let created = try! #require(store.ensureWorkspace(named: "  fresh  "))
        #expect(created.name == "fresh")
        #expect(store.workspaces.count == before + 1)
        #expect(store.ensureWorkspace(named: "fresh")?.id == created.id)
        #expect(store.workspaces.count == before + 1)
        #expect(store.ensureWorkspace(named: "   ") == nil)
        #expect(store.workspaces.count == before + 1)
    }

    @Test func selectSessionUpdatesActive() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.selectSession(a.id)
        #expect(store.activeSession?.id == a.id)
        store.selectSession(b.id)
        #expect(store.activeSession?.id == b.id)
    }

    @Test func selectUnknownSessionIsIgnored() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.selectSession(UUID())
        #expect(store.selectedSessionID == a.id)
    }

    @Test func selectSessionClearsOnlyItsUnseenBadge() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        a.unseenCount = 3
        b.unseenCount = 2
        store.selectSession(a.id)
        #expect(a.unseenCount == 0)
        #expect(b.unseenCount == 2)
    }

    @Test func clearUnseenResetsCountAndIgnoresUnknownID() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        a.unseenCount = 5
        store.clearUnseen(a.id)
        #expect(a.unseenCount == 0)
        store.clearUnseen(UUID()) // unknown id is a no-op, no crash
    }

    @Test func clearUnseenDoesNotChangeSelection() {
        // the focus-free invariant behind session.seen: markSessionSeen calls clearUnseen and nothing else
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        a.unseenCount = 3
        store.selectSession(b.id)
        store.clearUnseen(a.id)
        #expect(store.selectedSessionID == b.id)
        #expect(a.unseenCount == 0)
    }

    @Test func setAgentIndicatorSetsFieldOnRightSession() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.setAgentIndicator(AgentIndicator(status: .active, blink: true), forSession: a.id)
        #expect(a.agentIndicator == AgentIndicator(status: .active, blink: true))
        #expect(b.agentIndicator == AgentIndicator())
    }

    @Test func setAgentIndicatorUnknownSessionIsNoop() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: UUID()) // unknown id: no crash
        #expect(a.agentIndicator == AgentIndicator())
    }

    @Test func setAgentIndicatorStampsStatusChangedAtOnNonIdle() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        #expect(a.statusChangedAt == nil)
        let before = Date()
        store.setAgentIndicator(AgentIndicator(status: .active), forSession: a.id)
        let stamp = try! #require(a.statusChangedAt)
        #expect(stamp >= before)
    }

    @Test func setAgentIndicatorClearsStatusChangedAtOnIdle() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: a.id)
        #expect(a.statusChangedAt != nil)
        store.setAgentIndicator(AgentIndicator(), forSession: a.id)
        #expect(a.statusChangedAt == nil)
    }

    @Test func setAgentIndicatorReassertingNonIdleUpdatesStatusChangedAt() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        a.statusChangedAt = Date(timeIntervalSince1970: 0) // pretend a stale stamp
        let before = Date()
        store.setAgentIndicator(AgentIndicator(status: .active), forSession: a.id)
        let stamp = try! #require(a.statusChangedAt)
        #expect(stamp >= before) // re-asserting a non-idle status moves the stamp to ~now, not just off epoch-0
    }

    @Test func statusChangedAtDoesNotSurviveSnapshotRestore() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.setAgentIndicator(AgentIndicator(status: .completed), forSession: session.id)
        #expect(session.statusChangedAt != nil)
        let restored = makeStore()
        restored.restore(from: store.snapshot())
        #expect(restored.workspaces[0].sessions[0].statusChangedAt == nil)
    }

    @Test func agentIndicatorDoesNotSurviveSnapshotRestore() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.setAgentIndicator(AgentIndicator(status: .completed, blink: true), forSession: session.id)
        let restored = makeStore()
        restored.restore(from: store.snapshot())
        #expect(restored.workspaces[0].sessions[0].agentIndicator == AgentIndicator())
    }

    @Test func selectSessionKeepsNonAutoResetIndicator() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.setAgentIndicator(AgentIndicator(status: .active), forSession: a.id) // autoReset defaults false
        store.selectSession(a.id)
        #expect(a.agentIndicator == AgentIndicator(status: .active))
        store.selectSession(b.id)
        #expect(a.agentIndicator == AgentIndicator(status: .active))
    }

    @Test func selectSessionResetsAutoResetIndicator() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        a.hasSplit = true
        let indicator = AgentIndicator(status: .completed, autoReset: true, statusPane: .right)
        store.setAgentIndicator(indicator, forSession: a.id)
        let captured = store.selectSession(a.id) // visiting clears it, but returns the pre-clear routing value
        #expect(captured == indicator)
        #expect(a.agentIndicator == AgentIndicator())
    }

    @Test func selectSessionDoesNotResetUnrelatedAutoResetIndicator() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.setAgentIndicator(AgentIndicator(status: .completed, autoReset: true), forSession: a.id)
        store.selectSession(b.id)
        #expect(a.agentIndicator == AgentIndicator(status: .completed, autoReset: true))
    }

    @Test func switchingAwayClearsAutoResetIndicatorOnTheLeftSession() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.selectSession(a.id)
        // the agent finishes WHILE a is the selected session, so no visit fires and its completed flash lingers
        store.setAgentIndicator(AgentIndicator(status: .completed, autoReset: true), forSession: a.id)
        #expect(a.agentIndicator == AgentIndicator(status: .completed, autoReset: true))
        store.selectSession(b.id)
        #expect(a.agentIndicator == AgentIndicator())
        #expect(b.agentIndicator == AgentIndicator())
    }

    @Test func workspaceForSessionDerivesOwner() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let inWork = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let inPersonal = store.addSession(toWorkspace: personal.id, cwd: "/b")!
        #expect(store.workspace(forSession: inWork.id)?.id == work.id)
        #expect(store.workspace(forSession: inPersonal.id)?.id == personal.id)
        #expect(store.workspace(forSession: UUID()) == nil)
    }

    @Test func closeNonActiveSessionKeepsSelection() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.selectSession(b.id)
        store.closeSession(a.id)
        #expect(store.workspaces[0].sessions.map(\.id) == [b.id])
        #expect(store.selectedSessionID == b.id)
    }

    @Test func closeActiveSessionReselectsNext() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.selectSession(a.id)
        store.closeSession(a.id)
        #expect(store.selectedSessionID == b.id)
        #expect(store.activeSession?.id == b.id)
    }

    @Test func closeActiveLastSessionReselectsPrevious() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.selectSession(b.id)
        store.closeSession(b.id)
        #expect(store.selectedSessionID == a.id)
    }

    @Test func closeActiveSessionFallsBackToOtherWorkspace() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let other = store.addSession(toWorkspace: personal.id, cwd: "/other")!
        let only = store.addSession(toWorkspace: work.id, cwd: "/only")!
        store.selectSession(only.id)
        store.closeSession(only.id)
        #expect(store.workspaces[0].sessions.isEmpty)
        #expect(store.selectedSessionID == other.id)
    }

    @Test func closeLastSessionClearsSelection() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let only = store.addSession(toWorkspace: ws.id, cwd: "/only")!
        store.closeSession(only.id)
        #expect(store.selectedSessionID == nil)
        #expect(store.activeSession == nil)
    }

    @Test func closeSessionTearsDownSurface() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let surface = SpySurface()
        session.surface = surface
        store.closeSession(session.id)
        #expect(surface.teardownCount == 1)
    }

    @Test func closeSessionTearsDownSplitSurface() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let split = SpySurface()
        session.splitSurface = split
        store.closeSession(session.id)
        #expect(split.teardownCount == 1)
    }

    @Test func softCloseSessionHidesWithoutTearingDownAndUndoRestoresSameSession() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let first = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a", name: "alpha"))
        let second = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b", name: "beta"))
        let surface = SpySurface()
        first.surface = surface
        store.selectSession(first.id)

        #expect(store.softCloseSession(first.id, grace: 60))

        #expect(store.workspaces[0].sessions.map(\.id) == [second.id])
        #expect(store.selectedSessionID == second.id)
        #expect(surface.teardownCount == 0)
        let summary = try #require(store.pendingCloseSummary)
        #expect(summary.kind == .session)
        #expect(summary.title == "alpha")

        #expect(store.undoPendingClose(summary.id))

        #expect(store.workspaces[0].sessions.map(\.id) == [first.id, second.id])
        #expect(store.selectedSessionID == first.id)
        #expect(store.workspaces[0].sessions[0] === first)
        #expect(surface.teardownCount == 0)
        #expect(store.pendingCloseSummary == nil)
    }

    // a stillborn slot terminal zoom was sparing outlives its last host: the zoom layer drops a target whose
    // session left the tree, and the unmounted deck entry never re-runs its reconcile on the undo's remount.
    @Test func undoingASessionCloseRetiresAPaneOverlayLeftWithoutAHost() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let windowID = UUID()
        let zoom = TerminalZoomController()
        TerminalZoomRegistry.shared.register(windowID, controller: zoom)
        defer { TerminalZoomRegistry.shared.unregister(windowID) }
        session.isSplit = true
        session.hasSplit = true
        session.splitSurface = SpySurface()
        #expect(store.openPaneOverlay(session.id, pane: .right, command: "htop") == nil)
        let parked = SpySurface()
        parked.isRealized = false
        session.rightOverlaySurface = parked
        zoom.set(.on, target: .session(session.id, .overlayRight))
        store.toggleSplit(session.id)
        #expect(session.rightOverlay?.command == "htop")

        #expect(store.softCloseSession(session.id, grace: 60))
        zoom.clear()
        #expect(store.undoPendingClose())

        #expect(session.rightOverlay == nil)
        #expect(session.rightOverlaySurface == nil)
        #expect(parked.teardownCount == 1)
    }

    @Test func undoingASessionCloseKeepsARealizedPaneOverlayRunning() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        session.isSplit = true
        session.hasSplit = true
        session.splitSurface = SpySurface()
        #expect(store.openPaneOverlay(session.id, pane: .right, command: "htop") == nil)
        let right = SpySurface()
        session.rightOverlaySurface = right
        store.toggleSplit(session.id)

        #expect(store.softCloseSession(session.id, grace: 60))
        #expect(store.undoPendingClose())

        #expect(session.rightOverlay?.command == "htop")
        #expect(session.rightOverlaySurface === right)
        #expect(right.teardownCount == 0)
    }

    @Test func undoingAWorkspaceCloseRetiresAPaneOverlayLeftWithoutAHost() throws {
        let store = makeStore()
        _ = store.addWorkspace(name: "keep")
        let doomed = store.addWorkspace(name: "doomed")
        let session = try #require(store.addSession(toWorkspace: doomed.id, cwd: "/a"))
        let windowID = UUID()
        let zoom = TerminalZoomController()
        TerminalZoomRegistry.shared.register(windowID, controller: zoom)
        defer { TerminalZoomRegistry.shared.unregister(windowID) }
        session.isSplit = true
        session.hasSplit = true
        session.splitSurface = SpySurface()
        #expect(store.openPaneOverlay(session.id, pane: .right, command: "htop") == nil)
        let parked = SpySurface()
        parked.isRealized = false
        session.rightOverlaySurface = parked
        zoom.set(.on, target: .session(session.id, .overlayRight))
        store.toggleSplit(session.id)

        #expect(store.softRemoveWorkspace(doomed.id, grace: 60))
        zoom.clear()
        #expect(store.undoPendingClose())

        #expect(store.workspaces.last?.sessions.first === session)
        #expect(session.rightOverlay == nil)
        #expect(session.rightOverlaySurface == nil)
        #expect(parked.teardownCount == 1)
    }

    @Test func softCloseSessionsWithOneTargetKeepsSingleSessionSummary() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let first = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a", name: "alpha"))
        let second = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b", name: "beta"))

        #expect(store.softCloseSessions([first.id], grace: 60))

        let summary = try #require(store.pendingCloseSummary)
        #expect(summary.kind == .session)
        #expect(summary.title == "alpha")

        #expect(store.undoPendingClose(summary.id))
        #expect(store.workspaces[0].sessions.map(\.id) == [first.id, second.id])
        #expect(store.selectedSessionID == first.id)
    }

    @Test func softCloseSessionsGroupsUndoAndRestoresEverySession() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let first = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a", name: "alpha"))
        let second = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b", name: "beta"))
        let third = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c", name: "gamma"))
        let firstSurface = SpySurface(); first.surface = firstSurface
        let secondSurface = SpySurface(); second.surface = secondSurface
        store.selectSession(second.id)

        #expect(store.softCloseSessions([first.id, second.id], grace: 60))

        #expect(store.workspaces[0].sessions.map(\.id) == [third.id])
        #expect(store.selectedSessionID == third.id)
        #expect(firstSurface.teardownCount == 0)
        #expect(secondSurface.teardownCount == 0)
        let summary = try #require(store.pendingCloseSummary)
        #expect(summary.kind == .sessions)
        #expect(summary.title == "2 sessions")

        #expect(store.undoPendingClose(summary.id))

        #expect(store.workspaces[0].sessions.map(\.id) == [first.id, second.id, third.id])
        #expect(store.selectedSessionID == second.id)
        #expect(store.workspaces[0].sessions[0] === first)
        #expect(store.workspaces[0].sessions[1] === second)
        #expect(firstSurface.teardownCount == 0)
        #expect(secondSurface.teardownCount == 0)
        #expect(store.pendingCloseSummary == nil)
    }

    @Test func softCloseSessionsSelectsNearestSurvivorAfterActiveClose() throws {
        let store = makeStore()
        let firstWorkspace = store.addWorkspace(name: "one")
        let secondWorkspace = store.addWorkspace(name: "two")
        let distant = try #require(store.addSession(toWorkspace: firstWorkspace.id, cwd: "/a"))
        let active = try #require(store.addSession(toWorkspace: secondWorkspace.id, cwd: "/b"))
        let neighbor = try #require(store.addSession(toWorkspace: secondWorkspace.id, cwd: "/c"))
        store.selectSession(active.id)

        #expect(store.softCloseSessions([active.id, distant.id], grace: 60))

        #expect(store.selectedSessionID == neighbor.id)
    }

    @Test func softCloseSessionsAdjustsReselectionForEarlierBatchRemovals() throws {
        // the index adjustment feeds the POSITIONAL fallback, which only runs when the scoped recency is
        // empty — hence the restore: nothing is activated but the selection that is then closed.
        let store = makeStore()
        let wsID = UUID()
        let ids = [UUID(), UUID(), UUID(), UUID()]
        let sessions = ids.enumerated().map { SessionSnapshot(id: $1, customName: nil, cwd: "/\($0)") }
        store.restore(from: Snapshot(selectedSessionID: ids[1],
                                     workspaces: [WorkspaceSnapshot(id: wsID, name: "work", sessions: sessions)]))

        #expect(store.softCloseSessions([ids[0], ids[1]], grace: 60))

        // without the adjustment the stale index 1 would pick the LAST session instead of the neighbor
        #expect(store.selectedSessionID == ids[2])
    }

    @Test func softCloseSessionsFallsBackWhenActiveWorkspaceIsEmptied() throws {
        let store = makeStore()
        let firstWorkspace = store.addWorkspace(name: "one")
        let secondWorkspace = store.addWorkspace(name: "two")
        let distant = try #require(store.addSession(toWorkspace: firstWorkspace.id, cwd: "/a"))
        let active = try #require(store.addSession(toWorkspace: secondWorkspace.id, cwd: "/b"))
        let sibling = try #require(store.addSession(toWorkspace: secondWorkspace.id, cwd: "/c"))
        store.selectSession(active.id)

        #expect(store.softCloseSessions([active.id, sibling.id], grace: 60))

        #expect(store.selectedSessionID == distant.id)
    }

    @Test func finalizedSoftCloseSessionsTearsDownEverySessionAndCannotUndo() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let first = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let second = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        let firstSurface = SpySurface(); first.surface = firstSurface
        let secondSurface = SpySurface(); second.surface = secondSurface

        #expect(store.softCloseSessions([first.id, second.id], grace: 60))
        let summary = try #require(store.pendingCloseSummary)
        store.finalizePendingClose(summary.id)

        #expect(firstSurface.teardownCount == 1)
        #expect(secondSurface.teardownCount == 1)
        #expect(!store.undoPendingClose(summary.id))
        #expect(store.pendingCloseSummary == nil)
    }

    @Test func finalizedSoftCloseSessionTearsDownAndCannotUndo() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let surface = SpySurface()
        session.surface = surface

        #expect(store.softCloseSession(session.id, grace: 60))
        let summary = try #require(store.pendingCloseSummary)
        store.finalizePendingClose(summary.id)

        #expect(surface.teardownCount == 1)
        #expect(!store.undoPendingClose(summary.id))
        #expect(store.pendingCloseSummary == nil)
    }

    @Test func undoingLatestPendingClosePromotesPreviousPendingClose() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let first = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a", name: "alpha"))
        let second = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b", name: "beta"))
        let third = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c", name: "gamma"))

        #expect(store.softCloseSession(first.id, grace: 60))
        #expect(store.pendingCloseSummary?.title == "alpha")
        #expect(store.softCloseSession(second.id, grace: 60))
        #expect(store.pendingCloseSummary?.title == "beta")

        #expect(store.undoPendingClose())
        #expect(store.workspaces[0].sessions.map(\.id) == [second.id, third.id])
        #expect(store.pendingCloseSummary?.title == "alpha")

        #expect(store.undoPendingClose())
        #expect(store.workspaces[0].sessions.map(\.id) == [first.id, second.id, third.id])
        #expect(store.pendingCloseSummary == nil)
    }

    @Test func undoBeforeScheduledFinalizeMakesTimerFireNoOp() async throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let surface = SpySurface()
        session.surface = surface

        #expect(store.softCloseSession(session.id, grace: 0.01))
        let summary = try #require(store.pendingCloseSummary)
        #expect(store.undoPendingClose(summary.id))
        try await Task.sleep(nanoseconds: 30_000_000)

        #expect(store.session(withID: session.id) === session)
        #expect(surface.teardownCount == 0)
        #expect(store.pendingCloseSummary == nil)
    }

    @Test func scheduledFinalizeTearsDownAfterGrace() async throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let surface = SpySurface()
        session.surface = surface

        #expect(store.softCloseSession(session.id, grace: 0.01))
        // the suites run in parallel, so the 10 ms grace timer can land well past a flat 30 ms sleep
        // (reproduced: ~1 run in 6). poll the TEARDOWN, not `session(withID:)`: the session is removed
        // synchronously and only the teardown deferred, so a lookup poll exits at once and proves nothing.
        for _ in 0..<200 {
            if surface.teardownCount == 1 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(store.session(withID: session.id) == nil)
        #expect(surface.teardownCount == 1)
        #expect(store.pendingCloseSummary == nil)
    }

    @Test func softRemoveWorkspaceHidesWithoutTearingDownAndUndoRestores() throws {
        let store = makeStore()
        let keep = store.addWorkspace(name: "keep")
        let doomed = store.addWorkspace(name: "doomed")
        let session = try #require(store.addSession(toWorkspace: doomed.id, cwd: "/a"))
        let surface = SpySurface()
        session.surface = surface
        _ = store.addSession(toWorkspace: keep.id, cwd: "/b")

        #expect(store.softRemoveWorkspace(doomed.id, grace: 60))

        #expect(store.workspaces.map(\.id) == [keep.id])
        #expect(surface.teardownCount == 0)
        let summary = try #require(store.pendingCloseSummary)
        #expect(summary.kind == .workspace)
        #expect(summary.title == "doomed")

        #expect(store.undoPendingClose(summary.id))

        #expect(store.workspaces.map(\.id) == [keep.id, doomed.id])
        #expect(store.workspaces[1].sessions[0] === session)
        #expect(store.selectedSessionID == session.id)
        #expect(surface.teardownCount == 0)
    }

    @Test func undoingPendingSessionCloseThenWorkspaceCloseKeepsOneWorkspace() throws {
        let store = makeStore()
        let doomed = store.addWorkspace(name: "doomed")
        _ = store.addWorkspace(name: "keep")
        let first = try #require(store.addSession(toWorkspace: doomed.id, cwd: "/a"))
        let second = try #require(store.addSession(toWorkspace: doomed.id, cwd: "/b"))
        let firstSurface = SpySurface()
        let secondSurface = SpySurface()
        first.surface = firstSurface
        second.surface = secondSurface

        #expect(store.softCloseSession(first.id, grace: 60))
        let sessionClose = try #require(store.pendingCloseSummary?.id)
        #expect(store.softRemoveWorkspace(doomed.id, grace: 60))
        let workspaceClose = try #require(store.pendingCloseSummary?.id)

        // undoing the session first recreates the workspace shell; the workspace undo must merge into it
        #expect(store.undoPendingClose(sessionClose))
        #expect(store.undoPendingClose(workspaceClose))

        #expect(store.workspaces.count(where: { $0.id == doomed.id }) == 1)
        let restored = try #require(store.workspaces.first { $0.id == doomed.id })
        #expect(restored.sessions.map(\.id) == [first.id, second.id])
        #expect(restored.sessions[0] === first)
        #expect(restored.sessions[1] === second)
        #expect(store.selectedSessionID == second.id)
        #expect(firstSurface.teardownCount == 0)
        #expect(secondSurface.teardownCount == 0)
    }

    @Test func undoingWorkspaceCloseThenSessionCloseKeepsOneWorkspace() throws {
        let store = makeStore()
        let doomed = store.addWorkspace(name: "doomed")
        _ = store.addWorkspace(name: "keep")
        let first = try #require(store.addSession(toWorkspace: doomed.id, cwd: "/a"))
        let second = try #require(store.addSession(toWorkspace: doomed.id, cwd: "/b"))

        #expect(store.softCloseSession(first.id, grace: 60))
        let sessionClose = try #require(store.pendingCloseSummary?.id)
        #expect(store.softRemoveWorkspace(doomed.id, grace: 60))
        let workspaceClose = try #require(store.pendingCloseSummary?.id)

        // the reverse order takes the insert branch, then restorePendingSession finds the workspace
        #expect(store.undoPendingClose(workspaceClose))
        #expect(store.undoPendingClose(sessionClose))

        #expect(store.workspaces.count(where: { $0.id == doomed.id }) == 1)
        let restored = try #require(store.workspaces.first { $0.id == doomed.id })
        #expect(restored.sessions.map(\.id) == [first.id, second.id])
    }

    @Test func rebuiltShellSeedsNameAndExpansionFromPendingWorkspaceClose() throws {
        let store = makeStore()
        let doomed = store.addWorkspace(name: "old")
        _ = store.addWorkspace(name: "keep")
        let first = try #require(store.addSession(toWorkspace: doomed.id, cwd: "/a"))
        _ = try #require(store.addSession(toWorkspace: doomed.id, cwd: "/b"))

        #expect(store.softCloseSession(first.id, grace: 60))
        let sessionClose = try #require(store.pendingCloseSummary?.id)
        // rename and collapse after the session close, so the session record's captured name is stale
        store.renameWorkspace(doomed.id, to: "renamed")
        store.setWorkspaceExpanded(doomed.id, expanded: false)
        #expect(store.softRemoveWorkspace(doomed.id, grace: 60))
        let workspaceClose = try #require(store.pendingCloseSummary?.id)

        #expect(store.undoPendingClose(sessionClose))
        let shell = try #require(store.workspaces.first { $0.id == doomed.id })
        #expect(shell.name == "renamed")
        #expect(shell.isExpanded == false)

        #expect(store.undoPendingClose(workspaceClose))
        let restored = try #require(store.workspaces.first { $0.id == doomed.id })
        #expect(restored.name == "renamed")
        #expect(restored.isExpanded == false)
    }

    @Test func workspaceUndoKeepsEditsMadeToTheRebuiltShell() throws {
        let store = makeStore()
        let doomed = store.addWorkspace(name: "old")
        _ = store.addWorkspace(name: "keep")
        let first = try #require(store.addSession(toWorkspace: doomed.id, cwd: "/a"))
        _ = try #require(store.addSession(toWorkspace: doomed.id, cwd: "/b"))

        #expect(store.softCloseSession(first.id, grace: 60))
        let sessionClose = try #require(store.pendingCloseSummary?.id)
        #expect(store.softRemoveWorkspace(doomed.id, grace: 60))
        let workspaceClose = try #require(store.pendingCloseSummary?.id)

        #expect(store.undoPendingClose(sessionClose))
        store.renameWorkspace(doomed.id, to: "new")
        store.setWorkspaceExpanded(doomed.id, expanded: false)
        #expect(store.undoPendingClose(workspaceClose))

        let restored = try #require(store.workspaces.first { $0.id == doomed.id })
        #expect(restored.name == "new")
        #expect(restored.isExpanded == false)
    }

    @Test func restoringRecentSessionThenUndoingWorkspaceCloseKeepsOneWorkspace() throws {
        let store = makeStore()
        let doomed = store.addWorkspace(name: "doomed")
        _ = store.addWorkspace(name: "keep")
        let first = try #require(store.addSession(toWorkspace: doomed.id, cwd: "/a"))
        let second = try #require(store.addSession(toWorkspace: doomed.id, cwd: "/b"))

        #expect(store.softCloseSession(first.id, grace: 60))
        let sessionClose = try #require(store.pendingCloseSummary?.id)
        store.finalizePendingClose(sessionClose)
        #expect(store.softRemoveWorkspace(doomed.id, grace: 60))
        let workspaceClose = try #require(store.pendingCloseSummary?.id)

        // a finalized session reopens from Open Recent, which rebuilds the workspace shell on its own
        let recent = RecentClosedItem(
            kind: .session, title: "a", subtitle: "doomed",
            session: RecentClosedSession(workspaceID: doomed.id, workspaceName: "doomed",
                                         workspaceIndex: 0, sessionIndex: 0,
                                         snapshot: store.sessionSnapshot(first))
        )
        #expect(store.restoreRecentClosed(recent))
        #expect(store.undoPendingClose(workspaceClose))

        #expect(store.workspaces.count(where: { $0.id == doomed.id }) == 1)
        let restored = try #require(store.workspaces.first { $0.id == doomed.id })
        #expect(Set(restored.sessions.map(\.id)) == Set([first.id, second.id]))
        #expect(restored.sessions.count == 2)
        #expect(store.selectedSessionID == second.id)
        // the reopened session is a fresh object rebuilt from its snapshot; the merged-in one is live
        #expect(restored.sessions.contains { $0 === second })
        #expect(restored.sessions.allSatisfy { $0 !== first })
    }

    @Test func undoingWorkspaceCloseMergesDisjointSessionsIntoRebuiltShell() throws {
        let store = makeStore()
        let doomed = store.addWorkspace(name: "doomed")
        _ = store.addWorkspace(name: "keep")
        let first = try #require(store.addSession(toWorkspace: doomed.id, cwd: "/a"))
        let second = try #require(store.addSession(toWorkspace: doomed.id, cwd: "/b"))

        // close the second session, so the workspace snapshot carries only the first
        #expect(store.softCloseSession(second.id, grace: 60))
        let sessionClose = try #require(store.pendingCloseSummary?.id)
        #expect(store.softRemoveWorkspace(doomed.id, grace: 60))
        let workspaceClose = try #require(store.pendingCloseSummary?.id)

        #expect(store.undoPendingClose(sessionClose))
        #expect(store.undoPendingClose(workspaceClose))

        #expect(store.workspaces.count(where: { $0.id == doomed.id }) == 1)
        let restored = try #require(store.workspaces.first { $0.id == doomed.id })
        // the shell keeps its slot, so the merged order trails the shell's session
        #expect(restored.sessions.map(\.id) == [second.id, first.id])
        #expect(restored.sessions.contains { $0 === first })
        #expect(restored.sessions.contains { $0 === second })
    }

    @Test func reopeningRecentWorkspaceMergesMissingSessionsIntoRebuiltShell() throws {
        let (store, _, persistence) = makeStoreWithRecentClosed()
        let doomed = store.addWorkspace(name: "doomed")
        _ = store.addWorkspace(name: "keep")
        let first = try #require(store.addSession(toWorkspace: doomed.id, cwd: "/a"))
        let second = try #require(store.addSession(toWorkspace: doomed.id, cwd: "/b"))
        let firstSnapshot = store.sessionSnapshot(first)
        // snapshot the workspace while it still holds both, so it overlaps the shell the session restore
        // rebuilds. a disjoint snapshot would merge cleanly even without the live-session filter.
        let workspaceSnapshot = store.workspaceSnapshot(try #require(store.workspaces.first { $0.id == doomed.id }))

        #expect(store.softCloseSession(first.id, grace: 60))
        store.finalizePendingClose(try #require(store.pendingCloseSummary?.id))
        #expect(store.softRemoveWorkspace(doomed.id, grace: 60))
        store.finalizePendingClose(try #require(store.pendingCloseSummary?.id))

        let recentSession = RecentClosedItem(
            kind: .session, title: "a", subtitle: "doomed",
            session: RecentClosedSession(workspaceID: doomed.id, workspaceName: "doomed",
                                         workspaceIndex: 0, sessionIndex: 0, snapshot: firstSnapshot)
        )
        #expect(store.restoreRecentClosed(recentSession))

        let recentWorkspace = RecentClosedItem(
            kind: .workspace, title: "doomed", subtitle: "2 sessions",
            workspace: RecentClosedWorkspace(snapshot: workspaceSnapshot, selectedSessionID: second.id)
        )
        #expect(store.restoreRecentClosed(recentWorkspace))

        let restored = try #require(store.workspaces.first { $0.id == doomed.id })
        // count, not just the id set: the shell already holds `first`, and a merge that skips the
        // live-session filter appends a second copy of it under the same id
        #expect(restored.sessions.count == 2)
        #expect(Set(restored.sessions.map(\.id)) == Set([first.id, second.id]))
        #expect(store.session(withID: second.id) != nil)
        #expect(store.selectedSessionID == second.id)
        // the merge persists immediately, ahead of the debounced selection save
        #expect(persistence.load().workspaces.first { $0.id == doomed.id }?.sessions.count == 2)
    }

    @Test func reopeningRecentWorkspaceRestoresSessionsHeldByAPendingSessionClose() throws {
        let store = makeStore()
        let doomed = store.addWorkspace(name: "doomed")
        _ = store.addWorkspace(name: "keep")
        let first = try #require(store.addSession(toWorkspace: doomed.id, cwd: "/a"))
        let second = try #require(store.addSession(toWorkspace: doomed.id, cwd: "/b"))
        let firstSnapshot = store.sessionSnapshot(first)
        let workspaceSnapshot = store.workspaceSnapshot(try #require(store.workspaces.first { $0.id == doomed.id }))

        #expect(store.softRemoveWorkspace(doomed.id, grace: 60))
        store.finalizePendingClose(try #require(store.pendingCloseSummary?.id))

        // reopen `first` alone, rebuilding the workspace as a shell, then soft-close it again so a
        // pending session close holds it while the workspace's recent entry still lists both sessions
        let recentSession = RecentClosedItem(
            kind: .session, title: "a", subtitle: "doomed",
            session: RecentClosedSession(workspaceID: doomed.id, workspaceName: "doomed",
                                         workspaceIndex: 0, sessionIndex: 0, snapshot: firstSnapshot)
        )
        #expect(store.restoreRecentClosed(recentSession))
        let rebuiltFirst = try #require(store.workspaces.first { $0.id == doomed.id }?.sessions.first)
        #expect(store.softCloseSession(rebuiltFirst.id, grace: 60))

        // the pending close would restore only `first`; the workspace restore must still rebuild `second`
        let recentWorkspace = RecentClosedItem(
            kind: .workspace, title: "doomed", subtitle: "2 sessions",
            workspace: RecentClosedWorkspace(snapshot: workspaceSnapshot, selectedSessionID: second.id)
        )
        #expect(store.restoreRecentClosed(recentWorkspace))

        let restored = try #require(store.workspaces.first { $0.id == doomed.id })
        #expect(restored.sessions.count == 2)
        #expect(Set(restored.sessions.map(\.id)) == Set([first.id, second.id]))
        #expect(store.session(withID: second.id) != nil)
    }

    @Test func reopeningRecentWorkspaceDrainsEveryPendingSessionClose() throws {
        let store = makeStore()
        let doomed = store.addWorkspace(name: "doomed")
        _ = store.addWorkspace(name: "keep")
        let first = try #require(store.addSession(toWorkspace: doomed.id, cwd: "/a"))
        let second = try #require(store.addSession(toWorkspace: doomed.id, cwd: "/b"))
        let firstSurface = SpySurface()
        first.surface = firstSurface
        let workspaceSnapshot = store.workspaceSnapshot(try #require(store.workspaces.first { $0.id == doomed.id }))

        // both sessions are held by their own pending close, so neither is live at the reopen
        #expect(store.softCloseSession(first.id, grace: 60))
        let firstClose = try #require(store.pendingCloseSummary?.id)
        #expect(store.softCloseSession(second.id, grace: 60))

        let recentWorkspace = RecentClosedItem(
            kind: .workspace, title: "doomed", subtitle: "2 sessions",
            workspace: RecentClosedWorkspace(snapshot: workspaceSnapshot, selectedSessionID: first.id)
        )
        #expect(store.restoreRecentClosed(recentWorkspace))

        let restored = try #require(store.workspaces.first { $0.id == doomed.id })
        // the live originals come back, not snapshot rebuilds sharing their ids
        #expect(restored.sessions.count == 2)
        #expect(restored.sessions.contains { $0 === first })
        #expect(restored.sessions.contains { $0 === second })
        // no pending record still holds a session the tree now shows: undoing one would duplicate its id,
        // finalizing one would tear down the surfaces of a session the user can see
        #expect(store.pendingCloseRecords.isEmpty)
        #expect(store.undoPendingClose(firstClose) == false)
        #expect(store.workspaces.flatMap(\.sessions).count { $0.id == first.id } == 1)
        #expect(firstSurface.teardownCount == 0)
    }

    @Test func closingARebuiltShellFoldsIntoTheStillPendingWorkspaceClose() throws {
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        let doomed = store.addWorkspace(name: "doomed")
        _ = store.addWorkspace(name: "keep")
        let first = try #require(store.addSession(toWorkspace: doomed.id, cwd: "/a"))
        let second = try #require(store.addSession(toWorkspace: doomed.id, cwd: "/b"))

        // two pending records must never share a workspace id: both would key one Open Recent entry, and
        // the newer snapshot evicts the older one's sessions.
        #expect(store.softCloseSession(first.id, grace: 60))
        let sessionClose = try #require(store.pendingCloseSummary?.id)
        #expect(store.softRemoveWorkspace(doomed.id, grace: 60))
        let firstWorkspaceClose = try #require(store.pendingCloseSummary?.id)
        #expect(store.undoPendingClose(sessionClose))
        #expect(store.softRemoveWorkspace(doomed.id, grace: 60))
        let foldedClose = try #require(store.pendingCloseSummary?.id)

        #expect(foldedClose != firstWorkspaceClose)
        #expect(store.pendingCloseRecords.count == 1)
        // the superseded record is gone with its timer, so finalizing it cannot tear down the folded one
        store.finalizePendingClose(firstWorkspaceClose)
        #expect(store.pendingCloseRecords.count == 1)

        #expect(store.undoPendingClose(foldedClose))
        let restored = try #require(store.workspaces.first { $0.id == doomed.id })
        #expect(restored.sessions.map(\.id) == [first.id, second.id])
        #expect(recentClosed.load().isEmpty)
    }

    @Test func finalizedShellSeedsNameAndExpansionFromTheRecentWorkspaceSnapshot() throws {
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        _ = store.addWorkspace(name: "keep")
        let workspaceID = UUID()
        let sessionSnapshot = SessionSnapshot(id: UUID(), customName: "a", cwd: "/a")
        // nothing pending describes the workspace, so its newest surviving description is the Open Recent
        // snapshot, taken after the rename and collapse. the session entry's `workspaceName` predates both.
        recentClosed.record(RecentClosedItem(
            kind: .workspace, title: "renamed", subtitle: "1 session",
            workspace: RecentClosedWorkspace(
                snapshot: WorkspaceSnapshot(id: workspaceID, name: "renamed", sessions: [sessionSnapshot], collapsed: true),
                selectedSessionID: nil)
        ))

        let recentSession = RecentClosedItem(
            kind: .session, title: "a", subtitle: "old",
            session: RecentClosedSession(workspaceID: workspaceID, workspaceName: "old",
                                         workspaceIndex: 0, sessionIndex: 0, snapshot: sessionSnapshot)
        )
        #expect(store.restoreRecentClosed(recentSession))

        let shell = try #require(store.workspaces.first { $0.id == workspaceID })
        #expect(shell.name == "renamed")
        #expect(!shell.isExpanded)
    }

    @Test func reopeningRecentWorkspaceLeavesAForeignPendingWorkspaceCloseAlone() throws {
        let store = makeStore()
        let wsW = store.addWorkspace(name: "W")
        let wsV = store.addWorkspace(name: "V")
        let moved = try #require(store.addSession(toWorkspace: wsW.id, cwd: "/moved"))
        let staleSnapshot = store.workspaceSnapshot(try #require(store.workspaces.first { $0.id == wsW.id }))

        // the session moves to V, then the user closes V deliberately. W's recent entry still lists it.
        store.moveSession(moved.id, toWorkspace: wsV.id)
        #expect(store.softRemoveWorkspace(wsV.id, grace: 60))

        let recentW = RecentClosedItem(kind: .workspace, title: "W", subtitle: "1 session",
                                       workspace: RecentClosedWorkspace(snapshot: staleSnapshot, selectedSessionID: moved.id))
        _ = store.restoreRecentClosed(recentW)

        #expect(store.workspaces.contains { $0.id == wsV.id } == false)
        #expect(store.pendingCloseRecords.count == 1)
        #expect(store.workspaces.flatMap(\.sessions).count { $0.id == moved.id } == 0)
    }

    @Test func reopeningRecentWorkspaceNeverRebuildsASessionAForeignPendingCloseHolds() throws {
        let store = makeStore()
        let wsW = store.addWorkspace(name: "W")
        let wsV = store.addWorkspace(name: "V")
        _ = store.addWorkspace(name: "keep")
        _ = store.addSession(toWorkspace: wsV.id, cwd: "/anchor")
        let moved = try #require(store.addSession(toWorkspace: wsW.id, cwd: "/moved"))
        let staleSnapshot = store.workspaceSnapshot(try #require(store.workspaces.first { $0.id == wsW.id }))

        store.moveSession(moved.id, toWorkspace: wsV.id)
        // W is gone for good, so reopening it rebuilds the workspace wholesale
        #expect(store.softRemoveWorkspace(wsW.id, grace: 60))
        store.finalizePendingClose(try #require(store.pendingCloseSummary?.id))
        #expect(store.softRemoveWorkspace(wsV.id, grace: 60))
        let vClose = try #require(store.pendingCloseSummary?.id)

        let recentW = RecentClosedItem(kind: .workspace, title: "W", subtitle: "1 session",
                                       workspace: RecentClosedWorkspace(snapshot: staleSnapshot, selectedSessionID: moved.id))
        _ = store.restoreRecentClosed(recentW)
        #expect(store.pendingCloseRecords[vClose] != nil)

        #expect(store.undoPendingClose(vClose))
        #expect(store.workspaces.flatMap(\.sessions).count { $0.id == moved.id } == 1)
        #expect(store.workspaces.flatMap(\.sessions).contains { $0 === moved })
    }

    @Test func restoreDropsASessionRepeatedInsideOneWorkspace() {
        let store = makeStore()
        let repeated = UUID()
        store.restore(from: Snapshot(workspaces: [
            WorkspaceSnapshot(id: UUID(), name: "one", sessions: [
                SessionSnapshot(id: repeated, customName: "a", cwd: "/a"),
                SessionSnapshot(id: repeated, customName: "a-again", cwd: "/b"),
            ]),
        ]))

        #expect(store.workspaces.flatMap(\.sessions).count { $0.id == repeated } == 1)
        #expect(store.workspaces[0].sessions[0].customName == "a")
    }

    @Test func restoreDropsASessionRepeatedAcrossWorkspacesWithDifferentIDs() {
        let store = makeStore()
        let repeated = UUID()
        store.restore(from: Snapshot(workspaces: [
            WorkspaceSnapshot(id: UUID(), name: "one", sessions: [SessionSnapshot(id: repeated, customName: "a", cwd: "/a")]),
            WorkspaceSnapshot(id: UUID(), name: "two", sessions: [SessionSnapshot(id: repeated, customName: "a-again", cwd: "/b")]),
        ]))

        #expect(store.workspaces.count == 2)
        #expect(store.workspaces.flatMap(\.sessions).count { $0.id == repeated } == 1)
        #expect(store.workspaces[1].sessions.isEmpty)
    }

    @Test func restoreFoldsWorkspacesSharingAnIDIntoOne() throws {
        let store = makeStore()
        let shared = UUID()
        let firstID = UUID()
        let secondID = UUID()
        let snapshot = Snapshot(workspaces: [
            WorkspaceSnapshot(id: shared, name: "one", sessions: [SessionSnapshot(id: firstID, customName: "a", cwd: "/a")]),
            WorkspaceSnapshot(id: shared, name: "dupe", sessions: [SessionSnapshot(id: secondID, customName: "b", cwd: "/b")]),
        ])

        store.restore(from: snapshot)

        #expect(store.workspaces.count == 1)
        #expect(store.workspaces[0].name == "one")
        #expect(store.workspaces[0].sessions.map(\.id) == [firstID, secondID])
        #expect(store.session(withID: secondID) != nil)
    }

    @Test func restoreDropsASessionRepeatedAcrossWorkspacesSharingAnID() throws {
        let store = makeStore()
        let shared = UUID()
        let repeated = UUID()
        let snapshot = Snapshot(workspaces: [
            WorkspaceSnapshot(id: shared, name: "one", sessions: [SessionSnapshot(id: repeated, customName: "a", cwd: "/a")]),
            WorkspaceSnapshot(id: shared, name: "dupe", sessions: [SessionSnapshot(id: repeated, customName: "a-again", cwd: "/b")]),
        ])

        store.restore(from: snapshot)

        #expect(store.workspaces.count == 1)
        #expect(store.workspaces[0].sessions.map(\.id) == [repeated])
        #expect(store.workspaces[0].sessions[0].customName == "a")
    }

    @Test func finalizedSoftRemoveWorkspaceTearsDownSessions() throws {
        let store = makeStore()
        _ = store.addWorkspace(name: "keep")
        let doomed = store.addWorkspace(name: "doomed")
        let session = try #require(store.addSession(toWorkspace: doomed.id, cwd: "/a"))
        let surface = SpySurface()
        session.surface = surface

        #expect(store.softRemoveWorkspace(doomed.id, grace: 60))
        let summary = try #require(store.pendingCloseSummary)
        store.finalizePendingClose(summary.id)

        #expect(surface.teardownCount == 1)
        #expect(store.workspaces.map(\.name) == ["keep"])
    }

    @Test func removeWorkspaceTearsDownSessionsAndPrunesRecency() {
        let store = makeStore()
        let keep = store.addWorkspace(name: "keep")
        let doomed = store.addWorkspace(name: "doomed")
        let session = store.addSession(toWorkspace: doomed.id, cwd: "/a")!
        let surface = SpySurface(); session.surface = surface
        let split = SpySurface(); session.splitSurface = split
        store.removeWorkspace(doomed.id)
        #expect(store.workspaces.map(\.id) == [keep.id])
        #expect(surface.teardownCount == 1)
        #expect(split.teardownCount == 1)
        #expect(!store.sessionRecency.items.contains(session.id))
    }

    @Test func removeWorkspaceReselectsWhenActiveInside() {
        let store = makeStore()
        let keep = store.addWorkspace(name: "keep")
        let kept = store.addSession(toWorkspace: keep.id, cwd: "/k")!
        let doomed = store.addWorkspace(name: "doomed")
        let active = store.addSession(toWorkspace: doomed.id, cwd: "/a")!
        store.selectSession(active.id)
        store.removeWorkspace(doomed.id)
        #expect(store.selectedSessionID == kept.id)
    }

    @Test func removeWorkspaceLeavesSelectionWhenActiveElsewhere() {
        let store = makeStore()
        let keep = store.addWorkspace(name: "keep")
        let active = store.addSession(toWorkspace: keep.id, cwd: "/k")!
        let doomed = store.addWorkspace(name: "doomed")
        _ = store.addSession(toWorkspace: doomed.id, cwd: "/d")!
        store.selectSession(active.id)
        store.removeWorkspace(doomed.id)
        #expect(store.selectedSessionID == active.id)
    }

    @Test func removeWorkspaceKeepsAtLeastOne() {
        let store = makeStore()
        let only = store.addWorkspace(name: "only")
        #expect(store.canRemoveWorkspace == false)
        store.removeWorkspace(only.id)
        #expect(store.workspaces.map(\.id) == [only.id])
    }

    @Test func selectionUpdatesRecencyMostRecentFirst() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        #expect(store.sessionRecency.items == [b.id, a.id]) // b selected last
        store.selectSession(a.id)
        #expect(store.sessionRecency.items == [a.id, b.id])
        #expect(store.sessionRecency.items[1] == b.id)
    }

    @Test func closeSessionRemovesFromRecency() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.closeSession(b.id)
        #expect(!store.sessionRecency.items.contains(b.id))
        #expect(store.sessionRecency.items == [a.id])
    }

    @Test func recentSessionsReturnsMostRecentFirstRespectingLimit() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        let c = store.addSession(toWorkspace: ws.id, cwd: "/c")!
        // drive the recency order explicitly (selectSession pushes MRU front): most-recent is the last select.
        store.selectSession(a.id)
        store.selectSession(c.id)
        store.selectSession(b.id)
        #expect(store.recentSessions(limit: 9) == [b.id, c.id, a.id])
        #expect(store.recentSessions(limit: 2) == [b.id, c.id])
    }

    @Test func recentSessionsSpansWorkspacesAndSkipsClosed() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: personal.id, cwd: "/b")!
        store.selectSession(a.id)
        store.selectSession(b.id)
        #expect(store.recentSessions(limit: 9) == [b.id, a.id])
        store.closeSession(b.id) // closed sessions are pruned from recency, so they drop out
        #expect(store.recentSessions(limit: 9) == [a.id])
    }

    @Test func navigableRecentSessionsExcludesCurrentAndUsesVisibleScope() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: work.id, cwd: "/b")!
        let c = store.addSession(toWorkspace: personal.id, cwd: "/c")!
        let d = store.addSession(toWorkspace: personal.id, cwd: "/d", select: false)!
        store.selectSession(d.id)
        store.selectSession(a.id)
        store.selectSession(c.id)
        store.selectSession(b.id)

        #expect(store.navigableRecentSessions(limit: 2) == [c.id, a.id])

        store.setFocusedWorkspace(personal.id)
        #expect(store.selectedSessionID == c.id)
        #expect(store.navigableRecentSessions(limit: 9) == [d.id])
    }

    @Test func setFontSizeRecordsValue() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        #expect(session.fontSize == nil)
        store.setFontSize(session.id, 16)
        #expect(session.fontSize == 16)
        store.setFontSize(session.id, 16)
        #expect(session.fontSize == 16)
        store.setFontSize(session.id, 13)
        #expect(session.fontSize == 13)
    }

    @Test func resetSessionFontSizesClearsAllOverrides() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.setFontSize(a.id, 16)
        store.setFontSize(b.id, 18)
        store.resetSessionFontSizes()
        #expect(a.fontSize == nil)
        #expect(b.fontSize == nil)
    }

    @Test func setFontSizeUnknownSessionIsIgnored() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.setFontSize(UUID(), 20)
        #expect(session.fontSize == nil)
    }

    @Test func selectSessionThenSavePersistsSelectionToDisk() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let persistence = PersistenceStore(directory: dir)
        let store = AppStore(persistence: persistence)
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        _ = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.selectSession(a.id)
        store.save() // selection saves are debounced; save() flushes the write
        #expect(persistence.load().selectedSessionID == a.id)
    }

    @Test func rapidSelectionAndFontThenSavePersistsLatestSnapshot() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let persistence = PersistenceStore(directory: dir)
        let store = AppStore(persistence: persistence)
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        _ = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        let c = store.addSession(toWorkspace: ws.id, cwd: "/c")!
        store.selectSession(a.id)
        store.selectSession(c.id)
        store.setFontSize(c.id, 18)
        store.save()
        let loaded = persistence.load()
        #expect(loaded.selectedSessionID == c.id)
        #expect(loaded.workspaces[0].sessions[2].fontSize == 18)
    }

    @Test func selectSessionDefersWriteUntilSaveFlushes() {
        // addSession saves immediately (structural), so disk shows the last-added session selected; a
        // revert to a synchronous save() in selectSession fails the middle assertion.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let persistence = PersistenceStore(directory: dir)
        let store = AppStore(persistence: persistence)
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")! // structural save: disk now selects b
        #expect(persistence.load().selectedSessionID == b.id)
        store.selectSession(a.id) // debounced — must not hit disk yet
        #expect(persistence.load().selectedSessionID == b.id)
        store.save()
        #expect(persistence.load().selectedSessionID == a.id)
    }

    @Test func setFontSizeDefersWriteUntilSaveFlushes() {
        // same guard for setFontSize: the per-keystroke font change is debounced, not synchronous.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let persistence = PersistenceStore(directory: dir)
        let store = AppStore(persistence: persistence)
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")! // structural save: fontSize nil on disk
        #expect(persistence.load().workspaces[0].sessions[0].fontSize == nil)
        store.setFontSize(a.id, 18) // debounced — must not hit disk yet
        #expect(persistence.load().workspaces[0].sessions[0].fontSize == nil)
        store.save()
        #expect(persistence.load().workspaces[0].sessions[0].fontSize == 18)
    }

    @Test func closeUnknownSessionIsIgnored() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.selectSession(a.id)
        store.closeSession(UUID())
        #expect(store.workspaces[0].sessions.map(\.id) == [a.id])
        #expect(store.selectedSessionID == a.id)
    }

    @Test func renameUnknownWorkspaceIsIgnored() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        store.renameWorkspace(UUID(), to: "renamed")
        #expect(store.workspaces.map(\.name) == ["work"])
        #expect(store.workspaces[0].id == ws.id)
    }

    @Test func mutationSurvivesSaveFailure() {
        let unwritable = URL(fileURLWithPath: "/dev/null/agterm-cannot-write")
        let store = AppStore(persistence: PersistenceStore(directory: unwritable))
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")
        #expect(session != nil)
        #expect(store.workspaces[0].sessions.count == 1)
    }

    @Test func renameSessionSetsCustomName() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.renameSession(session.id, to: "build")
        #expect(session.customName == "build")
        #expect(session.displayName == "build")
    }

    @Test func renameSessionWithBlankClearsCustomName() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/Users/user/foo")!
        store.renameSession(session.id, to: "build")
        store.renameSession(session.id, to: "   ")
        #expect(session.customName == nil)
        #expect(session.displayName == "foo")
    }

    @Test func renameSessionTrimsWhitespace() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.renameSession(session.id, to: "  build  ")
        #expect(session.customName == "build")
    }

    @Test func renameWorkspaceSetsName() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        store.renameWorkspace(ws.id, to: "personal")
        #expect(store.workspaces[0].name == "personal")
    }

    @Test func renameWorkspaceWithBlankIsIgnored() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        store.renameWorkspace(ws.id, to: "   ")
        #expect(store.workspaces[0].name == "work")
    }

    @Test func setBackgroundWatermarkReportsWhetherChanged() {
        // the change-gate the control server uses to skip a redundant per-surface config apply (which
        // retains an owned config freed only at teardown) on a scripted set-loop.
        let store = makeStore()
        let ws = store.addWorkspace(name: "w")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/tmp")!
        let mark = BackgroundWatermark(kind: .text, text: "PROD")

        #expect(store.setBackgroundWatermark(mark, forSession: session.id))
        #expect(!store.setBackgroundWatermark(mark, forSession: session.id))
        #expect(store.setBackgroundWatermark(nil, forSession: session.id))
        #expect(!store.setBackgroundWatermark(nil, forSession: session.id))
        #expect(!store.setBackgroundWatermark(mark, forSession: UUID()))
    }

}

// MARK: - Sidebar multi-selection (the transient selection model)

extension AppStoreTests {
    @Test func contextTargetsUseFullSelectionOnlyWhenClickedRowIsSelected() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let b = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        let c = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/c"))
        store.selectSession(a.id)
        store.setSidebarSelection([b.id, a.id])

        #expect(store.sidebarSelectionIDs == [a.id, b.id])
        #expect(store.sidebarSelectionTargets(forContextSession: a.id) == [a.id, b.id])
        #expect(store.sidebarSelectionTargets(forContextSession: c.id) == [c.id])
        #expect(store.sidebarSelectionTargets(forContextSession: nil) == [a.id, b.id])
    }

    @Test func selectingSessionResetsTransientSidebarSelection() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let b = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))

        store.setSidebarSelection([a.id, b.id])
        #expect(store.sidebarSelectionIDs == [a.id, b.id])

        store.selectSession(b.id)
        #expect(store.selectedSessionID == b.id)
        #expect(store.sidebarSelectionIDs == [b.id])
    }

    @Test func selectingSessionCanPreserveTransientSidebarSelection() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let b = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        let c = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/c"))

        store.selectSession(c.id, sidebarSelection: [a.id, c.id])

        #expect(store.selectedSessionID == c.id)
        #expect(store.sidebarSelectionIDs == [a.id, c.id])
        #expect(store.sidebarSelectionTargets(forContextSession: a.id) == [a.id, c.id])
        #expect(store.sidebarSelectionTargets(forContextSession: b.id) == [b.id])
    }

    @Test func sidebarSelectionFallsBackToActiveWhenStoredSelectionIsStale() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let b = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        store.setSidebarSelection([a.id, b.id])

        let c = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/c"))

        #expect(store.selectedSessionID == c.id)
        #expect(store.sidebarSelectionIDs == [])
        #expect(store.sidebarSelectionTargets(forContextSession: nil) == [c.id])
        #expect(store.sidebarSelectionTargets(forContextSession: a.id) == [a.id])
    }

    @Test func sidebarTargetsDropRowsHiddenByModeOrFocus() {
        let store = makeStore()
        let ws1 = store.addWorkspace(name: "one")
        let ws2 = store.addWorkspace(name: "two")
        let a = try! #require(store.addSession(toWorkspace: ws1.id, cwd: "/a"))
        let b = try! #require(store.addSession(toWorkspace: ws1.id, cwd: "/b"))
        let c = try! #require(store.addSession(toWorkspace: ws2.id, cwd: "/c"))
        store.setFlag(true, forSession: a.id)

        store.selectSession(a.id)
        store.setSidebarSelection([a.id, b.id, c.id])
        store.setSidebarMode(.flagged)

        #expect(store.sidebarSelectionIDs == [a.id])
        #expect(store.sidebarSelectionTargets(forContextSession: a.id) == [a.id])

        store.setSidebarMode(.tree)
        store.selectSession(a.id)
        store.setSidebarSelection([a.id, c.id])
        store.setFocusedWorkspace(ws1.id)

        #expect(store.sidebarSelectionIDs == [a.id])
        #expect(store.sidebarSelectionTargets(forContextSession: a.id) == [a.id])
    }

    // the prune-guard tests below hide selected rows, then RE-SHOW them and assert again:
    // `sidebarSelectionIDs` filters on read, so only the second step catches a missing prune.
    @Test func modeChangePrunesRowsHiddenInFlaggedMode() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let b = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        store.setFlag(true, forSession: b.id)
        store.setSidebarSelection([a.id, b.id])

        store.setSidebarMode(.flagged)

        #expect(store.sidebarSelectionIDs == [b.id])
        store.setSidebarMode(.tree)
        #expect(store.sidebarSelectionIDs == [b.id],
                "rows hidden by the mode switch must not re-enter the selection when visible again")
    }

    @Test func singleFlagChangePrunesRowHiddenInFlaggedMode() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let b = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        store.setFlag(true, forSessions: [a.id, b.id])
        store.setSidebarMode(.flagged)
        store.setSidebarSelection([a.id, b.id])

        store.setFlag(false, forSession: a.id)

        #expect(store.sidebarSelectionIDs == [b.id])
        store.setFlag(true, forSession: a.id)
        #expect(store.sidebarSelectionIDs == [b.id],
                "an unflagged row must not re-enter the selection when re-flagged")
    }

    @Test func batchFlagChangePrunesRowsHiddenInFlaggedMode() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let b = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        store.setFlag(true, forSessions: [a.id, b.id])
        store.setSidebarMode(.flagged)
        store.setSidebarSelection([a.id, b.id])

        store.setFlag(false, forSessions: [a.id, b.id])

        #expect(store.sidebarSelectionIDs == [])
        store.setFlag(true, forSessions: [a.id, b.id])
        #expect(store.sidebarSelectionIDs == [])
    }

    @Test func clearFlagsPrunesRowsHiddenInFlaggedMode() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let b = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        store.setFlag(true, forSessions: [a.id, b.id])
        store.setSidebarMode(.flagged)
        store.setSidebarSelection([a.id, b.id])

        store.clearFlags()

        #expect(store.sidebarSelectionIDs == [])
        store.setFlag(true, forSessions: [a.id, b.id])
        #expect(store.sidebarSelectionIDs == [], "cleared rows must not re-enter selection when visible again")
    }

    @Test func batchFlagSetsEverySelectedSessionInOneCommand() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let b = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))

        store.setFlag(true, forSessions: [a.id, b.id])

        #expect(a.flagged)
        #expect(b.flagged)
    }

    @Test func batchMoveAppendsCrossWorkspaceSessionsAndLeavesTargetSessionsInPlace() {
        let store = makeStore()
        let ws1 = store.addWorkspace(name: "one")
        let ws2 = store.addWorkspace(name: "two")
        let a = try! #require(store.addSession(toWorkspace: ws1.id, cwd: "/a"))
        let b = try! #require(store.addSession(toWorkspace: ws1.id, cwd: "/b"))
        let c = try! #require(store.addSession(toWorkspace: ws2.id, cwd: "/c"))

        let affected = store.moveSessions([c.id, b.id, a.id], toWorkspace: ws2.id)

        #expect(affected == 2)
        #expect(store.workspaces[0].sessions.map(\.id) == [])
        #expect(store.workspaces[1].sessions.map(\.id) == [c.id, a.id, b.id])
    }

    @Test func oneElementBatchMoveWithinWorkspaceMatchesSingularAppend() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let b = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        let c = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/c"))

        let affected = store.moveSessions([a.id], toWorkspace: ws.id)

        #expect(affected == 1)
        #expect(store.workspaces[0].sessions.map(\.id) == [b.id, c.id, a.id])
    }

    @Test func multiElementBatchMoveAlreadyInTargetReportsZeroAndKeepsOrder() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let b = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))

        let affected = store.moveSessions([a.id, b.id], toWorkspace: ws.id)

        #expect(affected == 0)
        #expect(store.workspaces[0].sessions.map(\.id) == [a.id, b.id])
    }

    @Test func batchMoveInsertsCrossWorkspaceSessionsAtDropIndex() {
        let store = makeStore()
        let ws1 = store.addWorkspace(name: "one")
        let ws2 = store.addWorkspace(name: "two")
        let a = try! #require(store.addSession(toWorkspace: ws1.id, cwd: "/a"))
        let b = try! #require(store.addSession(toWorkspace: ws1.id, cwd: "/b"))
        let c = try! #require(store.addSession(toWorkspace: ws2.id, cwd: "/c"))
        let d = try! #require(store.addSession(toWorkspace: ws2.id, cwd: "/d"))
        let e = try! #require(store.addSession(toWorkspace: ws2.id, cwd: "/e"))

        store.moveSessions([a.id, b.id], toWorkspace: ws2.id, at: 1)

        #expect(store.workspaces[0].sessions.map(\.id) == [])
        #expect(store.workspaces[1].sessions.map(\.id) == [c.id, a.id, b.id, d.id, e.id])
    }

    @Test func batchMoveReordersSameWorkspaceAtDropIndex() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let b = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        let c = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/c"))
        let d = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/d"))
        let e = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/e"))

        store.moveSessions([a.id, b.id], toWorkspace: ws.id, at: 2)

        #expect(store.workspaces[0].sessions.map(\.id) == [c.id, d.id, a.id, b.id, e.id])
    }

    @Test func batchMoveMixedSelectionAdjustsTargetInsertionAfterRemoval() {
        let store = makeStore()
        let ws1 = store.addWorkspace(name: "one")
        let ws2 = store.addWorkspace(name: "two")
        let a = try! #require(store.addSession(toWorkspace: ws1.id, cwd: "/a"))
        let b = try! #require(store.addSession(toWorkspace: ws2.id, cwd: "/b"))
        let c = try! #require(store.addSession(toWorkspace: ws2.id, cwd: "/c"))
        let d = try! #require(store.addSession(toWorkspace: ws2.id, cwd: "/d"))

        store.moveSessions([a.id, b.id], toWorkspace: ws2.id, at: 1)

        #expect(store.workspaces[0].sessions.map(\.id) == [])
        #expect(store.workspaces[1].sessions.map(\.id) == [c.id, a.id, b.id, d.id])
    }
}
