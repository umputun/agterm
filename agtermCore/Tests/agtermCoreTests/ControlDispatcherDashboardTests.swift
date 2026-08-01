import Foundation
import Testing
@testable import agtermCore

// the `dashboard --mru` dispatcher cases live here because `ControlDispatcherTests.swift` is already
// at the 2000-line test-file cap; they share its `MockControlActions` (internal for that reason).
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

    @Test func paneRefsPassThroughVerbatim() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .dashboard, args: ControlArgs(targets: ["a:left", "b:right", "c", "active:left"])))

        #expect(response == ControlResponse(ok: true))
        #expect(actions.calls == [
            .dashboard(targets: ["a:left", "b:right", "c", "active:left"], window: nil, close: false,
                       fontMode: .untouched, mru: false)
        ])
    }

    @Test(arguments: ["a:lft", "a:primary", "a:split", "a:scratch", "a:overlay", "a:", ":left",
                      "surface:9F3CAAAA-0000-0000-0000-000000000001:left"])
    func malformedPaneRefIsRejected(_ target: String) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .dashboard, args: ControlArgs(targets: [target])))

        #expect(response == ControlResponse(
            ok: false, error: "dashboard: invalid session id '\(target)' — use <id>, <id>:left, or <id>:right"))
        #expect(actions.calls.isEmpty)
    }

    @Test func oneMalformedRefRejectsTheWholeRequest() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .dashboard, args: ControlArgs(targets: ["a:left", "b:nope"])))

        #expect(response?.ok == false)
        #expect(actions.calls.isEmpty)
    }

    @Test func closeStillIgnoresTargetGrammar() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .dashboard, args: ControlArgs(targets: ["a:nope"], close: true)))

        #expect(response == ControlResponse(
            ok: false, error: "dashboard --close takes no ids, --mru, or font options"))
        #expect(actions.calls.isEmpty)
    }
}
