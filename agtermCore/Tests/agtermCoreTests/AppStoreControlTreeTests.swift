import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreControlTreeTests {
    @Test func controlTreeStampsOwnershipOnEveryNode() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let side = store.addWorkspace(name: "side")
        let first = try #require(store.addSession(toWorkspace: work.id, cwd: "/repo"))
        let second = try #require(store.addSession(toWorkspace: work.id, cwd: "/repo"))
        let third = try #require(store.addSession(toWorkspace: side.id, cwd: "/tmp"))

        let tree = store.controlTree(windowID: "win-1")

        #expect(tree.windowId == "win-1")
        let nodes = tree.workspaces.flatMap(\.sessions)
        #expect(nodes.allSatisfy { $0.windowId == "win-1" })
        let owners = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.workspaceId) })
        #expect(owners[first.id.uuidString] == work.id.uuidString)
        #expect(owners[second.id.uuidString] == work.id.uuidString)
        #expect(owners[third.id.uuidString] == side.id.uuidString)
    }

    @Test func controlTreeOmitsOwnershipWithoutAWindow() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        _ = try #require(store.addSession(toWorkspace: work.id, cwd: "/repo"))

        let tree = store.controlTree()

        #expect(tree.windowId == nil)
        let node = try #require(tree.workspaces.flatMap(\.sessions).first)
        #expect(node.windowId == nil)
        #expect(node.workspaceId == nil)
    }

    @Test func controlTreeFollowsASessionToItsNewWorkspace() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let side = store.addWorkspace(name: "side")
        let session = try #require(store.addSession(toWorkspace: work.id, cwd: "/repo"))

        store.moveSession(session.id, toWorkspace: side.id)

        let node = try #require(store.controlTree(windowID: "win-1")
            .workspaces.flatMap(\.sessions).first { $0.id == session.id.uuidString })
        #expect(node.workspaceId == side.id.uuidString)
    }
}
