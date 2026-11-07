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

        #expect(kinds == ["session.removed", "workspace.changed", "pane.added", "session.changed", "session.added"])
    }

    @Test func anUnchangedCatalogHasNoChanges() {
        let current = CatalogFixture.snapshot([CatalogWorkspace(id: UUID(), name: "w", sessions: [CatalogFixture.session()])])

        #expect(current.changes(to: current).isEmpty)
    }
}
