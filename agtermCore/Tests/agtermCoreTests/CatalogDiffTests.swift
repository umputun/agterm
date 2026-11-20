import Foundation
import Testing
@testable import agtermCore

struct CatalogDiffTests {
    @Test(arguments: CatalogFixture.transitions())
    func applyingTheChangesInOrderLandsOnTheNextCatalog(_ name: String, _ old: [CatalogWorkspace], _ new: [CatalogWorkspace]) {
        let current = CatalogFixture.snapshot(old)
        let next = CatalogFixture.snapshot(new)
        var applied = current

        for change in current.changes(to: next) { applied.apply(change) }

        #expect(applied.workspaces == next.workspaces, "\(name)")
    }

    @Test func anAddedRootArrivesMarked() throws {
        let current = CatalogFixture.snapshot([])
        let next = CatalogFixture.snapshot([CatalogWorkspace(id: UUID(), name: "", root: true, sessions: [])])

        let change = try #require(current.changes(to: next).first)

        guard case .workspaceAdded(let workspace, _) = change else {
            Issue.record("expected workspace.added, got \(change.kind)")
            return
        }
        #expect(workspace.root == true)
    }

    @Test func eachKindOfChangeIsNamedForWhatChanged() {
        let w = UUID()
        let a = CatalogFixture.session(name: "a")
        let left = CatalogFixture.pane(), right = CatalogFixture.pane()
        var split = CatalogFixture.session(panes: [left, right])
        let current = CatalogFixture.snapshot([CatalogWorkspace(id: w, name: "w", sessions: [a, CatalogFixture.session(split.id, panes: [left])])])
        split.fields.name = "two"
        let added = CatalogFixture.session(name: "new")
        let next = CatalogFixture.snapshot([CatalogWorkspace(id: w, name: "w2", sessions: [split, added])])

        let kinds = current.changes(to: next).map(\.kind)

        #expect(kinds == ["session.removed", "workspace.changed", "session.added", "pane.added", "session.changed"])
    }

    @Test func aTintOrFlagAloneIsAChangeOfItsRow() {
        let w = UUID()
        var session = CatalogFixture.session()
        session.fields.flagged = false
        let current = CatalogFixture.snapshot([CatalogWorkspace(id: w, name: "w", tint: "", sessions: [session])])
        session.fields.flagged = true
        let next = CatalogFixture.snapshot([CatalogWorkspace(id: w, name: "w", tint: "red", tintOn: ["icon"], sessions: [session])])
        var applied = current

        let changes = current.changes(to: next)
        for change in changes { applied.apply(change) }

        #expect(changes == [.workspaceChanged(id: w, name: "w", tint: "red", tintOn: ["icon"]), .sessionChanged(session.fields)])
        #expect(applied.workspaces == next.workspaces)
    }

    @Test func aChangedRecentListIsOneChangeAndAServerWithoutOneSendsNone() {
        let item = ControlRecentItem(id: "r1", kind: "session", title: "a", subtitle: nil, closedAt: 1, workspaceID: "w", sessionIDs: ["s"])
        var current = CatalogFixture.snapshot([])
        current.recent = []
        var next = current
        next.recent = [item]
        var older = current
        older.recent = nil
        var applied = current

        let changes = current.changes(to: next)
        for change in changes { applied.apply(change) }

        #expect(changes == [.recentChanged([item])])
        #expect(applied.recent == [item])
        #expect(current.changes(to: older).isEmpty)
    }

    @Test func anUnchangedCatalogHasNoChanges() {
        let current = CatalogFixture.snapshot([CatalogWorkspace(id: UUID(), name: "w", sessions: [CatalogFixture.session()])])

        #expect(current.changes(to: current).isEmpty)
    }
}
