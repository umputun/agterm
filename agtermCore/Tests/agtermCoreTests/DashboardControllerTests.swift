import Foundation
import Testing
@testable import agtermCore

@MainActor
struct DashboardControllerTests {
    @Test func openSetsMembersHighlightAndModeThenCloseResets() {
        let controller = DashboardController()
        #expect(controller.isOpen == false)
        #expect(controller.members.isEmpty)
        #expect(controller.highlighted == nil)
        #expect(controller.fontMode == .untouched)

        let a = UUID(), b = UUID(), c = UUID()
        controller.open(members: [a, b, c], highlighted: b, fontMode: .auto)
        #expect(controller.isOpen)
        #expect(controller.members == [a, b, c])
        #expect(controller.highlighted == b)
        #expect(controller.fontMode == .auto)

        controller.setAppliedFontSize(9)
        controller.close()
        #expect(controller.isOpen == false)
        #expect(controller.members.isEmpty)
        #expect(controller.highlighted == nil)
        #expect(controller.fontMode == .untouched)
        #expect(controller.appliedFontSize == nil)
    }

    @Test func highlightInitPrefersSuppliedMemberElseFirst() {
        let controller = DashboardController()
        let a = UUID(), b = UUID(), c = UUID()

        // no supplied highlight → first member.
        controller.open(members: [a, b, c])
        #expect(controller.highlighted == a)

        // supplied member in the set → that member.
        controller.open(members: [a, b, c], highlighted: c)
        #expect(controller.highlighted == c)

        // supplied member not in the set → falls back to the first member.
        controller.open(members: [a, b, c], highlighted: UUID())
        #expect(controller.highlighted == a)
    }

    @Test func moveWalksHighlightAcrossFullGrid() {
        let controller = DashboardController()
        let ids = (0..<4).map { _ in UUID() } // cols=2: 0 1 / 2 3
        controller.open(members: ids)
        #expect(controller.highlighted == ids[0])
        controller.move(.right)
        #expect(controller.highlighted == ids[1])
        controller.move(.down)
        #expect(controller.highlighted == ids[3])
        controller.move(.left)
        #expect(controller.highlighted == ids[2])
        controller.move(.up)
        #expect(controller.highlighted == ids[0])
        // clamp: up/left at the top-left corner stays put.
        controller.move(.up)
        #expect(controller.highlighted == ids[0])
        controller.move(.left)
        #expect(controller.highlighted == ids[0])
    }

    @Test func moveClampsRaggedLastRow() {
        let controller = DashboardController()
        let ids = (0..<5).map { _ in UUID() } // cols=3: 0 1 2 / 3 4
        controller.open(members: ids, highlighted: ids[4])
        // no cell right of the last member in a ragged row.
        controller.move(.right)
        #expect(controller.highlighted == ids[4])
        // no cell below index 4 (would be index 7, out of range).
        controller.move(.down)
        #expect(controller.highlighted == ids[4])
        controller.move(.up)
        #expect(controller.highlighted == ids[1])
    }

    @Test func highlightMovesToMemberElseLeavesUnchanged() {
        let controller = DashboardController()
        let a = UUID(), b = UUID(), c = UUID()
        controller.open(members: [a, b, c])
        #expect(controller.highlighted == a)

        // click on a member moves the highlight to it.
        controller.highlight(c)
        #expect(controller.highlighted == c)

        // a non-member id leaves the highlight where it was.
        controller.highlight(UUID())
        #expect(controller.highlighted == c)
    }

    @Test func highlightIsNoOpWhenClosed() {
        let controller = DashboardController()
        controller.highlight(UUID())
        #expect(controller.highlighted == nil)
    }

    @Test func moveIsNoOpWhenClosedOrUnhighlighted() {
        let controller = DashboardController()
        controller.move(.right)
        #expect(controller.highlighted == nil)
        #expect(controller.isOpen == false)
    }

    @Test func fontModeAndAppliedSizeCarryState() {
        let controller = DashboardController()
        let a = UUID()
        controller.open(members: [a], fontMode: .fixed(18))
        #expect(controller.fontMode == .fixed(18))
        #expect(controller.appliedFontSize == nil)
        controller.setAppliedFontSize(18)
        #expect(controller.appliedFontSize == 18)
    }

    @Test func reopenOverSameMembersUpdatesFontMode() {
        // a same-members re-open with a new font mode must update the mode (the app-side wiring keys its
        // font re-apply off members+fontMode, so this is what a `dashboard A B --font-size 20` re-open sees).
        let controller = DashboardController()
        let a = UUID(), b = UUID()
        controller.open(members: [a, b], highlighted: b, fontMode: .fixed(20))
        controller.setAppliedFontSize(20)
        #expect(controller.fontMode == .fixed(20))

        controller.open(members: [a, b], highlighted: b, fontMode: .untouched)
        #expect(controller.members == [a, b])
        #expect(controller.highlighted == b, "the highlight survives a same-members re-open")
        #expect(controller.fontMode == .untouched, "the font mode reflects the latest open")
    }

    @Test func reconcileDropsClosedMembersAndFixesHighlight() {
        let controller = DashboardController()
        let a = UUID(), b = UUID(), c = UUID()
        controller.open(members: [a, b, c], highlighted: b)

        // b closed while open: it is pruned, order preserved, and the highlight moves to the first survivor.
        controller.reconcile(existing: [a, c])
        #expect(controller.members == [a, c])
        #expect(controller.highlighted == a)

        // a survivor highlight is left in place.
        controller.reconcile(existing: [a, c])
        #expect(controller.highlighted == a, "a no-op reconcile leaves state unchanged")
    }

    @Test func reconcileClosesDashboardWhenNoMemberSurvives() {
        let controller = DashboardController()
        let a = UUID(), b = UUID()
        controller.open(members: [a, b], fontMode: .fixed(14))
        controller.setAppliedFontSize(14)

        controller.reconcile(existing: [])
        #expect(controller.isOpen == false)
        #expect(controller.members.isEmpty)
        #expect(controller.highlighted == nil)
        #expect(controller.fontMode == .untouched)
        #expect(controller.appliedFontSize == nil)
    }

    @Test func appliedFontSizeResolvesPerMode() {
        // .untouched → nil regardless of grid; .fixed → its exact value; .auto → the grid-derived size.
        #expect(DashboardFontMode.untouched.appliedFontSize(memberCount: 4, base: 13) == nil)
        #expect(DashboardFontMode.fixed(20).appliedFontSize(memberCount: 9, base: 13) == 20)

        // .auto matches DashboardLayout.dashboardFontSize for the count's grid (4 → 2×2, 9 → 3×3).
        let (c4, r4) = DashboardLayout.grid(count: 4)
        #expect(DashboardFontMode.auto.appliedFontSize(memberCount: 4, base: 16)
            == DashboardLayout.dashboardFontSize(cols: c4, rows: r4, base: 16))
        let (c9, r9) = DashboardLayout.grid(count: 9)
        #expect(DashboardFontMode.auto.appliedFontSize(memberCount: 9, base: 13)
            == DashboardLayout.dashboardFontSize(cols: c9, rows: r9, base: 13))
    }

    @Test func registryRegistersLooksUpAndUnregisters() {
        let registry = DashboardControllerRegistry.shared
        let id = UUID() // unique key keeps this hermetic under parallel tests on the shared singleton
        #expect(registry.controller(for: id) == nil)
        #expect(registry.controller(for: nil) == nil)

        let controller = DashboardController()
        registry.register(id, controller: controller)
        #expect(registry.controller(for: id) === controller)

        registry.unregister(id)
        #expect(registry.controller(for: id) == nil)
    }
}
