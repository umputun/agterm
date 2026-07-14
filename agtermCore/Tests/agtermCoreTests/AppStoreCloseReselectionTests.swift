import Foundation
import Testing
@testable import agtermCore

/// Closing the ACTIVE session returns to the most-recently-active SURVIVING session, scoped to the
/// closing session's workspace and the active focus/flagged filter, with the positional
/// `reselectionTarget` as the fallback (GitHub Discussion #147).
@MainActor
struct AppStoreCloseReselectionTests {
    @Test func closeActiveSessionInsertedAfterCurrentReturnsToTheSessionItCameFrom() throws {
        // discussion example 1: from `1 2 3` on `1`, a new session inserted after the current one
        // (`1 4 2 3`) and closed lands back on `1` — not on the positional neighbor `2`.
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let one = try #require(store.addSession(toWorkspace: ws.id, cwd: "/1"))
        let two = try #require(store.addSession(toWorkspace: ws.id, cwd: "/2"))
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/3"))
        store.selectSession(one.id)
        let four = try #require(store.addSession(toWorkspace: ws.id, cwd: "/4", at: 1))
        #expect(store.selectedSessionID == four.id)

        store.closeSession(four.id)
        #expect(store.selectedSessionID == one.id)
        #expect(store.selectedSessionID != two.id)
    }

    @Test func closeActiveSessionAppendedAtTheEndReturnsToTheSessionItCameFrom() throws {
        // discussion example 2: from `1 2 3` on `1`, a new session appended (`1 2 3 4`) and closed
        // lands back on `1` — not on the positional previous `3`.
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let one = try #require(store.addSession(toWorkspace: ws.id, cwd: "/1"))
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/2"))
        let three = try #require(store.addSession(toWorkspace: ws.id, cwd: "/3"))
        store.selectSession(one.id)
        let four = try #require(store.addSession(toWorkspace: ws.id, cwd: "/4"))

        store.closeSession(four.id)
        #expect(store.selectedSessionID == one.id)
        #expect(store.selectedSessionID != three.id)
    }

    @Test func closeActiveSessionPrefersTheRecentSurvivorOverThePositionalNeighbor() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let first = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let second = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        let third = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c"))
        let fourth = try #require(store.addSession(toWorkspace: ws.id, cwd: "/d"))
        store.selectSession(second.id)
        store.selectSession(fourth.id)

