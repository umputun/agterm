import Foundation
import Testing
@testable import agtermCore

@MainActor
struct SidebarSelectionTests {
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
