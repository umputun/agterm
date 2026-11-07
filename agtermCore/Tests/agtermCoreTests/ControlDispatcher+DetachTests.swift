import Foundation
import Testing
@testable import agtermCore

@MainActor
struct ControlDispatcherDetachTests {
    private func dispatch(_ cmd: Command, target: String? = nil, _ args: ControlArgs? = nil) async -> ControlResponse? {
        await ControlDispatcher(actions: MockControlActions()).dispatch(ControlRequest(cmd: cmd, target: target, args: args))
    }

    @Test(arguments: [(Command.sessionDetach, "active"), (.sessionReattach, "abc"), (.workspaceDetach, "active"), (.workspaceReattach, "abc"),
                      (.windowRemoteDismiss, "active")])
    func everyDetachCommandReachesItsOwnActionWhichALocalHostRefuses(_ cmd: Command, _ target: String) async {
        let response = await dispatch(cmd, target: target)

        #expect(response?.error == "\(cmd.rawValue) acts only on a remote window")
    }

    @Test(arguments: [(Command.sessionReattach, "session.reattach requires a detached session's id"),
                      (.workspaceReattach, "workspace.reattach requires a detached workspace's id")])
    func aReattachWithoutAnIdIsRefusedBeforeTheHost(_ cmd: Command, _ error: String) async {
        let missing = await dispatch(cmd)
        let active = await dispatch(cmd, target: "Active")

        #expect(missing?.error == error)
        #expect(active?.error == error)
    }

    @Test func anEmptyDetachBatchIsRefused() async {
        let response = await dispatch(.sessionDetach, ControlArgs(targets: []))

        #expect(response?.error == "session.detach requires at least one --target")
    }
}