        store.closeSession(fourth.id)
        #expect(store.selectedSessionID == second.id) // the MRU survivor, though `third` is the neighbor
        #expect(store.selectedSessionID != third.id)
        #expect(first.id != store.selectedSessionID)
    }

    @Test func closeActiveSessionIgnoresAMoreRecentSessionInAnotherWorkspace() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let inWork = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let closing = try #require(store.addSession(toWorkspace: work.id, cwd: "/b"))
        let elsewhere = try #require(store.addSession(toWorkspace: personal.id, cwd: "/x"))
        store.selectSession(inWork.id)
        store.selectSession(elsewhere.id) // more recent than `inWork`, but in another workspace
        store.selectSession(closing.id)

        store.closeSession(closing.id)
        #expect(store.selectedSessionID == inWork.id) // stays in the closing session's workspace
        #expect(store.selectedSessionID != elsewhere.id)
        #expect(store.focusedWorkspaceID == nil) // the close must not introduce a focus filter
    }

    @Test func closeActiveSessionWithAFocusFilterStaysInsideTheFocusedWorkspace() throws {
        let store = makeStore()
        let personal = store.addWorkspace(name: "personal")
        let work = store.addWorkspace(name: "work")
        let elsewhere = try #require(store.addSession(toWorkspace: personal.id, cwd: "/x"))
        let first = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let second = try #require(store.addSession(toWorkspace: work.id, cwd: "/b"))
        let closing = try #require(store.addSession(toWorkspace: work.id, cwd: "/c"))
        store.selectSession(first.id)
        store.selectSession(closing.id)
        store.setFocusedWorkspace(work.id)

        store.closeSession(closing.id)
        #expect(store.selectedSessionID == first.id) // the MRU survivor inside the focus filter
        #expect(store.selectedSessionID != second.id) // not the positional neighbor
        #expect(store.selectedSessionID != elsewhere.id)
        #expect(store.focusedWorkspaceID == work.id) // the filter survives the close
    }

    @Test func closeActiveSessionInFlaggedModeStaysWithinTheFlaggedSet() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let flagged = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let unflagged = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        let closing = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c"))
        store.setFlag(true, forSession: flagged.id)
        store.setFlag(true, forSession: closing.id)
        store.sidebarMode = .flagged
        store.selectSession(flagged.id)
        store.selectSession(unflagged.id) // more recent, but outside the flagged view
        store.selectSession(closing.id)

        store.closeSession(closing.id)
        #expect(store.selectedSessionID == flagged.id)
        #expect(store.selectedSessionID != unflagged.id) // the flagged filter scopes the MRU pick
    }

    @Test func closeActiveSessionWithAnEmptyScopedRecencyFallsBackToThePositionalTarget() throws {
        // a cold restore: nothing has been activated, so once the closing session is pruned the scoped
        // recency is empty and the pick is exactly today's positional neighbor.
        let store = makeStore()
        let wsID = UUID()
        let ids = [UUID(), UUID(), UUID()]
        let sessions = ids.enumerated().map { SessionSnapshot(id: $1, customName: nil, cwd: "/\($0)") }
        store.restore(from: Snapshot(selectedSessionID: ids[1],
                                     workspaces: [WorkspaceSnapshot(id: wsID, name: "work", sessions: sessions)]))
        #expect(store.sessionRecency.items == [ids[1]]) // only the restored selection

        store.closeSession(ids[1])
        #expect(store.selectedSessionID == ids[2]) // the session that shifted into the removed slot
    }

    @Test func softCloseActiveSessionPicksTheRecentSurvivorLikeTheHardClose() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let first = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        let neighbor = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c"))
        let closing = try #require(store.addSession(toWorkspace: ws.id, cwd: "/d"))
        store.selectSession(first.id)
        store.selectSession(closing.id)

        #expect(store.softCloseSession(closing.id, grace: 60))
        #expect(store.selectedSessionID == first.id) // the MRU survivor
        #expect(store.selectedSessionID != neighbor.id) // not the positional neighbor
    }

    @Test func softCloseSessionsNeverPicksAMemberOfTheClosingGroup() throws {
        // the soft-close paths deliberately leave the closing sessions in `sessionRecency` (undo needs
        // them back), so the MRU pick must be kept off them by the TREE-derived scope alone.
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let oldest = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let survivor = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        let alsoClosing = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c"))
        let closing = try #require(store.addSession(toWorkspace: ws.id, cwd: "/d"))
        store.selectSession(survivor.id)
        store.selectSession(alsoClosing.id)
        store.selectSession(closing.id)

        #expect(store.softCloseSessions([alsoClosing.id, closing.id], grace: 60))
        #expect(store.selectedSessionID == survivor.id) // the most recent survivor OUTSIDE the group
        #expect(store.selectedSessionID != oldest.id)
        // both closed sessions are more recent than `survivor` and still in the stack, yet unpickable
        #expect(store.sessionRecency.items.contains(closing.id))
        #expect(store.sessionRecency.items.contains(alsoClosing.id))
    }

    @Test func undoOfASoftCloseStillRestoresThePreviouslySelectedSession() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let other = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let closing = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        store.selectSession(other.id)
        store.selectSession(closing.id)

        #expect(store.softCloseSession(closing.id, grace: 60))
        #expect(store.selectedSessionID == other.id)

        let summary = try #require(store.pendingCloseSummary)
        #expect(store.undoPendingClose(summary.id))
        #expect(store.session(withID: closing.id) === closing)
        #expect(store.selectedSessionID == closing.id) // undo reselects what was closed
    }

    @Test func graceExpiryAfterASoftCloseLeavesTheSelectionAlone() async throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let survivor = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let closing = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        let surface = SpySurface()
        closing.surface = surface
        store.selectSession(survivor.id)
        store.selectSession(closing.id)

        #expect(store.softCloseSession(closing.id, grace: 0.01))
        #expect(store.selectedSessionID == survivor.id)
        // poll the teardown rather than a flat sleep: the grace timer can land late under parallel load
        for _ in 0..<200 {
            if surface.teardownCount == 1 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(surface.teardownCount == 1)
        #expect(store.selectedSessionID == survivor.id) // finalization must not re-run reselection
        #expect(!store.sessionRecency.items.contains(closing.id)) // finalize prunes it now
    }

    @Test func closeActiveSessionNeverClearsTheSelectionWhileSessionsSurvive() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        _ = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        _ = try #require(store.addSession(toWorkspace: work.id, cwd: "/b"))
        _ = try #require(store.addSession(toWorkspace: personal.id, cwd: "/x"))

        for remaining in stride(from: 3, through: 2, by: -1) {
            let active = try #require(store.selectedSessionID)
            store.closeSession(active)
            #expect(store.selectedSessionID != nil, "\(remaining - 1) sessions survive, selection must not go nil")
        }
        let last = try #require(store.selectedSessionID)
        store.closeSession(last)
        #expect(store.selectedSessionID == nil) // the tree is empty now
    }
}
