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
        b.hasSplit = true
        let (members, dropped) = store.dashboardMembers(for: [a.id, b.id], limit: 9)
        #expect(dropped == 0)
        #expect(members == [DashboardMember(session: a.id, surface: .primary),
                            DashboardMember(session: b.id, surface: .primary),
                            DashboardMember(session: b.id, surface: .split)])
        #expect(members.map(\.controlRef) ==
                ["\(a.id.uuidString):left", "\(b.id.uuidString):left", "\(b.id.uuidString):right"])
    }

    @Test func dashboardMembersCapsAtLimitAndReportsDropped() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let ids = (0..<5).map { store.addSession(toWorkspace: ws.id, cwd: "/\($0)")!.id }
        let (members, dropped) = store.dashboardMembers(for: ids, limit: 3)
        #expect(members == ids.prefix(3).map { DashboardMember(session: $0, surface: .primary) })
        #expect(dropped == 2)
    }

    @Test func dashboardMembersSkipsUnresolvedIDs() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let (members, dropped) = store.dashboardMembers(for: [UUID(), a.id, UUID()], limit: 9)
        #expect(dropped == 0)
        #expect(members == [DashboardMember(session: a.id, surface: .primary)])
    }

    @Test func dashboardMRUMembersFollowsRecencyOrderAndExpands() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        b.hasSplit = true
        store.selectSession(a.id)
        store.selectSession(b.id)
        #expect(store.dashboardMRUMembers(limit: 9) == [DashboardMember(session: b.id, surface: .primary),
                                                        DashboardMember(session: b.id, surface: .split),
                                                        DashboardMember(session: a.id, surface: .primary)])
    }

    @Test func dashboardMRUMembersEmptyWhenNoSessions() {
        let store = makeStore()
        #expect(store.dashboardMRUMembers(limit: 9).isEmpty)
    }

    @Test func explicitPaneTakesThatCellAlone() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        a.hasSplit = true
        let left = store.dashboardMembers(for: [ResolvedDashboardTarget(session: a.id, pane: .primary)], limit: 9)
        let right = store.dashboardMembers(for: [ResolvedDashboardTarget(session: a.id, pane: .split)], limit: 9)
        #expect(left.members == [DashboardMember(session: a.id, surface: .primary)])
        #expect(right.members == [DashboardMember(session: a.id, surface: .split)])
        #expect(left.dropped == 0)
        #expect(right.dropped == 0)
    }

    @Test func mixedBareAndPaneTargetsKeepRequestOrder() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        a.hasSplit = true
        b.hasSplit = true
        let (members, dropped) = store.dashboardMembers(
            for: [ResolvedDashboardTarget(session: a.id, pane: .primary),
                  ResolvedDashboardTarget(session: b.id, pane: .split)], limit: 9)
        #expect(dropped == 0)
        #expect(members.map(\.controlRef) == ["\(a.id.uuidString):left", "\(b.id.uuidString):right"])
    }

    @Test func bareIDAndPaneRefForOneSessionCollapse() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        a.hasSplit = true
        let (members, dropped) = store.dashboardMembers(
            for: [ResolvedDashboardTarget(session: a.id, pane: nil),
                  ResolvedDashboardTarget(session: a.id, pane: .primary)], limit: 9)
        #expect(dropped == 0)
        #expect(members == [DashboardMember(session: a.id, surface: .primary),
                            DashboardMember(session: a.id, surface: .split)])
    }

    @Test func repeatedPaneRefCollapses() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        a.hasSplit = true
        let (members, _) = store.dashboardMembers(
            for: [ResolvedDashboardTarget(session: a.id, pane: .split),
                  ResolvedDashboardTarget(session: a.id, pane: .split)], limit: 9)
        #expect(members == [DashboardMember(session: a.id, surface: .split)])
    }

    @Test func paneTargetsStillCapAndReportDropped() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let ids = (0..<5).map { store.addSession(toWorkspace: ws.id, cwd: "/\($0)")!.id }
        let targets = ids.map { ResolvedDashboardTarget(session: $0, pane: .primary) }
        let (members, dropped) = store.dashboardMembers(for: targets, limit: 3)
        #expect(members == ids.prefix(3).map { DashboardMember(session: $0, surface: .primary) })
        #expect(dropped == 2)
    }

    @Test func paneTargetForUnknownSessionIsSkipped() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let (members, _) = store.dashboardMembers(
            for: [ResolvedDashboardTarget(session: UUID(), pane: .primary),
                  ResolvedDashboardTarget(session: a.id, pane: .primary)], limit: 9)
        #expect(members == [DashboardMember(session: a.id, surface: .primary)])
    }
}
