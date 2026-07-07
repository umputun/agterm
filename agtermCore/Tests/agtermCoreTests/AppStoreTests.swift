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
        store.setSidebarVisible(true) // unchanged: clean no-op
        #expect(store.sidebarVisible)
    }

    @Test func defaultWorkspaceNameCountsUp() {
        let store = makeStore()
        #expect(store.defaultWorkspaceName == "workspace 1")
        store.addWorkspace(name: "work")
        #expect(store.defaultWorkspaceName == "workspace 2")
    }

    @Test func currentWorkspaceFollowsSelectionThenFallsBackToLast() {
        let store = makeStore()
        #expect(store.currentWorkspaceID == nil)
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        // no selection -> last workspace.
        #expect(store.currentWorkspaceID == personal.id)
        // a selected session pins its owning workspace.
        let session = try! #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        store.selectSession(session.id)
        #expect(store.currentWorkspaceID == work.id)
        // deselecting falls back to the last workspace again.
        store.selectSession(nil)
        #expect(store.currentWorkspaceID == personal.id)
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

    @Test func addSessionCarriesInitialCommand() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let withCmd = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/tmp", command: "ssh host"))
        #expect(withCmd.initialCommand == "ssh host")
        // default is nil — a plain session runs the login shell.
        let plain = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/tmp"))
        #expect(plain.initialCommand == nil)
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
        // default is nil — no custom name.
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
        // reuse: the same name returns the existing workspace, no new one appended.
        #expect(store.ensureWorkspace(named: "servers")?.id == existing.id)
        #expect(store.workspaces.count == before)
        // create: a new name appends exactly one workspace, trimmed.
        let created = try! #require(store.ensureWorkspace(named: "  fresh  "))
        #expect(created.name == "fresh")
        #expect(store.workspaces.count == before + 1)
        // idempotent: ensuring the just-created name again reuses it.
        #expect(store.ensureWorkspace(named: "fresh")?.id == created.id)
        #expect(store.workspaces.count == before + 1)
        // a blank name creates nothing.
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
        #expect(a.unseenCount == 0) // selecting a session clears its own badge
        #expect(b.unseenCount == 2) // other sessions are untouched
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
        // the focus-free invariant behind session.seen: clearing a NON-selected session's badge must
        // leave the selection put (markSessionSeen calls clearUnseen and nothing else).
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        a.unseenCount = 3
        store.selectSession(b.id)
        store.clearUnseen(a.id)
        #expect(store.selectedSessionID == b.id) // focus-free: selecting is untouched
        #expect(a.unseenCount == 0)              // the target's badge is cleared
    }

    @Test func setAgentIndicatorSetsFieldOnRightSession() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.setAgentIndicator(AgentIndicator(status: .active, blink: true), forSession: a.id)
        #expect(a.agentIndicator == AgentIndicator(status: .active, blink: true))
        #expect(b.agentIndicator == AgentIndicator()) // other sessions are untouched
    }

    @Test func setAgentIndicatorUnknownSessionIsNoop() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: UUID()) // unknown id: no crash
        #expect(a.agentIndicator == AgentIndicator()) // existing session untouched
    }

    @Test func setAgentIndicatorStampsStatusChangedAtOnNonIdle() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        #expect(a.statusChangedAt == nil) // a fresh session has no stamp
        let before = Date()
        store.setAgentIndicator(AgentIndicator(status: .active), forSession: a.id)
        let stamp = try! #require(a.statusChangedAt) // a non-idle status stamps the change time
        #expect(stamp >= before)
    }

    @Test func setAgentIndicatorClearsStatusChangedAtOnIdle() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: a.id)
        #expect(a.statusChangedAt != nil)
        store.setAgentIndicator(AgentIndicator(), forSession: a.id) // back to idle clears the stamp
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
        // the stamp is ephemeral like the indicator: a restored session falls back to nil.
        #expect(restored.workspaces[0].sessions[0].statusChangedAt == nil)
    }

    @Test func agentIndicatorDoesNotSurviveSnapshotRestore() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.setAgentIndicator(AgentIndicator(status: .completed, blink: true), forSession: session.id)
        let restored = makeStore()
        restored.restore(from: store.snapshot())
        // the indicator is ephemeral: a restored session falls back to the default idle state.
        #expect(restored.workspaces[0].sessions[0].agentIndicator == AgentIndicator())
    }

    @Test func selectSessionKeepsNonAutoResetIndicator() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.setAgentIndicator(AgentIndicator(status: .active), forSession: a.id) // autoReset defaults false
        store.selectSession(a.id) // a non-auto-reset indicator survives a visit (keep-state)
        #expect(a.agentIndicator == AgentIndicator(status: .active))
        store.selectSession(b.id)
        #expect(a.agentIndicator == AgentIndicator(status: .active)) // still set after switching away
    }

    @Test func selectSessionResetsAutoResetIndicator() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.setAgentIndicator(AgentIndicator(status: .completed, autoReset: true), forSession: a.id)
        store.selectSession(a.id) // visiting an auto-reset indicator clears it to idle for good
        #expect(a.agentIndicator == AgentIndicator())
    }

    @Test func selectSessionDoesNotResetUnrelatedAutoResetIndicator() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.setAgentIndicator(AgentIndicator(status: .completed, autoReset: true), forSession: a.id)
        store.selectSession(b.id) // selecting a different session leaves a background indicator alone
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
        // switching away from a clears its one-time completed flash (it must not persist on the row you left)
        store.selectSession(b.id)
        #expect(a.agentIndicator == AgentIndicator())
        #expect(b.agentIndicator == AgentIndicator()) // and b (the one moved to) carries nothing
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

    @Test func splitCwdRoundTripsThroughSnapshot() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.isSplit = true
        session.currentCwd = "/a/primary"
        session.splitCwd = "/var/log"
        let snap = store.snapshot()
        let snapped = snap.workspaces[0].sessions[0]
        #expect(snapped.cwd == "/a/primary")
        #expect(snapped.splitCwd == "/var/log")
        // restore into a fresh store: each pane keeps its own seed.
        let restored = makeStore()
        restored.restore(from: snap)
        let r = restored.workspaces[0].sessions[0]
        #expect(r.initialCwd == "/a/primary")
        #expect(r.initialSplitCwd == "/var/log")
        #expect(r.isSplit == true)
    }

    @Test func foregroundCommandRoundTripsThroughSnapshot() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.foregroundCommand = ["ssh", "gate", "-p", "22"]
        session.splitForegroundCommand = ["tail", "-f", "/var/log/x"]
        let snap = store.snapshot()
        let snapped = snap.workspaces[0].sessions[0]
        #expect(snapped.foregroundCommand == ["ssh", "gate", "-p", "22"])
        #expect(snapped.splitForegroundCommand == ["tail", "-f", "/var/log/x"])
        let restored = makeStore()
        restored.restore(from: snap)
        let r = restored.workspaces[0].sessions[0]
        #expect(r.foregroundCommand == ["ssh", "gate", "-p", "22"])
        #expect(r.splitForegroundCommand == ["tail", "-f", "/var/log/x"])
    }

    @Test func legacySnapshotWithoutForegroundCommandDecodesNil() throws {
        // a snapshot written before this field existed must still decode (nil = plain shell on restore).
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","cwd":"/tmp"}"#
        let snap = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        #expect(snap.foregroundCommand == nil)
        #expect(snap.splitForegroundCommand == nil)
        #expect(snap.initialCommand == nil)
        #expect(snap.cwd == "/tmp")
    }

    @Test func initialCommandRoundTripsThroughSnapshot() {
        // a command session (e.g. `--command ssh …`) persists its creation command so it re-runs on
        // restore instead of coming back a plain shell.
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.initialCommand = "ssh user@host -t 'ssh inner'"
        #expect(session.wasRestored == false) // a fresh session is not marked restored
        let snap = store.snapshot()
        #expect(snap.workspaces[0].sessions[0].initialCommand == "ssh user@host -t 'ssh inner'")
        let restored = makeStore()
        restored.restore(from: snap)
        let r = restored.workspaces[0].sessions[0]
        #expect(r.initialCommand == "ssh user@host -t 'ssh inner'")
        #expect(r.wasRestored == true) // restore marks the session, so the surface factory can gate its re-run
    }

    @Test func sidebarWidthAndVisibilityRoundTripThroughSnapshot() {
        let store = makeStore()
        _ = store.addWorkspace(name: "work")
        store.sidebarWidth = 312
        store.sidebarVisible = false
        let snap = store.snapshot()
        #expect(snap.sidebarWidth == 312)
        #expect(snap.sidebarVisible == false)
        let restored = makeStore()
        restored.restore(from: snap)
        #expect(restored.sidebarWidth == 312)
        #expect(restored.sidebarVisible == false)
    }

    @Test func sidebarDefaultsWhenSnapshotOmitsThem() {
        // a snapshot written before these fields existed decodes them as nil; restore falls back to defaults.
        let store = makeStore()
        store.sidebarWidth = 400
        store.sidebarVisible = false
        store.restore(from: Snapshot(workspaces: []))
        #expect(store.sidebarWidth == 220)
        #expect(store.sidebarVisible == true)
    }

    @Test func restoreClampsOutOfRangeSidebarWidth() {
        // a corrupt or hand-edited snapshot must not drive an out-of-range frame width; restore clamps it.
        let store = makeStore()
        store.restore(from: Snapshot(workspaces: [], sidebarWidth: 2000))
        #expect(store.sidebarWidth == AppStore.sidebarWidthMax)
        store.restore(from: Snapshot(workspaces: [], sidebarWidth: 10))
        #expect(store.sidebarWidth == AppStore.sidebarWidthMin)
    }

    @Test func restoreClampsOutOfRangeSplitRatio() {
        // a corrupt snapshot ratio must not feed an out-of-range fraction into NSSplitView.setPosition.
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.isSplit = true
        session.splitRatio = 5.0
        let restored = makeStore()
        restored.restore(from: store.snapshot())
        #expect(restored.workspaces[0].sessions[0].splitRatio == AppStore.splitRatioMax)
    }

    @Test func splitRatioRoundTripsThroughSnapshot() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.isSplit = true
        session.splitRatio = 0.63
        #expect(store.snapshot().workspaces[0].sessions[0].splitRatio == 0.63)
        let restored = makeStore()
        restored.restore(from: store.snapshot())
        #expect(restored.workspaces[0].sessions[0].splitRatio == 0.63)
    }

    @Test func sessionSnapshotDecodesWithoutSplitRatio() throws {
        // a SessionSnapshot persisted before splitRatio existed (the key absent) must decode to nil, not
        // fail the load — the forward-compat contract the optional field documents.
        let json = "{\"id\":\"\(UUID().uuidString)\",\"cwd\":\"/a\"}"
        let snap = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        #expect(snap.splitRatio == nil)
        #expect(snap.isSplit == nil)
        #expect(snap.fontSize == nil)
    }

    @Test func selectionUpdatesRecencyMostRecentFirst() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        #expect(store.sessionRecency.items == [b.id, a.id]) // b selected last
        store.selectSession(a.id)
        #expect(store.sessionRecency.items == [a.id, b.id]) // a now front, b is the previous
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

    @Test func setFontSizeRecordsValue() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        #expect(session.fontSize == nil)
        store.setFontSize(session.id, 16)
        #expect(session.fontSize == 16)
        store.setFontSize(session.id, 16) // unchanged: no-op, value unchanged
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
        #expect(persistence.load().selectedSessionID == a.id) // persisted to disk, not just in-memory
    }

    @Test func rapidSelectionAndFontThenSavePersistsLatestSnapshot() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let persistence = PersistenceStore(directory: dir)
        let store = AppStore(persistence: persistence)
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        _ = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        let c = store.addSession(toWorkspace: ws.id, cwd: "/c")!
        // a burst of debounced selection/font changes; save() writes the latest state once
        store.selectSession(a.id)
        store.selectSession(c.id)
        store.setFontSize(c.id, 18)
        store.save()
        let loaded = persistence.load()
        #expect(loaded.selectedSessionID == c.id)               // the latest selection won
        #expect(loaded.workspaces[0].sessions[2].fontSize == 18) // and the latest font change landed
    }

    @Test func selectSessionDefersWriteUntilSaveFlushes() {
        // guards the DEBOUNCE itself: selectSession must NOT write synchronously. addSession saves
        // immediately (structural), so disk shows the last-added session selected; a debounced
        // selectSession leaves the disk unchanged until save() flushes. A revert to a synchronous
        // save() in selectSession fails the middle assertion.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let persistence = PersistenceStore(directory: dir)
        let store = AppStore(persistence: persistence)
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")! // structural save: disk now selects b
        #expect(persistence.load().selectedSessionID == b.id)
        store.selectSession(a.id)                                // debounced — must not hit disk yet
        #expect(persistence.load().selectedSessionID == b.id)    // still b: the write was deferred
        store.save()                                             // flush
        #expect(persistence.load().selectedSessionID == a.id)    // now a is persisted
    }

    @Test func setFontSizeDefersWriteUntilSaveFlushes() {
        // same guard for setFontSize: the per-keystroke font change is debounced, not synchronous.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let persistence = PersistenceStore(directory: dir)
        let store = AppStore(persistence: persistence)
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")! // structural save: fontSize nil on disk
        #expect(persistence.load().workspaces[0].sessions[0].fontSize == nil)
        store.setFontSize(a.id, 18)                              // debounced — must not hit disk yet
        #expect(persistence.load().workspaces[0].sessions[0].fontSize == nil) // still nil: deferred
        store.save()                                             // flush
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
        // save() to an unwritable directory is swallowed; the in-memory mutation stands.
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

        #expect(store.setBackgroundWatermark(mark, forSession: session.id))       // first set changes
        #expect(!store.setBackgroundWatermark(mark, forSession: session.id))      // identical re-set: no change
        #expect(store.setBackgroundWatermark(nil, forSession: session.id))        // clear changes
        #expect(!store.setBackgroundWatermark(nil, forSession: session.id))       // clear again: no change
        #expect(!store.setBackgroundWatermark(mark, forSession: UUID()))          // unknown id: no change
    }

    @Test func controlTreeProjectsWorkspaceAndSessionShape() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let a = try #require(store.addSession(toWorkspace: work.id, cwd: "/repo/a", name: "alpha"))
        let b = try #require(store.addSession(toWorkspace: personal.id, cwd: "/repo/b"))
        b.currentCwd = "/live/b"
        b.oscTitle = "remote:~/b"
        b.isSplit = true
        b.overlayActive = true
        b.scratchActive = true
        b.flagged = true
        b.backgroundWatermark = BackgroundWatermark(kind: .text, text: "PROD")
        store.setAgentIndicator(AgentIndicator(status: .blocked, statusPane: .right), forSession: b.id)
        store.selectSession(b.id)

        let tree = store.controlTree()

        #expect(tree.workspaces.map(\.id) == [work.id.uuidString, personal.id.uuidString])
        #expect(tree.workspaces.map(\.name) == ["work", "personal"])
        #expect(tree.workspaces.map(\.active) == [false, true])
        #expect(tree.workspaces[0].sessions == [
            ControlSessionNode(id: a.id.uuidString, name: "alpha", cwd: "/repo/a",
                               active: false, split: false)
        ])
        #expect(tree.workspaces[1].sessions == [
            ControlSessionNode(id: b.id.uuidString, name: "remote:~/b", cwd: "/live/b",
                               title: "remote:~/b", active: true, split: true,
                               overlay: true, scratch: true, flagged: true,
                               status: "blocked", statusPane: "right",
                               background: BackgroundWatermark(kind: .text, text: "PROD"))
        ])
    }

    @Test func controlTreeReportsSidebarVisibility() {
        let store = makeStore()
        #expect(store.controlTree().sidebarVisible == true) // default: sidebar shown
        store.setSidebarVisible(false)
        #expect(store.controlTree().sidebarVisible == false)
        store.setSidebarVisible(true)
        #expect(store.controlTree().sidebarVisible == true)
    }

    @Test func setSidebarVisiblePostsChangeNotificationOnlyOnChange() {
        // the app-target ControlServer observes this to refresh window.list's cached sidebarVisible; the
        // post must fire only on an actual change (queue nil so the synchronous post delivers inline).
        final class Counter: @unchecked Sendable { var n = 0 }
        let store = makeStore() // default sidebarVisible == true
        let counter = Counter()
        let token = NotificationCenter.default.addObserver(forName: .agtermSidebarVisibilityChanged, object: nil,
                                                           queue: nil) { _ in counter.n += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        store.setSidebarVisible(true)   // unchanged from default -> no post
        #expect(counter.n == 0)
        store.setSidebarVisible(false)  // change -> post
        #expect(counter.n == 1)
        store.setSidebarVisible(false)  // unchanged -> no post
        #expect(counter.n == 1)
        store.setSidebarVisible(true)   // change -> post
        #expect(counter.n == 2)
    }

    @Test func controlTreeReportsUnseenCountWhenPositive() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        session.unseenCount = 4

        let node = try #require(store.controlTree().workspaces[0].sessions.first)

        #expect(node.unseen == 4)
    }

    @Test func controlTreeOmitsUnseenCountWhenZero() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        session.unseenCount = 0

        let node = try #require(store.controlTree().workspaces[0].sessions.first)

        #expect(node.unseen == nil) // zero reads as "no badge", omitted from the wire
    }

    @Test func controlTreeReportsStatusPaneForNonIdleSession() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        store.setAgentIndicator(AgentIndicator(status: .blocked, statusPane: .right), forSession: session.id)

        let node = try #require(store.controlTree().workspaces[0].sessions.first)

        #expect(node.status == "blocked")
        #expect(node.statusPane == "right")
    }

    @Test func controlTreeNilsStatusPaneWhenIdleEvenWithPane() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        // an idle indicator carrying a pane must project BOTH status and statusPane as nil, never a
        // self-contradictory (status == nil while statusPane == "right") node
        store.setAgentIndicator(AgentIndicator(status: .idle, statusPane: .right), forSession: session.id)

        let node = try #require(store.controlTree().workspaces[0].sessions.first)

        #expect(node.status == nil)
        #expect(node.statusPane == nil)
    }

    @Test func controlTreeOmitsStatusPaneWhenNonIdleButUnspecified() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        // non-idle status with no pane recorded: status present, statusPane stays nil
        store.setAgentIndicator(AgentIndicator(status: .completed), forSession: session.id)

        let node = try #require(store.controlTree().workspaces[0].sessions.first)

        #expect(node.status == "completed")
        #expect(node.statusPane == nil)
    }

    @Test func controlTreeUsesForegroundLookups() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let active = try #require(store.addSession(toWorkspace: ws.id, cwd: "/active"))
        let other = try #require(store.addSession(toWorkspace: ws.id, cwd: "/other"))
        store.selectSession(active.id)

        let tree = store.controlTree(
            foreground: { session in session.id == active.id ? ["ssh", "host"] : nil },
            splitForeground: { session in session.id == other.id ? ["tail", "-f", "app.log"] : nil }
        )

        #expect(tree.workspaces[0].sessions[0].foreground == ["ssh", "host"])
        #expect(tree.workspaces[0].sessions[0].splitForeground == nil)
        #expect(tree.workspaces[0].sessions[1].foreground == nil)
        #expect(tree.workspaces[0].sessions[1].splitForeground == ["tail", "-f", "app.log"])
    }
}
