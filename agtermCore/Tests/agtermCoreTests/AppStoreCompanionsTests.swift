import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreCompanionsTests {
    private func refusal(_ result: Result<Session, CompanionRefusal>) -> CompanionRefusal? {
        if case .failure(let refusal) = result { return refusal }
        return nil
    }

    @Test func aCompanionLandsAfterTheParentsLastCompanion() throws {
        let g = try CompanionGroup()
        let (store, parent, first, second, after) = (g.store, g.parent, g.first, g.second, g.after)

        #expect(g.order == [parent.id, first.id, second.id, after.id])
        #expect(first.parentID == parent.id)
        #expect(second.parentID == parent.id)
        #expect(store.companions(of: parent.id).map(\.id) == [first.id, second.id])
        #expect(store.parent(of: first) === parent)
        #expect(store.parent(of: parent) == nil)
    }

    @Test func aCompanionOfACompanionBecomesASibling() throws {
        let g = try CompanionGroup()
        let (store, parent, first, second, after) = (g.store, g.parent, g.first, g.second, g.after)

        let third = try store.addCompanion(to: first.id).get()

        #expect(third.parentID == parent.id)
        #expect(g.order == [parent.id, first.id, second.id, third.id, after.id])
    }

    @Test func aCompanionStartsInTheParentsCwdUnlessGivenOne() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let parent = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/parent/dir"))

        let companion = try store.addCompanion(to: parent.id, options: CompanionOptions(command: "lazygit", name: "git", wait: true)).get()

        #expect(companion.initialCwd == "/parent/dir")
        #expect(companion.initialCommand == "lazygit")
        #expect(companion.customName == "git")
        #expect(companion.commandWait)
        #expect(store.selectedSessionID == companion.id)
    }

    @Test func aBackgroundCompanionKeepsTheSelection() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let parent = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/parent"))

        _ = try store.addCompanion(to: parent.id, options: CompanionOptions(select: false)).get()

        #expect(store.selectedSessionID == parent.id)
    }

    @Test func aRemoteParentIsRefused() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let remote = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/r", remoteHost: "buildbox"))

        #expect(refusal(store.addCompanion(to: remote.id)) == .remoteParent)
        #expect(refusal(store.addCompanion(to: UUID())) == .noSuchSession)
        #expect(store.workspaces[0].sessions.count == 1)
    }

    @Test(arguments: [1, 2, 3])
    func aTopLevelSessionInsertedInsideAGroupLandsAfterIt(index: Int) throws {
        let g = try CompanionGroup()
        let (store, workspace, parent, first, second, after) = (g.store, g.work, g.parent, g.first, g.second, g.after)

        let inserted = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/new", at: index))

        #expect(g.order == [parent.id, first.id, second.id, inserted.id, after.id])
    }

    @Test func insertionBeforeTheParentStaysBeforeTheGroup() throws {
        let g = try CompanionGroup()
        let (store, workspace, parent, first, second, after) = (g.store, g.work, g.parent, g.first, g.second, g.after)

        let inserted = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/new", at: 0))

        #expect(g.order == [inserted.id, parent.id, first.id, second.id, after.id])
    }

    @Test func plainDuplicateOfAParentLandsAfterItsGroup() throws {
        let g = try CompanionGroup()
        let (store, parent, first, second, after) = (g.store, g.parent, g.first, g.second, g.after)

        let duplicate = try #require(store.duplicateSession(parent.id))

        #expect(duplicate.parentID == nil)
        #expect(g.order == [parent.id, first.id, second.id, duplicate.id, after.id])
    }

    @Test func anUndoneCloseOfATopLevelSessionLandsOutsideAGroupThatGrewIntoItsSlot() throws {
        let g = try CompanionGroup()
        #expect(g.store.softCloseSession(g.after.id))
        let third = try g.store.addCompanion(to: g.parent.id).get()

        #expect(g.store.undoPendingClose())

        #expect(g.order == [g.parent.id, g.first.id, g.second.id, third.id, g.after.id])
    }

    @Test func regroupingDropsLinksWithoutATopLevelParentAndRebuildsOrder() {
        let parent = Session(initialCwd: "/p")
        let companion = Session(initialCwd: "/c")
        companion.parentID = parent.id
        let orphan = Session(initialCwd: "/o")
        orphan.parentID = UUID()
        let chained = Session(initialCwd: "/x")
        chained.parentID = companion.id
        let other = Session(initialCwd: "/other")

        let regrouped = AppStore.regroupedCompanions([companion, other, orphan, parent, chained])

        #expect(regrouped.map(\.id) == [other.id, orphan.id, parent.id, companion.id, chained.id])
        #expect(orphan.parentID == nil)
        #expect(chained.parentID == nil)
        #expect(companion.parentID == parent.id)
    }
}
