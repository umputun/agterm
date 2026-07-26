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
        store.clearFocus()
        #expect(store.focusedWorkspaceIDs.isEmpty && !store.focusEnabled)
    }

    @Test func clearFocusEmptiesAWholeMultiMemberSet() {
        // what "Clear Focus" / Unfocus actually does in the set model: it empties the WHOLE set, not just
        // drops a member. The one-member case above cannot tell the two apart.
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let side = store.addWorkspace(name: "side")
        store.setFocusMembership(work.id, member: true)
        store.setFocusMembership(personal.id, member: true)
        store.setFocusEnabled(true)

        store.clearFocus()

        #expect(store.focusedWorkspaceIDs.isEmpty && !store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id) == [work.id, personal.id, side.id]) // the whole tree is back
    }

    @Test func markingAnIDThatIsNotAWorkspaceIsACleanNoOp() {
        // the `enabled + empty is unrepresentable` invariant has a twin: `enabled` must never hold over a
        // set of ids no workspace matches, or `workspaceFilter` reads true while nothing reports `focused`
        // (and the phantom would persist until the next restore pruned it). Both entry points guard, so a
        // caller that skipped its own existence check cannot create the state.
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let phantom = UUID()

        store.setFocusMembership(phantom, member: true)
        #expect(store.focusedWorkspaceIDs.isEmpty)
        store.setFocusEnabled(true)
        #expect(!store.focusEnabled) // nothing was marked, so there is still nothing to enable

        store.setFocusedWorkspace(phantom)
        #expect(store.focusedWorkspaceIDs.isEmpty && !store.focusEnabled)

        // un-marking is NOT gated on existence: a stale id already in the set must stay removable.
        store.setFocusMembership(work.id, member: true)
        store.focusedWorkspaceIDs.insert(phantom) // as a restore of a hand-edited file could leave it
        store.setFocusMembership(phantom, member: false)
        #expect(store.focusedWorkspaceIDs == [work.id])
    }

    @Test func isSoleFocusIsTrueOnlyForTheOneMarkedWorkspaceWithTheFilterOn() {
        // the semantic definition of "Unfocus": the row menu's label, the View-menu label and the
        // replace-toggle all read this one predicate, so its three false cases are what keep a label from
        // disagreeing with the action it invokes.
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")

        store.setFocusMembership(work.id, member: true)
        #expect(!store.isSoleFocus(work.id)) // marked, but the filter is off — nothing to un-focus yet
        store.setFocusEnabled(true)
        #expect(store.isSoleFocus(work.id))
        #expect(!store.isSoleFocus(personal.id)) // an unmarked workspace is never the sole focus
        store.setFocusMembership(personal.id, member: true)
        #expect(!store.isSoleFocus(work.id)) // one of two members is not the SOLE focus
    }

    @Test func toggleFocusedWorkspaceNarrowsAMultiMemberSetThenClears() {
        // the DEFAULT `workspace.focus` mode and the row menu's Focus/Unfocus. Against a set of two it
        // REPLACES (narrows to the target) rather than un-marking it, and only a repeat — where the target
        // is now the sole focus — clears.
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

        // from an empty set it marks + applies, so one toggle is the whole zoom-in.
        store.toggleFocusedWorkspace(work.id)
        #expect(store.focusedWorkspaceIDs == [work.id] && store.focusEnabled)
        // a toggle onto a workspace marked while the filter is OFF applies rather than clears: it is not
        // the SOLE FOCUS until the filter is on, so `isSoleFocus` and the toggle agree.
        store.setFocusEnabled(false)
        store.toggleFocusedWorkspace(work.id)
        #expect(store.focusedWorkspaceIDs == [work.id] && store.focusEnabled)
    }

    @Test func currentWorkspaceFocusHelpersFollowTheSelection() throws {
        // the keyless View-menu items target `currentWorkspaceID`, so their label flip and their disabled
        // state read these two — the store-side twins of `isSoleFocus`, so the menu needs no optional dance.
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        _ = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        #expect(store.currentWorkspaceID == work.id)
        #expect(!store.isCurrentWorkspaceSoleFocus && !store.isCurrentWorkspaceFocusMember)

        store.setFocusMembership(work.id, member: true)
        #expect(store.isCurrentWorkspaceFocusMember) // marked, so "Add Workspace to Focus" is a no-op now
        #expect(!store.isCurrentWorkspaceSoleFocus)  // but not applied, so the label still reads "Focus"
        store.setFocusEnabled(true)
        #expect(store.isCurrentWorkspaceSoleFocus)

        // the current workspace follows the selection, and so do both helpers.
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
        // the single-workspace convenience REPLACES rather than adds, so the row menu's Focus still zooms.
        store.setFocusedWorkspace(personal.id)
        #expect(store.focusedWorkspaceIDs == [personal.id] && store.focusEnabled)
    }

    @Test func setFocusMembershipAddsAndRemoves() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        store.setFocusMembership(work.id, member: true)
        #expect(store.focusedWorkspaceIDs == [work.id] && !store.focusEnabled) // marking never turns the filter on
        store.setFocusMembership(personal.id, member: true)
        #expect(store.focusedWorkspaceIDs == [work.id, personal.id] && !store.focusEnabled)
        store.setFocusEnabled(true)
        store.setFocusMembership(work.id, member: false)
        #expect(store.focusedWorkspaceIDs == [personal.id] && store.focusEnabled) // the survivor keeps the filter on
    }

    @Test func addingToTheSetNeverTurnsTheFilterOn() {
        // the contract that makes a multi-workspace set buildable: an add MARKS and nothing else. If it
        // enabled the filter, marking the first workspace would collapse the tree to it and the rows of
        // every workspace still to be marked would be gone — each extra member costing a toggle off and
        // back. Both polarities are pinned: adding while OFF leaves it off, adding while ON leaves it on.
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        store.setFocusMembership(work.id, member: true)
        #expect(store.focusedWorkspaceIDs == [work.id] && !store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id) == [work.id, personal.id]) // the whole tree is still on screen
        store.setFocusEnabled(true)
        store.setFocusMembership(personal.id, member: true)
        #expect(store.focusedWorkspaceIDs == [work.id, personal.id] && store.focusEnabled) // still on, not flipped
    }

    @Test func removingTheLastMemberDisablesTheFilter() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        store.setFocusMembership(work.id, member: true)
        store.setFocusEnabled(true)
        store.setFocusMembership(work.id, member: false)
        #expect(store.focusedWorkspaceIDs.isEmpty && !store.focusEnabled) // `enabled + empty` is unrepresentable
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
        #expect(store.focusedWorkspaceIDs == [personal.id] && !store.focusEnabled) // removing never turns it back on
    }

    @Test func setFocusEnabledRoundTripsWithoutLosingTheSet() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        store.setFocusMembership(work.id, member: true)
        store.setFocusMembership(personal.id, member: true)
        store.setFocusEnabled(true)
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
        // marking then applying then switching the filter off reveals the whole tree again, set intact.
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
        store.setFocusMembership(three.id, member: true) // marked out of tree order
        store.setFocusMembership(one.id, member: true)
        store.setFocusEnabled(true)
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
        store.setFocusEnabled(true)
        store.removeWorkspace(doomed.id)
        #expect(store.focusedWorkspaceIDs == [work.id] && store.focusEnabled) // the survivor keeps filtering
        #expect(store.visibleWorkspaces.map(\.id) == [work.id])
    }

    @Test func removingTheLastMemberWorkspaceDisablesTheFilter() {
        let store = makeStore()
        _ = store.addWorkspace(name: "other")
        let doomed = store.addWorkspace(name: "doomed")
        store.setFocusMembership(doomed.id, member: true)
        store.setFocusEnabled(true)
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
        store.setFocusEnabled(true)
        store.removeWorkspace(doomed.id)
        #expect(store.focusedWorkspaceIDs == [work.id, personal.id] && store.focusEnabled)
    }

    @Test func undoingASoftRemovedMemberRestoresItsMembership() throws {
        // the undo half of the prune below. Without it a re-added member came back UNMARKED: a workspace
        // holding sessions was revealed anyway (the undo's reselect trips the cross-set auto-disable), but
        // an EMPTY one was reinserted behind the still-applied filter and its row simply never came back.
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let doomed = store.addWorkspace(name: "doomed") // empty on purpose: the case the undo used to lose
        _ = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        store.setFocusMembership(work.id, member: true)
        store.setFocusMembership(doomed.id, member: true)
        store.setFocusEnabled(true)

        #expect(store.softRemoveWorkspace(doomed.id))
        #expect(store.focusedWorkspaceIDs == [work.id] && store.focusEnabled)

        #expect(store.undoPendingClose())
        #expect(store.focusedWorkspaceIDs == [work.id, doomed.id], "an undone member must be marked again")
        #expect(store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id) == [work.id, doomed.id]) // its row is rendered again
    }

    @Test func undoingTheLastMemberRestoresTheSetWithoutReApplyingTheFilter() throws {
        // removing the last member disables the filter, and the undo brings the SET back but leaves the
        // flag alone: membership belongs to the closed workspace, the flag is current window state. Both
        // restore legs (this and Reopen Closed Item) mark only, so they cannot disagree.
        let store = makeStore()
        let other = store.addWorkspace(name: "other")
        let doomed = store.addWorkspace(name: "doomed")
        let spare = store.addWorkspace(name: "spare") // soft-remove keeps at least one workspace
        store.setFocusMembership(doomed.id, member: true)
        store.setFocusEnabled(true)

        #expect(store.softRemoveWorkspace(doomed.id))
        #expect(store.focusedWorkspaceIDs.isEmpty && !store.focusEnabled)

        #expect(store.undoPendingClose())
        #expect(store.focusedWorkspaceIDs == [doomed.id], "an undone member must be marked again")
        #expect(!store.focusEnabled, "restoring a member must never switch the filter on")
        // so the workspace is genuinely back on screen, in its old slot, alongside everything else
        #expect(store.visibleWorkspaces.map(\.id) == [other.id, doomed.id, spare.id])
        store.setFocusEnabled(true) // and one flip of the bottom-bar toggle re-applies it
        #expect(store.visibleWorkspaces.map(\.id) == [doomed.id])
    }

    @Test func suspendingTheFilterDuringTheGraceSurvivesTheUndo() {
        // the flag is CURRENT window state, so a toggle the user makes inside the 3-second grace is newer
        // than anything the pending record captured. An undo that restored the captured flag would put the
        // filter back on seconds after he deliberately switched it off.
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let doomed = store.addWorkspace(name: "doomed")
        _ = store.addWorkspace(name: "spare")
        store.setFocusMembership(work.id, member: true)
        store.setFocusMembership(doomed.id, member: true)
        store.setFocusEnabled(true)

        #expect(store.softRemoveWorkspace(doomed.id))
        store.setFocusEnabled(false) // one click on the bottom-bar toggle, still inside the grace

        #expect(store.undoPendingClose())
        #expect(store.focusedWorkspaceIDs == [work.id, doomed.id], "the membership still comes back")
        #expect(!store.focusEnabled, "the undo must not override the toggle the user just made")
    }

    @Test func reClosingAWorkspaceRebuiltByASessionUndoKeepsItsMembership() throws {
        // the superseded-record case: closing a workspace, undoing an EARLIER session close (which rebuilds
        // that workspace as an unmarked shell and trips the cross-set auto-disable), then closing it again
        // makes the second close absorb the first record. The live set no longer holds the membership by
        // then, so the absorbed record's flag is its only surviving copy — and the newer Open Recent entry
        // overwrites the older one on the same workspace id, so losing it there kills BOTH recovery routes.
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
        #expect(store.focusedWorkspaceIDs == [keep.id]) // the close pruned the membership into its record

        // undoing the SESSION close rebuilds `work` as a shell — unmarked, and the reselect into it
        // switches the filter off through the cross-set auto-disable.
        #expect(store.undoPendingClose(sessionCloseID))
        #expect(store.workspaces.contains { $0.id == work.id })
        #expect(!store.focusedWorkspaceIDs.contains(work.id) && !store.focusEnabled)

        #expect(store.softRemoveWorkspace(work.id, grace: 60))
        // the second recovery route: this close OVERWRITES the Open Recent entry the first one wrote, so a
        // lost membership here also kills every reopen past the grace window.
        let item = try #require(recentClosed.load().first { $0.workspace?.snapshot.id == work.id })
        #expect(item.workspace?.focusMember == true, "the overwriting Open Recent entry must keep the membership")

        #expect(store.undoPendingClose())
        #expect(store.focusedWorkspaceIDs == [keep.id, work.id],
                "the absorbed record's membership must survive the re-close")
    }

    @Test func undoingANonMemberWorkspaceDoesNotMarkIt() {
        // the other polarity: an unmarked workspace must come back unmarked, or an undo would silently
        // widen a working set the user never put it in.
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
        // the grace window's SIBLING: once the pending record is finalized, Reopen Closed Item is the only
        // route back, so an empty member reopened behind a still-applied filter hit the exact silent no-op
        // the undo leg fixed — appended, never marked, never rendered.
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        let work = store.addWorkspace(name: "work")
        let doomed = store.addWorkspace(name: "doomed") // empty on purpose: the case the restore used to lose
        _ = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        store.setFocusMembership(work.id, member: true)
        store.setFocusMembership(doomed.id, member: true)
        store.setFocusEnabled(true)

        #expect(store.softRemoveWorkspace(doomed.id, grace: 60))
        store.finalizePendingClose(try #require(store.pendingCloseSummary?.id)) // the 3s grace expires
        #expect(store.focusedWorkspaceIDs == [work.id] && store.focusEnabled)

        let item = try #require(recentClosed.load().first { $0.workspace?.snapshot.id == doomed.id })
        #expect(store.restoreRecentClosed(item))
        #expect(store.focusedWorkspaceIDs == [work.id, doomed.id], "a reopened member must be marked again")
        #expect(store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id) == [work.id, doomed.id]) // its row is rendered again
    }

    @Test func reopeningARecentClosedMemberWithSessionsKeepsTheFilterOn() throws {
        // the non-empty half: rejoining the set is what keeps the reselect INSIDE it. Without the re-mark
        // the restore was not silent but suspended the whole filter through the cross-set auto-disable,
        // blowing a hand-curated working set open — while the same restore one second earlier (the undo)
        // preserved it.
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
        #expect(store.selectedSessionID == stray.id) // the rebuilt session, selected inside the set
    }

    @Test func reopeningTheLastRecentClosedMemberMarksItWithoutReApplyingTheFilter() throws {
        // the recent-closed leg MARKS ONLY, unlike the undo twin: removing the last member disabled the
        // filter, and the reopen must NOT switch it back on. The entry is not window-scoped or time-scoped,
        // so a flag taken from it would describe some other window (or some other day), and re-applying
        // here would collapse the tree the user is currently looking at.
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        let other = store.addWorkspace(name: "other")
        let doomed = store.addWorkspace(name: "doomed")
        let spare = store.addWorkspace(name: "spare") // soft-remove keeps at least one workspace
        store.setFocusMembership(doomed.id, member: true)
        store.setFocusEnabled(true)

        #expect(store.softRemoveWorkspace(doomed.id, grace: 60))
        store.finalizePendingClose(try #require(store.pendingCloseSummary?.id))
        #expect(store.focusedWorkspaceIDs.isEmpty && !store.focusEnabled)

        let item = try #require(recentClosed.load().first { $0.workspace?.snapshot.id == doomed.id })
        #expect(store.restoreRecentClosed(item))
        #expect(store.focusedWorkspaceIDs == [doomed.id], "a reopened member must be marked again")
        #expect(!store.focusEnabled, "marking on reopen must never switch the filter on")
        // so the workspace is genuinely back on screen, alongside everything else
        #expect(store.visibleWorkspaces.map(\.id) == [other.id, spare.id, doomed.id])
    }

    @Test func reopeningARecentClosedMemberWithTheFilterOffLeavesItOff() throws {
        // the untested polarity of every other reopen case: the target window's filter is OFF while it has
        // its own marked set. The reopen must join the set and change nothing else — an enable here would
        // collapse the tree onto `the window's members + this one` behind the user's back.
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        let work = store.addWorkspace(name: "work")
        let doomed = store.addWorkspace(name: "doomed")
        let spare = store.addWorkspace(name: "spare")
        store.setFocusMembership(work.id, member: true)
        store.setFocusMembership(doomed.id, member: true)
        store.setFocusEnabled(true)

        #expect(store.softRemoveWorkspace(doomed.id, grace: 60))
        store.finalizePendingClose(try #require(store.pendingCloseSummary?.id))
        store.setFocusEnabled(false) // the user peeks at the whole tree before reopening

        let item = try #require(recentClosed.load().first { $0.workspace?.snapshot.id == doomed.id })
        #expect(store.restoreRecentClosed(item))
        #expect(store.focusedWorkspaceIDs == [work.id, doomed.id])
        #expect(!store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id) == [work.id, spare.id, doomed.id]) // the whole tree, unchanged
    }

    @Test func reopeningARecordFromAFilteringWindowCannotEnableAnotherWindowsFilter() throws {
        // the cross-window/stale case the flag-restoring version got wrong: ONE `RecentClosedStore` is
        // shared by every window's store and entries never expire, so a record written while window A was
        // filtering can be reopened into window B (or into the same window days later). Marking only is
        // what makes that safe — B's filter, and therefore what B renders, is untouched.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let recentClosed = RecentClosedStore(directory: dir)
        let windowA = AppStore(persistence: PersistenceStore(directory: dir.appendingPathComponent("a")),
                               recentClosedStore: recentClosed)
        let windowB = AppStore(persistence: PersistenceStore(directory: dir.appendingPathComponent("b")),
                               recentClosedStore: recentClosed)

        let shared = windowA.addWorkspace(name: "shared")
        _ = windowA.addWorkspace(name: "keeper") // `removeWorkspace` keeps at least one
        windowA.setFocusedWorkspace(shared.id) // A closes it with its own filter applied
        #expect(windowA.focusEnabled)
        windowA.removeWorkspace(shared.id)

        let curated = windowB.addWorkspace(name: "curated")
        let extra = windowB.addWorkspace(name: "extra")
        windowB.setFocusMembership(curated.id, member: true) // B has its own set, filter off

        let item = try #require(recentClosed.load().first { $0.workspace?.snapshot.id == shared.id })
        #expect(windowB.restoreRecentClosed(item))
        #expect(!windowB.focusEnabled, "a record from a filtering window must not apply B's filter")
        #expect(windowB.focusedWorkspaceIDs == [curated.id, shared.id])
        #expect(windowB.visibleWorkspaces.map(\.id) == [curated.id, extra.id, shared.id]) // B still shows everything
    }

    @Test func reopeningARecentClosedNonMemberDoesNotMarkIt() throws {
        // the other polarity, matching the undo twin: an unmarked workspace comes back unmarked, or a
        // reopen would silently widen a working set the user never put it in.
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
        // `removeWorkspace` (no grace at all) records its recent entry BEFORE `dropFocusMember` prunes the
        // id, so the restore leg has the same state to work from as the soft-remove path.
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        let work = store.addWorkspace(name: "work")
        let doomed = store.addWorkspace(name: "doomed")
        _ = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        store.setFocusMembership(work.id, member: true)
        store.setFocusMembership(doomed.id, member: true)
        store.setFocusEnabled(true)

        store.removeWorkspace(doomed.id)
        let item = try #require(recentClosed.load().first { $0.workspace?.snapshot.id == doomed.id })
        #expect(item.workspace?.focusMember == true) // membership only — the flag is deliberately not recorded

        #expect(store.restoreRecentClosed(item))
        #expect(store.focusedWorkspaceIDs == [work.id, doomed.id])
        #expect(store.focusEnabled) // still on because `work` kept it on, not because the reopen re-applied it
    }

    @Test func softRemovingAMemberPrunesItAndDisablesWhenTheSetEmpties() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let doomed = store.addWorkspace(name: "doomed")
        _ = store.addWorkspace(name: "spare") // soft-remove keeps at least one workspace
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
        #expect(store.focusedWorkspaceIDs == [work.id, personal.id] && !store.focusEnabled) // set intact
        store.setFocusEnabled(true) // one flip restores the hand-curated working set
        #expect(store.visibleWorkspaces.map(\.id) == [work.id, personal.id])
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
        store.setFocusEnabled(true)
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

    @Test func dropFallbackIsNilWithNothingMarked() {
        let store = makeStore()
        _ = store.addWorkspace(name: "work")
        #expect(store.soleFocusedWorkspaceID == nil) // no filter, so an empty-space drop uses the current workspace
    }

    @Test func dropFallbackIsTheSoleMemberWhileTheFilterIsOn() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        _ = store.addWorkspace(name: "personal")
        store.setFocusedWorkspace(work.id)
        #expect(store.soleFocusedWorkspaceID == work.id) // the only workspace the tree is rendering
    }

    @Test func dropFallbackIsNilWhenTheFilterIsOff() {
        // the load-bearing case: one workspace is MARKED but the filter is OFF, so the whole tree is on
        // screen — an empty-space drop must not silently land in the marked workspace.
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        _ = store.addWorkspace(name: "personal")
        store.setFocusMembership(work.id, member: true)
        store.setFocusEnabled(false)
        #expect(store.focusedWorkspaceIDs == [work.id]) // still marked, so set SIZE alone would answer wrong
        #expect(store.soleFocusedWorkspaceID == nil)
    }

    @Test func dropFallbackIsNilWithTwoMembersMarked() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        store.setFocusMembership(work.id, member: true)
        store.setFocusMembership(personal.id, member: true)
        store.setFocusEnabled(true) // enabled, so the nil answer comes from the COUNT, not from the flag
        #expect(store.soleFocusedWorkspaceID == nil) // no unambiguous target among several rendered rows
    }

    @Test func dropFallbackFeedsTheDirectoryDropResolverAcrossEverySetShape() throws {
        // the pair the sidebar's empty-space Finder drop is built from: the store answers "is there ONE
        // unambiguous rendered workspace", and `SidebarDrop` turns that into the destination. Composed here
        // because the promise the two make together — an empty-space drop lands where the user is looking,
        // and falls through to the current workspace whenever the tree shows more than one workspace — is
        // not visible from either side alone. (The AppKit `Coordinator` call that feeds one into the other
        // is a single line, build-verified.)
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let current = try #require(store.currentWorkspaceID)
        func emptySpaceDrop() -> UUID? {
            SidebarDrop.resolveDirectoryWorkspace(sidebarMode: store.sidebarMode, rowWorkspaceID: nil,
                                                  fallbackWorkspaceID: store.soleFocusedWorkspaceID,
                                                  currentWorkspaceID: store.currentWorkspaceID)
        }

        #expect(emptySpaceDrop() == current) // nothing marked: the current workspace
        store.setFocusMembership(work.id, member: true)
        #expect(emptySpaceDrop() == current) // marked but NOT applied — the whole tree is on screen
        store.setFocusEnabled(true)
        #expect(emptySpaceDrop() == work.id) // the one workspace the filtered tree renders
        store.setFocusMembership(personal.id, member: true)
        #expect(emptySpaceDrop() == current) // two rendered workspaces give no unambiguous target

        // a drop ON a row always wins over both, and the flagged view takes no folder drops at all.
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
        // no focus: no workspace node reports focused.
        #expect(store.controlTree().workspaces.allSatisfy { $0.focused == nil })
        // focus the second workspace: ONLY its node reports focused == true (distinct from active).
        store.setFocusedWorkspace(ws2.id)
        let nodes = store.controlTree().workspaces
        #expect(nodes.first { $0.id == ws2.id.uuidString }?.focused == true)
        #expect(nodes.filter { $0.focused == true }.count == 1)
        // clearing focus: no node reports focused again.
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
        // membership and the flag are separate read-back fields: a marked-but-not-filtering set must still
        // report `focused`, else a script could not record a working set while the filter is off.
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
        #expect(store.controlTree().workspaceFilter == false) // nothing marked, filter off
        store.setFocusMembership(work.id, member: true)
        #expect(store.controlTree().workspaceFilter == false) // marking alone does not apply the filter
        store.setFocusEnabled(true)
        #expect(store.controlTree().workspaceFilter == true)
        store.setFocusEnabled(false)
        #expect(store.controlTree().workspaceFilter == false)
    }

    @Test func workspaceFilterOnAnEmptySetLeavesTheFilterOffThroughTheControlPath() async {
        // the row-visibility contract published to scripts carries `!workspaceFilter || focused` as its
        // filter term (alongside the sidebar-visible and tree-mode terms — see `ControlWorkspaceNode`). If
        // the control path could enable an EMPTY set, `workspaceFilter` would report true while no
        // workspace reported `focused`, so a script would conclude nothing is visible while the whole tree
        // is on screen. Driven through the dispatcher's parse into `AppStore.applyWorkspaceFilter` — the SAME
        // host-free helper the app-side arm calls, so the refusal is exercised where it actually lives.
        // (The arm's own legs — the window resolution and the "no open window" error — are app-side and
        // covered by `ControlSidebarStatusUITests`.)
        let store = makeStore()
        _ = store.addWorkspace(name: "work")
        let actions = MockControlActions()
        actions.focusStore = store
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .workspaceFilter, args: ControlArgs(mode: "on")))

        #expect(response?.ok == true)
        #expect(actions.calls == [.workspaceFilter(window: nil, .on)]) // `on` reached the arm, unparsed-mode-free
        #expect(!store.focusEnabled) // and changed nothing
        let tree = store.controlTree()
        #expect(tree.workspaceFilter == false)
        #expect(tree.workspaces.allSatisfy { $0.focused == nil })
    }

    @Test func workspaceFocusModesDriveTheStoreThroughTheControlPath() async throws {
        // the four modes' semantics run through the dispatcher's parse into `AppStore.applyFocusMode`, the
        // host-free half of the app-side arm. `toggle` is the DEFAULT mode (an omitted `mode` arg), and its
        // replace-toggle against a two-member set — narrow to the target, then clear on a repeat — is the
        // behavior nothing else pins.
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
        #expect(store.focusedWorkspaceIDs == [work.id, personal.id] && !store.focusEnabled) // add never applies

        #expect(await focus(work.id, nil)?.ok == true) // omitted mode = toggle
        #expect(store.focusedWorkspaceIDs == [work.id] && store.focusEnabled) // replace-toggle NARROWS
        #expect(store.visibleWorkspaces.map(\.id) == [work.id])

        #expect(await focus(work.id, "toggle")?.ok == true)
        #expect(store.focusedWorkspaceIDs.isEmpty && !store.focusEnabled) // a repeat on the sole member clears

        #expect(await focus(personal.id, "on")?.ok == true)
        #expect(store.focusedWorkspaceIDs == [personal.id] && store.focusEnabled)
        #expect(await focus(personal.id, "off")?.ok == true)
        #expect(store.focusedWorkspaceIDs.isEmpty && !store.focusEnabled)
        #expect(actions.calls.count == 6) // every mode routed, none swallowed by the dispatcher
        // the double resolves only full-id targets, so an unresolved one would make every "the store
        // changed" assertion above pass vacuously against a store nothing ever touched.
        #expect(actions.unresolvedFocusTargets.isEmpty)
    }

    @Test func aTargetTheStoreDrivingDoubleCannotResolveIsRecordedRatherThanSwallowed() async {
        // the double stands in for the app-side arm's target resolution but implements only its id-spelling
        // half — `active` and prefixes need `ControlTargetResolver`. Silently no-opping on one would let a
        // "the store did not change" assertion pass without the command ever reaching the store.
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        store.setFocusMembership(work.id, member: true)
        let actions = MockControlActions()
        actions.focusStore = store
        let dispatcher = ControlDispatcher(actions: actions)

        #expect(await dispatcher.dispatch(ControlRequest(cmd: .workspaceFocus, args: ControlArgs(mode: "off")))?.ok == true)
        #expect(actions.unresolvedFocusTargets == ["active"])
        #expect(store.focusedWorkspaceIDs == [work.id]) // unchanged, but now provably for the wrong reason
    }

    @Test func workspaceFilterTogglesTheFlagThroughTheControlPathOnceAWorkspaceIsMarked() async {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        store.setFocusMembership(work.id, member: true)
        let actions = MockControlActions()
        actions.focusStore = store
        let dispatcher = ControlDispatcher(actions: actions)

        // marking left the filter off, so `on` is what applies the set — the two-call build-then-apply
        // shape a script uses after a run of `workspace.focus add`.
        _ = await dispatcher.dispatch(ControlRequest(cmd: .workspaceFilter, args: ControlArgs(mode: "on")))
        #expect(store.controlTree().workspaceFilter == true)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .workspaceFilter, args: ControlArgs(mode: "off")))
        #expect(store.controlTree().workspaceFilter == false)
        #expect(store.focusedWorkspaceIDs == [work.id]) // turning the filter off keeps the marked set

        _ = await dispatcher.dispatch(ControlRequest(cmd: .workspaceFilter, args: ControlArgs(mode: "toggle")))
        #expect(store.controlTree().workspaceFilter == true)
    }
}
