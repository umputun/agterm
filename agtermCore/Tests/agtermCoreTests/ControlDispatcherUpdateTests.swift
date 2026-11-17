import Foundation
import Testing
@testable import agtermCore

@MainActor
struct ControlDispatcherUpdateTests {
    @Test func updateCheckRoutesToActionsAndKeepsTheReply() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextUpdateCheckResponse = ControlResponse(ok: false, error: UpdateCheck.busy)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .updateCheck))

        #expect(response == ControlResponse(ok: false, error: "an update check is already running"))
        #expect(actions.calls == [.updateCheck])
    }

    @Test func updateCheckRefusesATargetOrWindowBeforeAnyAction() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let targeted = await dispatcher.dispatch(ControlRequest(cmd: .updateCheck, target: "active"))
        let windowed = await dispatcher.dispatch(ControlRequest(cmd: .updateCheck, args: ControlArgs(window: "w1")))

        #expect(targeted == ControlResponse(ok: false, error: "update.check takes no target or --window"))
        #expect(windowed == ControlResponse(ok: false, error: "update.check takes no target or --window"))
        #expect(actions.calls.isEmpty)
    }

    @Test func updateCheckRoundTripsOnTheWire() throws {
        let data = try JSONEncoder().encode(ControlRequest(cmd: .updateCheck))
        #expect(String(decoding: data, as: UTF8.self) == #"{"cmd":"update.check"}"#)
        #expect(try JSONDecoder().decode(ControlRequest.self, from: data).cmd == .updateCheck)
    }

    @Test func aHostWithoutAnUpdaterRefusesByName() {
        #expect(ControlActionsUnsupported.message("update.check") == "update.check is not supported on this platform")
    }
}
