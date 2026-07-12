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

        controller.appliedFontSize = 9
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
        controller.appliedFontSize = 18
        #expect(controller.appliedFontSize == 18)
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
