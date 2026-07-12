import Foundation
import Testing
@testable import agtermCore

// dispatcher tests for the `dashboard --mru` open path. They live here rather than in
// `ControlDispatcherTests.swift` only because that file is already at the 2000-line test-file cap; they
// share its `MockControlActions` (made internal for that reason). The other dashboard dispatcher cases
// (explicit ids, font modes, close, cap-to-9) stay in `ControlDispatcherTests`.
@MainActor
struct ControlDispatcherDashboardTests {
    @Test func dashboardMruRoutesWithMruTrueAndNoTargets() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let plain = await dispatcher.dispatch(ControlRequest(cmd: .dashboard, args: ControlArgs(mru: true)))
        let autoSized = await dispatcher.dispatch(ControlRequest(
            cmd: .dashboard, args: ControlArgs(window: "win", autoSize: true, mru: true)))
        let fixed = await dispatcher.dispatch(ControlRequest(
            cmd: .dashboard, args: ControlArgs(fontSize: 12, mru: true)))

        #expect(plain == ControlResponse(ok: true))
        #expect(autoSized == ControlResponse(ok: true))
        #expect(fixed == ControlResponse(ok: true))
        #expect(actions.calls == [
            .dashboard(targets: [], window: nil, close: false, fontMode: .untouched, mru: true),
            .dashboard(targets: [], window: "win", close: false, fontMode: .auto, mru: true),
            .dashboard(targets: [], window: nil, close: false, fontMode: .fixed(12), mru: true)
        ])
    }

    @Test func dashboardMruRejectsExplicitIdsAndClose() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let withIds = await dispatcher.dispatch(ControlRequest(
            cmd: .dashboard, args: ControlArgs(targets: ["a"], mru: true)))
        let withClose = await dispatcher.dispatch(ControlRequest(
            cmd: .dashboard, args: ControlArgs(close: true, mru: true)))

        #expect(withIds == ControlResponse(
            ok: false, error: "dashboard --mru cannot be combined with explicit session ids"))
        #expect(withClose == ControlResponse(
            ok: false, error: "dashboard --close takes no ids, --mru, or font options"))
        #expect(actions.calls.isEmpty)
    }
}
