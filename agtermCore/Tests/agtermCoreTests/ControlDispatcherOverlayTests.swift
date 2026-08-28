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

    // `open` and `resize` share the field, the documented 1...100 range and the host clamp behind it, so
    // they have to share the refusal too: without this, `open` answers ok and silently clamps while the
    // sibling errors on the same value. The conflict check stays ahead of the range check, as in `resize`.
    @Test func sessionOverlayOpenRejectsOutOfRangeSizePercent() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let tooBig = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayOpen, target: "session", args: ControlArgs(command: "cat", sizePercent: 101)))
        let tooSmall = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayOpen, target: "session", args: ControlArgs(command: "cat", sizePercent: 0)))
        let withPane = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayOpen, target: "session",
            args: ControlArgs(command: "cat", sizePercent: 500, pane: "right")))

        #expect(tooBig == ControlResponse(ok: false, error: "session.overlay.open: --size-percent must be 1...100"))
        #expect(tooSmall == ControlResponse(ok: false, error: "session.overlay.open: --size-percent must be 1...100"))
        #expect(withPane == ControlResponse(ok: false, error: PaneOverlayError.sizePercentConflict))
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
        let copy = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayCopy, target: "session", args: ControlArgs(pane: "scratch")))
        let text = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayText, target: "session", args: ControlArgs(pane: "middle")))

        #expect(open == ControlResponse(ok: false, error: PaneOverlayError.invalidPane))
        #expect(close == ControlResponse(ok: false, error: PaneOverlayError.invalidPane))
        #expect(result == ControlResponse(ok: false, error: PaneOverlayError.invalidPane))
        #expect(copy == ControlResponse(ok: false, error: PaneOverlayError.invalidPane))
        #expect(text == ControlResponse(ok: false, error: PaneOverlayError.invalidPane))
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

    @Test func sessionOverlayCopyRoutesTargetWindowAndPaneAndEchoesActionResponse() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextOverlayCopyResponse = ControlResponse(ok: true, result: ControlResult(text: "picked"))

        let scoped = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayCopy, target: "session", args: ControlArgs(window: "win", pane: "split")))
        let sessionWide = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayCopy, target: "session"))

        #expect(scoped == ControlResponse(ok: true, result: ControlResult(text: "picked")))
        #expect(sessionWide == ControlResponse(ok: true, result: ControlResult(text: "picked")))
        #expect(actions.calls == [
            .overlayCopy(target: "session", window: "win", pane: .right),
            .overlayCopy(target: "session", window: nil, pane: nil)
        ])
    }

    @Test func sessionOverlayTextRoutesExtentPaneAndWindow() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayText, target: "session",
            args: ControlArgs(window: "win", pane: "primary", all: true)))
        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayText, target: "session", args: ControlArgs(lines: 12)))
        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayText, target: "session"))

        #expect(actions.calls == [
            .overlayText(target: "session", window: "win",
                         ControlSessionOverlayTextOptions(pane: .left, all: true, lines: nil)),
            .overlayText(target: "session", window: nil,
                         ControlSessionOverlayTextOptions(pane: nil, all: false, lines: 12)),
            .overlayText(target: "session", window: nil,
                         ControlSessionOverlayTextOptions(pane: nil, all: false, lines: nil))
        ])
    }

    @Test func sessionOverlayTextRejectsConflictingAndNonpositiveExtentBeforeThePane() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let both = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayText, target: "session", args: ControlArgs(all: true, lines: 5)))
        let zero = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayText, target: "session", args: ControlArgs(lines: 0)))
        let negative = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayText, target: "session", args: ControlArgs(lines: -3)))
        let extentAndPane = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayText, target: "session", args: ControlArgs(pane: "scratch", all: true, lines: 5)))

        #expect(both == ControlResponse(ok: false, error: "use either --all or --lines, not both"))
        #expect(zero == ControlResponse(ok: false, error: "--lines must be greater than 0"))
        #expect(negative == ControlResponse(ok: false, error: "--lines must be greater than 0"))
        #expect(extentAndPane == ControlResponse(ok: false, error: "use either --all or --lines, not both"))
        #expect(actions.calls.isEmpty)
    }
}
