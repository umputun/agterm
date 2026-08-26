import Testing
@testable import agtermCore

/// `session.move`'s cross-window form: routing the destination window (and its optional workspace) and
/// refusing the in-store placement flags, whose positions only resolve within one store.
@MainActor
struct ControlDispatcherSessionMoveTests {
    @Test func sessionMoveRoutesCrossWindowForm() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let bare = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionMove,
            target: "session",
            args: ControlArgs(toWindow: "other")
        ))
        let workspaced = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionMove,
            target: "session",
            args: ControlArgs(workspace: "dest", select: true, window: "win", toWindow: "other")
        ))
        let batch = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionMove,
            args: ControlArgs(targets: ["a", "b"], toWindow: "other")
        ))

        #expect(bare == ControlResponse(ok: true))
        #expect(workspaced == ControlResponse(ok: true))
        #expect(batch == ControlResponse(ok: true))
        #expect(actions.calls == [
            .sessionMove(target: "session", window: nil, .window(window: "other", workspace: nil), select: false),
            .sessionMove(target: "session", window: "win", .window(window: "other", workspace: "dest"), select: true),
            .sessionMoveBatch(targets: ["a", "b"], window: nil, .window(window: "other", workspace: nil),
                              select: false),
        ])
    }

    @Test func sessionMoveRejectsCrossWindowWithInStorePlacement() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let withTo = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionMove,
            target: "active",
            args: ControlArgs(toWindow: "other", to: "up")
        ))
        let withAfter = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionMove,
            target: "active",
            args: ControlArgs(toWindow: "other", after: "anchor")
        ))
        let withBefore = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionMove,
            target: "active",
            args: ControlArgs(toWindow: "other", before: "anchor")
        ))

        #expect(withTo == ControlResponse(ok: false, error: "session.move takes --to-window or --to, not both"))
        #expect(withAfter == ControlResponse(
            ok: false, error: "session.move takes --to-window or --after/--before, not both"))
        #expect(withBefore == ControlResponse(
            ok: false, error: "session.move takes --to-window or --after/--before, not both"))
        #expect(actions.calls.isEmpty)
    }

    // destination resolution belongs to the host, which alone knows the open window set: the dispatcher
    // must hand every spelling over untouched instead of pre-judging it.
    @Test func sessionMoveForwardsUnresolvedDestinationSpellings() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        for destination in ["active", "7b33", "no-such-window"] {
            let response = await dispatcher.dispatch(ControlRequest(
                cmd: .sessionMove,
                target: "session",
                args: ControlArgs(toWindow: destination)
            ))
            #expect(response == ControlResponse(ok: true))
        }

        #expect(actions.calls == ["active", "7b33", "no-such-window"].map {
            .sessionMove(target: "session", window: nil, .window(window: $0, workspace: nil), select: false)
        })
    }
}
