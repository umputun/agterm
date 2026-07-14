import Foundation
import Testing
@testable import agtermCore

@MainActor
struct DashboardControllerTests {
    // pane-cell members: a plain session is one `.primary` cell; a split session is `.primary` + `.split`.
    private func primary(_ id: UUID) -> DashboardMember { DashboardMember(session: id, surface: .primary) }
    private func split(_ id: UUID) -> DashboardMember { DashboardMember(session: id, surface: .split) }

    @Test func openSetsMembersHighlightAndModeThenCloseResets() {
        let controller = DashboardController()
        #expect(controller.isOpen == false)
        #expect(controller.members.isEmpty)
        #expect(controller.highlighted == nil)
        #expect(controller.fontMode == .untouched)

        let a = UUID(), b = UUID(), c = UUID()
        let members = [primary(a), primary(b), primary(c)]
        controller.open(members: members, highlighted: primary(b), fontMode: .auto)
        #expect(controller.isOpen)
        #expect(controller.members == members)
        #expect(controller.highlighted == primary(b))
        #expect(controller.fontMode == .auto)

        controller.setAppliedFontSize(9)
        controller.close()
        #expect(controller.isOpen == false)
        #expect(controller.members.isEmpty)
        #expect(controller.highlighted == nil)
        #expect(controller.fontMode == .untouched)
        #expect(controller.appliedFontSize == nil)
    }

    @Test func splitSessionExpandsToTwoPaneCells() {
        // a split session contributes two cells — its primary AND its split pane — and the highlight/move
        // treat them as distinct grid positions of the same session.
        let controller = DashboardController()
        let a = UUID()
        controller.open(members: [primary(a), split(a)])
        #expect(controller.members == [primary(a), split(a)])
        #expect(controller.highlighted == primary(a), "the highlight starts on the first cell (the primary pane)")
        controller.move(.right)
        #expect(controller.highlighted == split(a), "moving right lands on the same session's split pane cell")
    }

    @Test func highlightInitPrefersSuppliedMemberElseFirst() {
        let controller = DashboardController()
        let a = UUID(), b = UUID(), c = UUID()
        let members = [primary(a), primary(b), primary(c)]

        // no supplied highlight → first member.
        controller.open(members: members)
        #expect(controller.highlighted == primary(a))

        // supplied member in the set → that member.
        controller.open(members: members, highlighted: primary(c))
        #expect(controller.highlighted == primary(c))

        // supplied member not in the set → falls back to the first member.
        controller.open(members: members, highlighted: primary(UUID()))
        #expect(controller.highlighted == primary(a))
    }

    @Test func moveWalksHighlightAcrossFullGrid() {
        let controller = DashboardController()
        let ids = (0..<4).map { _ in primary(UUID()) } // cols=2: 0 1 / 2 3
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
        let ids = (0..<5).map { _ in primary(UUID()) } // cols=3: 0 1 2 / 3 4
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
        controller.open(members: [primary(a), primary(b), primary(c)])
        #expect(controller.highlighted == primary(a))

        // a click flashes the highlight onto that member.
        controller.highlight(primary(c))
        #expect(controller.highlighted == primary(c))

        // a non-member leaves the highlight where it was.
        controller.highlight(primary(UUID()))
        #expect(controller.highlighted == primary(c))
    }

    @Test func highlightIsNoOpWhenClosed() {
        let controller = DashboardController()
        controller.highlight(primary(UUID()))
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
        controller.open(members: [primary(a)], fontMode: .fixed(18))
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
        let members = [primary(a), primary(b)]
        controller.open(members: members, highlighted: primary(b), fontMode: .fixed(20))
        controller.setAppliedFontSize(20)
        #expect(controller.fontMode == .fixed(20))

        controller.open(members: members, highlighted: primary(b), fontMode: .untouched)
        #expect(controller.members == members)
        #expect(controller.highlighted == primary(b), "the highlight survives a same-members re-open")
        #expect(controller.fontMode == .untouched, "the font mode reflects the latest open")
    }

    @Test func reconcileDropsClosedMembersAndFixesHighlight() {
        let controller = DashboardController()
        let a = UUID(), b = UUID(), c = UUID()
        controller.open(members: [primary(a), primary(b), primary(c)], highlighted: primary(b))

        // b closed while open: it is pruned, order preserved, and the highlight moves to the first survivor.
        controller.reconcile(existing: [primary(a), primary(c)])
        #expect(controller.members == [primary(a), primary(c)])
        #expect(controller.highlighted == primary(a))

        // a survivor highlight is left in place.
        controller.reconcile(existing: [primary(a), primary(c)])
        #expect(controller.highlighted == primary(a), "a no-op reconcile leaves state unchanged")
    }

    @Test func reconcileDropsSplitPaneWhenSplitClosesButKeepsPrimary() {
        // a split session opens as two cells; closing just its split pane (primary stays valid) prunes ONLY
        // the split cell and moves the highlight off it, leaving the primary cell in place.
        let controller = DashboardController()
        let a = UUID(), b = UUID()
        controller.open(members: [primary(a), split(a), primary(b)], highlighted: split(a))

        controller.reconcile(existing: [primary(a), primary(b)]) // a's split pane closed
        #expect(controller.members == [primary(a), primary(b)], "only the split cell is pruned")
        #expect(controller.highlighted == primary(a), "the highlight moves to the first survivor")
    }

    @Test func reconcileClosesDashboardWhenNoMemberSurvives() {
        let controller = DashboardController()
        let a = UUID(), b = UUID()
        controller.open(members: [primary(a), primary(b)], fontMode: .fixed(14))
        controller.setAppliedFontSize(14)

        controller.reconcile(existing: [])
        #expect(controller.isOpen == false)
        #expect(controller.members.isEmpty)
        #expect(controller.highlighted == nil)
        #expect(controller.fontMode == .untouched)
        #expect(controller.appliedFontSize == nil)
    }

    @Test func memberControlRefEncodesSessionAndPane() {
        let a = UUID()
        #expect(primary(a).controlRef == "\(a.uuidString):left")
        #expect(split(a).controlRef == "\(a.uuidString):right")
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
