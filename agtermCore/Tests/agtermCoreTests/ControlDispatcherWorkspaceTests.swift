import Foundation
import Testing
@testable import agtermCore

// dispatcher tests for the `workspace.*` commands — the focus-mode parse and the `workspace.filter`
// routing. They live here rather than in `ControlDispatcherTests.swift` only because that file is
// already close to the 2000-line test-file cap; they share its `MockControlActions` (internal for
// exactly that reason), the same split `ControlDispatcherDashboardTests` uses.
@MainActor
struct ControlDispatcherWorkspaceTests {
    // migrated here from `ControlDispatcherTests.workspaceFocusRoutesModeForHostSideValidation`, whose
    // contract (the raw mode routed through for the host to validate) this task moved into the dispatcher.
    @Test func workspaceFocusRoutesToTheAction() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .workspaceFocus, target: "work", args: ControlArgs(mode: "on", window: "win")))

        #expect(response == ControlResponse(ok: true))
        #expect(actions.calls == [.workspaceFocus(target: "work", window: "win", .on)])
    }

    @Test(arguments: ControlWorkspaceFocusMode.allCases)
    func workspaceFocusParsesEveryMode(mode: ControlWorkspaceFocusMode) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .workspaceFocus, target: "work", args: ControlArgs(mode: mode.rawValue)))

        #expect(actions.calls == [.workspaceFocus(target: "work", window: nil, mode)])
    }

    @Test func workspaceFocusDefaultsToToggle() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .workspaceFocus, target: "work"))

        #expect(actions.calls == [.workspaceFocus(target: "work", window: nil, .toggle)])
    }

    @Test func workspaceFocusRejectsUnknownModeWithoutCallingActions() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .workspaceFocus, target: "work", args: ControlArgs(mode: "pin")))

        #expect(response == ControlResponse(ok: false,
                                            error: "invalid focus mode: pin (\(ControlWorkspaceFocusMode.validNamesList))"))
        #expect(actions.calls.isEmpty)
    }

    @Test func workspaceFocusRejectionListsEveryAcceptedMode() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .workspaceFocus, target: "work", args: ControlArgs(mode: "pin")))

        let error = response?.error ?? ""
        for mode in ControlWorkspaceFocusMode.allCases {
            #expect(error.contains(mode.rawValue))
        }
    }

    @Test func workspaceFilterRoutesModesAndKeepsExactResponse() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextWorkspaceFilterResponse = ControlResponse(ok: true)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .workspaceFilter, args: ControlArgs(mode: "on")))

        #expect(response == ControlResponse(ok: true))
        #expect(actions.calls == [.workspaceFilter(window: nil, .on)])
    }

    @Test(arguments: [("on", ControlToggleMode.on), ("off", .off), ("toggle", .toggle)])
    func workspaceFilterParsesEveryMode(raw: String, expected: ControlToggleMode) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .workspaceFilter, args: ControlArgs(mode: raw)))

        #expect(actions.calls == [.workspaceFilter(window: nil, expected)])
    }

    @Test func workspaceFilterDefaultsToToggle() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .workspaceFilter))

        #expect(actions.calls == [.workspaceFilter(window: nil, .toggle)])
    }

    @Test func workspaceFilterCarriesTheWindowSelector() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .workspaceFilter, args: ControlArgs(mode: "off", window: "win")))

        #expect(actions.calls == [.workspaceFilter(window: "win", .off)])
    }

    @Test func workspaceFilterRejectsUnknownModeWithoutCallingActions() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .workspaceFilter, args: ControlArgs(mode: "show")))

        #expect(response == ControlResponse(ok: false, error: "invalid workspace filter mode: show"))
        #expect(actions.calls.isEmpty)
    }

    @Test func workspaceFilterPropagatesTheActionResponse() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextWorkspaceFilterResponse = ControlResponse(ok: false, error: "no open window")

        let response = await dispatcher.dispatch(ControlRequest(cmd: .workspaceFilter, args: ControlArgs(mode: "on")))

        #expect(response == ControlResponse(ok: false, error: "no open window"))
    }
}
