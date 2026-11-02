import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreRememberedFolderTests {
    @Test func normalizedFolderExpandsTildeAndStandardizes() {
        let home = NSHomeDirectory()
        #expect(Workspace.normalizedFolder("~/proj/") == "\(home)/proj")
        #expect(Workspace.normalizedFolder("/a/./b/../c/") == "/a/c")
        #expect(Workspace.normalizedFolder("  ") == nil)
    }

    @Test func anyLocalPaneReportSetsItsWorkspaceFolderAndItSurvivesTheLastClose() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let other = store.addWorkspace(name: "other")
        let first = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let second = try #require(store.addSession(toWorkspace: work.id, cwd: "/b"))

        store.rememberFolder("/proj/api/", reportedBy: first.id)
        #expect(store.rememberedFolder(ofWorkspace: work.id) == "/proj/api")
        store.rememberFolder("/proj/web", reportedBy: second.id)
        #expect(store.rememberedFolder(ofWorkspace: work.id) == "/proj/web")
        #expect(store.rememberedFolder(ofWorkspace: other.id) == nil)

        store.closeSession(first.id)
        store.closeSession(second.id)
        #expect(store.rememberedFolder(ofWorkspace: work.id) == "/proj/web")
    }

    @Test func aRemoteSessionNeverSetsTheFolder() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let remote = try #require(store.addSession(toWorkspace: work.id, cwd: "/r", remoteHost: "buildbox"))

        store.rememberFolder("/home/me", reportedBy: remote.id)

        #expect(store.rememberedFolder(ofWorkspace: work.id) == nil)
    }

    @Test func workspaceMatchIsIdenticalAndFirstInSidebarOrder() throws {
        let store = makeStore()
        let one = store.addWorkspace(name: "one")
        let two = store.addWorkspace(name: "two")
        let three = store.addWorkspace(name: "three")
        store.rememberFolder("/proj/api/src", reportedBy: try #require(store.addSession(toWorkspace: one.id, cwd: "/")).id)
        store.rememberFolder("/proj/api", reportedBy: try #require(store.addSession(toWorkspace: two.id, cwd: "/")).id)
        store.rememberFolder("/proj/api", reportedBy: try #require(store.addSession(toWorkspace: three.id, cwd: "/")).id)

        #expect(store.workspaceID(rememberingFolder: "/proj/api/") == two.id)
        #expect(store.workspaceID(rememberingFolder: "/proj") == nil)
        #expect(store.workspaceID(rememberingFolder: "") == nil)
    }

    @Test func folderRoundTripsThroughTheSnapshotAndIsOmittedWhenNil() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        _ = store.addWorkspace(name: "empty")
        let session = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        store.rememberFolder("/proj", reportedBy: session.id)

        let data = try JSONEncoder().encode(store.snapshot())
        #expect(String(decoding: data, as: UTF8.self).components(separatedBy: "rememberedFolder").count == 2)

        let restored = makeStore()
        restored.restore(from: try JSONDecoder().decode(Snapshot.self, from: data))
        #expect(restored.workspaces.map(\.rememberedFolder) == ["/proj", nil])
    }

    @Test func treeReportsTheFolderAndOmitsItWhenNil() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        _ = store.addWorkspace(name: "empty")
        store.rememberFolder("/proj", reportedBy: try #require(store.addSession(toWorkspace: work.id, cwd: "/a")).id)

        let nodes = store.controlTree().workspaces
        #expect(nodes.map(\.rememberedFolder) == ["/proj", nil])
        #expect(!String(decoding: try JSONEncoder().encode(nodes[1]), as: UTF8.self).contains("rememberedFolder"))
    }
}
