import Foundation
import Testing
@testable import agtermCore

@MainActor
struct ControlDispatcherSidebarTests {
    @Test func sidebarWidthRoutesPointsAndWindow() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextSidebarWidthResponse = ControlResponse(ok: true, result: ControlResult(sidebarWidth: 271.3))

        let response = await dispatcher.dispatch(
            ControlRequest(cmd: .sidebarWidth, args: ControlArgs(window: "win", sidebarWidth: 271.3)))

        #expect(response == ControlResponse(ok: true, result: ControlResult(sidebarWidth: 271.3)))
        #expect(actions.calls == [.sidebarWidth(points: 271.3, window: "win")])
    }

    @Test func sidebarWidthDefaultsToFrontmostWindow() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .sidebarWidth, args: ControlArgs(sidebarWidth: 300)))

        #expect(actions.calls == [.sidebarWidth(points: 300, window: nil)])
    }

    @Test(arguments: [nil, Double.nan, Double.infinity])
    func sidebarWidthRejectsMissingOrNonFinitePointsWithoutCallingActions(_ points: Double?) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(
            ControlRequest(cmd: .sidebarWidth, args: ControlArgs(sidebarWidth: points)))

        #expect(response == ControlResponse(ok: false, error: "sidebar.width requires a width in points"))
        #expect(actions.calls.isEmpty)
    }
}
