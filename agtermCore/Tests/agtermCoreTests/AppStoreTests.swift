import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreTests {
    /// A store backed by a throwaway temp directory so mutation-time saves never
    /// touch the real Application Support path. PersistenceStore creates the
    /// directory lazily on first write.
    static func makeStore() -> AppStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        return AppStore(persistence: PersistenceStore(directory: dir))
    }

    @Test func emptyStoreHasNoSelectionOrActiveSession() {
        let store = Self.makeStore()
        #expect(store.workspaces.isEmpty)
        #expect(store.selectedSessionID == nil)
        #expect(store.activeSession == nil)
    }

    @Test func defaultWorkspaceNameCountsUp() {
        let store = Self.makeStore()
        #expect(store.defaultWorkspaceName == "workspace 1")
        store.addWorkspace(name: "work")
        #expect(store.defaultWorkspaceName == "workspace 2")
    }

    @Test func currentWorkspaceFollowsSelectionThenFallsBackToLast() {
        let store = Self.makeStore()
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
        let store = Self.makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        #expect(store.workspaces.map(\.id) == [work.id, personal.id])
        #expect(store.workspaces.map(\.name) == ["work", "personal"])
    }

    @Test func addSessionAppendsAndSelects() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/tmp")
        let unwrapped = try! #require(session)
        #expect(store.workspaces[0].sessions.map(\.id) == [unwrapped.id])
        #expect(unwrapped.initialCwd == "/tmp")
        #expect(store.selectedSessionID == unwrapped.id)
        #expect(store.activeSession?.id == unwrapped.id)
    }

    @Test func addSessionCarriesInitialCommand() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let withCmd = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/tmp", command: "ssh host"))
        #expect(withCmd.initialCommand == "ssh host")
        // default is nil — a plain session runs the login shell.
        let plain = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/tmp"))
        #expect(plain.initialCommand == nil)
    }

    @Test func addSessionToUnknownWorkspaceReturnsNil() {
        let store = Self.makeStore()
        #expect(store.addSession(toWorkspace: UUID(), cwd: "/tmp") == nil)
        #expect(store.selectedSessionID == nil)
    }

    @Test func selectSessionUpdatesActive() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.selectSession(a.id)
        #expect(store.activeSession?.id == a.id)
        store.selectSession(b.id)
        #expect(store.activeSession?.id == b.id)
    }

    @Test func selectUnknownSessionIsIgnored() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.selectSession(UUID())
        #expect(store.selectedSessionID == a.id)
    }

    @Test func selectSessionClearsOnlyItsUnseenBadge() {
        let store = Self.makeStore()
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
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        a.unseenCount = 5
        store.clearUnseen(a.id)
        #expect(a.unseenCount == 0)
        store.clearUnseen(UUID()) // unknown id is a no-op, no crash
    }

    @Test func setAgentIndicatorSetsFieldOnRightSession() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.setAgentIndicator(AgentIndicator(status: .active, blink: true), forSession: a.id)
        #expect(a.agentIndicator == AgentIndicator(status: .active, blink: true))
        #expect(b.agentIndicator == AgentIndicator()) // other sessions are untouched
    }

    @Test func setAgentIndicatorUnknownSessionIsNoop() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: UUID()) // unknown id: no crash
        #expect(a.agentIndicator == AgentIndicator()) // existing session untouched
    }

    @Test func agentIndicatorDoesNotSurviveSnapshotRestore() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.setAgentIndicator(AgentIndicator(status: .completed, blink: true), forSession: session.id)
        let restored = Self.makeStore()
        restored.restore(from: store.snapshot())
        // the indicator is ephemeral: a restored session falls back to the default idle state.
        #expect(restored.workspaces[0].sessions[0].agentIndicator == AgentIndicator())
    }

    @Test func selectSessionKeepsNonAutoResetIndicator() {
        let store = Self.makeStore()
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
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.setAgentIndicator(AgentIndicator(status: .completed, autoReset: true), forSession: a.id)
        store.selectSession(a.id) // visiting an auto-reset indicator clears it to idle for good
        #expect(a.agentIndicator == AgentIndicator())
    }

    @Test func selectSessionDoesNotResetUnrelatedAutoResetIndicator() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.setAgentIndicator(AgentIndicator(status: .completed, autoReset: true), forSession: a.id)
        store.selectSession(b.id) // selecting a different session leaves a background indicator alone
        #expect(a.agentIndicator == AgentIndicator(status: .completed, autoReset: true))
    }

    @Test func switchingAwayClearsAutoResetIndicatorOnTheLeftSession() {
        let store = Self.makeStore()
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
        let store = Self.makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let inWork = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let inPersonal = store.addSession(toWorkspace: personal.id, cwd: "/b")!
        #expect(store.workspace(forSession: inWork.id)?.id == work.id)
        #expect(store.workspace(forSession: inPersonal.id)?.id == personal.id)
        #expect(store.workspace(forSession: UUID()) == nil)
    }

    @Test func closeNonActiveSessionKeepsSelection() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.selectSession(b.id)
        store.closeSession(a.id)
        #expect(store.workspaces[0].sessions.map(\.id) == [b.id])
        #expect(store.selectedSessionID == b.id)
    }

    @Test func closeActiveSessionReselectsNext() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.selectSession(a.id)
        store.closeSession(a.id)
        #expect(store.selectedSessionID == b.id)
        #expect(store.activeSession?.id == b.id)
    }

    @Test func closeActiveLastSessionReselectsPrevious() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.selectSession(b.id)
        store.closeSession(b.id)
        #expect(store.selectedSessionID == a.id)
    }

    @Test func closeActiveSessionFallsBackToOtherWorkspace() {
        let store = Self.makeStore()
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
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let only = store.addSession(toWorkspace: ws.id, cwd: "/only")!
        store.closeSession(only.id)
        #expect(store.selectedSessionID == nil)
        #expect(store.activeSession == nil)
    }

    @Test func closeSessionTearsDownSurface() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let surface = SpySurface()
        session.surface = surface
        store.closeSession(session.id)
        #expect(surface.teardownCount == 1)
    }

    @Test func closeSessionTearsDownSplitSurface() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let split = SpySurface()
        session.splitSurface = split
        store.closeSession(session.id)
        #expect(split.teardownCount == 1)
    }

    @Test func removeWorkspaceTearsDownSessionsAndPrunesRecency() {
        let store = Self.makeStore()
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
        let store = Self.makeStore()
        let keep = store.addWorkspace(name: "keep")
        let kept = store.addSession(toWorkspace: keep.id, cwd: "/k")!
        let doomed = store.addWorkspace(name: "doomed")
        let active = store.addSession(toWorkspace: doomed.id, cwd: "/a")!
        store.selectSession(active.id)
        store.removeWorkspace(doomed.id)
        #expect(store.selectedSessionID == kept.id)
    }

    @Test func removeWorkspaceLeavesSelectionWhenActiveElsewhere() {
        let store = Self.makeStore()
        let keep = store.addWorkspace(name: "keep")
        let active = store.addSession(toWorkspace: keep.id, cwd: "/k")!
        let doomed = store.addWorkspace(name: "doomed")
        _ = store.addSession(toWorkspace: doomed.id, cwd: "/d")!
        store.selectSession(active.id)
        store.removeWorkspace(doomed.id)
        #expect(store.selectedSessionID == active.id)
    }

    @Test func removeWorkspaceKeepsAtLeastOne() {
        let store = Self.makeStore()
        let only = store.addWorkspace(name: "only")
        #expect(store.canRemoveWorkspace == false)
        store.removeWorkspace(only.id)
        #expect(store.workspaces.map(\.id) == [only.id])
    }

    @Test func toggleSplitFlipsFlag() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        #expect(session.isSplit == false)
        #expect(session.hasSplit == false)
        store.toggleSplit(session.id)
        #expect(session.isSplit == true)
        #expect(session.hasSplit == true)
        #expect(session.splitFocused == true)  // opening focuses the new (right) pane
        store.toggleSplit(session.id)
        #expect(session.isSplit == false)
        // hiding the split keeps hasSplit so the sidebar/title split indicators persist, and keeps
        // splitFocused so the focused pane is the one shown maximized.
        #expect(session.hasSplit == true)
        #expect(session.splitFocused == true)
    }

    @Test func closeSplitHidesAndTearsDownSurface() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.isSplit = true
        session.hasSplit = true
        session.splitFocused = true
        let split = SpySurface()
        session.splitSurface = split
        session.splitCwd = "/var/log"
        store.closeSplit(session.id)
        #expect(session.isSplit == false)
        #expect(session.hasSplit == false)
        #expect(session.splitFocused == false)
        #expect(session.splitSurface == nil)
        #expect(session.splitCwd == nil)
        #expect(session.initialSplitCwd == nil)
        #expect(split.teardownCount == 1)
    }

    @Test func closePrimaryPaneWithSplitKeepsSessionAndPromotesSurvivor() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let primary = SpySurface(); session.surface = primary
        let split = SpySurface(); session.splitSurface = split
        session.isSplit = true
        session.hasSplit = true
        session.splitCwd = "/var/log"
        store.closePrimaryPane(session.id)
        #expect(store.session(withID: session.id) != nil) // session survives
        #expect(primary.teardownCount == 1)               // the dead primary is torn down
        #expect(split.teardownCount == 0)                 // the survivor is kept
        #expect(session.surface == nil)
        #expect(session.splitSurface != nil)
        #expect(session.isSplit == false)
        #expect(session.hasSplit == false)
        #expect(session.splitFocused == true)             // the maximized survivor is shown
        #expect(session.currentCwd == "/var/log")         // the survivor's cwd is promoted
    }

    @Test func closePrimaryPaneWithoutSplitClosesSession() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let primary = SpySurface(); session.surface = primary
        store.closePrimaryPane(session.id)
        #expect(store.session(withID: session.id) == nil) // single session → closed
        #expect(primary.teardownCount == 1)
    }

    @Test func closeSplitPaneWithPrimaryCollapsesToPrimary() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let primary = SpySurface(); session.surface = primary
        let split = SpySurface(); session.splitSurface = split
        session.isSplit = true
        session.hasSplit = true
        store.closeSplitPane(session.id)
        #expect(store.session(withID: session.id) != nil) // session survives
        #expect(split.teardownCount == 1)                 // the split is torn down
        #expect(primary.teardownCount == 0)               // the primary is kept
        #expect(session.splitSurface == nil)
        #expect(session.isSplit == false)
    }

    @Test func closeSplitPaneWithoutPrimaryClosesSession() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        // the primary already exited (surface nil); only the split survives, so this is the last pane.
        let split = SpySurface(); session.splitSurface = split
        store.closeSplitPane(session.id)
        #expect(store.session(withID: session.id) == nil) // last pane → closed
        #expect(split.teardownCount == 1)
    }

    @Test func splitCwdRoundTripsThroughSnapshot() {
        let store = Self.makeStore()
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
        let restored = Self.makeStore()
        restored.restore(from: snap)
        let r = restored.workspaces[0].sessions[0]
        #expect(r.initialCwd == "/a/primary")
        #expect(r.initialSplitCwd == "/var/log")
        #expect(r.isSplit == true)
    }

    @Test func openOverlaySetsCommandAndFlag() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        #expect(store.openOverlay(session.id, command: "revdiff", cwd: "/b") == true)
        #expect(session.overlayActive == true)
        #expect(session.overlayCommand == "revdiff")
        #expect(session.overlayCwd == "/b")
        // no size given → the default full-pane overlay, not a floating one.
        #expect(session.overlaySizePercent == nil)
        // a second open while one is active is a no-op.
        #expect(store.openOverlay(session.id, command: "other") == false)
        #expect(session.overlayCommand == "revdiff")
    }

    @Test func overlayExitCodeRecordedAndSurvivesClose() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.openOverlay(session.id, command: "revdiff")
        #expect(session.overlayExitCode == nil)
        store.recordOverlayExit(session.id, code: 10)
        #expect(store.closeOverlay(session.id) == true)
        // the exit code survives close (read by session.overlay.result after the overlay vanishes)...
        #expect(session.overlayExitCode == 10)
        // ...and is reset when a new overlay opens.
        #expect(store.openOverlay(session.id, command: "revdiff") == true)
        #expect(session.overlayExitCode == nil)
    }

    @Test func recordOverlayExitUnknownSessionIsNoop() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        // a bogus id must be a no-op, not a crash, and must not touch any existing session.
        store.recordOverlayExit(UUID(), code: 5)
        #expect(session.overlayExitCode == nil)
    }

    @Test func openOverlayFloatingClampsSizePercent() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        #expect(store.openOverlay(session.id, command: "htop", sizePercent: 70) == true)
        #expect(session.overlaySizePercent == 70)
        // close clears the floating size back to nil.
        store.closeOverlay(session.id)
        #expect(session.overlaySizePercent == nil)
        // out-of-range values clamp to 1...100, including negatives; the exact bounds pass through.
        store.openOverlay(session.id, command: "htop", sizePercent: 250)
        #expect(session.overlaySizePercent == 100)
        store.closeOverlay(session.id)
        store.openOverlay(session.id, command: "htop", sizePercent: 0)
        #expect(session.overlaySizePercent == 1)
        store.closeOverlay(session.id)
        store.openOverlay(session.id, command: "htop", sizePercent: -5)
        #expect(session.overlaySizePercent == 1)
        store.closeOverlay(session.id)
        store.openOverlay(session.id, command: "htop", sizePercent: 100)
        #expect(session.overlaySizePercent == 100)
        store.closeOverlay(session.id)
        store.openOverlay(session.id, command: "htop", sizePercent: 1)
        #expect(session.overlaySizePercent == 1)
    }

    @Test func closeOverlayTearsDownAndClears() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.openOverlay(session.id, command: "revdiff")
        let overlay = SpySurface()
        session.overlaySurface = overlay
        #expect(store.closeOverlay(session.id) == true)
        #expect(session.overlayActive == false)
        #expect(session.overlaySurface == nil)
        #expect(session.overlayCommand == nil)
        #expect(overlay.teardownCount == 1)
        // closing again is a no-op.
        #expect(store.closeOverlay(session.id) == false)
    }

    @Test func closeSessionTearsDownOverlaySurface() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.openOverlay(session.id, command: "revdiff")
        let overlay = SpySurface()
        session.overlaySurface = overlay
        store.closeSession(session.id)
        #expect(overlay.teardownCount == 1)
    }

    @Test func toggleScratchFlipsFlagAndKeepsSurfaceAlive() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        #expect(session.scratchActive == false)
        store.toggleScratch(session.id)
        #expect(session.scratchActive == true)
        // the detail pane lazily creates the surface on show; simulate that.
        let scratch = SpySurface()
        session.scratchSurface = scratch
        // hiding keeps the shell alive (slot retained), so a re-show reuses it.
        store.toggleScratch(session.id)
        #expect(session.scratchActive == false)
        #expect(session.scratchSurface === scratch)
        #expect(scratch.teardownCount == 0)
        store.toggleScratch(session.id)
        #expect(session.scratchActive == true)
        #expect(session.scratchSurface === scratch)
    }

    @Test func closeScratchTearsDownAndClears() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.scratchActive = true
        let scratch = SpySurface()
        session.scratchSurface = scratch
        #expect(store.closeScratch(session.id) == true)
        #expect(session.scratchActive == false)
        #expect(session.scratchSurface == nil)
        #expect(scratch.teardownCount == 1)
        // closing again (no surface) is a no-op.
        #expect(store.closeScratch(session.id) == false)
    }

    @Test func toggleScratchUnknownSessionIsNoop() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.toggleScratch(UUID()) // unknown id
        #expect(session.scratchActive == false) // existing session untouched
    }

    @Test func closeScratchUnknownSessionReturnsFalse() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        _ = store.addSession(toWorkspace: ws.id, cwd: "/a")
        #expect(store.closeScratch(UUID()) == false) // unknown id, no surface
    }

    @Test func closeSessionTearsDownScratchSurface() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let scratch = SpySurface()
        session.scratchSurface = scratch
        store.closeSession(session.id)
        #expect(scratch.teardownCount == 1)
    }

    @Test func removeWorkspaceTearsDownScratchSurface() {
        let store = Self.makeStore()
        let keep = store.addWorkspace(name: "keep")
        _ = store.addSession(toWorkspace: keep.id, cwd: "/k")
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let scratch = SpySurface()
        session.scratchSurface = scratch
        store.removeWorkspace(ws.id)
        #expect(scratch.teardownCount == 1)
    }

    @Test func selectionUpdatesRecencyMostRecentFirst() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        #expect(store.sessionRecency.items == [b.id, a.id]) // b selected last
        store.selectSession(a.id)
        #expect(store.sessionRecency.items == [a.id, b.id]) // a now front, b is the previous
        #expect(store.sessionRecency.items[1] == b.id)
    }

    @Test func closeSessionRemovesFromRecency() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.closeSession(b.id)
        #expect(!store.sessionRecency.items.contains(b.id))
        #expect(store.sessionRecency.items == [a.id])
    }

    @Test func setFontSizeRecordsValue() {
        let store = Self.makeStore()
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
        let store = Self.makeStore()
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
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.setFontSize(UUID(), 20)
        #expect(session.fontSize == nil)
    }

    @Test func closeUnknownSessionIsIgnored() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.selectSession(a.id)
        store.closeSession(UUID())
        #expect(store.workspaces[0].sessions.map(\.id) == [a.id])
        #expect(store.selectedSessionID == a.id)
    }

    @Test func moveSessionDoesNotTearDownSurface() {
        let store = Self.makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let session = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let surface = SpySurface()
        session.surface = surface
        store.moveSession(session.id, toWorkspace: personal.id)
        #expect(surface.teardownCount == 0)
        #expect(store.workspaces[1].sessions[0].surface === surface)
    }

    @Test func moveSessionClampsNegativeIndex() {
        let store = Self.makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let moved = store.addSession(toWorkspace: work.id, cwd: "/moved")!
        let x = store.addSession(toWorkspace: personal.id, cwd: "/x")!
        store.moveSession(moved.id, toWorkspace: personal.id, at: -5)
        #expect(store.workspaces[1].sessions.map(\.id) == [moved.id, x.id])
    }

    @Test func renameUnknownWorkspaceIsIgnored() {
        let store = Self.makeStore()
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
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.renameSession(session.id, to: "build")
        #expect(session.customName == "build")
        #expect(session.displayName == "build")
    }

    @Test func renameSessionWithBlankClearsCustomName() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/Users/user/foo")!
        store.renameSession(session.id, to: "build")
        store.renameSession(session.id, to: "   ")
        #expect(session.customName == nil)
        #expect(session.displayName == "foo")
    }

    @Test func renameSessionTrimsWhitespace() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.renameSession(session.id, to: "  build  ")
        #expect(session.customName == "build")
    }

    @Test func renameWorkspaceSetsName() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        store.renameWorkspace(ws.id, to: "personal")
        #expect(store.workspaces[0].name == "personal")
    }

    @Test func renameWorkspaceWithBlankIsIgnored() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        store.renameWorkspace(ws.id, to: "   ")
        #expect(store.workspaces[0].name == "work")
    }

    @Test func moveSessionAppendsToTargetWorkspace() {
        let store = Self.makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: personal.id, cwd: "/b")!
        store.moveSession(a.id, toWorkspace: personal.id)
        #expect(store.workspaces[0].sessions.isEmpty)
        #expect(store.workspaces[1].sessions.map(\.id) == [b.id, a.id])
    }

    @Test func moveSessionInsertsAtIndex() {
        let store = Self.makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let moved = store.addSession(toWorkspace: work.id, cwd: "/moved")!
        let x = store.addSession(toWorkspace: personal.id, cwd: "/x")!
        let y = store.addSession(toWorkspace: personal.id, cwd: "/y")!
        store.moveSession(moved.id, toWorkspace: personal.id, at: 1)
        #expect(store.workspaces[1].sessions.map(\.id) == [x.id, moved.id, y.id])
    }

    @Test func moveSessionClampsOutOfRangeIndex() {
        let store = Self.makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let moved = store.addSession(toWorkspace: work.id, cwd: "/moved")!
        let x = store.addSession(toWorkspace: personal.id, cwd: "/x")!
        store.moveSession(moved.id, toWorkspace: personal.id, at: 99)
        #expect(store.workspaces[1].sessions.map(\.id) == [x.id, moved.id])
    }

    @Test func moveSessionPreservesSameInstance() {
        let store = Self.makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let session = store.addSession(toWorkspace: work.id, cwd: "/a")!
        session.customName = "build"
        store.moveSession(session.id, toWorkspace: personal.id)
        let movedRef = store.workspaces[1].sessions[0]
        #expect(movedRef === session)
        #expect(movedRef.customName == "build")
    }

    @Test func moveActiveSessionKeepsItSelected() {
        let store = Self.makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        store.selectSession(a.id)
        store.moveSession(a.id, toWorkspace: personal.id)
        #expect(store.selectedSessionID == a.id)
        #expect(store.activeSession?.id == a.id)
        #expect(store.workspace(forSession: a.id)?.id == personal.id)
    }

    @Test func moveNonActiveSessionLeavesSelectionUntouched() {
        let store = Self.makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: work.id, cwd: "/b")!
        store.selectSession(b.id)
        store.moveSession(a.id, toWorkspace: personal.id)
        #expect(store.selectedSessionID == b.id)
    }

    @Test func moveLastSessionLeavesSourceEmpty() {
        let store = Self.makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let only = store.addSession(toWorkspace: work.id, cwd: "/only")!
        store.selectSession(only.id)
        store.moveSession(only.id, toWorkspace: personal.id)
        #expect(store.workspaces[0].sessions.isEmpty)
        #expect(store.workspaces[1].sessions.map(\.id) == [only.id])
        #expect(store.selectedSessionID == only.id)
    }

    @Test func moveSessionWithinSameWorkspaceReorders() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        let c = store.addSession(toWorkspace: ws.id, cwd: "/c")!
        store.moveSession(a.id, toWorkspace: ws.id, at: 2)
        #expect(store.workspaces[0].sessions.map(\.id) == [b.id, c.id, a.id])
    }

    @Test func moveSessionWithinSameWorkspaceToCurrentSlotIsNoOp() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.moveSession(a.id, toWorkspace: ws.id, at: 0)
        #expect(store.workspaces[0].sessions.map(\.id) == [a.id, b.id])
    }

    @Test func moveUnknownSessionIsIgnored() {
        let store = Self.makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        store.moveSession(UUID(), toWorkspace: personal.id)
        #expect(store.workspaces[0].sessions.map(\.id) == [a.id])
        #expect(store.workspaces[1].sessions.isEmpty)
    }

    @Test func moveToUnknownWorkspaceIsIgnored() {
        let store = Self.makeStore()
        let work = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        store.moveSession(a.id, toWorkspace: UUID())
        #expect(store.workspaces[0].sessions.map(\.id) == [a.id])
    }

    /// Builds a single-workspace tree (a, b, c) with the middle session (b) selected.
    static func makeReorderTree() -> (store: AppStore, ws: Workspace, ids: [UUID]) {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        let c = store.addSession(toWorkspace: ws.id, cwd: "/c")!
        store.selectSession(b.id)
        return (store, ws, [a.id, b.id, c.id])
    }

    @Test func reorderSessionUp() {
        let (store, _, ids) = Self.makeReorderTree()
        store.reorderSession(ids[1], .up)
        #expect(store.workspaces[0].sessions.map(\.id) == [ids[1], ids[0], ids[2]])
        #expect(store.selectedSessionID == ids[1])
    }

    @Test func reorderSessionDown() {
        let (store, _, ids) = Self.makeReorderTree()
        store.reorderSession(ids[1], .down)
        #expect(store.workspaces[0].sessions.map(\.id) == [ids[0], ids[2], ids[1]])
        #expect(store.selectedSessionID == ids[1])
    }

    @Test func reorderSessionTop() {
        let (store, _, ids) = Self.makeReorderTree()
        store.reorderSession(ids[2], .top)
        #expect(store.workspaces[0].sessions.map(\.id) == [ids[2], ids[0], ids[1]])
    }

    @Test func reorderSessionBottom() {
        let (store, _, ids) = Self.makeReorderTree()
        store.reorderSession(ids[0], .bottom)
        #expect(store.workspaces[0].sessions.map(\.id) == [ids[1], ids[2], ids[0]])
    }

    @Test func reorderSessionUpAtTopIsNoOp() {
        let (store, _, ids) = Self.makeReorderTree()
        store.reorderSession(ids[0], .up)
        #expect(store.workspaces[0].sessions.map(\.id) == ids)
        store.reorderSession(ids[0], .top)
        #expect(store.workspaces[0].sessions.map(\.id) == ids)
    }

    @Test func reorderSessionDownAtBottomIsNoOp() {
        let (store, _, ids) = Self.makeReorderTree()
        store.reorderSession(ids[2], .down)
        #expect(store.workspaces[0].sessions.map(\.id) == ids)
        store.reorderSession(ids[2], .bottom)
        #expect(store.workspaces[0].sessions.map(\.id) == ids)
    }

    @Test func reorderUnknownSessionIsIgnored() {
        let (store, _, ids) = Self.makeReorderTree()
        store.reorderSession(UUID(), .up)
        #expect(store.workspaces[0].sessions.map(\.id) == ids)
    }

    @Test func sessionLocationReportsWorkspaceIndexAndCount() {
        let store = Self.makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: work.id, cwd: "/b")!
        let c = store.addSession(toWorkspace: personal.id, cwd: "/c")!

        let locA = store.sessionLocation(ofSession: a.id)
        #expect(locA?.workspace == work.id)
        #expect(locA?.index == 0)
        #expect(locA?.count == 2)

        let locB = store.sessionLocation(ofSession: b.id)
        #expect(locB?.workspace == work.id)
        #expect(locB?.index == 1)
        #expect(locB?.count == 2)

        let locC = store.sessionLocation(ofSession: c.id)
        #expect(locC?.workspace == personal.id)
        #expect(locC?.index == 0)
        #expect(locC?.count == 1)
    }

    @Test func sessionLocationOfUnknownSessionIsNil() {
        let store = Self.makeStore()
        let work = store.addWorkspace(name: "work")
        _ = store.addSession(toWorkspace: work.id, cwd: "/a")!
        #expect(store.sessionLocation(ofSession: UUID()) == nil)
    }

    /// Builds a three-workspace tree [w0, w1, w2] with no sessions.
    static func makeWorkspaceReorderTree() -> (store: AppStore, ids: [UUID]) {
        let store = Self.makeStore()
        let w0 = store.addWorkspace(name: "w0")
        let w1 = store.addWorkspace(name: "w1")
        let w2 = store.addWorkspace(name: "w2")
        return (store, [w0.id, w1.id, w2.id])
    }

    @Test func moveWorkspaceReordersWithinBounds() {
        let (store, ids) = Self.makeWorkspaceReorderTree()
        store.moveWorkspace(ids[0], at: 2)
        #expect(store.workspaces.map(\.id) == [ids[1], ids[2], ids[0]])
    }

    @Test func moveWorkspaceClampsIndexAtBothEnds() {
        let (store, ids) = Self.makeWorkspaceReorderTree()
        store.moveWorkspace(ids[1], at: 99)
        #expect(store.workspaces.map(\.id) == [ids[0], ids[2], ids[1]])
        store.moveWorkspace(ids[1], at: -5)
        #expect(store.workspaces.map(\.id) == [ids[1], ids[0], ids[2]])
    }

    @Test func moveUnknownWorkspaceIsIgnored() {
        let (store, ids) = Self.makeWorkspaceReorderTree()
        store.moveWorkspace(UUID(), at: 0)
        #expect(store.workspaces.map(\.id) == ids)
    }

    @Test func reorderWorkspaceUp() {
        let (store, ids) = Self.makeWorkspaceReorderTree()
        store.reorderWorkspace(ids[1], .up)
        #expect(store.workspaces.map(\.id) == [ids[1], ids[0], ids[2]])
    }

    @Test func reorderWorkspaceDown() {
        let (store, ids) = Self.makeWorkspaceReorderTree()
        store.reorderWorkspace(ids[1], .down)
        #expect(store.workspaces.map(\.id) == [ids[0], ids[2], ids[1]])
    }

    @Test func reorderWorkspaceTop() {
        let (store, ids) = Self.makeWorkspaceReorderTree()
        store.reorderWorkspace(ids[2], .top)
        #expect(store.workspaces.map(\.id) == [ids[2], ids[0], ids[1]])
    }

    @Test func reorderWorkspaceBottom() {
        let (store, ids) = Self.makeWorkspaceReorderTree()
        store.reorderWorkspace(ids[0], .bottom)
        #expect(store.workspaces.map(\.id) == [ids[1], ids[2], ids[0]])
    }

    @Test func reorderWorkspaceAtEndsIsNoOp() {
        let (store, ids) = Self.makeWorkspaceReorderTree()
        store.reorderWorkspace(ids[0], .up)
        store.reorderWorkspace(ids[0], .top)
        store.reorderWorkspace(ids[2], .down)
        store.reorderWorkspace(ids[2], .bottom)
        #expect(store.workspaces.map(\.id) == ids)
    }

    @Test func reorderWorkspaceKeepsSelectedSession() {
        let (store, ids) = Self.makeWorkspaceReorderTree()
        let session = store.addSession(toWorkspace: ids[0], cwd: "/a")!
        store.selectSession(session.id)
        store.reorderWorkspace(ids[0], .bottom)
        #expect(store.workspaces.map(\.id) == [ids[1], ids[2], ids[0]])
        #expect(store.selectedSessionID == session.id)
    }

    @Test func moveWorkspaceKeepsSelectedSession() {
        let (store, ids) = Self.makeWorkspaceReorderTree()
        let session = store.addSession(toWorkspace: ids[1], cwd: "/a")!
        store.selectSession(session.id)
        store.moveWorkspace(ids[1], at: 0)
        #expect(store.workspaces.map(\.id) == [ids[1], ids[0], ids[2]])
        #expect(store.selectedSessionID == session.id)
    }

    @Test func reorderOrderSurvivesSnapshotRestore() {
        let store = Self.makeStore()
        let w0 = store.addWorkspace(name: "w0")
        let w1 = store.addWorkspace(name: "w1")
        let a = store.addSession(toWorkspace: w0.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: w0.id, cwd: "/b")!
        let c = store.addSession(toWorkspace: w0.id, cwd: "/c")!
        store.reorderSession(a.id, .bottom) // sessions -> [b, c, a]
        store.reorderWorkspace(w1.id, .top) // workspaces -> [w1, w0]

        let snap = store.snapshot()
        let restored = Self.makeStore()
        restored.restore(from: snap)
        #expect(restored.workspaces.map(\.id) == [w1.id, w0.id])
        #expect(restored.workspaces[1].sessions.map(\.id) == [b.id, c.id, a.id])
    }

    /// Builds a two-workspace tree (work: a, b; personal: c, d) so flattened order is [a, b, c, d].
    static func makeNavTree() -> (store: AppStore, ids: [UUID]) {
        let store = Self.makeStore()
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
        store.navigateSession(.next) // crosses from work into personal
        #expect(store.selectedSessionID == ids[2])
        store.navigateSession(.next)
        #expect(store.selectedSessionID == ids[3])
    }

    @Test func navigatePreviousStepsBackwardCrossingWorkspaces() {
        let (store, ids) = Self.makeNavTree()
        store.selectSession(ids[3])
        store.navigateSession(.previous)
        #expect(store.selectedSessionID == ids[2])
        store.navigateSession(.previous) // crosses from personal into work
        #expect(store.selectedSessionID == ids[1])
        store.navigateSession(.previous)
        #expect(store.selectedSessionID == ids[0])
    }

    @Test func navigateNextAtLastStaysPut() {
        let (store, ids) = Self.makeNavTree()
        store.selectSession(ids.last!)
        store.navigateSession(.next) // already at the end: no wrap, stays put
        #expect(store.selectedSessionID == ids.last!)
    }

    @Test func navigatePreviousAtFirstStaysPut() {
        let (store, ids) = Self.makeNavTree()
        store.selectSession(ids.first!)
        store.navigateSession(.previous) // already at the start: no wrap, stays put
        #expect(store.selectedSessionID == ids.first!)
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
        #expect(store.selectedSessionID == ids.last!) // .last ignores the (absent) selection
        store.selectSession(nil)
        store.navigateSession(.first)
        #expect(store.selectedSessionID == ids.first!) // .first ignores the (absent) selection
    }

    @Test func navigateSingleSessionStaysSelected() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let only = store.addSession(toWorkspace: ws.id, cwd: "/only")!
        store.selectSession(only.id)
        for direction in [SessionNavigation.next, .previous, .first, .last] {
            store.navigateSession(direction)
            #expect(store.selectedSessionID == only.id)
        }
    }

    @Test func navigateEmptyTreeIsNoOp() {
        let store = Self.makeStore()
        store.addWorkspace(name: "work") // no sessions
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
        #expect(store.session(withID: ids[1])?.unseenCount == 0) // selectSession cleared the badge
        // the navigation pushed a NEW recency entry on top of the prior selection (most-recent first).
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
        let (store, ids) = Self.makeNavTree() // a, b, c, d
        store.session(withID: ids[1])?.agentIndicator = AgentIndicator(status: .blocked)   // b
        store.session(withID: ids[3])?.agentIndicator = AgentIndicator(status: .completed) // d
        store.selectSession(ids[0]) // a (idle)
        store.navigateSession(.nextAttention)
        #expect(store.selectedSessionID == ids[1]) // skips to blocked b
        store.navigateSession(.nextAttention)
        #expect(store.selectedSessionID == ids[3]) // skips idle c, lands on completed d
    }

    @Test func navigateAttentionWrapsAround() {
        let (store, ids) = Self.makeNavTree()
        store.session(withID: ids[1])?.agentIndicator = AgentIndicator(status: .blocked)   // b
        store.session(withID: ids[3])?.agentIndicator = AgentIndicator(status: .completed) // d
        store.selectSession(ids[3]) // d (last attention)
        store.navigateSession(.nextAttention)
        #expect(store.selectedSessionID == ids[1]) // wraps forward to b
        store.navigateSession(.previousAttention)
        #expect(store.selectedSessionID == ids[3]) // wraps backward to d
    }

    @Test func navigateAttentionSkipsActiveAndIdle() {
        let (store, ids) = Self.makeNavTree()
        store.session(withID: ids[1])?.agentIndicator = AgentIndicator(status: .active)  // b active - excluded
        store.session(withID: ids[2])?.agentIndicator = AgentIndicator(status: .blocked) // c blocked - included
        store.selectSession(ids[0])
        store.navigateSession(.nextAttention)
        #expect(store.selectedSessionID == ids[2]) // skips active b, lands on blocked c
    }

    @Test func navigateAttentionWithSingleAttentionSessionStaysPut() {
        let (store, ids) = Self.makeNavTree()
        store.session(withID: ids[2])?.agentIndicator = AgentIndicator(status: .completed) // c, the only one
        store.selectSession(ids[2])
        store.navigateSession(.nextAttention)
        #expect(store.selectedSessionID == ids[2]) // no other attention session -> no-op
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
        store.session(withID: ids[1])?.agentIndicator = AgentIndicator(status: .blocked)   // b
        store.session(withID: ids[3])?.agentIndicator = AgentIndicator(status: .completed) // d
        store.selectSession(nil)
        store.navigateSession(.nextAttention)
        #expect(store.selectedSessionID == ids[1]) // forward from before-first -> first attention
        store.selectSession(nil)
        store.navigateSession(.previousAttention)
        #expect(store.selectedSessionID == ids[3]) // backward from after-last -> last attention
    }
}

private final class SpySurface: TerminalSurface {
    var teardownCount = 0
    func teardown() { teardownCount += 1 }
}
