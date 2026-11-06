import Foundation
import Testing
@testable import agtermCore

struct ControlRecentTests {
    private let workspaceID = UUID()
    private let first = SessionSnapshot(id: UUID(), customName: "a", cwd: "/a")
    private let second = SessionSnapshot(id: UUID(), customName: "b", cwd: "/b")

    private func sessionItem(id: UUID = UUID()) -> RecentClosedItem {
        RecentClosedItem(id: id, kind: .session, title: "a", subtitle: "project",
                         closedAt: Date(timeIntervalSince1970: 1_700_000_000),
                         session: RecentClosedSession(workspaceID: workspaceID, workspaceName: "project",
                                                      workspaceIndex: 0, sessionIndex: 1, snapshot: first))
    }

    private func workspaceItem(id: UUID = UUID()) -> RecentClosedItem {
        RecentClosedItem(id: id, kind: .workspace, title: "project", subtitle: "2 sessions",
                         closedAt: Date(timeIntervalSince1970: 1_700_000_500),
                         workspace: RecentClosedWorkspace(
                            snapshot: WorkspaceSnapshot(id: workspaceID, name: "project", sessions: [first, second]),
                            selectedSessionID: second.id))
    }

    @Test func aSessionEntryProjectsItsParentWorkspaceAndOneSession() {
        let item = sessionItem()

        #expect(ControlRecentItem(item) == ControlRecentItem(
            id: item.id.uuidString, kind: "session", title: "a", subtitle: "project", closedAt: 1_700_000_000,
            workspaceID: workspaceID.uuidString, sessionIDs: [first.id.uuidString]))
    }

    @Test func aParentEntryListsItsCompanionsAfterIt() {
        let item = RecentClosedItem(
            id: UUID(), kind: .session, title: "a", subtitle: "project", closedAt: Date(timeIntervalSince1970: 0),
            session: RecentClosedSession(workspaceID: workspaceID, workspaceName: "project", workspaceIndex: 0,
                                         sessionIndex: 0, snapshot: first, companions: [second]))

        #expect(ControlRecentItem(item).sessionIDs == [first.id.uuidString, second.id.uuidString])
    }

    @Test func aWorkspaceEntryProjectsItselfAndEverySnapshotSession() {
        let item = workspaceItem()

        #expect(ControlRecentItem(item) == ControlRecentItem(
            id: item.id.uuidString, kind: "workspace", title: "project", subtitle: "2 sessions",
            closedAt: 1_700_000_500, workspaceID: workspaceID.uuidString,
            sessionIDs: [first.id.uuidString, second.id.uuidString]))
    }

    @Test func payloadsRoundTripThroughTheWire() throws {
        let item = ControlRecentItem(sessionItem())
        let result = ControlResult(recent: [item],
                                   recentOpen: ControlRecentOpen(item: item, window: "W1", complete: false))

        let decoded = try JSONDecoder().decode(ControlResult.self, from: JSONEncoder().encode(result))

        #expect(decoded == result)
    }

    @Test func noTargetResolvesTheNewestEntry() {
        let newest = sessionItem(), older = workspaceItem()

        #expect(RecentClosedTarget.resolve(nil, in: [newest, older]) == .success(newest.id))
    }

    @Test func aTargetResolvesByExactIdOrUniquePrefix() {
        let a = sessionItem(id: UUID(uuidString: "AAAA0000-0000-0000-0000-000000000001")!)
        let b = workspaceItem(id: UUID(uuidString: "BBBB0000-0000-0000-0000-000000000002")!)

        #expect(RecentClosedTarget.resolve("bbbb", in: [a, b]) == .success(b.id))
        #expect(RecentClosedTarget.resolve(a.id.uuidString.lowercased(), in: [a, b]) == .success(a.id))
    }

    @Test func anEmptyListIsRefusedWhateverTheTarget() {
        #expect(RecentClosedTarget.resolve(nil, in: []) == .failure(RecentClosedTargetError("no recently closed items")))
        #expect(RecentClosedTarget.resolve("ab", in: []) == .failure(RecentClosedTargetError("no recently closed items")))
    }

    @Test func unknownAmbiguousAndActiveTargetsAreRefused() {
        let a = sessionItem(id: UUID(uuidString: "AAAA0000-0000-0000-0000-000000000001")!)
        let b = workspaceItem(id: UUID(uuidString: "AAAA0000-0000-0000-0000-000000000002")!)

        #expect(RecentClosedTarget.resolve("cccc", in: [a, b])
            == .failure(RecentClosedTargetError("no such recent item: cccc")))
        #expect(RecentClosedTarget.resolve("active", in: [a, b])
            == .failure(RecentClosedTargetError("no such recent item: active")))
        #expect(RecentClosedTarget.resolve("aaaa", in: [a, b])
            == .failure(RecentClosedTargetError("ambiguous recent item prefix 'aaaa' → AAAA0000, AAAA0000")))
    }
}
