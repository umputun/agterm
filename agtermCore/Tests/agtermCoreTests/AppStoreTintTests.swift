import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreTintTests {
    @Test func setTintOnASessionReportsOnlyARealChange() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let red = SidebarTint(color: .red, parts: [.icon, .name])

        #expect(store.setTint(red, forSession: session.id))
        #expect(session.tint == red)
        #expect(!store.setTint(red, forSession: session.id))
        #expect(store.setTint(nil, forSession: session.id))
        #expect(session.tint == nil)
        #expect(!store.setTint(red, forSession: UUID()))
    }

    @Test func setTintOnAWorkspaceLeavesItsSessionsUntinted() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))

        #expect(store.setTint(SidebarTint(color: .red), forWorkspace: work.id))
        #expect(store.workspaces.first { $0.id == work.id }?.tint == SidebarTint(color: .red))
        #expect(session.tint == nil)
        #expect(!store.setTint(SidebarTint(color: .red), forWorkspace: work.id))
        #expect(!store.setTint(SidebarTint(color: .red), forWorkspace: UUID()))
    }

    @Test func batchColorKeepsEachRowsPlacementAndStartsUntintedRowsOnTheIcon() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let named = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let plain = try #require(store.addSession(toWorkspace: work.id, cwd: "/b"))
        store.setTint(SidebarTint(color: .green, parts: [.name]), forSession: named.id)

        store.setTintColor(.red, forSessions: [named.id, plain.id])

        #expect(named.tint == SidebarTint(color: .red, parts: [.name]))
        #expect(plain.tint == SidebarTint(color: .red, parts: [.icon]))

        store.setTintColor(nil, forSessions: [named.id, plain.id])
        #expect(named.tint == nil && plain.tint == nil)
    }

    @Test func batchPlacementKeepsEachRowsColorAndSkipsUntintedRows() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let red = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let blue = try #require(store.addSession(toWorkspace: work.id, cwd: "/b"))
        let plain = try #require(store.addSession(toWorkspace: work.id, cwd: "/c"))
        store.setTint(SidebarTint(color: .red), forSession: red.id)
        store.setTint(SidebarTint(color: .blue), forSession: blue.id)

        store.setTintParts([.icon, .name], forSessions: [red.id, blue.id, plain.id])

        #expect(red.tint == SidebarTint(color: .red, parts: [.icon, .name]))
        #expect(blue.tint == SidebarTint(color: .blue, parts: [.icon, .name]))
        #expect(plain.tint == nil)
    }

    @Test func creationTintIsSetBeforeTheFirstSave() throws {
        let (store, _, persistence) = makeStoreWithRecentClosed()
        let work = store.addWorkspace(name: "work", tint: SidebarTint(color: .orange, parts: [.name]))
        let session = try #require(store.addSession(toWorkspace: work.id, cwd: "/a", tint: SidebarTint(color: .red)))

        let saved = persistence.load()
        let workspace = try #require(saved.workspaces.first { $0.id == work.id })
        #expect(workspace.tint == SidebarTint(color: .orange, parts: [.name]))
        #expect(workspace.sessions.first { $0.id == session.id }?.tint == SidebarTint(color: .red))
    }

    @Test func tintsSurviveASaveAndReload() throws {
        let (store, _, persistence) = makeStoreWithRecentClosed()
        let work = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        store.setTint(SidebarTint(color: .purple, parts: [.icon, .name]), forSession: session.id)
        store.setTint(SidebarTint(color: .gray, parts: [.name]), forWorkspace: work.id)

        let reloaded = AppStore(persistence: persistence)
        reloaded.restore(from: persistence.load())

        #expect(reloaded.session(withID: session.id)?.tint == SidebarTint(color: .purple, parts: [.icon, .name]))
        #expect(reloaded.workspaces.first { $0.id == work.id }?.tint == SidebarTint(color: .gray, parts: [.name]))
    }

    @Test func duplicateDoesNotCopyTheTint() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        store.setTint(SidebarTint(color: .red), forSession: session.id)

        let copy = try #require(store.duplicateSession(session.id))

        #expect(copy.tint == nil)
    }

    @Test func undoingASessionCloseIntoARemovedWorkspaceRebuildsItWithItsTint() throws {
        let (store, _, _) = makeStoreWithRecentClosed()
        let keep = store.addWorkspace(name: "keep")
        let work = store.addWorkspace(name: "work", tint: SidebarTint(color: .red, parts: [.name]))
        _ = try #require(store.addSession(toWorkspace: keep.id, cwd: "/a"))
        let stray = try #require(store.addSession(toWorkspace: work.id, cwd: "/b", select: false))

        #expect(store.softCloseSession(stray.id, grace: 60))
        let sessionCloseID = try #require(store.pendingCloseSummary?.id)
        #expect(store.softRemoveWorkspace(work.id, grace: 60))

        #expect(store.undoPendingClose(sessionCloseID))
        #expect(store.workspaces.first { $0.id == work.id }?.tint == SidebarTint(color: .red, parts: [.name]))
    }

    @Test func reopeningASessionWhoseWorkspaceWasClosedRebuildsItWithItsTint() throws {
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        let keep = store.addWorkspace(name: "keep")
        let work = store.addWorkspace(name: "work", tint: SidebarTint(color: .blue))
        _ = try #require(store.addSession(toWorkspace: keep.id, cwd: "/a"))
        let stray = try #require(store.addSession(toWorkspace: work.id, cwd: "/b", select: false))
        _ = try #require(store.addSession(toWorkspace: work.id, cwd: "/c", select: false))

        #expect(store.softCloseSession(stray.id, grace: 60))
        store.finalizePendingClose(try #require(store.pendingCloseSummary?.id))
        #expect(store.softRemoveWorkspace(work.id, grace: 60))
        store.finalizePendingClose(try #require(store.pendingCloseSummary?.id))

        let item = try #require(recentClosed.load().first { $0.session?.snapshot.id == stray.id })
        #expect(store.restoreRecentClosed(item))
        #expect(store.workspaces.first { $0.id == work.id }?.tint == SidebarTint(color: .blue))
    }

    @Test func treeReportsTintAndPlacementAndOmitsThemWhenUntinted() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let tinted = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        _ = try #require(store.addSession(toWorkspace: work.id, cwd: "/b"))
        store.setTint(SidebarTint(color: .green, parts: [.name, .icon]), forSession: tinted.id)
        store.setTint(SidebarTint(color: .yellow, parts: [.name]), forWorkspace: work.id)

        let node = try #require(store.controlTree().workspaces.first { $0.id == work.id.uuidString })

        #expect(node.tint == "yellow")
        #expect(node.tintOn == ["name"])
        #expect(node.sessions[0].tint == "green")
        #expect(node.sessions[0].tintOn == ["icon", "name"])
        #expect(node.sessions[1].tint == nil && node.sessions[1].tintOn == nil)
        store.setTint(nil, forWorkspace: work.id)
        store.setTint(nil, forSession: tinted.id)
        let bare = try String(decoding: JSONEncoder().encode(store.controlTree()), as: UTF8.self)
        #expect(!bare.contains("\"tint\"") && !bare.contains("\"tintOn\""))
    }
}
