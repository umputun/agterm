import Foundation
import Testing
@testable import agtermCore

// dispatcher tests for the `workspace.*` commands — the focus-mode parse and the `workspace.filter`
// routing. They live here rather than in `ControlDispatcherTests.swift` only because that file is
// already close to the 2000-line test-file cap; they share its `MockControlActions` (internal for
// exactly that reason), the same split `ControlDispatcherDashboardTests` uses.
@MainActor
struct ControlDispatcherWorkspaceTests {
    @Test func workspaceFocusRoutesToTheAction() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .workspaceFocus, target: "work", args: ControlArgs(mode: "on", window: "win")))

        #expect(response == ControlResponse(ok: true))
        #expect(actions.calls == [.workspaceFocus(target: "work", window: "win", "on")])
    }
}
