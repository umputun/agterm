import Foundation
import Testing
@testable import agtermCore

// the sidebar focus filter: the focus mutators, the `visibleWorkspaces` projection they drive, the
// sidebar-selection prune that follows it, and the `controlTree` focus read-back. Split out of
// `AppStoreOrganizationTests`/`AppStoreTests` so the focus behavior has one home (and so the latter
// stays clear of the 2000-line test-file cap).
@MainActor
struct AppStoreFocusTests {
    @Test func setFocusedWorkspaceSetsAndClears() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        #expect(store.focusedWorkspaceIDs.isEmpty && !store.focusEnabled)
        store.setFocusedWorkspace(work.id)
        #expect(store.focusedWorkspaceIDs == [work.id] && store.focusEnabled)
        store.setFocusedWorkspace(nil)
        #expect(store.focusedWorkspaceIDs.isEmpty && !store.focusEnabled)
    }

    @Test func setFocusedWorkspaceReplacesTheWholeSet() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        store.setFocusMembership(work.id, member: true)
        store.setFocusMembership(personal.id, member: true)
        #expect(store.focusedWorkspaceIDs == [work.id, personal.id])
        // the single-workspace convenience REPLACES rather than adds, so the row menu's Focus still zooms.
        store.setFocusedWorkspace(personal.id)
        #expect(store.focusedWorkspaceIDs == [personal.id] && store.focusEnabled)
    }

    @Test func setFocusMembershipAddsAndRemoves() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        store.setFocusMembership(work.id, member: true)
        #expect(store.focusedWorkspaceIDs == [work.id] && store.focusEnabled) // marking also turns the filter on
        store.setFocusMembership(personal.id, member: true)
        #expect(store.focusedWorkspaceIDs == [work.id, personal.id] && store.focusEnabled)
        store.setFocusMembership(work.id, member: false)
        #expect(store.focusedWorkspaceIDs == [personal.id] && store.focusEnabled) // the survivor keeps the filter on
    }

    @Test func removingTheLastMemberDisablesTheFilter() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        store.setFocusMembership(work.id, member: true)
        store.setFocusMembership(work.id, member: false)
        #expect(store.focusedWorkspaceIDs.isEmpty && !store.focusEnabled) // `enabled + empty` is unrepresentable
    }

    @Test func setFocusMembershipOnADisabledSetKeepsItDisabledWhenRemoving() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        store.setFocusMembership(work.id, member: true)
        store.setFocusMembership(personal.id, member: true)
        store.setFocusEnabled(false)
        store.setFocusMembership(work.id, member: false)
        #expect(store.focusedWorkspaceIDs == [personal.id] && !store.focusEnabled) // removing never turns it back on
    }

    @Test func setFocusEnabledRoundTripsWithoutLosingTheSet() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        store.setFocusMembership(work.id, member: true)
        store.setFocusMembership(personal.id, member: true)
        store.setFocusEnabled(false)
        #expect(store.focusedWorkspaceIDs == [work.id, personal.id] && !store.focusEnabled) // the set survives
        store.setFocusEnabled(true)
        #expect(store.focusedWorkspaceIDs == [work.id, personal.id] && store.focusEnabled)
    }

    @Test func setFocusEnabledRefusesAnEmptySet() {
        let store = makeStore()
        _ = store.addWorkspace(name: "work")
        store.setFocusEnabled(true)
        #expect(!store.focusEnabled) // nothing marked, so there is nothing to filter to
    }

    @Test func focusSettersAreNoOpWritesWhenUnchanged() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let persistence = PersistenceStore(directory: dir)
        let store = AppStore(persistence: persistence)
        let ws = store.addWorkspace(name: "work")
        store.setFocusedWorkspace(ws.id)
        let file = dir.appendingPathComponent("workspaces.json")
        try? FileManager.default.removeItem(at: file) // a no-op setter must NOT recreate the file
        store.setFocusedWorkspace(ws.id)            // unchanged
        store.setFocusMembership(ws.id, member: true) // already a member, already enabled
        store.setFocusEnabled(true)                 // already enabled
        #expect(!FileManager.default.fileExists(atPath: file.path)) // no write happened
        #expect(store.focusedWorkspaceIDs == [ws.id] && store.focusEnabled) // state stable across the no-op setters
    }

    @Test func setFocusEnabledOnAnEmptySetIsANoOpWrite() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let persistence = PersistenceStore(directory: dir)
        let store = AppStore(persistence: persistence)
        _ = store.addWorkspace(name: "work")
        let file = dir.appendingPathComponent("workspaces.json")
        try? FileManager.default.removeItem(at: file)
        store.setFocusEnabled(true) // refused, so it must not write either
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func visibleWorkspacesReturnsAllWhenTheFilterIsOff() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        #expect(store.visibleWorkspaces.map(\.id) == [work.id, personal.id])
        // marking then switching the filter off reveals the whole tree again, set intact.
        store.setFocusMembership(work.id, member: true)
        store.setFocusEnabled(false)
        #expect(store.visibleWorkspaces.map(\.id) == [work.id, personal.id])
    }

    @Test func visibleWorkspacesReturnsOneWhenFocused() {
        let store = makeStore()
        _ = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        store.setFocusedWorkspace(personal.id)
        #expect(store.visibleWorkspaces.map(\.id) == [personal.id])
    }

    @Test func visibleWorkspacesReturnsTheMarkedSubsetInTreeOrder() {
        let store = makeStore()
        let one = store.addWorkspace(name: "one")
        _ = store.addWorkspace(name: "two")
        let three = store.addWorkspace(name: "three")
        store.setFocusMembership(three.id, member: true) // marked out of tree order
        store.setFocusMembership(one.id, member: true)
        #expect(store.visibleWorkspaces.map(\.id) == [one.id, three.id]) // rendered in tree order, not mark order
    }

    @Test func visibleWorkspacesKeepsSurvivorsForAPartiallyStaleSet() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        _ = store.addWorkspace(name: "personal")
        store.focusedWorkspaceIDs = [work.id, UUID()] // one member no longer in the tree
        store.focusEnabled = true
        #expect(store.visibleWorkspaces.map(\.id) == [work.id])
    }

    @Test func visibleWorkspacesFallsBackToAllForAnAllStaleSet() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        store.focusedWorkspaceIDs = [UUID()] // stale id, no matching workspace
        store.focusEnabled = true
        #expect(store.visibleWorkspaces.map(\.id) == [work.id, personal.id]) // defensive fallback, not a reachable state
    }

    @Test func removingAMemberPrunesItAndKeepsTheRestFiltered() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let doomed = store.addWorkspace(name: "doomed")
        _ = store.addWorkspace(name: "other")
        store.setFocusMembership(work.id, member: true)
        store.setFocusMembership(doomed.id, member: true)
        store.removeWorkspace(doomed.id)
        #expect(store.focusedWorkspaceIDs == [work.id] && store.focusEnabled) // the survivor keeps filtering
        #expect(store.visibleWorkspaces.map(\.id) == [work.id])
    }

    @Test func removingTheLastMemberWorkspaceDisablesTheFilter() {
        let store = makeStore()
        _ = store.addWorkspace(name: "other")
        let doomed = store.addWorkspace(name: "doomed")
        store.setFocusMembership(doomed.id, member: true)
        store.removeWorkspace(doomed.id)
        #expect(store.focusedWorkspaceIDs.isEmpty && !store.focusEnabled) // nothing left to filter to
    }

    @Test func removingANonMemberWorkspaceLeavesTheFilterUntouched() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let doomed = store.addWorkspace(name: "doomed")
        store.setFocusMembership(work.id, member: true)
        store.setFocusMembership(personal.id, member: true)
        store.removeWorkspace(doomed.id)
        #expect(store.focusedWorkspaceIDs == [work.id, personal.id] && store.focusEnabled)
    }

    @Test func softRemovingAMemberPrunesItAndDisablesWhenTheSetEmpties() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let doomed = store.addWorkspace(name: "doomed")
        _ = store.addWorkspace(name: "spare") // soft-remove keeps at least one workspace
        store.setFocusMembership(work.id, member: true)
        store.setFocusMembership(doomed.id, member: true)
        #expect(store.softRemoveWorkspace(doomed.id))
        #expect(store.focusedWorkspaceIDs == [work.id] && store.focusEnabled)
        #expect(store.softRemoveWorkspace(work.id))
        #expect(store.focusedWorkspaceIDs.isEmpty && !store.focusEnabled)
    }

    @Test func selectingOutsideTheSetDisablesTheFilterButKeepsEveryMember() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let outside = store.addWorkspace(name: "outside")
        _ = store.addSession(toWorkspace: work.id, cwd: "/a")
        store.setFocusMembership(work.id, member: true)
        store.setFocusMembership(personal.id, member: true)
        let stray = try! #require(store.addSession(toWorkspace: outside.id, cwd: "/b", select: false))
        store.selectSession(stray.id)
        #expect(store.focusedWorkspaceIDs == [work.id, personal.id] && !store.focusEnabled) // set intact
        store.setFocusEnabled(true) // one flip restores the hand-curated working set
        #expect(store.visibleWorkspaces.map(\.id) == [work.id, personal.id])
    }

    @Test func selectingInsideTheSetChangesNothing() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        _ = store.addSession(toWorkspace: work.id, cwd: "/a")
        let inSet = try! #require(store.addSession(toWorkspace: personal.id, cwd: "/b", select: false))
        store.setFocusMembership(work.id, member: true)
        store.setFocusMembership(personal.id, member: true)
        store.selectSession(inSet.id)
        #expect(store.focusedWorkspaceIDs == [work.id, personal.id] && store.focusEnabled)
    }

    @Test func addWorkspaceJoinsTheSetOnlyWhileTheFilterIsOn() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        // filter OFF with a marked set: the new workspace is visible anyway, so neither field is touched.
        store.setFocusMembership(work.id, member: true)
        store.setFocusEnabled(false)
        _ = store.addWorkspace(name: "quiet")
        #expect(store.focusedWorkspaceIDs == [work.id] && !store.focusEnabled)
        // filter ON: the new workspace joins the set so it is visible without dropping the filter.
        store.setFocusEnabled(true)
        let fresh = store.addWorkspace(name: "fresh")
        #expect(store.focusedWorkspaceIDs == [work.id, fresh.id] && store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id) == [work.id, fresh.id]) // `quiet` stays filtered out
    }

    @Test func addWorkspaceWithoutRevealDoesNotWidenTheSet() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        store.setFocusMembership(work.id, member: true)
        _ = store.addWorkspace(name: "background", revealNewWorkspace: false)
        #expect(store.focusedWorkspaceIDs == [work.id] && store.focusEnabled) // the background create stays hidden
        #expect(store.visibleWorkspaces.map(\.id) == [work.id])
    }

    @Test func restorePrunesAnAllStaleSetToEmptyAndDisabled() {
        // every marked workspace is gone from the restored tree (deleted from another window, or a
        // hand-edited file). Restoring the set verbatim would leave `enabled + empty`, which reports
        // `workspaceFilter == true` while no workspace reports `focused` — a read-back contract that lies.
        let store = makeStore()
        let survivor = WorkspaceSnapshot(id: UUID(), name: "survivor", sessions: [])
        store.restore(from: Snapshot(workspaces: [survivor], focusedWorkspaceIDs: [UUID(), UUID()],
                                     focusEnabled: true))
        #expect(store.focusedWorkspaceIDs.isEmpty && !store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id) == [survivor.id])
    }

    @Test func restoreKeepsTheSurvivorsOfAPartiallyStaleSet() {
        let store = makeStore()
        let kept = WorkspaceSnapshot(id: UUID(), name: "kept", sessions: [])
        let other = WorkspaceSnapshot(id: UUID(), name: "other", sessions: [])
        store.restore(from: Snapshot(workspaces: [kept, other], focusedWorkspaceIDs: [kept.id, UUID()],
                                     focusEnabled: true))
        #expect(store.focusedWorkspaceIDs == [kept.id] && store.focusEnabled) // the survivor keeps filtering
        #expect(store.visibleWorkspaces.map(\.id) == [kept.id])
    }

    @Test func restoreKeepsADisabledSetWithoutEnablingIt() {
        // the flag is persisted apart from the set, so restoring a marked-but-off filter must not turn it
        // back on just because members survived the prune.
        let store = makeStore()
        let kept = WorkspaceSnapshot(id: UUID(), name: "kept", sessions: [])
        let other = WorkspaceSnapshot(id: UUID(), name: "other", sessions: [])
        store.restore(from: Snapshot(workspaces: [kept, other], focusedWorkspaceIDs: [kept.id]))
        #expect(store.focusedWorkspaceIDs == [kept.id] && !store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id) == [kept.id, other.id]) // off means the whole tree renders
    }

    @Test func restoreClearsAFocusSetLeftOverFromAPreviousTree() {
        // `restore` replaces the state wholesale (a window reopen reloads through it), so a set left from
        // the store's previous contents must not survive into the new tree.
        let store = makeStore()
        let stale = store.addWorkspace(name: "stale")
        store.setFocusMembership(stale.id, member: true)
        let fresh = WorkspaceSnapshot(id: UUID(), name: "fresh", sessions: [])
        store.restore(from: Snapshot(workspaces: [fresh]))
        #expect(store.focusedWorkspaceIDs.isEmpty && !store.focusEnabled)
    }

    @Test func workspaceFocusPrunesRowsOutsideFocusedWorkspace() {
        let store = makeStore()
        let ws1 = store.addWorkspace(name: "one")
        let ws2 = store.addWorkspace(name: "two")
        let a = try! #require(store.addSession(toWorkspace: ws1.id, cwd: "/a"))
        let b = try! #require(store.addSession(toWorkspace: ws2.id, cwd: "/b"))
        store.setSidebarSelection([a.id, b.id])

        store.setFocusedWorkspace(ws2.id)

        #expect(store.sidebarSelectionIDs == [b.id])
        store.setFocusedWorkspace(nil)
        #expect(store.sidebarSelectionIDs == [b.id],
                "rows hidden by the focus filter must not re-enter the selection when unfocused")
    }

    @Test func controlTreeReportsFocusedWorkspace() {
        let store = makeStore()
        let ws2 = store.addWorkspace(name: "second")
        // no focus: no workspace node reports focused.
        #expect(store.controlTree().workspaces.allSatisfy { $0.focused == nil })
        // focus the second workspace: ONLY its node reports focused == true (distinct from active).
        store.setFocusedWorkspace(ws2.id)
        let nodes = store.controlTree().workspaces
        #expect(nodes.first { $0.id == ws2.id.uuidString }?.focused == true)
        #expect(nodes.filter { $0.focused == true }.count == 1)
        // clearing focus: no node reports focused again.
        store.setFocusedWorkspace(nil)
        #expect(store.controlTree().workspaces.allSatisfy { $0.focused == nil })
    }
}
