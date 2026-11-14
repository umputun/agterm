import Foundation
import Testing
@testable import agtermCore

@MainActor
struct ControlDispatcherSessionCloseTests {
    @Test func aHostWithoutTheUndoableFormsRefusesRatherThanHardClosing() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let single = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionClose, target: "a", args: ControlArgs(window: "win", undoable: true)))
        let batch = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionClose, target: "a", args: ControlArgs(targets: ["a", "b"], undoable: true)))

        let refusal = ControlResponse(ok: false, error: "session.close --undoable is not supported by this control host")
        #expect(single == refusal)
        #expect(batch == refusal)
        #expect(actions.calls.isEmpty)
    }

    @Test func undoableFalseKeepsThePlainForms() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionClose, target: "a", args: ControlArgs(undoable: false)))
        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionClose, args: ControlArgs(targets: ["a", "b"], undoable: false)))

        #expect(actions.calls == [
            .sessionClose(target: "a", window: nil),
            .sessionCloseBatch(targets: ["a", "b"], window: nil)
        ])
    }

    @Test func undoableEmptyBatchIsRefusedBeforeAnyAction() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let empty = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionClose, args: ControlArgs(targets: [], undoable: true)))

        #expect(empty == ControlResponse(ok: false, error: "session.close requires at least one --target"))
        #expect(actions.calls.isEmpty)
    }

    @Test func terminateWithAnEmptyBatchIsRefusedBeforeAnyAction() async {
        let actions = MockControlActions()

        let empty = await ControlDispatcher(actions: actions).dispatch(ControlRequest(cmd: .sessionTerminate, args: ControlArgs(targets: [])))

        #expect(empty == ControlResponse(ok: false, error: "session.terminate requires at least one --target"))
        #expect(actions.calls.isEmpty)
    }

    @Test func terminatePassesTheTargetsWindowAndUndoableToTheHost() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionTerminate))
        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionTerminate, target: "a", args: ControlArgs(window: "win", undoable: true)))
        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionTerminate, target: "a", args: ControlArgs(targets: ["a", "b"])))

        #expect(actions.calls == [
            .sessionTerminate(targets: ["active"], window: nil, undoable: false),
            .sessionTerminate(targets: ["a"], window: "win", undoable: true),
            .sessionTerminate(targets: ["a", "b"], window: nil, undoable: false),
        ])
    }

    @Test func undoableRoundTripsAndIsOmittedWhenNil() throws {
        let request = ControlRequest(cmd: .sessionClose, target: "9f3c", args: ControlArgs(undoable: true))
        let response = ControlResponse(ok: true, result: ControlResult(id: "9f3c", undoable: false))

        #expect(try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(request)) == request)
        #expect(try JSONDecoder().decode(ControlResponse.self, from: JSONEncoder().encode(response)) == response)
        let plainRequest = String(decoding: try JSONEncoder().encode(
            ControlRequest(cmd: .sessionClose, args: ControlArgs(targets: ["a", "b"]))), as: UTF8.self)
        let plainResponse = String(decoding: try JSONEncoder().encode(
            ControlResponse(ok: true, result: ControlResult(id: "9f3c"))), as: UTF8.self)
        #expect(!plainRequest.contains("undoable"))
        #expect(!plainResponse.contains("undoable"))
    }
}
