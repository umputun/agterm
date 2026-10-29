import Foundation
import Testing
@testable import agtermCore

@MainActor
struct ControlDispatcherCompanionsTests {
    @Test func companionNewRoutesItsOptionsAndTint() async {
        let actions = MockControlActions()
        let request = ControlRequest(cmd: .sessionCompanionNew, target: "p1", args: ControlArgs(
            name: "logs", cwd: "/tmp", noSelect: true, command: "tail -f log", wait: true, window: "win", tint: "red"))

        let response = await ControlDispatcher(actions: actions).dispatch(request)

        #expect(response == ControlResponse(ok: true))
        #expect(actions.calls == [.companionNew(target: "p1", options: CompanionOptions(
            cwd: "/tmp", command: "tail -f log", name: "logs", wait: true, select: false,
            tint: SidebarTint(color: .red)), window: "win")])
    }

    @Test(arguments: [
        ControlArgs(workspace: "w"), ControlArgs(workspaceName: "w"), ControlArgs(createWorkspace: true),
        ControlArgs(after: "a"), ControlArgs(before: "b"),
    ])
    func companionNewRefusesWorkspaceAndPlacement(args: ControlArgs) async {
        let actions = MockControlActions()

        let response = await ControlDispatcher(actions: actions).dispatch(
            ControlRequest(cmd: .sessionCompanionNew, target: "p1", args: args))

        #expect(response?.error == "a companion takes no workspace or placement: it lands under its parent")
        #expect(actions.calls.isEmpty)
    }

    @Test func companionNewRefusesWaitWithoutCommandAndABadTintBeforeCreating() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let wait = await dispatcher.dispatch(ControlRequest(cmd: .sessionCompanionNew, args: ControlArgs(wait: true)))
        let tint = await dispatcher.dispatch(ControlRequest(cmd: .sessionCompanionNew, args: ControlArgs(tint: "mauve")))

        #expect(wait?.error == "--wait requires --command")
        #expect(tint?.ok == false)
        #expect(actions.calls.isEmpty)
    }

    @Test func sessionCollapseAndExpandRouteExpandedFlag() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let collapsed = await dispatcher.dispatch(ControlRequest(cmd: .sessionCollapse, target: "p1", args: ControlArgs(window: "win")))
        let expanded = await dispatcher.dispatch(ControlRequest(cmd: .sessionExpand, target: "active"))

        #expect(collapsed == ControlResponse(ok: true))
        #expect(expanded == ControlResponse(ok: true))
        #expect(actions.calls == [
            .sessionExpansion(target: "p1", window: "win", expanded: false),
            .sessionExpansion(target: "active", window: nil, expanded: true),
        ])
    }

    @Test func companionNewRawStringMapsToItsCommand() throws {
        let request = try JSONDecoder().decode(ControlRequest.self, from: Data(#"{"cmd":"session.companion.new","target":"p1"}"#.utf8))
        #expect(request.cmd == .sessionCompanionNew)
        #expect(request.target == "p1")
    }

    @Test func parentAndClosedRoundTripAndAreOmittedWhenUnset() throws {
        let result = ControlResult(id: "c1", parent: "p1", closed: ["p1", "c1"])
        #expect(try JSONDecoder().decode(ControlResult.self, from: JSONEncoder().encode(result)) == result)
        let bare = try String(decoding: JSONEncoder().encode(ControlResult(id: "s1")), as: UTF8.self)
        #expect(!bare.contains("parent"))
        #expect(!bare.contains("closed"))
    }

    @Test func sessionCollapseExpandRawStringsMapToCommands() throws {
        let collapse = try JSONDecoder().decode(ControlRequest.self, from: Data(#"{"cmd":"session.collapse","target":"9f3c"}"#.utf8))
        let expand = try JSONDecoder().decode(ControlRequest.self, from: Data(#"{"cmd":"session.expand"}"#.utf8))
        #expect(collapse.cmd == .sessionCollapse)
        #expect(collapse.target == "9f3c")
        #expect(expand.cmd == .sessionExpand)
    }
}
