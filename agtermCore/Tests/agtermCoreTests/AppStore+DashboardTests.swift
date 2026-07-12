import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreDashboardTests {
    @Test func dashboardMembersExpandsSessionsToPaneCells() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        b.hasSplit = true // a split session expands into two cells (primary + split)
        let (members, dropped) = store.dashboardMembers(for: [a.id, b.id], limit: 9)
        #expect(dropped == 0)
        #expect(members == [DashboardMember(session: a.id, surface: .primary),
                            DashboardMember(session: b.id, surface: .primary),
                            DashboardMember(session: b.id, surface: .split)])
        // control refs: a non-split session is one `:left` cell, a split session is `:left` + `:right`.
        #expect(members.map(\.controlRef) ==
                ["\(a.id.uuidString):left", "\(b.id.uuidString):left", "\(b.id.uuidString):right"])
    }

    @Test func dashboardMembersCapsAtLimitAndReportsDropped() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let ids = (0..<5).map { store.addSession(toWorkspace: ws.id, cwd: "/\($0)")!.id }
        let (members, dropped) = store.dashboardMembers(for: ids, limit: 3)
        #expect(members == ids.prefix(3).map { DashboardMember(session: $0, surface: .primary) }) // first 3 kept
        #expect(dropped == 2) // two panes past the cap
    }

    @Test func dashboardMembersSkipsUnresolvedIDs() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let (members, dropped) = store.dashboardMembers(for: [UUID(), a.id, UUID()], limit: 9)
        #expect(dropped == 0)
        #expect(members == [DashboardMember(session: a.id, surface: .primary)]) // only the real id yields a cell
    }

    @Test func dashboardMRUMembersFollowsRecencyOrderAndExpands() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        b.hasSplit = true
        store.selectSession(a.id)
        store.selectSession(b.id) // most-recent-first recency: [b, a]
        #expect(store.dashboardMRUMembers(limit: 9) == [DashboardMember(session: b.id, surface: .primary),
                                                        DashboardMember(session: b.id, surface: .split),
                                                        DashboardMember(session: a.id, surface: .primary)])
    }

    @Test func dashboardMRUMembersEmptyWhenNoSessions() {
        let store = makeStore()
        #expect(store.dashboardMRUMembers(limit: 9).isEmpty) // no sessions → no recent members
    }
}
