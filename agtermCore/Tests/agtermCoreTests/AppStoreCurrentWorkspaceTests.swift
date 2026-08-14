import Foundation
import Testing
@testable import agtermCore

/// `AppStore.currentWorkspaceID` — where a new session, a rename, and a control-channel `active` workspace
/// target land. Split out of `AppStoreTests` for the line budget.
@MainActor
struct AppStoreCurrentWorkspaceTests {
    @Test func currentWorkspaceFollowsSelectionThenFallsBackToLast() {
        let store = makeStore()
        #expect(store.currentWorkspaceID == nil)
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        #expect(store.currentWorkspaceID == personal.id)
        let session = try! #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        store.selectSession(session.id)
        #expect(store.currentWorkspaceID == work.id)
        store.selectSession(nil)
        #expect(store.currentWorkspaceID == personal.id)
    }

    // pins discussion #325: a foreground create used to leave the previous workspace current, so Rename
    // Workspace edited the wrong row and the next new session landed in the old workspace.
    @Test func foregroundCreateBecomesCurrentOverTheSelectedSessionsWorkspace() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let session = try! #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        store.selectSession(session.id)
        #expect(store.currentWorkspaceID == work.id)

        let fresh = store.addWorkspace(name: "fresh")
        #expect(store.currentWorkspaceID == fresh.id)
    }

    @Test func selectingASessionDropsTheFreshWorkspaceAsCurrent() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let first = try! #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let other = store.addWorkspace(name: "other")
        try! #require(store.addSession(toWorkspace: other.id, cwd: "/b"))
        store.addWorkspace(name: "fresh")

        store.selectSession(first.id)
        #expect(store.currentWorkspaceID == work.id)
    }

    // `navigateSession` with one visible session and `overlay open --follow` both reselect the active
    // session without moving the user, so a same-value selection must leave the target alone
    @Test func reselectingTheActiveSessionKeepsTheFreshWorkspaceCurrent() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let fresh = store.addWorkspace(name: "fresh")

        store.selectSession(session.id)
        #expect(store.currentWorkspaceID == fresh.id)
        store.navigateSession(.next)
        #expect(store.selectedSessionID == session.id)
        #expect(store.currentWorkspaceID == fresh.id)
    }

    @Test func selectingASessionOnCreationDropsTheFreshWorkspaceAsCurrent() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        store.addWorkspace(name: "fresh")

        store.addSession(toWorkspace: work.id, cwd: "/a")
        #expect(store.currentWorkspaceID == work.id)
    }

    @Test func backgroundCreateDoesNotBecomeCurrent() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let session = try! #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        store.selectSession(session.id)

        store.addWorkspace(name: "background", revealNewWorkspace: false)
        #expect(store.currentWorkspaceID == work.id)
    }

    @Test func backgroundSessionAddKeepsTheFreshWorkspaceCurrent() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let fresh = store.addWorkspace(name: "fresh")

        store.addSession(toWorkspace: work.id, cwd: "/a", select: false)
        #expect(store.currentWorkspaceID == fresh.id)
    }

    @Test func removingTheFreshWorkspaceFallsBackToSelection() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let session = try! #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        store.selectSession(session.id)
        let fresh = store.addWorkspace(name: "fresh")

        store.removeWorkspace(fresh.id)
        #expect(store.currentWorkspaceID == work.id)
    }
    @Test func closingTheSelectedSessionDropsTheFreshWorkspaceAsCurrent() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let first = try! #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        try! #require(store.addSession(toWorkspace: work.id, cwd: "/b"))
        store.selectSession(first.id)
        let fresh = store.addWorkspace(name: "fresh")
        #expect(store.currentWorkspaceID == fresh.id)

        store.closeSession(first.id)
        #expect(store.currentWorkspaceID == work.id)
    }

    @Test func reopeningAClosedSessionDropsTheFreshWorkspaceAsCurrent() {
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        let work = store.addWorkspace(name: "work")
        let first = try! #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        try! #require(store.addSession(toWorkspace: work.id, cwd: "/b"))
        store.selectSession(first.id)
        store.closeSession(first.id)
        let fresh = store.addWorkspace(name: "fresh")
        #expect(store.currentWorkspaceID == fresh.id)

        store.restoreRecentClosed(try! #require(recentClosed.load().first))
        #expect(store.currentWorkspaceID == work.id)
    }

    @Test func undoingAFreshWorkspaceCloseDoesNotReviveItAsCurrent() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let session = try! #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        store.selectSession(session.id)
        let fresh = store.addWorkspace(name: "fresh")

        store.softRemoveWorkspace(fresh.id, grace: 60)
        store.undoPendingClose()
        #expect(store.workspaces.map(\.id) == [work.id, fresh.id])
        #expect(store.currentWorkspaceID == work.id)
    }

    // the undo path keeps the selection, so a reopen after the grace expired must not differ
    @Test func reopeningAnEmptyClosedWorkspaceKeepsTheSelectionAndTarget() throws {
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        let work = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let second = try #require(store.addSession(toWorkspace: work.id, cwd: "/b"))
        store.selectSession(session.id, sidebarSelection: [session.id, second.id])
        let empty = store.addWorkspace(name: "empty")
        #expect(store.softRemoveWorkspace(empty.id, grace: 60))
        store.finalizePendingClose(try #require(store.pendingCloseSummary?.id))

        #expect(store.restoreRecentClosed(try #require(recentClosed.load().first)))
        #expect(store.workspaces.map(\.id) == [work.id, empty.id])
        #expect(store.selectedSessionID == session.id)
        #expect(store.sidebarSelectionIDs == [session.id, second.id], "a multi-row selection must survive")
        #expect(store.currentWorkspaceID == work.id)
    }

    @Test func closingTheOnlySessionDropsTheFreshWorkspaceAsCurrent() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        store.selectSession(session.id)
        let fresh = store.addWorkspace(name: "fresh")
        let last = store.addWorkspace(name: "last", revealNewWorkspace: false)
        #expect(store.currentWorkspaceID == fresh.id)

        store.closeSession(session.id)
        #expect(store.selectedSessionID == nil)
        #expect(store.currentWorkspaceID == last.id)
    }

    // `workspace select` on the workspace already holding the selection lands on a same-value
    // `selectSession`, which by itself leaves the fresh preference alive
    @Test func selectingAWorkspaceDropsTheFreshWorkspaceAsCurrent() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        store.selectSession(session.id)
        store.addWorkspace(name: "fresh")

        #expect(store.selectWorkspace(work.id) != nil)
        #expect(store.selectedSessionID == session.id)
        #expect(store.currentWorkspaceID == work.id)
    }

    // an empty workspace has no session to select, so targeting is the only thing `workspace select` can
    // do there — reporting success while the target stayed elsewhere was the defect
    @Test func selectingAnEmptyWorkspaceStillMakesItCurrent() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        store.selectSession(session.id)
        store.addWorkspace(name: "fresh")
        let empty = store.addWorkspace(name: "empty", revealNewWorkspace: false)

        #expect(store.selectWorkspace(empty.id) != nil)
        #expect(store.selectedSessionID == session.id)
        #expect(store.currentWorkspaceID == empty.id)
    }

    @Test func selectingAFilteredOutEmptyWorkspaceRevealsIt() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        store.selectSession(session.id)
        let empty = store.addWorkspace(name: "empty", revealNewWorkspace: false)
        let other = store.addWorkspace(name: "other", revealNewWorkspace: false)
        store.setFocusedWorkspace(work.id)
        #expect(store.visibleWorkspaces.map(\.id) == [work.id])

        #expect(store.selectWorkspace(empty.id) != nil)
        #expect(store.currentWorkspaceID == empty.id)
        #expect(store.visibleWorkspaces.map(\.id) == [work.id, empty.id], "the target must be on screen")
        #expect(store.focusEnabled, "the filter must widen, not switch off")
        #expect(!store.focusedWorkspaceIDs.contains(other.id), "an unrelated workspace stays filtered out")
    }

    @Test func removingAnotherWorkspaceKeepsTheFreshTarget() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        store.selectSession(session.id)
        let spare = store.addWorkspace(name: "spare", revealNewWorkspace: false)
        let fresh = store.addWorkspace(name: "fresh")

        store.removeWorkspace(spare.id)
        #expect(store.currentWorkspaceID == fresh.id, "only the target's own removal hands targeting back")
    }

    // hard removal records the workspace for Open Recent, so a stale target could come back with it
    @Test func reopeningAHardRemovedFreshWorkspaceDoesNotReviveTheTarget() throws {
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        let work = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        store.selectSession(session.id)
        let fresh = store.addWorkspace(name: "fresh")
        #expect(store.currentWorkspaceID == fresh.id)

        store.removeWorkspace(fresh.id)
        #expect(store.restoreRecentClosed(try #require(recentClosed.load().first)))
        #expect(store.workspaces.map(\.id) == [work.id, fresh.id])
        #expect(store.selectedSessionID == session.id)
        #expect(store.currentWorkspaceID == work.id)
    }

    @Test func selectingAnUnknownWorkspaceIsANoOp() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")

        #expect(store.selectWorkspace(UUID()) == nil)
        #expect(store.currentWorkspaceID == work.id)
    }

    // the sidebar builds its row cache from `visibleWorkspaces`, so a filtered-out target would leave
    // Rename Workspace enabled and doing nothing — and un-filtering must not bring it back
    @Test func filteringOutTheFreshWorkspaceDropsItForGood() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        store.selectSession(session.id)
        let fresh = store.addWorkspace(name: "fresh")
        #expect(store.currentWorkspaceID == fresh.id)

        store.setFocusedWorkspace(work.id)
        #expect(store.visibleWorkspaces.map(\.id) == [work.id])
        #expect(store.currentWorkspaceID == work.id)

        store.clearFocus()
        #expect(store.currentWorkspaceID == work.id, "un-filtering must not revive a target already handed back")
    }

    @Test func restoringASnapshotDropsTheFreshWorkspaceAsCurrent() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let session = try! #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        store.selectSession(session.id)
        let fresh = store.addWorkspace(name: "fresh")
        let snapshot = store.snapshot()
        #expect(store.currentWorkspaceID == fresh.id)

        store.restore(from: snapshot)
        #expect(store.currentWorkspaceID == work.id)
    }
}
