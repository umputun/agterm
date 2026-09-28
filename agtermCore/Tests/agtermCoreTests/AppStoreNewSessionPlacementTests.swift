import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreNewSessionPlacementTests {
    @Test func afterCurrentInsertsBehindTheSelectedSession() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let one = try #require(store.addSession(toWorkspace: ws.id, cwd: "/1"))
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/2"))
        store.selectSession(one.id)

        #expect(store.newSessionInsertionIndex(inWorkspace: ws.id, placement: .afterCurrent) == 1)
    }

    @Test func endAlwaysAppends() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let one = try #require(store.addSession(toWorkspace: ws.id, cwd: "/1"))
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/2"))
        store.selectSession(one.id)

        #expect(store.newSessionInsertionIndex(inWorkspace: ws.id, placement: .end) == nil)
    }

    @Test func afterCurrentAppendsIntoAWorkspaceWithoutTheSelection() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let other = store.addWorkspace(name: "other")
        let selected = try #require(store.addSession(toWorkspace: work.id, cwd: "/1"))
        _ = try #require(store.addSession(toWorkspace: other.id, cwd: "/x"))
        store.selectSession(selected.id)

        #expect(store.newSessionInsertionIndex(inWorkspace: other.id, placement: .afterCurrent) == nil)
    }

    @Test func afterCurrentAppendsWithNoSelection() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/1"))
        store.selectSession(nil)

        #expect(store.newSessionInsertionIndex(inWorkspace: ws.id, placement: .afterCurrent) == nil)
    }

    @Test func chainedAfterCurrentInsertsKeepCreationOrder() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let one = try #require(store.addSession(toWorkspace: ws.id, cwd: "/1"))
        let last = try #require(store.addSession(toWorkspace: ws.id, cwd: "/9"))
        store.selectSession(one.id)

        for cwd in ["/a", "/b"] {
            let index = store.newSessionInsertionIndex(inWorkspace: ws.id, placement: .afterCurrent)
            _ = try #require(store.addSession(toWorkspace: ws.id, cwd: cwd, at: index))
        }

        let sessions = try #require(store.workspaces.first { $0.id == ws.id }).sessions
        #expect(sessions.map(\.initialCwd) == ["/1", "/a", "/b", "/9"])
        #expect(sessions.last?.id == last.id)
    }
}
