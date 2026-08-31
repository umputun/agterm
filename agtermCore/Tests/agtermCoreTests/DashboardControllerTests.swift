import Foundation
import Testing
@testable import agtermCore

@MainActor
struct DashboardControllerTests {
    // pane-cell members: a plain session is one `.primary` cell; a split session is `.primary` + `.split`.
    private func primary(_ id: UUID) -> DashboardMember { DashboardMember(session: id, surface: .primary) }
    private func split(_ id: UUID) -> DashboardMember { DashboardMember(session: id, surface: .split) }

    private func makeSwappableSession() -> (AppStore, Session) {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: workspace.id, cwd: "/left")!
        session.surface = SpySurface(paneToken: "primary")
        session.splitSurface = SpySurface(paneToken: "split")
        session.hasSplit = true
        return (store, session)
    }

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
        let controller = DashboardController()
        let a = UUID()
        controller.open(members: [primary(a), split(a)])
        #expect(controller.members == [primary(a), split(a)])
        #expect(controller.highlighted == primary(a), "the highlight starts on the first cell (the primary pane)")
        controller.move(.right)
        #expect(controller.highlighted == split(a), "moving right lands on the same session's split pane cell")
    }

    @Test func loneDashboardMemberKeepsItsSlotAcrossPaneSwap() {
        let (store, session) = makeSwappableSession()
        let controller = DashboardController()
        controller.open(members: [split(session.id)])

        #expect(store.swapPanes(session.id) == nil)

        #expect(controller.members == [split(session.id)])
        #expect(controller.highlighted == split(session.id))
    }

    @Test func bothDashboardMembersKeepOrderAndHighlightAcrossPaneSwap() {
        let (store, session) = makeSwappableSession()
        let controller = DashboardController()
        let members = [primary(session.id), split(session.id)]
        controller.open(members: members, highlighted: split(session.id))

        #expect(store.swapPanes(session.id) == nil)

        #expect(controller.members == members)
        #expect(controller.highlighted == split(session.id))
    }

    @Test func highlightInitPrefersSuppliedMemberElseFirst() {
        let controller = DashboardController()
        let a = UUID(), b = UUID(), c = UUID()
        let members = [primary(a), primary(b), primary(c)]

        controller.open(members: members)
        #expect(controller.highlighted == primary(a))

        controller.open(members: members, highlighted: primary(c))
        #expect(controller.highlighted == primary(c))

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
        controller.move(.up)
        #expect(controller.highlighted == ids[0])
        controller.move(.left)
        #expect(controller.highlighted == ids[0])
    }

    @Test func moveClampsRaggedLastRow() {
        let controller = DashboardController()
        let ids = (0..<5).map { _ in primary(UUID()) } // cols=3: 0 1 2 / 3 4
        controller.open(members: ids, highlighted: ids[4])
        controller.move(.right)
        #expect(controller.highlighted == ids[4])
        // below index 4 would be index 7, out of range.
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

        controller.highlight(primary(c))
        #expect(controller.highlighted == primary(c))

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

    @Test func requestFocusAdvancesRevisionWithoutChangingDashboardState() {
        let controller = DashboardController()
        let member = primary(UUID())
        controller.open(members: [member])

        controller.requestFocus()

        #expect(controller.focusRevision == 1)
        #expect(controller.members == [member])
        #expect(controller.highlighted == member)
    }

    @Test func reopenOverSameMembersUpdatesFontMode() {
        // the app-side wiring keys its font re-apply off members+fontMode.
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

        controller.reconcile(existing: [primary(a), primary(c)])
        #expect(controller.members == [primary(a), primary(c)])
        #expect(controller.highlighted == primary(a))

        controller.reconcile(existing: [primary(a), primary(c)])
        #expect(controller.highlighted == primary(a), "a no-op reconcile leaves state unchanged")
    }

    @Test func reconcileDropsSplitPaneWhenSplitClosesButKeepsPrimary() {
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
        #expect(DashboardFontMode.untouched.appliedFontSize(memberCount: 4, base: 13) == nil)
        #expect(DashboardFontMode.fixed(20).appliedFontSize(memberCount: 9, base: 13) == 20)

        // the counts resolve to 4 → 2×2 and 9 → 3×3.
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

    // pins #331: a grid built from `<id>:right` must survive `closePrimaryPane` promoting that pane
    @Test func promoteRewritesALoneSplitMemberToPrimary() {
        let controller = DashboardController()
        let a = UUID()
        controller.open(members: [split(a)])

        controller.promoteSplitMember(session: a)

        #expect(controller.members == [primary(a)])
        #expect(controller.highlighted == primary(a))
        #expect(controller.isOpen)
    }

    @Test func promoteCollapsesIntoAnExistingPrimaryMember() {
        let controller = DashboardController()
        let a = UUID()
        let b = UUID()
        controller.open(members: [primary(a), split(a), primary(b)])

        controller.promoteSplitMember(session: a)

        #expect(controller.members == [primary(a), primary(b)])
    }

    @Test func promoteMovesTheHighlightOffTheRewrittenCell() {
        let controller = DashboardController()
        let a = UUID()
        controller.open(members: [primary(a), split(a)], highlighted: DashboardMember(session: a, surface: .split))

        controller.promoteSplitMember(session: a)

        #expect(controller.members == [primary(a)])
        #expect(controller.highlighted == primary(a))
    }

    @Test func promoteLeavesAnUnhighlightedSiblingHighlightAlone() {
        let controller = DashboardController()
        let a = UUID()
        let b = UUID()
        controller.open(members: [split(a), primary(b)], highlighted: DashboardMember(session: b, surface: .primary))

        controller.promoteSplitMember(session: a)

        #expect(controller.members == [primary(a), primary(b)])
        #expect(controller.highlighted == primary(b))
    }

    @Test func promoteIsANoOpWithoutASplitMember() {
        let controller = DashboardController()
        let a = UUID()
        controller.open(members: [primary(a)])

        controller.promoteSplitMember(session: a)

        #expect(controller.members == [primary(a)])
    }

    // the other teardown path: the split's OWN shell exiting must still drop the cell, not rewrite it
    @Test func reconcileStillPrunesASplitMemberWhenTheSplitItselfClosed() {
        let controller = DashboardController()
        let a = UUID()
        controller.open(members: [primary(a), split(a)])

        controller.reconcile(existing: [primary(a)])

        #expect(controller.members == [primary(a)])
    }
}
