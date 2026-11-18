import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreFollowCompanionsTests {
    let store = makeStore()

    private func attachedRow(origin: String = "o1") throws -> Session {
        try addAttachedRow(to: store, workspace: store.workspaces.first?.id ?? store.addWorkspace(name: "work").id, origin: origin)
    }

    private func list(_ members: [(UUID, PresentationCompanions.Member.Kind)]) -> PresentationCompanions {
        PresentationCompanions(members: members.map { PresentationCompanions.Member(id: $0.0, kind: $0.1) })
    }

    @Test func aBaselinedRowAttachesNewMembersInOriginOrderAndMarksOnlyTheOnesShownHere() throws {
        let row = try attachedRow()
        let known = UUID()
        let page = UUID()
        let shell = UUID()
        let shown = UUID()
        store.baselineCompanions(list([(known, .terminal)]), forSession: row.id)

        let follow = store.companionsToFollow(list([(page, .page), (known, .terminal), (shown, .terminal), (shell, .terminal)]),
                                              forSession: row.id, shown: [shown.uuidString.lowercased()])

        #expect(follow.attach == list([(page, .page), (shell, .terminal)]).members)
        #expect(follow.markOnly == [shown.uuidString])
    }

    @Test func aRowNotBaselinedFollowsNothing() throws {
        let row = try attachedRow()

        let follow = store.companionsToFollow(list([(UUID(), .terminal)]), forSession: row.id, shown: [])

        #expect(follow == CompanionFollow(attach: [], markOnly: []))
    }

    @Test func aMemberMovedInFromAnotherParentIsNewAndEachCopyKeepsItsOwnSet() throws {
        let row = try attachedRow()
        let copy = try attachedRow()
        let moved = UUID()
        store.baselineCompanions(list([]), forSession: row.id)
        store.baselineCompanions(list([(moved, .terminal)]), forSession: copy.id)

        #expect(store.companionsToFollow(list([(moved, .terminal)]), forSession: row.id, shown: []).attach.map(\.id) == [moved])
        #expect(store.companionsToFollow(list([(moved, .terminal)]), forSession: copy.id, shown: []).attach.isEmpty)
    }

    @Test func aBaselineTakesEveryListedIdAndAnEmptyListStillBaselines() throws {
        let row = try attachedRow()
        let empty = try attachedRow()
        let first = UUID()
        let second = UUID()

        store.baselineCompanions(list([(first, .terminal), (second, .page)]), forSession: row.id)
        store.baselineCompanions(list([]), forSession: empty.id)

        #expect(row.companionsBaselined)
        #expect(row.followedCompanions == [first.uuidString, second.uuidString])
        #expect(empty.companionsBaselined)
        #expect(empty.followedCompanions.isEmpty)
    }

    @Test func aMarkBeforeTheFirstListKeepsTheRowUnbaselinedAndSurvivesTheBaseline() throws {
        let row = try attachedRow()
        let marked = UUID()
        let listed = UUID()

        store.markFollowed([marked.uuidString.lowercased()], forSession: row.id)
        #expect(!row.companionsBaselined)
        #expect(row.followedCompanions == [marked.uuidString])

        store.baselineCompanions(list([(listed, .terminal)]), forSession: row.id)

        #expect(row.followedCompanions == [marked.uuidString, listed.uuidString])
        #expect(store.companionsToFollow(list([(marked, .terminal), (listed, .terminal)]), forSession: row.id, shown: []).attach.isEmpty)
    }
}
