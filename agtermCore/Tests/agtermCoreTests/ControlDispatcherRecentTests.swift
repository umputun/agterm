import Foundation
import Testing
@testable import agtermCore

@MainActor
struct ControlDispatcherRecentTests {
    @Test func listAndClearRouteToActions() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        let item = ControlRecentItem(id: "R1", kind: "session", title: "api", subtitle: "project", closedAt: 1,
                                     workspaceID: "W1", sessionIDs: ["S1"])
        actions.nextRecentResponse = ControlResponse(ok: true, result: ControlResult(recent: [item]))

        let list = await dispatcher.dispatch(ControlRequest(cmd: .recentList))
        let clear = await dispatcher.dispatch(ControlRequest(cmd: .recentClear))

        #expect(list == ControlResponse(ok: true, result: ControlResult(recent: [item])))
        #expect(clear == ControlResponse(ok: true, result: ControlResult(recent: [item])))
        #expect(actions.calls == [.recentList, .recentClear])
    }

    @Test func openPassesTheEntryAndWindowThrough() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .recentOpen))
        _ = await dispatcher.dispatch(ControlRequest(cmd: .recentOpen, target: "ab12", args: ControlArgs(window: "w1")))

        #expect(actions.calls == [.recentOpen(target: nil, window: nil), .recentOpen(target: "ab12", window: "w1")])
    }

    @Test(arguments: [Command.recentList, .recentClear])
    func listAndClearRefuseATargetBeforeAnyAction(_ cmd: Command) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let targeted = await dispatcher.dispatch(ControlRequest(cmd: cmd, target: "active"))

        #expect(targeted == ControlResponse(ok: false, error: "\(cmd.rawValue) takes no target"))
        #expect(actions.calls.isEmpty)
    }

    @Test(arguments: [Command.recentList, .recentClear])
    func aWindowReachesTheWindowFormWhichAHostWithoutOneRefuses(_ cmd: Command) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let windowed = await dispatcher.dispatch(ControlRequest(cmd: cmd, args: ControlArgs(window: "w1")))

        #expect(windowed == ControlResponse(ok: false, error: "\(cmd.rawValue) takes no --window on this control host"))
        #expect(actions.calls.isEmpty)
    }

    @Test func undoNeedsTheUndoIDAndAHostWithoutUndoRefusesIt() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let missing = await dispatcher.dispatch(ControlRequest(cmd: .sessionUndo))
        let active = await dispatcher.dispatch(ControlRequest(cmd: .sessionUndo, target: "active"))
        let unsupported = await dispatcher.dispatch(ControlRequest(cmd: .sessionUndo, target: " u1 "))

        let refusal = ControlResponse(ok: false, error: "session.undo requires --target with the undo id a close answered")
        #expect(missing == refusal)
        #expect(active == refusal)
        #expect(unsupported == ControlResponse(ok: false, error: "session.undo is not supported by this control host"))
    }
}
