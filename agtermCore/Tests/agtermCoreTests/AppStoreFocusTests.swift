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
        #expect(store.focusedWorkspaceID == nil)
        store.setFocusedWorkspace(work.id)
        #expect(store.focusedWorkspaceID == work.id)
        store.setFocusedWorkspace(nil)
        #expect(store.focusedWorkspaceID == nil)
    }

    @Test func visibleWorkspacesReturnsAllWhenUnfocused() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        #expect(store.visibleWorkspaces.map(\.id) == [work.id, personal.id])
    }

    @Test func visibleWorkspacesReturnsOneWhenFocused() {
        let store = makeStore()
        _ = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        store.setFocusedWorkspace(personal.id)
        #expect(store.visibleWorkspaces.map(\.id) == [personal.id])
    }

    @Test func visibleWorkspacesFallsBackToAllForStaleFocusID() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        store.focusedWorkspaceID = UUID() // stale id, no matching workspace
        #expect(store.visibleWorkspaces.map(\.id) == [work.id, personal.id])
    }

    @Test func workspaceFocusPrunesRowsOutsideFocusedWorkspace() {
        let store = makeStore()
        let ws1 = store.addWorkspace(name: "one")
        let ws2 = store.addWorkspace(name: "two")
        let a = try! #require(store.addSession(toWorkspace: ws1.id, cwd: "/a"))
        let b = try! #require(store.addSession(toWorkspace: ws2.id, cwd: "/b"))
        store.setSidebarSelection([a.id, b.id])

        store.setFocusedWorkspace(ws2.id)

        #expect(store.sidebarSelectionIDs == [b.id])
        store.setFocusedWorkspace(nil)
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
        store.setFocusedWorkspace(nil)
        #expect(store.controlTree().workspaces.allSatisfy { $0.focused == nil })
    }
}
