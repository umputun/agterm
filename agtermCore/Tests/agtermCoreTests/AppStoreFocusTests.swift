import Foundation
import Testing
@testable import agtermCore

// the sidebar focus filter: the focus mutators, the `visibleWorkspaces` projection they drive, the
// sidebar-selection prune that follows it, and the `controlTree` focus read-back.
@MainActor
struct AppStoreFocusTests {
    @Test func setFocusedWorkspaceSetsAndClears() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        #expect(store.focusedWorkspaceIDs.isEmpty && !store.focusEnabled)
        store.setFocusedWorkspace(work.id)
        #expect(store.focusedWorkspaceIDs == [work.id] && store.focusEnabled)
        store.clearFocus()
        #expect(store.focusedWorkspaceIDs.isEmpty && !store.focusEnabled)
    }

    @Test func clearFocusEmptiesAWholeMultiMemberSet() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let side = store.addWorkspace(name: "side")
        store.setFocusMembership(work.id, member: true)
        store.setFocusMembership(personal.id, member: true)
        store.setFocusEnabled(true)

        store.clearFocus()

        #expect(store.focusedWorkspaceIDs.isEmpty && !store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id) == [work.id, personal.id, side.id])
    }

    @Test func markingAnIDThatIsNotAWorkspaceIsACleanNoOp() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let phantom = UUID()

        store.setFocusMembership(phantom, member: true)
        #expect(store.focusedWorkspaceIDs.isEmpty)
        store.setFocusEnabled(true)
        #expect(!store.focusEnabled)

        store.setFocusedWorkspace(phantom)
        #expect(store.focusedWorkspaceIDs.isEmpty && !store.focusEnabled)

        store.setFocusMembership(work.id, member: true)
        store.focusedWorkspaceIDs.insert(phantom)
        store.setFocusMembership(phantom, member: false)
        #expect(store.focusedWorkspaceIDs == [work.id])
    }

    @Test func isSoleFocusIsTrueOnlyForTheOneMarkedWorkspaceWithTheFilterOn() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")

        store.setFocusMembership(work.id, member: true)
        #expect(!store.isSoleFocus(work.id))
        store.setFocusEnabled(true)
        #expect(store.isSoleFocus(work.id))
        #expect(!store.isSoleFocus(personal.id))
        store.setFocusMembership(personal.id, member: true)
        #expect(!store.isSoleFocus(work.id))
    }

    @Test func toggleFocusedWorkspaceNarrowsAMultiMemberSetThenClears() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        store.setFocusMembership(work.id, member: true)
        store.setFocusMembership(personal.id, member: true)
        store.setFocusEnabled(true)

        store.toggleFocusedWorkspace(personal.id)
        #expect(store.focusedWorkspaceIDs == [personal.id] && store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id) == [personal.id])

        store.toggleFocusedWorkspace(personal.id)
        #expect(store.focusedWorkspaceIDs.isEmpty && !store.focusEnabled)

        store.toggleFocusedWorkspace(work.id)
        #expect(store.focusedWorkspaceIDs == [work.id] && store.focusEnabled)
        store.setFocusEnabled(false)
        store.toggleFocusedWorkspace(work.id)
        #expect(store.focusedWorkspaceIDs == [work.id] && store.focusEnabled)
    }

    @Test func currentWorkspaceFocusHelpersFollowTheSelection() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        _ = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        #expect(store.currentWorkspaceID == work.id)
        #expect(!store.isCurrentWorkspaceSoleFocus && !store.isCurrentWorkspaceFocusMember)

        store.setFocusMembership(work.id, member: true)
        #expect(store.isCurrentWorkspaceFocusMember)
        #expect(!store.isCurrentWorkspaceSoleFocus)
        store.setFocusEnabled(true)
        #expect(store.isCurrentWorkspaceSoleFocus)

        _ = try #require(store.addSession(toWorkspace: personal.id, cwd: "/b"))
        #expect(store.currentWorkspaceID == personal.id)
        #expect(!store.isCurrentWorkspaceSoleFocus && !store.isCurrentWorkspaceFocusMember)
    }

    @Test func setFocusedWorkspaceReplacesTheWholeSet() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        store.setFocusMembership(work.id, member: true)
        store.setFocusMembership(personal.id, member: true)
        #expect(store.focusedWorkspaceIDs == [work.id, personal.id])
        store.setFocusedWorkspace(personal.id)
        #expect(store.focusedWorkspaceIDs == [personal.id] && store.focusEnabled)
    }

    @Test func setFocusMembershipAddsAndRemoves() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        store.setFocusMembership(work.id, member: true)
        #expect(store.focusedWorkspaceIDs == [work.id] && !store.focusEnabled)
        store.setFocusMembership(personal.id, member: true)
        #expect(store.focusedWorkspaceIDs == [work.id, personal.id] && !store.focusEnabled)
        store.setFocusEnabled(true)
        store.setFocusMembership(work.id, member: false)
        #expect(store.focusedWorkspaceIDs == [personal.id] && store.focusEnabled)
    }

    @Test func addingToTheSetNeverTurnsTheFilterOn() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        store.setFocusMembership(work.id, member: true)
        #expect(store.focusedWorkspaceIDs == [work.id] && !store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id) == [work.id, personal.id])
        store.setFocusEnabled(true)
        store.setFocusMembership(personal.id, member: true)
        #expect(store.focusedWorkspaceIDs == [work.id, personal.id] && store.focusEnabled)
    }

    @Test func removingTheLastMemberDisablesTheFilter() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        store.setFocusMembership(work.id, member: true)
        store.setFocusEnabled(true)
        store.setFocusMembership(work.id, member: false)
        #expect(store.focusedWorkspaceIDs.isEmpty && !store.focusEnabled)
    }

    @Test func setFocusMembershipOnADisabledSetKeepsItDisabledWhenRemoving() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        store.setFocusMembership(work.id, member: true)
        store.setFocusMembership(personal.id, member: true)
        store.setFocusEnabled(true)
        store.setFocusEnabled(false)
        store.setFocusMembership(work.id, member: false)
        #expect(store.focusedWorkspaceIDs == [personal.id] && !store.focusEnabled)
    }

    @Test func setFocusEnabledRoundTripsWithoutLosingTheSet() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        store.setFocusMembership(work.id, member: true)
        store.setFocusMembership(personal.id, member: true)
        store.setFocusEnabled(true)
        store.setFocusEnabled(false)
        #expect(store.focusedWorkspaceIDs == [work.id, personal.id] && !store.focusEnabled)
        store.setFocusEnabled(true)
        #expect(store.focusedWorkspaceIDs == [work.id, personal.id] && store.focusEnabled)
    }

    @Test func setFocusEnabledRefusesAnEmptySet() {
        let store = makeStore()
        _ = store.addWorkspace(name: "work")
        store.setFocusEnabled(true)
        #expect(!store.focusEnabled)
    }

    @Test func focusSettersAreNoOpWritesWhenUnchanged() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let persistence = PersistenceStore(directory: dir)
        let store = AppStore(persistence: persistence)
        let ws = store.addWorkspace(name: "work")
        store.setFocusedWorkspace(ws.id)
        let file = dir.appendingPathComponent("workspaces.json")
        try? FileManager.default.removeItem(at: file)
        store.setFocusedWorkspace(ws.id)
        store.setFocusMembership(ws.id, member: true)
        store.setFocusEnabled(true)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(store.focusedWorkspaceIDs == [ws.id] && store.focusEnabled)
    }

    @Test func setFocusEnabledOnAnEmptySetIsANoOpWrite() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let persistence = PersistenceStore(directory: dir)
        let store = AppStore(persistence: persistence)
        _ = store.addWorkspace(name: "work")
        let file = dir.appendingPathComponent("workspaces.json")
        try? FileManager.default.removeItem(at: file)
        store.setFocusEnabled(true)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func visibleWorkspacesReturnsAllWhenTheFilterIsOff() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        #expect(store.visibleWorkspaces.map(\.id) == [work.id, personal.id])
        store.setFocusMembership(work.id, member: true)
        store.setFocusEnabled(true)
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
        store.setFocusMembership(three.id, member: true)
        store.setFocusMembership(one.id, member: true)
        store.setFocusEnabled(true)
        #expect(store.visibleWorkspaces.map(\.id) == [one.id, three.id])
    }

    @Test func visibleWorkspacesKeepsSurvivorsForAPartiallyStaleSet() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        _ = store.addWorkspace(name: "personal")
        store.focusedWorkspaceIDs = [work.id, UUID()]
        store.focusEnabled = true
        #expect(store.visibleWorkspaces.map(\.id) == [work.id])
    }

    @Test func visibleWorkspacesFallsBackToAllForAnAllStaleSet() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        store.focusedWorkspaceIDs = [UUID()]
        store.focusEnabled = true
        #expect(store.visibleWorkspaces.map(\.id) == [work.id, personal.id])
    }

    @Test func removingAMemberPrunesItAndKeepsTheRestFiltered() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let doomed = store.addWorkspace(name: "doomed")
        _ = store.addWorkspace(name: "other")
        store.setFocusMembership(work.id, member: true)
        store.setFocusMembership(doomed.id, member: true)
        store.setFocusEnabled(true)
        store.removeWorkspace(doomed.id)
        #expect(store.focusedWorkspaceIDs == [work.id] && store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id) == [work.id])
    }

    @Test func removingTheLastMemberWorkspaceDisablesTheFilter() {
        let store = makeStore()
        _ = store.addWorkspace(name: "other")
        let doomed = store.addWorkspace(name: "doomed")
        store.setFocusMembership(doomed.id, member: true)
        store.setFocusEnabled(true)
        store.removeWorkspace(doomed.id)
        #expect(store.focusedWorkspaceIDs.isEmpty && !store.focusEnabled)
    }

    @Test func removingANonMemberWorkspaceLeavesTheFilterUntouched() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let doomed = store.addWorkspace(name: "doomed")
        store.setFocusMembership(work.id, member: true)
        store.setFocusMembership(personal.id, member: true)
        store.setFocusEnabled(true)
        store.removeWorkspace(doomed.id)
        #expect(store.focusedWorkspaceIDs == [work.id, personal.id] && store.focusEnabled)
    }

    @Test func undoingASoftRemovedMemberRestoresItsMembership() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let doomed = store.addWorkspace(name: "doomed")
        _ = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        store.setFocusMembership(work.id, member: true)
        store.setFocusMembership(doomed.id, member: true)
        store.setFocusEnabled(true)

        #expect(store.softRemoveWorkspace(doomed.id))
        #expect(store.focusedWorkspaceIDs == [work.id] && store.focusEnabled)

        #expect(store.undoPendingClose())
        #expect(store.focusedWorkspaceIDs == [work.id, doomed.id], "an undone member must be marked again")
        #expect(store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id) == [work.id, doomed.id])
    }

    @Test func undoingTheLastMemberRestoresTheSetWithoutReApplyingTheFilter() throws {
        let store = makeStore()
        let other = store.addWorkspace(name: "other")
        let doomed = store.addWorkspace(name: "doomed")
        let spare = store.addWorkspace(name: "spare")
        store.setFocusMembership(doomed.id, member: true)
        store.setFocusEnabled(true)

        #expect(store.softRemoveWorkspace(doomed.id))
        #expect(store.focusedWorkspaceIDs.isEmpty && !store.focusEnabled)

        #expect(store.undoPendingClose())
        #expect(store.focusedWorkspaceIDs == [doomed.id], "an undone member must be marked again")
        #expect(!store.focusEnabled, "restoring a member must never switch the filter on")
        #expect(store.visibleWorkspaces.map(\.id) == [other.id, doomed.id, spare.id])
        store.setFocusEnabled(true)
        #expect(store.visibleWorkspaces.map(\.id) == [doomed.id])
    }

    @Test func suspendingTheFilterDuringTheGraceSurvivesTheUndo() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let doomed = store.addWorkspace(name: "doomed")
        _ = store.addWorkspace(name: "spare")
        store.setFocusMembership(work.id, member: true)
        store.setFocusMembership(doomed.id, member: true)
        store.setFocusEnabled(true)

        #expect(store.softRemoveWorkspace(doomed.id))
        store.setFocusEnabled(false)

        #expect(store.undoPendingClose())
        #expect(store.focusedWorkspaceIDs == [work.id, doomed.id], "the membership still comes back")
        #expect(!store.focusEnabled, "the undo must not override the toggle the user just made")
    }

    @Test func reClosingAWorkspaceRebuiltByASessionUndoKeepsItsMembership() throws {
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        let keep = store.addWorkspace(name: "keep")
        let work = store.addWorkspace(name: "work")
        _ = try #require(store.addSession(toWorkspace: keep.id, cwd: "/a"))
        let stray = try #require(store.addSession(toWorkspace: work.id, cwd: "/b", select: false))
        store.setFocusMembership(keep.id, member: true)
        store.setFocusMembership(work.id, member: true)
        store.setFocusEnabled(true)

        #expect(store.softCloseSession(stray.id, grace: 60))
        let sessionCloseID = try #require(store.pendingCloseSummary?.id)
        #expect(store.softRemoveWorkspace(work.id, grace: 60))
        #expect(store.focusedWorkspaceIDs == [keep.id])

        #expect(store.undoPendingClose(sessionCloseID))
        #expect(store.workspaces.contains { $0.id == work.id })
        #expect(!store.focusedWorkspaceIDs.contains(work.id) && !store.focusEnabled)

        #expect(store.softRemoveWorkspace(work.id, grace: 60))
        let item = try #require(recentClosed.load().first { $0.workspace?.snapshot.id == work.id })
        #expect(item.workspace?.focusMember == true, "the overwriting Open Recent entry must keep the membership")

        #expect(store.undoPendingClose())
        #expect(store.focusedWorkspaceIDs == [keep.id, work.id],
                "the absorbed record's membership must survive the re-close")
    }

    @Test func undoingANonMemberWorkspaceDoesNotMarkIt() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let doomed = store.addWorkspace(name: "doomed")
        _ = store.addWorkspace(name: "spare")
        store.setFocusMembership(work.id, member: true)
        store.setFocusEnabled(true)

        #expect(store.softRemoveWorkspace(doomed.id))
        #expect(store.undoPendingClose())
        #expect(store.focusedWorkspaceIDs == [work.id] && store.focusEnabled)
    }

    @Test func reopeningARecentClosedMemberRestoresItsMembership() throws {
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        let work = store.addWorkspace(name: "work")
        let doomed = store.addWorkspace(name: "doomed")
        _ = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        store.setFocusMembership(work.id, member: true)
        store.setFocusMembership(doomed.id, member: true)
        store.setFocusEnabled(true)

        #expect(store.softRemoveWorkspace(doomed.id, grace: 60))
        store.finalizePendingClose(try #require(store.pendingCloseSummary?.id))
        #expect(store.focusedWorkspaceIDs == [work.id] && store.focusEnabled)

        let item = try #require(recentClosed.load().first { $0.workspace?.snapshot.id == doomed.id })
        #expect(store.restoreRecentClosed(item))
        #expect(store.focusedWorkspaceIDs == [work.id, doomed.id], "a reopened member must be marked again")
        #expect(store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id) == [work.id, doomed.id])
    }

    @Test func reopeningARecentClosedMemberWithSessionsKeepsTheFilterOn() throws {
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        let work = store.addWorkspace(name: "work")
        let doomed = store.addWorkspace(name: "doomed")
        _ = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let stray = try #require(store.addSession(toWorkspace: doomed.id, cwd: "/b", select: false))
        store.setFocusMembership(work.id, member: true)
        store.setFocusMembership(doomed.id, member: true)
        store.setFocusEnabled(true)

        #expect(store.softRemoveWorkspace(doomed.id, grace: 60))
        store.finalizePendingClose(try #require(store.pendingCloseSummary?.id))

        let item = try #require(recentClosed.load().first { $0.workspace?.snapshot.id == doomed.id })
        #expect(store.restoreRecentClosed(item))
        #expect(store.focusedWorkspaceIDs == [work.id, doomed.id] && store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id) == [work.id, doomed.id])
        #expect(store.selectedSessionID == stray.id)
    }

    @Test func reopeningTheLastRecentClosedMemberMarksItWithoutReApplyingTheFilter() throws {
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        let other = store.addWorkspace(name: "other")
        let doomed = store.addWorkspace(name: "doomed")
        let spare = store.addWorkspace(name: "spare")
        store.setFocusMembership(doomed.id, member: true)
        store.setFocusEnabled(true)

        #expect(store.softRemoveWorkspace(doomed.id, grace: 60))
        store.finalizePendingClose(try #require(store.pendingCloseSummary?.id))
        #expect(store.focusedWorkspaceIDs.isEmpty && !store.focusEnabled)

        let item = try #require(recentClosed.load().first { $0.workspace?.snapshot.id == doomed.id })
        #expect(store.restoreRecentClosed(item))
        #expect(store.focusedWorkspaceIDs == [doomed.id], "a reopened member must be marked again")
        #expect(!store.focusEnabled, "marking on reopen must never switch the filter on")
        #expect(store.visibleWorkspaces.map(\.id) == [other.id, spare.id, doomed.id])
    }

    @Test func reopeningARecentClosedMemberWithTheFilterOffLeavesItOff() throws {
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        let work = store.addWorkspace(name: "work")
        let doomed = store.addWorkspace(name: "doomed")
        let spare = store.addWorkspace(name: "spare")
        store.setFocusMembership(work.id, member: true)
        store.setFocusMembership(doomed.id, member: true)
        store.setFocusEnabled(true)

        #expect(store.softRemoveWorkspace(doomed.id, grace: 60))
        store.finalizePendingClose(try #require(store.pendingCloseSummary?.id))
        store.setFocusEnabled(false)

        let item = try #require(recentClosed.load().first { $0.workspace?.snapshot.id == doomed.id })
        #expect(store.restoreRecentClosed(item))
        #expect(store.focusedWorkspaceIDs == [work.id, doomed.id])
        #expect(!store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id) == [work.id, spare.id, doomed.id])
    }

    @Test func reopeningARecordFromAFilteringWindowCannotEnableAnotherWindowsFilter() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let recentClosed = RecentClosedStore(directory: dir)
        let windowA = AppStore(persistence: PersistenceStore(directory: dir.appendingPathComponent("a")),
                               recentClosedStore: recentClosed)
        let windowB = AppStore(persistence: PersistenceStore(directory: dir.appendingPathComponent("b")),
                               recentClosedStore: recentClosed)

        let shared = windowA.addWorkspace(name: "shared")
        _ = windowA.addWorkspace(name: "keeper")
        windowA.setFocusedWorkspace(shared.id)
        #expect(windowA.focusEnabled)
        windowA.removeWorkspace(shared.id)

        let curated = windowB.addWorkspace(name: "curated")
        let extra = windowB.addWorkspace(name: "extra")
        windowB.setFocusMembership(curated.id, member: true)

        let item = try #require(recentClosed.load().first { $0.workspace?.snapshot.id == shared.id })
        #expect(windowB.restoreRecentClosed(item))
        #expect(!windowB.focusEnabled, "a record from a filtering window must not apply B's filter")
        #expect(windowB.focusedWorkspaceIDs == [curated.id, shared.id])
        #expect(windowB.visibleWorkspaces.map(\.id) == [curated.id, extra.id, shared.id])
    }

    @Test func reopeningARecentClosedNonMemberDoesNotMarkIt() throws {
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        let work = store.addWorkspace(name: "work")
        let doomed = store.addWorkspace(name: "doomed")
        _ = store.addWorkspace(name: "spare")
        store.setFocusMembership(work.id, member: true)
        store.setFocusEnabled(true)

        #expect(store.softRemoveWorkspace(doomed.id, grace: 60))
        store.finalizePendingClose(try #require(store.pendingCloseSummary?.id))

        let item = try #require(recentClosed.load().first { $0.workspace?.snapshot.id == doomed.id })
        #expect(store.restoreRecentClosed(item))
        #expect(store.focusedWorkspaceIDs == [work.id] && store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id) == [work.id])
    }

    @Test func hardRemovingAMemberRecordsItsMembershipForReopen() throws {
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        let work = store.addWorkspace(name: "work")
        let doomed = store.addWorkspace(name: "doomed")
        _ = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        store.setFocusMembership(work.id, member: true)
        store.setFocusMembership(doomed.id, member: true)
        store.setFocusEnabled(true)

        store.removeWorkspace(doomed.id)
        let item = try #require(recentClosed.load().first { $0.workspace?.snapshot.id == doomed.id })
        #expect(item.workspace?.focusMember == true)

        #expect(store.restoreRecentClosed(item))
        #expect(store.focusedWorkspaceIDs == [work.id, doomed.id])
        #expect(store.focusEnabled)
    }

    @Test func softRemovingAMemberPrunesItAndDisablesWhenTheSetEmpties() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let doomed = store.addWorkspace(name: "doomed")
        _ = store.addWorkspace(name: "spare")
        store.setFocusMembership(work.id, member: true)
        store.setFocusMembership(doomed.id, member: true)
        store.setFocusEnabled(true)
        #expect(store.softRemoveWorkspace(doomed.id))
        #expect(store.focusedWorkspaceIDs == [work.id] && store.focusEnabled)
        #expect(store.softRemoveWorkspace(work.id))
        #expect(store.focusedWorkspaceIDs.isEmpty && !store.focusEnabled)
    }

    @Test func selectingOutsideTheSetDisablesTheFilterButKeepsEveryMember() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let outside = store.addWorkspace(name: "outside")
        _ = store.addSession(toWorkspace: work.id, cwd: "/a")
        store.setFocusMembership(work.id, member: true)
        store.setFocusMembership(personal.id, member: true)
        store.setFocusEnabled(true)
        let stray = try #require(store.addSession(toWorkspace: outside.id, cwd: "/b", select: false))
        store.selectSession(stray.id)
        #expect(store.focusedWorkspaceIDs == [work.id, personal.id] && !store.focusEnabled)
        store.setFocusEnabled(true)
        #expect(store.visibleWorkspaces.map(\.id) == [work.id, personal.id])
    }

    @Test func applyingTheFilterMovesTheSelectionIntoTheVisibleSet() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let inSet = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let outside = try #require(store.addSession(toWorkspace: personal.id, cwd: "/b"))
        store.selectSession(inSet.id)
        store.selectSession(outside.id)
        store.setFocusMembership(work.id, member: true)
        #expect(store.selectedSessionID == outside.id)

        store.setFocusEnabled(true)
        #expect(store.selectedSessionID == inSet.id)
        #expect(store.focusedWorkspaceIDs == [work.id] && store.focusEnabled)
    }

    @Test func focusingAWorkspaceMovesTheSelectionIntoIt() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let target = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let outside = try #require(store.addSession(toWorkspace: personal.id, cwd: "/b"))
        store.selectSession(target.id)
        store.selectSession(outside.id)

        store.setFocusedWorkspace(work.id)
        #expect(store.selectedSessionID == target.id)
        #expect(store.focusedWorkspaceIDs == [work.id] && store.focusEnabled)
    }

    @Test func switchingToTheFlaggedViewMovesTheSelectionIntoIt() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let flagged = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let plain = try #require(store.addSession(toWorkspace: work.id, cwd: "/b"))
        store.setFlag(true, forSession: flagged.id)
        store.selectSession(plain.id)

        store.setSidebarMode(.flagged)
        #expect(store.selectedSessionID == flagged.id)
    }

    @Test func switchingToTheFlaggedViewNeverDisablesTheWorkspaceFilter() throws {
        let store = makeStore()
        let marked = store.addWorkspace(name: "marked")
        let other = store.addWorkspace(name: "other")
        let inSet = try #require(store.addSession(toWorkspace: marked.id, cwd: "/a"))
        let flaggedOutside = try #require(store.addSession(toWorkspace: other.id, cwd: "/b", select: false))
        store.setFlag(true, forSession: flaggedOutside.id)
        store.selectSession(inSet.id)
        store.setFocusedWorkspace(marked.id)

        store.setSidebarMode(.flagged)
        #expect(store.selectedSessionID == flaggedOutside.id)
        #expect(store.focusedWorkspaceIDs == [marked.id] && store.focusEnabled)

        store.setSidebarMode(.tree)
        #expect(store.selectedSessionID == inSet.id)
        #expect(store.focusedWorkspaceIDs == [marked.id] && store.focusEnabled)
    }

    @Test func unflaggingTheActiveSessionInFlaggedModeMovesTheSelection() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let survivor = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let active = try #require(store.addSession(toWorkspace: work.id, cwd: "/b"))
        store.setFlag(true, forSession: survivor.id)
        store.setFlag(true, forSession: active.id)
        store.selectSession(active.id)
        store.setSidebarMode(.flagged)
        #expect(store.selectedSessionID == active.id)

        store.setFlag(false, forSession: active.id)
        #expect(store.selectedSessionID == survivor.id)
    }

    @Test func batchUnflaggingTheActiveSessionInFlaggedModeMovesTheSelection() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let survivor = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let active = try #require(store.addSession(toWorkspace: work.id, cwd: "/b"))
        let alsoUnflagged = try #require(store.addSession(toWorkspace: work.id, cwd: "/c", select: false))
        store.setFlag(true, forSessions: [survivor.id, active.id, alsoUnflagged.id])
        store.selectSession(active.id)
        store.setSidebarMode(.flagged)

        store.setFlag(false, forSessions: [active.id, alsoUnflagged.id])
        #expect(store.flaggedSessions.map(\.id) == [survivor.id])
        #expect(store.selectedSessionID == survivor.id)
    }

    @Test func unmarkingTheActiveSessionsWorkspaceMovesTheSelectionToASurvivingMember() throws {
        let store = makeStore()
        let staying = store.addWorkspace(name: "staying")
        let leaving = store.addWorkspace(name: "leaving")
        let survivor = try #require(store.addSession(toWorkspace: staying.id, cwd: "/a"))
        let active = try #require(store.addSession(toWorkspace: leaving.id, cwd: "/b"))
        store.setFocusMembership(staying.id, member: true)
        store.setFocusMembership(leaving.id, member: true)
        store.setFocusEnabled(true)
        store.selectSession(active.id)
        #expect(store.selectedSessionID == active.id)

        store.setFocusMembership(leaving.id, member: false)
        #expect(store.selectedSessionID == survivor.id)
        #expect(store.focusedWorkspaceIDs == [staying.id] && store.focusEnabled)
    }

    @Test func flaggingASessionWhileTheFlaggedViewIsEmptyMovesTheSelectionIntoIt() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let active = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let other = try #require(store.addSession(toWorkspace: work.id, cwd: "/b", select: false))
        store.selectSession(active.id)
        store.setSidebarMode(.flagged)
        #expect(store.selectedSessionID == active.id)

        store.setFlag(true, forSession: other.id)
        #expect(store.selectedSessionID == other.id)
    }

    @Test func markingAPopulatedWorkspaceWhileTheFilterShowsAnEmptyOneMovesTheSelection() throws {
        let store = makeStore()
        let home = store.addWorkspace(name: "home")
        let empty = store.addWorkspace(name: "empty")
        let populated = store.addWorkspace(name: "populated")
        let active = try #require(store.addSession(toWorkspace: home.id, cwd: "/a"))
        let target = try #require(store.addSession(toWorkspace: populated.id, cwd: "/b", select: false))
        store.selectSession(target.id)
        store.selectSession(active.id)
        store.setFocusedWorkspace(empty.id)
        #expect(store.selectedSessionID == active.id)

        store.setFocusMembership(populated.id, member: true)
        #expect(store.selectedSessionID == target.id)
    }

    @Test func aBackgroundInsertionIntoAnEmptyVisibleSetDoesNotRepairIt() throws {
        let store = makeStore()
        let home = store.addWorkspace(name: "home")
        let empty = store.addWorkspace(name: "empty")
        let active = try #require(store.addSession(toWorkspace: home.id, cwd: "/a"))
        store.selectSession(active.id)
        store.setFocusedWorkspace(empty.id)
        #expect(store.selectedSessionID == active.id)

        _ = try #require(store.addSession(toWorkspace: empty.id, cwd: "/b", select: false))
        #expect(store.navigableSessions.count == 1)
        #expect(store.selectedSessionID == active.id)
    }

    @Test func clearingEveryFlagInFlaggedModeLeavesTheSelectionAlone() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let active = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        store.setFlag(true, forSession: active.id)
        store.selectSession(active.id)
        store.setSidebarMode(.flagged)

        store.clearFlags()
        #expect(store.flaggedSessions.isEmpty)
        #expect(store.selectedSessionID == active.id)
    }

    @Test func unflaggingInTreeModeDoesNotMoveTheSelection() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        _ = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let active = try #require(store.addSession(toWorkspace: work.id, cwd: "/b"))
        store.setFlag(true, forSession: active.id)
        store.selectSession(active.id)

        store.setFlag(false, forSession: active.id)
        #expect(store.selectedSessionID == active.id)
    }

    @Test func theNarrowingReselectPrefersTheMostRecentVisibleSession() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let first = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let recent = try #require(store.addSession(toWorkspace: work.id, cwd: "/b", select: false))
        let outside = try #require(store.addSession(toWorkspace: personal.id, cwd: "/c"))
        store.selectSession(first.id)
        store.selectSession(recent.id)
        store.selectSession(outside.id)

        store.setFocusedWorkspace(work.id)
        #expect(store.selectedSessionID == recent.id)
    }

    @Test func theNarrowingReselectFallsBackToTheFirstVisibleSessionWithoutRecency() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let first = try #require(store.addSession(toWorkspace: work.id, cwd: "/a", select: false))
        _ = try #require(store.addSession(toWorkspace: work.id, cwd: "/b", select: false))
        let outside = try #require(store.addSession(toWorkspace: personal.id, cwd: "/c"))
        store.selectSession(outside.id)

        store.setFocusedWorkspace(work.id)
        #expect(store.selectedSessionID == first.id)
    }

    @Test func aNarrowingWithNoVisibleSessionLeavesTheSelectionAlone() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let empty = store.addWorkspace(name: "empty")
        let active = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        store.selectSession(active.id)

        store.setFocusedWorkspace(empty.id)
        #expect(store.selectedSessionID == active.id)
    }

    @Test func selectingInsideTheSetChangesNothing() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        _ = store.addSession(toWorkspace: work.id, cwd: "/a")
        let inSet = try #require(store.addSession(toWorkspace: personal.id, cwd: "/b", select: false))
        store.setFocusMembership(work.id, member: true)
        store.setFocusMembership(personal.id, member: true)
        store.setFocusEnabled(true)
        store.selectSession(inSet.id)
        #expect(store.focusedWorkspaceIDs == [work.id, personal.id] && store.focusEnabled)
    }

    @Test func addWorkspaceJoinsTheSetOnlyWhileTheFilterIsOn() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        store.setFocusMembership(work.id, member: true)
        store.setFocusEnabled(false)
        _ = store.addWorkspace(name: "quiet")
        #expect(store.focusedWorkspaceIDs == [work.id] && !store.focusEnabled)
        store.setFocusEnabled(true)
        let fresh = store.addWorkspace(name: "fresh")
        #expect(store.focusedWorkspaceIDs == [work.id, fresh.id] && store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id) == [work.id, fresh.id])
    }

    @Test func addWorkspaceWithoutRevealDoesNotWidenTheSet() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        store.setFocusMembership(work.id, member: true)
        store.setFocusEnabled(true)
        _ = store.addWorkspace(name: "background", revealNewWorkspace: false)
        #expect(store.focusedWorkspaceIDs == [work.id] && store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id) == [work.id])
    }

    @Test func restorePrunesAnAllStaleSetToEmptyAndDisabled() {
        let store = makeStore()
        let survivor = WorkspaceSnapshot(id: UUID(), name: "survivor", sessions: [])
        store.restore(from: Snapshot(workspaces: [survivor], focusedWorkspaceIDs: [UUID(), UUID()],
                                     focusEnabled: true))
        #expect(store.focusedWorkspaceIDs.isEmpty && !store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id) == [survivor.id])
    }

    @Test func restoreMovesASelectionThatLandsOutsideTheRestoredSet() {
        let store = makeStore()
        let markedSession = SessionSnapshot(id: UUID(), customName: nil, cwd: "/marked")
        let straySession = SessionSnapshot(id: UUID(), customName: nil, cwd: "/stray")
        let marked = WorkspaceSnapshot(id: UUID(), name: "marked", sessions: [markedSession])
        let unmarked = WorkspaceSnapshot(id: UUID(), name: "unmarked", sessions: [straySession])
        store.restore(from: Snapshot(selectedSessionID: straySession.id, workspaces: [marked, unmarked],
                                     focusedWorkspaceIDs: [marked.id], focusEnabled: true))
        #expect(store.selectedSessionID == markedSession.id)
        #expect(store.focusedWorkspaceIDs == [marked.id] && store.focusEnabled)
    }

    @Test func restoreReselectsByRecencyNotByTreeOrder() {
        let store = makeStore()
        let firstInTree = SessionSnapshot(id: UUID(), customName: nil, cwd: "/first")
        let mostRecent = SessionSnapshot(id: UUID(), customName: nil, cwd: "/recent")
        let straySession = SessionSnapshot(id: UUID(), customName: nil, cwd: "/stray")
        let marked = WorkspaceSnapshot(id: UUID(), name: "marked", sessions: [firstInTree, mostRecent])
        let unmarked = WorkspaceSnapshot(id: UUID(), name: "unmarked", sessions: [straySession])
        store.restore(from: Snapshot(selectedSessionID: straySession.id, workspaces: [marked, unmarked],
                                     focusedWorkspaceIDs: [marked.id], focusEnabled: true,
                                     sessionRecency: [mostRecent.id, firstInTree.id]))
        #expect(store.selectedSessionID == mostRecent.id)
    }

    @Test func restoreKeepsTheSurvivorsOfAPartiallyStaleSet() {
        let store = makeStore()
        let kept = WorkspaceSnapshot(id: UUID(), name: "kept", sessions: [])
        let other = WorkspaceSnapshot(id: UUID(), name: "other", sessions: [])
        store.restore(from: Snapshot(workspaces: [kept, other], focusedWorkspaceIDs: [kept.id, UUID()],
                                     focusEnabled: true))
        #expect(store.focusedWorkspaceIDs == [kept.id] && store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id) == [kept.id])
    }

    @Test func restoreKeepsADisabledSetWithoutEnablingIt() {
        let store = makeStore()
        let kept = WorkspaceSnapshot(id: UUID(), name: "kept", sessions: [])
        let other = WorkspaceSnapshot(id: UUID(), name: "other", sessions: [])
        store.restore(from: Snapshot(workspaces: [kept, other], focusedWorkspaceIDs: [kept.id]))
        #expect(store.focusedWorkspaceIDs == [kept.id] && !store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id) == [kept.id, other.id])
    }

    @Test func restoreClearsAFocusSetLeftOverFromAPreviousTree() {
        let store = makeStore()
        let stale = store.addWorkspace(name: "stale")
        store.setFocusMembership(stale.id, member: true)
        let fresh = WorkspaceSnapshot(id: UUID(), name: "fresh", sessions: [])
        store.restore(from: Snapshot(workspaces: [fresh]))
        #expect(store.focusedWorkspaceIDs.isEmpty && !store.focusEnabled)
    }

    @Test func dropFallbackIsNilWithNothingMarked() {
        let store = makeStore()
        _ = store.addWorkspace(name: "work")
        #expect(store.soleFocusedWorkspaceID == nil)
    }

    @Test func dropFallbackIsTheSoleMemberWhileTheFilterIsOn() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        _ = store.addWorkspace(name: "personal")
        store.setFocusedWorkspace(work.id)
        #expect(store.soleFocusedWorkspaceID == work.id)
    }

    @Test func dropFallbackIsNilWhenTheFilterIsOff() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        _ = store.addWorkspace(name: "personal")
        store.setFocusMembership(work.id, member: true)
        store.setFocusEnabled(false)
        #expect(store.focusedWorkspaceIDs == [work.id])
        #expect(store.soleFocusedWorkspaceID == nil)
    }

    @Test func dropFallbackIsNilWithTwoMembersMarked() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        store.setFocusMembership(work.id, member: true)
        store.setFocusMembership(personal.id, member: true)
        store.setFocusEnabled(true)
        #expect(store.soleFocusedWorkspaceID == nil)
    }

    @Test func dropFallbackFeedsTheDirectoryDropResolverAcrossEverySetShape() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let current = try #require(store.currentWorkspaceID)
        func emptySpaceDrop() -> UUID? {
            SidebarDrop.resolveDirectoryWorkspace(sidebarMode: store.sidebarMode, rowWorkspaceID: nil,
                                                  fallbackWorkspaceID: store.soleFocusedWorkspaceID,
                                                  currentWorkspaceID: store.currentWorkspaceID)
        }

        #expect(emptySpaceDrop() == current)
        store.setFocusMembership(work.id, member: true)
        #expect(emptySpaceDrop() == current)
        store.setFocusEnabled(true)
        #expect(emptySpaceDrop() == work.id)
        store.setFocusMembership(personal.id, member: true)
        #expect(emptySpaceDrop() == current)

        #expect(SidebarDrop.resolveDirectoryWorkspace(sidebarMode: .tree, rowWorkspaceID: personal.id,
                                                      fallbackWorkspaceID: work.id,
                                                      currentWorkspaceID: current) == personal.id)
        store.setSidebarMode(.flagged)
        #expect(emptySpaceDrop() == nil)
    }

    @Test func workspaceFocusPrunesRowsOutsideFocusedWorkspace() throws {
        let store = makeStore()
        let ws1 = store.addWorkspace(name: "one")
        let ws2 = store.addWorkspace(name: "two")
        let a = try #require(store.addSession(toWorkspace: ws1.id, cwd: "/a"))
        let b = try #require(store.addSession(toWorkspace: ws2.id, cwd: "/b"))
        store.setSidebarSelection([a.id, b.id])

        store.setFocusedWorkspace(ws2.id)

        #expect(store.sidebarSelectionIDs == [b.id])
        store.clearFocus()
        #expect(store.sidebarSelectionIDs == [b.id],
                "rows hidden by the focus filter must not re-enter the selection when unfocused")
    }

    @Test func controlTreeReportsFocusedWorkspace() {
        let store = makeStore()
        let ws2 = store.addWorkspace(name: "second")
        #expect(store.controlTree().workspaces.allSatisfy { $0.focused == nil })
        store.setFocusedWorkspace(ws2.id)
        let nodes = store.controlTree().workspaces
        #expect(nodes.first { $0.id == ws2.id.uuidString }?.focused == true)
        #expect(nodes.filter { $0.focused == true }.count == 1)
        store.clearFocus()
        #expect(store.controlTree().workspaces.allSatisfy { $0.focused == nil })
    }

    @Test func controlTreeReportsEveryMemberAsFocused() {
        let store = makeStore()
        let one = store.addWorkspace(name: "one")
        _ = store.addWorkspace(name: "two")
        let three = store.addWorkspace(name: "three")
        store.setFocusMembership(one.id, member: true)
        store.setFocusMembership(three.id, member: true)

        let nodes = store.controlTree().workspaces
        #expect(nodes.filter { $0.focused == true }.map(\.id).sorted() == [one.id, three.id].map(\.uuidString).sorted())
        #expect(nodes.first { $0.id != one.id.uuidString && $0.id != three.id.uuidString }?.focused == nil)
    }

    @Test func controlTreeReportsMembershipIndependentlyOfTheFilterFlag() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        _ = store.addWorkspace(name: "personal")
        store.setFocusMembership(work.id, member: true)
        store.setFocusEnabled(false)

        let tree = store.controlTree()
        #expect(tree.workspaceFilter == false)
        #expect(tree.workspaces.first { $0.id == work.id.uuidString }?.focused == true)
    }

    @Test func controlTreeReportsWorkspaceFilterInBothStates() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        #expect(store.controlTree().workspaceFilter == false)
        store.setFocusMembership(work.id, member: true)
        #expect(store.controlTree().workspaceFilter == false)
        store.setFocusEnabled(true)
        #expect(store.controlTree().workspaceFilter == true)
        store.setFocusEnabled(false)
        #expect(store.controlTree().workspaceFilter == false)
    }

    @Test func workspaceFilterOnAnEmptySetLeavesTheFilterOffThroughTheControlPath() async {
        let store = makeStore()
        _ = store.addWorkspace(name: "work")
        let actions = MockControlActions()
        actions.focusStore = store
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .workspaceFilter, args: ControlArgs(mode: "on")))

        #expect(response?.ok == true)
        #expect(actions.calls == [.workspaceFilter(window: nil, .on)])
        #expect(!store.focusEnabled)
        let tree = store.controlTree()
        #expect(tree.workspaceFilter == false)
        #expect(tree.workspaces.allSatisfy { $0.focused == nil })
    }

    @Test func workspaceFocusModesDriveTheStoreThroughTheControlPath() async throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let actions = MockControlActions()
        actions.focusStore = store
        let dispatcher = ControlDispatcher(actions: actions)
        func focus(_ id: UUID, _ mode: String?) async -> ControlResponse? {
            await dispatcher.dispatch(ControlRequest(cmd: .workspaceFocus, target: id.uuidString,
                                                     args: mode.map { ControlArgs(mode: $0) }))
        }

        #expect(await focus(work.id, "add")?.ok == true)
        #expect(await focus(personal.id, "add")?.ok == true)
        #expect(store.focusedWorkspaceIDs == [work.id, personal.id] && !store.focusEnabled)

        #expect(await focus(work.id, nil)?.ok == true) // an omitted mode is `toggle`
        #expect(store.focusedWorkspaceIDs == [work.id] && store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id) == [work.id])

        #expect(await focus(work.id, "toggle")?.ok == true)
        #expect(store.focusedWorkspaceIDs.isEmpty && !store.focusEnabled)

        #expect(await focus(personal.id, "on")?.ok == true)
        #expect(store.focusedWorkspaceIDs == [personal.id] && store.focusEnabled)
        #expect(await focus(personal.id, "off")?.ok == true)
        #expect(store.focusedWorkspaceIDs.isEmpty && !store.focusEnabled)
        #expect(actions.calls.count == 6)
        #expect(actions.unresolvedFocusTargets.isEmpty)
    }

    @Test func aTargetTheStoreDrivingDoubleCannotResolveIsRecordedRatherThanSwallowed() async {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        store.setFocusMembership(work.id, member: true)
        let actions = MockControlActions()
        actions.focusStore = store
        let dispatcher = ControlDispatcher(actions: actions)

        #expect(await dispatcher.dispatch(ControlRequest(cmd: .workspaceFocus, args: ControlArgs(mode: "off")))?.ok == true)
        #expect(actions.unresolvedFocusTargets == ["active"])
        #expect(store.focusedWorkspaceIDs == [work.id])
    }

    @Test func workspaceFilterTogglesTheFlagThroughTheControlPathOnceAWorkspaceIsMarked() async {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        store.setFocusMembership(work.id, member: true)
        let actions = MockControlActions()
        actions.focusStore = store
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .workspaceFilter, args: ControlArgs(mode: "on")))
        #expect(store.controlTree().workspaceFilter == true)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .workspaceFilter, args: ControlArgs(mode: "off")))
        #expect(store.controlTree().workspaceFilter == false)
        #expect(store.focusedWorkspaceIDs == [work.id])

        _ = await dispatcher.dispatch(ControlRequest(cmd: .workspaceFilter, args: ControlArgs(mode: "toggle")))
        #expect(store.controlTree().workspaceFilter == true)
    }
}
