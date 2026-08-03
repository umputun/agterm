import Foundation
import Testing
@testable import agtermCore

@MainActor
struct ControlDispatcherHudTests {
    @Test func openRejectsMissingAndEmptyMessageWithoutCallingHost() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let missing = await dispatcher.dispatch(ControlRequest(cmd: .sessionHudOpen))
        let empty = await dispatcher.dispatch(ControlRequest(cmd: .sessionHudOpen,
                                                             args: ControlArgs(message: "", detail: "still here")))

        let expected = ControlResponse(ok: false, error: "session.hud.open requires a message")
        #expect(missing == expected)
        #expect(empty == expected)
        #expect(actions.calls.isEmpty)
    }

    @Test func updateRejectsMissingAndEmptyMessageWithoutCallingHost() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let missing = await dispatcher.dispatch(ControlRequest(cmd: .sessionHudUpdate))
        let empty = await dispatcher.dispatch(ControlRequest(cmd: .sessionHudUpdate, args: ControlArgs(message: "")))

        let expected = ControlResponse(ok: false, error: "session.hud.update requires a message")
        #expect(missing == expected)
        #expect(empty == expected)
        #expect(actions.calls.isEmpty)
    }

    @Test func rejectsControlCharactersInMessageAndDetailWithoutCallingHost() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let escape = await dispatcher.dispatch(ControlRequest(cmd: .sessionHudOpen,
                                                              args: ControlArgs(message: "paint\u{1b}[2Jme")))
        let newline = await dispatcher.dispatch(ControlRequest(cmd: .sessionHudOpen,
                                                               args: ControlArgs(message: "two\nlines")))
        let detail = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionHudUpdate,
            args: ControlArgs(message: "fine", detail: "bad\u{7f}")
        ))

        let expected = ControlResponse(ok: false, error: "hud text must not contain control characters")
        #expect(escape == expected)
        #expect(newline == expected)
        #expect(detail == expected)
        #expect(actions.calls.isEmpty)
    }

    @Test func rejectsOversizedMessageAndDetailWithoutCallingHost() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        let tooLong = String(repeating: "a", count: HudSpec.maxTextLength + 1)
        let atCap = String(repeating: "b", count: HudSpec.maxTextLength)

        let message = await dispatcher.dispatch(ControlRequest(cmd: .sessionHudOpen,
                                                               args: ControlArgs(message: tooLong)))
        let detail = await dispatcher.dispatch(ControlRequest(cmd: .sessionHudOpen,
                                                              args: ControlArgs(message: "fine", detail: tooLong)))
        let accepted = await dispatcher.dispatch(ControlRequest(cmd: .sessionHudOpen,
                                                                args: ControlArgs(message: atCap, detail: atCap)))

        #expect(message == ControlResponse(ok: false, error: "hud message too long (max 256 characters)"))
        #expect(detail == ControlResponse(ok: false, error: "hud detail too long (max 256 characters)"))
        #expect(accepted == ControlResponse(ok: true))
        #expect(actions.calls.count == 1)
    }

    @Test func rejectsInvalidColorWithoutCallingHost() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionHudOpen,
            args: ControlArgs(message: "working", color: "blue")
        ))

        #expect(response == ControlResponse(ok: false, error: "invalid color: blue (#rrggbb)"))
        #expect(actions.calls.isEmpty)
    }

    @Test func rejectsSizePercentOutsideRangeWithoutCallingHost() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let zero = await dispatcher.dispatch(ControlRequest(cmd: .sessionHudOpen,
                                                            args: ControlArgs(sizePercent: 0, message: "working")))
        let over = await dispatcher.dispatch(ControlRequest(cmd: .sessionHudUpdate,
                                                            args: ControlArgs(sizePercent: 101, message: "working")))

        #expect(zero == ControlResponse(ok: false, error: "session.hud.open: --size-percent must be 1...100"))
        #expect(over == ControlResponse(ok: false, error: "session.hud.update: --size-percent must be 1...100"))
        #expect(actions.calls.isEmpty)
    }

    @Test func rejectsUnknownPositionWithoutCallingHost() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        // `top-left` is a valid session.background position, so the shared field must be re-validated here
        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionHudOpen,
            args: ControlArgs(message: "working", position: "top-left")
        ))

        #expect(response == ControlResponse(ok: false, error: "invalid position: top-left (top|center|bottom)"))
        #expect(actions.calls.isEmpty)
    }

    @Test func openRoutesParsedSpecAndReturnsHostResponse() async throws {
        let actions = MockControlActions()
        let expected = ControlResponse(ok: true, result: ControlResult(id: "session-id"))
        actions.nextHudOpenResponse = expected
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionHudOpen,
            target: "session-id",
            args: ControlArgs(sizePercent: 40, message: "gathering options", detail: "scanning 400 files",
                              spinner: true, window: "window-id", color: "#112233", position: "top")
        ))

        #expect(response == expected)
        let call = try #require(actions.calls.first)
        #expect(call == .hudOpen(target: "session-id", window: "window-id",
                                 HudSpec(message: "gathering options", detail: "scanning 400 files", spinner: true,
                                         backgroundColor: "#112233", sizePercent: 40, position: .top)))
    }

    @Test func updateRoutesParsedSpecAndReturnsHostResponse() async throws {
        let actions = MockControlActions()
        let expected = ControlResponse(ok: true, result: ControlResult(id: "session-id"))
        actions.nextHudUpdateResponse = expected
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionHudUpdate,
            target: "session-id",
            args: ControlArgs(message: "still working", detail: "312 of 400", position: "bottom")
        ))

        #expect(response == expected)
        let call = try #require(actions.calls.first)
        #expect(call == .hudUpdate(target: "session-id", window: nil,
                                   HudSpec(message: "still working", detail: "312 of 400", position: .bottom)))
    }

    @Test func omittedPositionSpinnerAndOverridesTakeTheirDefaults() async throws {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionHudOpen, args: ControlArgs(message: "working")))

        let call = try #require(actions.calls.first)
        guard case let .hudOpen(_, _, spec) = call else {
            Issue.record("expected session.hud.open host call")
            return
        }
        #expect(spec.position == .center)
        #expect(!spec.spinner)
        #expect(spec.detail == nil)
        #expect(spec.backgroundColor == nil)
        #expect(spec.sizePercent == nil)
    }

    @Test(arguments: HudPosition.allCases)
    func everyPositionRoundTripsToTheHost(position: HudPosition) async throws {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionHudOpen,
            args: ControlArgs(message: "working", position: position.rawValue)
        ))

        let call = try #require(actions.calls.first)
        guard case let .hudOpen(_, _, spec) = call else {
            Issue.record("expected session.hud.open host call")
            return
        }
        #expect(spec.position == position)
    }

    @Test func closeRoutesTargetAndWindowAndIgnoresEverythingElse() async {
        let actions = MockControlActions()
        let expected = ControlResponse(ok: true, result: ControlResult(id: "session-id"))
        actions.nextHudCloseResponse = expected
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionHudClose,
            target: "session-id",
            args: ControlArgs(message: "", window: "window-id", color: "not a color", position: "nowhere")
        ))

        #expect(response == expected)
        #expect(actions.calls == [.hudClose(target: "session-id", window: "window-id")])
    }
}
