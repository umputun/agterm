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

    @Test(arguments: [(String?.none, "session.overlay.job.run requires a job id"), ("  ", "session.overlay.job.run requires a job id"),
                      ("not-a-uuid", "invalid job id")])
    func jobRunRejectsAMissingOrMalformedJobBeforeCallingActions(_ target: String?, _ error: String) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayJobRun, target: target))

        #expect(response == ControlResponse(ok: false, error: error))
        #expect(actions.calls.isEmpty)
    }

    @Test func jobRunRoutesTheJobToTheHostsClaim() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        let job = UUID().uuidString

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayJobRun, target: job))

        #expect(response == ControlResponse(ok: true, result: ControlResult(id: job)))
        #expect(actions.calls == [.claimOverlayJob(job)])
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

    @Test(arguments: [
        (ControlArgs(command: "cat", html: "/tmp/r.html"), OverlayHtmlError.commandAndHtml),
        (ControlArgs(wait: true, html: "/tmp/r.html"), OverlayHtmlError.waitWithHtml),
        (ControlArgs(cwd: "/tmp/a", html: "/tmp/b/r.html"), "session.overlay.open: html file is outside cwd"),
        (ControlArgs(cwd: "/tmp/r.html", html: "/tmp/r.html"), "session.overlay.open: cwd must be a directory containing the html file"),
        (ControlArgs(html: "r.html"), "session.overlay.open: html file must be an absolute path"),
        (ControlArgs(sizePercent: 50, pane: "left", html: "/tmp/r.html"), PaneOverlayError.sizePercentConflict),
        (ControlArgs(command: "cat", navigation: true), OverlayHtmlError.navigationWithoutPage),
        (ControlArgs(html: "/tmp/r.html", url: "http://localhost:5173/"), OverlayHtmlError.htmlAndURL),
        (ControlArgs(command: "cat", url: "http://localhost:5173/"), OverlayHtmlError.commandAndURL),
        (ControlArgs(wait: true, url: "http://localhost:5173/"), OverlayHtmlError.waitWithURL),
        (ControlArgs(cwd: "/tmp", url: "http://localhost:5173/"), OverlayHtmlError.cwdWithURL),
        (ControlArgs(url: "ftp://example.com/"), OverlayHtmlError.invalidURL),
        (ControlArgs(url: "localhost:5173"), OverlayHtmlError.invalidURL),
    ])
    func htmlOpenRejectsInvalidInputsBeforeCallingActions(_ args: ControlArgs, _ error: String) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayOpen, target: "session", args: args))

        #expect(response == ControlResponse(ok: false, error: error))
        #expect(actions.calls.isEmpty)
    }

    @Test func htmlOpenRoutesThePageAndItsGrant() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayOpen, target: "session",
            args: ControlArgs(cwd: "/tmp", follow: true, pane: "right", color: "#102030", html: "/tmp/a/r.html",
                              navigation: true)
        ))

        #expect(actions.calls == [
            .overlayOpen(target: "session", window: nil,
                         ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: nil,
                                                          backgroundColor: "#102030", follow: true, pane: .right,
                                                          page: .file(path: "/tmp/a/r.html", grantRoot: "/tmp"),
                                                          navigation: true))
        ])
    }

    @Test func urlOpenRoutesTheWebPageWithItsToolbar() async throws {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayOpen, target: "session",
            args: ControlArgs(sizePercent: 60, navigation: true, url: "http://localhost:5173/app")
        ))

        #expect(actions.calls == [
            .overlayOpen(target: "session", window: nil,
                         ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: 60,
                                                          backgroundColor: nil,
                                                          page: .url(try #require(URL(string: "http://localhost:5173/app"))),
                                                          navigation: true))
        ])
    }

    @Test func reloadRoutesThePaneAndRejectsABadOne() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let bad = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayReload, target: "session",
                                                           args: ControlArgs(pane: "middle")))
        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayReload, target: "session",
                                                     args: ControlArgs(window: "win", pane: "split")))

        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayReload, target: "session",
                                                     args: ControlArgs(current: true)))

        #expect(bad == ControlResponse(ok: false, error: PaneOverlayError.invalidPane))
        #expect(actions.calls == [.overlayReload(target: "session", window: "win", pane: .right, current: false),
                                  .overlayReload(target: "session", window: nil, pane: nil, current: true)])
    }

    @Test(arguments: [("back", HtmlNavigation.back), ("forward", .forward), ("browser", .browser)])
    func navigateRoutesTheStepAndPane(_ name: String, _ navigation: HtmlNavigation) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayNavigate, target: "session",
                                                     args: ControlArgs(pane: "left", to: name)))

        #expect(actions.calls == [.overlayNavigate(target: "session", window: nil, pane: .left, navigation)])
    }

    @Test(arguments: [(String?.none, OverlayHtmlError.navigation), ("up", OverlayHtmlError.navigation)])
    func navigateRejectsAMissingOrUnknownStep(_ name: String?, _ error: String) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayNavigate, target: "session",
                                                                args: ControlArgs(to: name)))

        #expect(response == ControlResponse(ok: false, error: error))
        #expect(actions.calls.isEmpty)
    }

    @Test(arguments: [
        (HtmlOverlayOpenFailure.unknownSession, OverlayPane?.none, "no such session"),
        (.alreadyOpen, nil, "overlay already open"),
        (.alreadyOpen, .left, PaneOverlayError.alreadyOpen),
        (.paneNotVisible, .right, PaneOverlayError.paneNotVisible),
        (.presenter, nil, OverlayHtmlError.presenter),
    ])
    func openFailuresMapToTheirMessages(_ failure: HtmlOverlayOpenFailure, _ pane: OverlayPane?, _ message: String) {
        #expect(failure.message(pane: pane) == message)
    }

    @Test(arguments: [
        (HtmlOverlayCommandFailure.unknownSession, "no such session"),
        (.noOverlay, OverlayHtmlError.noOverlay),
        (.notHtml, OverlayHtmlError.notHtml),
    ])
    func commandFailuresMapToTheirMessages(_ failure: HtmlOverlayCommandFailure, _ message: String) {
        #expect(failure.message == message)
    }
}
