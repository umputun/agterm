import Foundation
import Testing
@testable import agtermCore

@MainActor
struct ControlDispatcherOverlayTests {
    @Test func sessionOverlayOpenRejectsInvalidInputsBeforeCallingActions() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let missing = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayOpen, target: "session"))
        let empty = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayOpen,
            target: "session",
            args: ControlArgs(command: "")
        ))
        let badColor = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayOpen,
            target: "session",
            args: ControlArgs(command: "cat", color: "purple")
        ))

        #expect(missing == ControlResponse(ok: false, error: "session.overlay.open requires a command"))
        #expect(empty == ControlResponse(ok: false, error: "session.overlay.open requires a command"))
        #expect(badColor == ControlResponse(ok: false, error: "invalid color: purple (#rrggbb)"))
        #expect(actions.calls.isEmpty)
    }

    @Test func sessionOverlayOpenRoutesOptionsAndEchoesActionResponse() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextOverlayOpenResponse = ControlResponse(ok: false, error: "overlay already open")

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayOpen,
            target: "session",
            args: ControlArgs(cwd: "/tmp", command: "cat", wait: true,
                              sizePercent: 70, follow: true, window: "win", color: "#2a1a3a")
        ))

        #expect(response == ControlResponse(ok: false, error: "overlay already open"))
        #expect(actions.calls == [
            .overlayOpen(target: "session", window: "win",
                         ControlSessionOverlayOpenOptions(command: "cat", cwd: "/tmp", wait: true,
                                                          sizePercent: 70, backgroundColor: "#2a1a3a",
                                                          follow: true))
        ])
    }

    @Test func sessionOverlayOpenDefaultsFollowToFalseWhenOmitted() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextOverlayOpenResponse = ControlResponse(ok: true, result: ControlResult(id: "session"))

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayOpen,
            target: "session",
            args: ControlArgs(command: "cat")
        ))

        #expect(response == ControlResponse(ok: true, result: ControlResult(id: "session")))
        #expect(actions.calls == [
            .overlayOpen(target: "session", window: nil,
                         ControlSessionOverlayOpenOptions(command: "cat", cwd: nil, wait: false,
                                                          sizePercent: nil, backgroundColor: nil,
                                                          follow: false))
        ])
    }

    @Test func sessionOverlayCloseAndResultRouteTargetAndWindow() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextOverlayCloseResponse = ControlResponse(ok: true, result: ControlResult(id: "session"))
        actions.nextOverlayResultResponse = ControlResponse(ok: true, result: ControlResult(id: "session", exitCode: 7))

        let close = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayClose,
            target: "session",
            args: ControlArgs(window: "win")
        ))
        let result = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayResult,
            target: "session",
            args: ControlArgs(window: "win")
        ))

        #expect(close == ControlResponse(ok: true, result: ControlResult(id: "session")))
        #expect(result == ControlResponse(ok: true, result: ControlResult(id: "session", exitCode: 7)))
        #expect(actions.calls == [
            .overlayClose(target: "session", window: "win", pane: nil),
            .overlayResult(target: "session", window: "win", pane: nil)
        ])
    }

    @Test func sessionOverlayResultKeepsExactActionErrorResponse() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextOverlayResultResponse = ControlResponse(ok: false, error: OverlayResultError.stillRunning)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayResult, target: "session"))

        #expect(response == ControlResponse(ok: false, error: OverlayResultError.stillRunning))
        #expect(actions.calls == [.overlayResult(target: "session", window: nil, pane: nil)])
    }

    @Test func sessionOverlayResizeRoutesSizePercentAndWindow() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextOverlayResizeResponse = ControlResponse(ok: true, result: ControlResult(id: "session"))

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayResize, target: "session",
            args: ControlArgs(sizePercent: 60, window: "win")
        ))

        #expect(response == ControlResponse(ok: true, result: ControlResult(id: "session")))
        #expect(actions.calls == [.overlayResize(target: "session", window: "win", sizePercent: 60)])
    }

    @Test func sessionOverlayResizeFullRoutesNilSizePercent() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayResize, target: "session", args: ControlArgs(full: true)
        ))

        #expect(response?.ok == true)
        #expect(actions.calls == [.overlayResize(target: "session", window: nil, sizePercent: nil)])
    }

    @Test func sessionOverlayResizeRejectsMissingConflictingAndOutOfRange() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let missing = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayResize, target: "session"))
        let both = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayResize, target: "session", args: ControlArgs(sizePercent: 50, full: true)))
        let tooBig = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayResize, target: "session", args: ControlArgs(sizePercent: 101)))
        let tooSmall = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayResize, target: "session", args: ControlArgs(sizePercent: 0)))

        #expect(missing == ControlResponse(ok: false, error: "session.overlay.resize requires --size-percent or --full"))
        #expect(both == ControlResponse(ok: false, error: "session.overlay.resize: --full is mutually exclusive with --size-percent"))
        #expect(tooBig == ControlResponse(ok: false, error: "session.overlay.resize: --size-percent must be 1...100"))
        #expect(tooSmall == ControlResponse(ok: false, error: "session.overlay.resize: --size-percent must be 1...100"))
        #expect(actions.calls.isEmpty)
    }

    @Test func sessionOverlayOpenRoutesPaneAndClearsSizePercent() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextOverlayOpenResponse = ControlResponse(ok: true, result: ControlResult(id: "session"))

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayOpen, target: "session",
            args: ControlArgs(cwd: "/tmp", command: "cat", wait: true, window: "win", pane: "right",
                              color: "#2a1a3a")
        ))

        #expect(response == ControlResponse(ok: true, result: ControlResult(id: "session")))
        #expect(actions.calls == [
            .overlayOpen(target: "session", window: "win",
                         ControlSessionOverlayOpenOptions(command: "cat", cwd: "/tmp", wait: true,
                                                          sizePercent: nil, backgroundColor: "#2a1a3a",
                                                          follow: false, pane: .right))
        ])
    }

    @Test func sessionOverlayCommandsAcceptPrimaryAndSplitPaneSpellings() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayOpen, target: "session", args: ControlArgs(command: "cat", pane: "primary")))
        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayClose, target: "session", args: ControlArgs(pane: "split")))

        #expect(actions.calls == [
            .overlayOpen(target: "session", window: nil,
                         ControlSessionOverlayOpenOptions(command: "cat", cwd: nil, wait: false,
                                                          sizePercent: nil, backgroundColor: nil,
                                                          follow: false, pane: .left)),
            .overlayClose(target: "session", window: nil, pane: .right)
        ])
    }

    @Test func sessionOverlayCloseAndResultRoutePane() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayClose, target: "session", args: ControlArgs(window: "win", pane: "left")))
        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayResult, target: "session", args: ControlArgs(pane: "right")))

        #expect(actions.calls == [
            .overlayClose(target: "session", window: "win", pane: .left),
            .overlayResult(target: "session", window: nil, pane: .right)
        ])
    }

    @Test func sessionOverlayRejectsInvalidPaneOnEveryCommand() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let open = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayOpen, target: "session", args: ControlArgs(command: "cat", pane: "scratch")))
        let close = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayClose, target: "session", args: ControlArgs(pane: "scratch")))
        let result = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayResult, target: "session", args: ControlArgs(pane: "middle")))

        #expect(open == ControlResponse(ok: false, error: PaneOverlayError.invalidPane))
        #expect(close == ControlResponse(ok: false, error: PaneOverlayError.invalidPane))
        #expect(result == ControlResponse(ok: false, error: PaneOverlayError.invalidPane))
        #expect(actions.calls.isEmpty)
    }

    @Test func sessionOverlayOpenRejectsPaneWithSizePercent() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayOpen, target: "session",
            args: ControlArgs(command: "cat", sizePercent: 60, pane: "left")))

        #expect(response == ControlResponse(ok: false, error: PaneOverlayError.sizePercentConflict))
        #expect(actions.calls.isEmpty)
    }

    @Test func sessionOverlayResizeRejectsAnyPane() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let valid = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayResize, target: "session", args: ControlArgs(sizePercent: 60, pane: "left")))
        let invalid = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayResize, target: "session", args: ControlArgs(full: true, pane: "scratch")))

        #expect(valid == ControlResponse(ok: false, error: PaneOverlayError.resizeUnsupported))
        #expect(invalid == ControlResponse(ok: false, error: PaneOverlayError.resizeUnsupported))
        #expect(actions.calls.isEmpty)
    }

    @Test func sessionOverlayCommandsStaySessionWideWithoutPane() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayOpen, target: "session",
            args: ControlArgs(command: "cat", sizePercent: 70)))
        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayClose, target: "session"))
        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayResult, target: "session"))
        let resize = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayResize, target: "session", args: ControlArgs(sizePercent: 60)))

        #expect(resize?.ok == true)
        #expect(actions.calls == [
            .overlayOpen(target: "session", window: nil,
                         ControlSessionOverlayOpenOptions(command: "cat", cwd: nil, wait: false,
                                                          sizePercent: 70, backgroundColor: nil,
                                                          follow: false, pane: nil)),
            .overlayClose(target: "session", window: nil, pane: nil),
            .overlayResult(target: "session", window: nil, pane: nil),
            .overlayResize(target: "session", window: nil, sizePercent: 60)
        ])
    }
}
