import Foundation
import Testing
@testable import agtermCore

/// Closing the ACTIVE session returns to the most-recently-active SURVIVING session, scoped to the
/// closing session's workspace ∩ the VISIBLE set — the flagged list in `.flagged` mode, the marked
/// workspaces' sessions while the focus filter applies — widening through everything visible and then
/// the whole tree, with a positional walk as the last fallback (GitHub Discussion #147).
@MainActor
struct AppStoreCloseReselectionTests {
    @Test func closeActiveSessionInsertedAfterCurrentReturnsToTheSessionItCameFrom() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let one = try #require(store.addSession(toWorkspace: ws.id, cwd: "/1"))
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/2"))
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/3"))
        store.selectSession(one.id)
        let four = try #require(store.addSession(toWorkspace: ws.id, cwd: "/4", at: 1))
        #expect(store.selectedSessionID == four.id)

        store.closeSession(four.id)
        #expect(store.selectedSessionID == one.id)
    }

    @Test func closeActiveSessionAppendedAtTheEndReturnsToTheSessionItCameFrom() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let one = try #require(store.addSession(toWorkspace: ws.id, cwd: "/1"))
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/2"))
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/3"))
        store.selectSession(one.id)
        let four = try #require(store.addSession(toWorkspace: ws.id, cwd: "/4"))

        store.closeSession(four.id)
        #expect(store.selectedSessionID == one.id)
    }

    @Test func closeActiveSessionPrefersTheRecentSurvivorOverThePositionalNeighbor() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let first = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let second = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c"))
        let fourth = try #require(store.addSession(toWorkspace: ws.id, cwd: "/d"))
        store.selectSession(first.id)
        store.selectSession(second.id)
        store.selectSession(fourth.id)

        store.closeSession(fourth.id)
        #expect(store.selectedSessionID == second.id)
    }

    @Test func closeActiveSessionIgnoresAMoreRecentSessionInAnotherWorkspace() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let inWork = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let closing = try #require(store.addSession(toWorkspace: work.id, cwd: "/b"))
        let elsewhere = try #require(store.addSession(toWorkspace: personal.id, cwd: "/x"))
        store.selectSession(inWork.id)
        store.selectSession(elsewhere.id)
        store.selectSession(closing.id)

        store.closeSession(closing.id)
        #expect(store.selectedSessionID == inWork.id)
        #expect(store.focusedWorkspaceIDs.isEmpty && !store.focusEnabled)
    }

    @Test func closeActiveSessionEmptyingItsWorkspacePicksTheRecentSurvivorElsewhere() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let scratch = store.addWorkspace(name: "scratch")
        _ = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let cameFrom = try #require(store.addSession(toWorkspace: work.id, cwd: "/b"))
        let onlyInScratch = try #require(store.addSession(toWorkspace: scratch.id, cwd: "/x"))
        store.selectSession(cameFrom.id)
        store.selectSession(onlyInScratch.id)

        store.closeSession(onlyInScratch.id)
        #expect(store.workspaces[1].sessions.isEmpty)
        #expect(store.selectedSessionID == cameFrom.id)
    }

    @Test func closeActiveSessionWithAFocusFilterStaysInsideTheFocusedWorkspace() throws {
        let store = makeStore()
        let personal = store.addWorkspace(name: "personal")
        let work = store.addWorkspace(name: "work")
        _ = try #require(store.addSession(toWorkspace: personal.id, cwd: "/x"))
        let first = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        _ = try #require(store.addSession(toWorkspace: work.id, cwd: "/b"))
        let closing = try #require(store.addSession(toWorkspace: work.id, cwd: "/c"))
        store.selectSession(first.id)
        store.selectSession(closing.id)
        store.setFocusedWorkspace(work.id)

        store.closeSession(closing.id)
        #expect(store.selectedSessionID == first.id)
        #expect(store.focusedWorkspaceIDs == [work.id] && store.focusEnabled)
    }

    @Test func closeTheFocusedWorkspacesLastSessionPicksTheRecentSurvivorElsewhere() throws {
        let store = makeStore()
        let personal = store.addWorkspace(name: "personal")
        let work = store.addWorkspace(name: "work")
        _ = try #require(store.addSession(toWorkspace: personal.id, cwd: "/first"))
        let cameFrom = try #require(store.addSession(toWorkspace: personal.id, cwd: "/mru"))
        let onlyInWork = try #require(store.addSession(toWorkspace: work.id, cwd: "/only"))
        store.selectSession(cameFrom.id)
        store.selectSession(onlyInWork.id)
        store.setFocusedWorkspace(work.id)

        store.closeSession(onlyInWork.id)
        #expect(store.workspaces[1].sessions.isEmpty)
        #expect(store.selectedSessionID == cameFrom.id)
        #expect(store.focusedWorkspaceIDs == [work.id] && !store.focusEnabled)
    }

    @Test func closeUnderAFocusFilterStaysInsideTheMarkedSet() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let survivor = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let closing = try #require(store.addSession(toWorkspace: work.id, cwd: "/c"))
        let elsewhere = try #require(store.addSession(toWorkspace: personal.id, cwd: "/x"))
        store.selectSession(survivor.id)
        store.selectSession(elsewhere.id)
        store.selectSession(closing.id)
        store.setFocusedWorkspace(work.id)
        #expect(store.selectedSessionID == closing.id)

        store.closeSession(closing.id)
        #expect(store.selectedSessionID == survivor.id)
        #expect(store.focusedWorkspaceIDs == [work.id] && store.focusEnabled)
    }

    @Test func closeInAMarkedWorkspaceCrossesToTheOtherMemberNotAnUnmarkedSurvivor() throws {
        // `unmarked` is deliberately more recent than `otherMember`: an unscoped MRU takes it.
        let store = makeStore()
        let first = store.addWorkspace(name: "first")
        let second = store.addWorkspace(name: "second")
        let outside = store.addWorkspace(name: "outside")
        let closing = try #require(store.addSession(toWorkspace: first.id, cwd: "/only"))
        let otherMember = try #require(store.addSession(toWorkspace: second.id, cwd: "/member", select: false))
        let unmarked = try #require(store.addSession(toWorkspace: outside.id, cwd: "/stray", select: false))
        store.selectSession(otherMember.id)
        store.selectSession(unmarked.id)
        store.selectSession(closing.id)
        store.setFocusMembership(first.id, member: true)
        store.setFocusMembership(second.id, member: true)
        store.setFocusEnabled(true)

        store.closeSession(closing.id)
        #expect(store.workspaces[0].sessions.isEmpty)
        #expect(store.selectedSessionID == otherMember.id)
        #expect(store.focusedWorkspaceIDs == [first.id, second.id] && store.focusEnabled)
    }

    @Test func closeUnderAFocusFilterWithNoRecencyKeepsThePositionalPickInsideTheSet() throws {
        // the unmarked workspace sits between the emptied one and the other marked one, so the picks differ.
        let store = makeStore()
        let wsClosing = UUID(), wsUnmarked = UUID(), wsOtherMember = UUID()
        let closing = UUID(), outside = UUID(), inSet = UUID()
        store.restore(from: Snapshot(selectedSessionID: closing, workspaces: [
            WorkspaceSnapshot(id: wsClosing, name: "closing", sessions: [
                SessionSnapshot(id: closing, customName: nil, cwd: "/closing"),
            ]),
            WorkspaceSnapshot(id: wsUnmarked, name: "unmarked", sessions: [
                SessionSnapshot(id: outside, customName: nil, cwd: "/outside"),
            ]),
            WorkspaceSnapshot(id: wsOtherMember, name: "member", sessions: [
                SessionSnapshot(id: inSet, customName: nil, cwd: "/inset"),
            ]),
        ], focusedWorkspaceIDs: [wsClosing, wsOtherMember], focusEnabled: true))
        #expect(store.sessionRecency.items == [closing])

        store.closeSession(closing)
        #expect(store.selectedSessionID == inSet)
        #expect(store.focusedWorkspaceIDs == [wsClosing, wsOtherMember] && store.focusEnabled)
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
        store.selectSession(unflagged.id)
        store.selectSession(closing.id)

        store.closeSession(closing.id)
        #expect(store.selectedSessionID == flagged.id)
    }

    @Test func closeActiveSessionInFlaggedModeCrossesWorkspacesRatherThanLeavingTheFlaggedSet() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let unflagged = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let closing = try #require(store.addSession(toWorkspace: work.id, cwd: "/b"))
        let flaggedElsewhere = try #require(store.addSession(toWorkspace: personal.id, cwd: "/x"))
        store.setFlag(true, forSession: closing.id)
        store.setFlag(true, forSession: flaggedElsewhere.id)
        store.sidebarMode = .flagged
        store.selectSession(flaggedElsewhere.id)
        store.selectSession(unflagged.id)
        store.selectSession(closing.id)

        store.closeSession(closing.id)
        #expect(store.selectedSessionID == flaggedElsewhere.id)
        #expect(store.flaggedSessions.map(\.id).contains(try #require(store.selectedSessionID)))
    }

    @Test func closeActiveSessionInFlaggedModeWithAnEmptyScopedRecencyStaysWithinTheFlaggedSet() throws {
        let store = makeStore()
        let wsID = UUID()
        let ids = [UUID(), UUID(), UUID()]
        let sessions = [SessionSnapshot(id: ids[0], customName: nil, cwd: "/a", flagged: true),
                        SessionSnapshot(id: ids[1], customName: nil, cwd: "/b", flagged: true),
                        SessionSnapshot(id: ids[2], customName: nil, cwd: "/c")]
        store.restore(from: Snapshot(selectedSessionID: ids[1],
                                     workspaces: [WorkspaceSnapshot(id: wsID, name: "work", sessions: sessions)],
                                     sidebarMode: .flagged))
        #expect(store.sessionRecency.items == [ids[1]])

        store.closeSession(ids[1])
        #expect(store.selectedSessionID == ids[0])
        #expect(store.flaggedSessions.map(\.id).contains(try #require(store.selectedSessionID)))
    }

    @Test func closeActiveSessionInFlaggedModeWithAnEmptyScopedRecencyPicksTheNEARESTFlaggedSurvivor() throws {
        let store = makeStore()
        let wsID = UUID()
        let ids = [UUID(), UUID(), UUID()]
        let sessions = ids.map { SessionSnapshot(id: $0, customName: nil, cwd: "/\($0)", flagged: true) }
        store.restore(from: Snapshot(selectedSessionID: ids[1],
                                     workspaces: [WorkspaceSnapshot(id: wsID, name: "work", sessions: sessions)],
                                     sidebarMode: .flagged))
        #expect(store.sessionRecency.items == [ids[1]])

        store.closeSession(ids[1])
        #expect(store.selectedSessionID == ids[2])
    }

    @Test func closeTheWorkspacesLastFlaggedSessionWithAnEmptyRecencyPicksTheADJACENTFlaggedRow() throws {
        let store = makeStore()
        let first = UUID(), last = UUID()
        let ids = (0..<4).map { _ in UUID() }
        let flaggedElsewhere = [SessionSnapshot(id: ids[0], customName: nil, cwd: "/a", flagged: true),
                                SessionSnapshot(id: ids[1], customName: nil, cwd: "/b", flagged: true)]
        let closing = [SessionSnapshot(id: ids[2], customName: nil, cwd: "/c"),
                       SessionSnapshot(id: ids[3], customName: nil, cwd: "/d", flagged: true)]
        store.restore(from: Snapshot(selectedSessionID: ids[3],
                                     workspaces: [WorkspaceSnapshot(id: first, name: "work", sessions: flaggedElsewhere),
                                                  WorkspaceSnapshot(id: last, name: "personal", sessions: closing)],
                                     sidebarMode: .flagged))
        #expect(store.sessionRecency.items == [ids[3]])

        store.closeSession(ids[3])
        #expect(store.selectedSessionID == ids[1])
    }

    @Test func closeTheLastFlaggedSessionWidensToTheWholeTree() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let recentSurvivor = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let closing = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c"))
        store.setFlag(true, forSession: closing.id)
        store.sidebarMode = .flagged
        store.selectSession(recentSurvivor.id)
        store.selectSession(closing.id)

        store.closeSession(closing.id)
        #expect(store.flaggedSessions.isEmpty)
        #expect(store.selectedSessionID == recentSurvivor.id)
    }

    @Test func closeActiveSessionWithAnEmptyScopedRecencyFallsBackToThePositionalTarget() throws {
        let store = makeStore()
        let wsID = UUID()
        let ids = [UUID(), UUID(), UUID()]
        let sessions = ids.enumerated().map { SessionSnapshot(id: $1, customName: nil, cwd: "/\($0)") }
        store.restore(from: Snapshot(selectedSessionID: ids[1],
                                     workspaces: [WorkspaceSnapshot(id: wsID, name: "work", sessions: sessions)]))
        #expect(store.sessionRecency.items == [ids[1]])

        store.closeSession(ids[1])
        #expect(store.selectedSessionID == ids[2])
    }

    @Test func softCloseActiveSessionPicksTheRecentSurvivorLikeTheHardClose() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let first = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c"))
        let closing = try #require(store.addSession(toWorkspace: ws.id, cwd: "/d"))
        store.selectSession(first.id)
        store.selectSession(closing.id)

        #expect(store.softCloseSession(closing.id, grace: 60))
        #expect(store.selectedSessionID == first.id)
    }

    @Test func softCloseActiveSessionWithAnEmptyScopedRecencyFallsBackToThePositionalTarget() throws {
        let store = makeStore()
        let wsID = UUID()
        let ids = [UUID(), UUID(), UUID()]
        let sessions = ids.enumerated().map { SessionSnapshot(id: $1, customName: nil, cwd: "/\($0)") }
        store.restore(from: Snapshot(selectedSessionID: ids[1],
                                     workspaces: [WorkspaceSnapshot(id: wsID, name: "work", sessions: sessions)]))

        #expect(store.softCloseSession(ids[1], grace: 60))
        #expect(store.selectedSessionID == ids[2])
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
        store.selectSession(oldest.id)
        store.selectSession(survivor.id)
        store.selectSession(alsoClosing.id)
        store.selectSession(closing.id)

        #expect(store.softCloseSessions([alsoClosing.id, closing.id], grace: 60))
        #expect(store.selectedSessionID == survivor.id)
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
        #expect(store.selectedSessionID == closing.id)
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
        #expect(store.selectedSessionID == survivor.id)
        #expect(!store.sessionRecency.items.contains(closing.id))
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
        #expect(store.selectedSessionID == nil)
    }
}
