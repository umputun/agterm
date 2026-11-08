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

    @Test(arguments: [(String?.none, "session.overlay.page.serve requires a page token"),
                      ("  ", "session.overlay.page.serve requires a page token"), ("not-a-uuid", "invalid page token")])
    func pageServeRejectsAMissingOrMalformedTokenBeforeCallingActions(_ target: String?, _ error: String) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayPageServe, target: target))

        #expect(response == ControlResponse(ok: false, error: error))
        #expect(actions.calls.isEmpty)
    }

    @Test func pageServeReachesTheHostsClaimWhichDefaultsToUnsupported() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayPageServe, target: UUID().uuidString))

        #expect(response == ControlResponse(ok: false, error: "session.overlay.page.serve is not supported on this platform"))
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

    @Test func sessionOverlaySubmitRoutesValuePaneAndWindow() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let submit = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlaySubmit, target: "session", args: ControlArgs(window: "win", pane: "right", value: "")))

        #expect(submit == ControlResponse(ok: true))
        #expect(actions.calls == [.overlaySubmit(target: "session", window: "win", pane: .right, value: "")])
    }

    @Test func sessionOverlaySubmitRefusesAMissingValueOrABadPane() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let missing = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlaySubmit, target: "session"))
        let badPane = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlaySubmit, target: "session", args: ControlArgs(pane: "middle", value: "x")))

        #expect(missing == ControlResponse(ok: false, error: OverlayHtmlError.submitValue))
        #expect(badPane?.ok == false)
        #expect(actions.calls.isEmpty)
    }

    @Test func sessionOverlayResultWithAPageReadsThePageOutcome() async throws {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        let id = UUID()

        let page = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayResult, target: "session", args: ControlArgs(page: id.uuidString)))
        let invalid = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayResult, args: ControlArgs(page: "not-a-uuid")))

        #expect(page == ControlResponse(ok: true))
        #expect(invalid == ControlResponse(ok: false, error: OverlayHtmlError.invalidPageID))
        #expect(actions.calls == [.pageResult(id)])
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

        #expect(missing == ControlResponse(ok: false, error: "session.overlay.resize requires --size-percent, --width/--height or --full"))
        #expect(both == ControlResponse(ok: false, error: "session.overlay.resize: --full is mutually exclusive with --size-percent"))
        #expect(tooBig == ControlResponse(ok: false, error: "session.overlay.resize: --size-percent must be 1...100"))
        #expect(tooSmall == ControlResponse(ok: false, error: "session.overlay.resize: --size-percent must be 1...100"))
        #expect(actions.calls.isEmpty)
    }

    @Test func sessionOverlayResizeRoutesPointsWithAndWithoutAPercent() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayResize, target: "session", args: ControlArgs(height: 240)))
        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayResize, target: "session", args: ControlArgs(sizePercent: 60, window: "win", width: 700)))

        #expect(actions.calls == [
            .overlayPointResize(target: "session", window: nil, sizePercent: nil, points: OverlayPointSize(height: 240)),
            .overlayPointResize(target: "session", window: "win", sizePercent: 60, points: OverlayPointSize(width: 700)),
        ])
    }

    @Test(arguments: [
        (ControlArgs(full: true, height: 240), OverlayPointError.fullConflict),
        (ControlArgs(height: 0), OverlayPointError.notPositive),
        (ControlArgs(sizePercent: 60, width: -5), OverlayPointError.notPositive),
        (ControlArgs(pane: "right", height: 240), PaneOverlayError.resizeUnsupported),
    ])
    func sessionOverlayResizeRefusesBadPoints(args: ControlArgs, error: String) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayResize, target: "session", args: args))

        #expect(response == ControlResponse(ok: false, error: error))
        #expect(actions.calls.isEmpty)
    }

    @Test func sessionOverlayOpenRoutesPointsBesideThePercent() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayOpen, target: "session",
            args: ControlArgs(command: "cat", sizePercent: 60, width: 500, height: 240)))

        guard case .overlayOpen(_, _, let options) = actions.calls.first else {
            Issue.record("expected an overlay open, got \(actions.calls)")
            return
        }
        #expect(options.sizePercent == 60)
        #expect(options.points == OverlayPointSize(width: 500, height: 240))
    }

    @Test(arguments: [
        (ControlArgs(command: "cat", height: 240), OverlayPointError.needsPercent),
        (ControlArgs(command: "cat", sizePercent: 60, height: 0), OverlayPointError.notPositive),
        (ControlArgs(command: "cat", pane: "right", width: 300), PaneOverlayError.pointsConflict),
    ])
    func sessionOverlayOpenRefusesBadPoints(args: ControlArgs, error: String) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayOpen, target: "session", args: args))

        #expect(response == ControlResponse(ok: false, error: error))
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
        (ControlArgs(cwd: "/", html: "/tmp/r.html"), "session.overlay.open: cwd must not be / or the home directory"),
        (ControlArgs(cwd: NSHomeDirectory(), html: NSHomeDirectory() + "/r.html"),
         "session.overlay.open: cwd must not be / or the home directory"),
        (ControlArgs(sizePercent: 50, pane: "left", html: "/tmp/r.html"), PaneOverlayError.sizePercentConflict),
        (ControlArgs(command: "cat", navigation: true), OverlayHtmlError.navigationWithoutPage),
        (ControlArgs(command: "cat", javascript: true), OverlayHtmlError.javascriptWithoutPage),
        (ControlArgs(command: "cat", chromeless: true), OverlayHtmlError.chromelessRequiresFile),
        (ControlArgs(url: "http://example.com/", chromeless: true), OverlayHtmlError.chromelessRequiresLoopback),
        (ControlArgs(url: "http://127.0.0.2:8792/", chromeless: true), OverlayHtmlError.chromelessRequiresLoopback),
        (ControlArgs(navigation: true, url: "http://localhost:5173/", chromeless: true), OverlayHtmlError.chromelessWithNavigation),
        (ControlArgs(html: "/tmp/r.html", navigation: true, chromeless: true), OverlayHtmlError.chromelessWithNavigation),
        (ControlArgs(command: "cat", persistent: true), OverlayHtmlError.persistentRequiresURL),
        (ControlArgs(html: "/tmp/r.html", persistent: true), OverlayHtmlError.persistentRequiresURL),
        (ControlArgs(command: "cat", browse: true), OverlayHtmlError.browseRequiresURL),
        (ControlArgs(html: "/tmp/r.html", browse: true), OverlayHtmlError.browseRequiresURL),
        (ControlArgs(url: "http://localhost:5173/", chromeless: true, browse: true), OverlayHtmlError.chromelessWithBrowse),
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
                              navigation: true, javascript: true)
        ))

        #expect(actions.calls == [
            .overlayOpen(target: "session", window: nil,
                         ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: nil,
                                                          backgroundColor: "#102030", follow: true, pane: .right,
                                                          page: .file(path: "/tmp/a/r.html", grantRoot: "/tmp"),
                                                          navigation: true, javascript: true))
        ])
    }

    @Test(arguments: [
        (ControlArgs(command: "cat", image: "/tmp/a.png"), OverlayHtmlError.oneSource),
        (ControlArgs(html: "/tmp/r.html", image: "/tmp/a.png"), OverlayHtmlError.oneSource),
        (ControlArgs(url: "http://localhost:5173/", image: "/tmp/a.png"), OverlayHtmlError.oneSource),
        (ControlArgs(wait: true, image: "/tmp/a.png"), OverlayHtmlError.imageOptions),
        (ControlArgs(cwd: "/tmp", image: "/tmp/a.png"), OverlayHtmlError.imageOptions),
        (ControlArgs(navigation: true, image: "/tmp/a.png"), OverlayHtmlError.imageOptions),
        (ControlArgs(javascript: true, image: "/tmp/a.png"), OverlayHtmlError.imageOptions),
        (ControlArgs(chromeless: true, image: "/tmp/a.png"), OverlayHtmlError.imageOptions),
        (ControlArgs(persistent: true, image: "/tmp/a.png"), OverlayHtmlError.imageOptions),
        (ControlArgs(browse: true, image: "/tmp/a.png"), OverlayHtmlError.imageOptions),
        (ControlArgs(image: "a.png"), OverlayHtmlError.imageNotAbsolute),
        (ControlArgs(image: "/tmp/a.svg"), OverlayHtmlError.imageType),
        (ControlArgs(image: "/tmp/a"), OverlayHtmlError.imageType),
        (ControlArgs(width: 400, image: "/tmp/a.png"), OverlayPointError.needsPercent),
        (ControlArgs(image: "/tmp/a.png", markdownFile: "/tmp/r.md"), OverlayHtmlError.oneSource),
    ])
    func imageOpenRejectsInvalidInputsBeforeCallingActions(_ args: ControlArgs, _ error: String) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayOpen, target: "session", args: args))

        #expect(response == ControlResponse(ok: false, error: error))
        #expect(actions.calls.isEmpty)
    }

    @Test func imageOpenRoutesTheStandardizedPathAndItsSize() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayOpen, target: "session",
            args: ControlArgs(sizePercent: 60, follow: true, width: 400, image: "/tmp/../tmp/Shot.PNG")
        ))

        #expect(actions.calls == [
            .overlayOpen(target: "session", window: nil,
                         ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: 60,
                                                          backgroundColor: nil, follow: true,
                                                          page: .image(path: "/tmp/Shot.PNG"),
                                                          points: OverlayPointSize(width: 400)))
        ])
    }

    @Test(arguments: [
        (ControlArgs(command: "cat", markdownFile: "/tmp/r.md"), OverlayHtmlError.oneSource),
        (ControlArgs(html: "/tmp/r.html", markdownFile: "/tmp/r.md"), OverlayHtmlError.oneSource),
        (ControlArgs(url: "http://localhost:5173/", markdownFile: "/tmp/r.md"), OverlayHtmlError.oneSource),
        (ControlArgs(wait: true, markdownFile: "/tmp/r.md"), OverlayHtmlError.markdownOptions),
        (ControlArgs(cwd: "/tmp", markdownFile: "/tmp/r.md"), OverlayHtmlError.markdownOptions),
        (ControlArgs(javascript: true, markdownFile: "/tmp/r.md"), OverlayHtmlError.markdownOptions),
        (ControlArgs(chromeless: true, markdownFile: "/tmp/r.md"), OverlayHtmlError.markdownOptions),
        (ControlArgs(persistent: true, markdownFile: "/tmp/r.md"), OverlayHtmlError.markdownOptions),
        (ControlArgs(browse: true, markdownFile: "/tmp/r.md"), OverlayHtmlError.markdownOptions),
        (ControlArgs(markdownFile: "r.md"), OverlayHtmlError.markdownNotAbsolute),
        (ControlArgs(markdownFile: "/tmp/r.txt"), OverlayHtmlError.markdownType),
        (ControlArgs(markdownFile: "/tmp/readme"), OverlayHtmlError.markdownType),
    ])
    func markdownOpenRejectsInvalidInputsBeforeCallingActions(_ args: ControlArgs, _ error: String) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayOpen, target: "session", args: args))

        #expect(response == ControlResponse(ok: false, error: error))
        #expect(actions.calls.isEmpty)
    }

    @Test func markdownOpenCarriesNavigationAndLeavesTheGrantToTheApp() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayOpen, target: "session",
                                                     args: ControlArgs(navigation: true, markdownFile: "/tmp/r.md")))

        #expect(actions.calls == [
            .overlayOpen(target: "session", window: nil,
                         ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil,
                                                          page: .markdown(path: "/tmp/r.md"), navigation: true))
        ])
    }

    @Test func navigationWithoutAPageNamesEveryPageThatTakesIt() async {
        let dispatcher = ControlDispatcher(actions: MockControlActions())

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayOpen, target: "session",
                                                                args: ControlArgs(command: "cat", navigation: true)))

        #expect(response?.error == "session.overlay.open: --navigation requires --html, --url or --markdown")
    }

    @Test(arguments: ["/tmp/../tmp/Notes.MD", "/tmp/notes.markdown"])
    func markdownOpenRoutesTheStandardizedPath(_ path: String) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayOpen, target: "session",
                                                     args: ControlArgs(sizePercent: 95, markdownFile: path)))

        #expect(actions.calls == [
            .overlayOpen(target: "session", window: nil,
                         ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: 95,
                                                          backgroundColor: nil,
                                                          page: .markdown(path: URL(fileURLWithPath: path).standardizedFileURL.path)))
        ])
    }

    @Test(arguments: [false, true])
    func pageCompanionRefusesAMarkdownFile(navigation: Bool) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sessionCompanionPage, target: "session",
                                                                args: ControlArgs(navigation: navigation, markdownFile: "/tmp/r.md")))

        #expect(response == ControlResponse(ok: false, error: OverlayHtmlError.companionNeedsPage))
        #expect(actions.calls.isEmpty)
    }

    @Test(arguments: [
        (ControlArgs(command: "cat", textFile: "/tmp/a.go"), OverlayHtmlError.oneSource),
        (ControlArgs(html: "/tmp/r.html", textFile: "/tmp/a.go"), OverlayHtmlError.oneSource),
        (ControlArgs(url: "http://localhost:5173/", textFile: "/tmp/a.go"), OverlayHtmlError.oneSource),
        (ControlArgs(image: "/tmp/a.png", textFile: "/tmp/a.go"), OverlayHtmlError.oneSource),
        (ControlArgs(markdownFile: "/tmp/r.md", textFile: "/tmp/a.go"), OverlayHtmlError.oneSource),
        (ControlArgs(wait: true, textFile: "/tmp/a.go"), OverlayHtmlError.textOptions),
        (ControlArgs(cwd: "/tmp", textFile: "/tmp/a.go"), OverlayHtmlError.textOptions),
        (ControlArgs(navigation: true, textFile: "/tmp/a.go"), OverlayHtmlError.textOptions),
        (ControlArgs(javascript: true, textFile: "/tmp/a.go"), OverlayHtmlError.textOptions),
        (ControlArgs(chromeless: true, textFile: "/tmp/a.go"), OverlayHtmlError.textOptions),
        (ControlArgs(persistent: true, textFile: "/tmp/a.go"), OverlayHtmlError.textOptions),
        (ControlArgs(browse: true, textFile: "/tmp/a.go"), OverlayHtmlError.textOptions),
        (ControlArgs(textFile: "a.go"), OverlayHtmlError.textNotAbsolute),
        (ControlArgs(textFile: "/tmp/a.html"), OverlayHtmlError.textType),
        (ControlArgs(textFile: "/tmp/a.svg"), OverlayHtmlError.textType),
        (ControlArgs(textFile: "/tmp/r.md"), OverlayHtmlError.textType),
        (ControlArgs(textFile: "/tmp/a.go:12"), OverlayHtmlError.textType),
        (ControlArgs(textFile: "/tmp/a.go", line: 0), OverlayHtmlError.lineNotPositive),
        (ControlArgs(textFile: "/tmp/a.go", line: -3), OverlayHtmlError.lineNotPositive),
        (ControlArgs(line: 4), OverlayHtmlError.lineWithoutText),
        (ControlArgs(command: "cat", line: 4), OverlayHtmlError.lineWithoutText),
        (ControlArgs(markdownFile: "/tmp/r.md", line: 4), OverlayHtmlError.lineWithoutText),
        (ControlArgs(tail: 10), OverlayHtmlError.tailWithoutText),
        (ControlArgs(followFile: true), OverlayHtmlError.tailWithoutText),
        (ControlArgs(command: "cat", tail: 10), OverlayHtmlError.tailWithoutText),
        (ControlArgs(image: "/tmp/a.png", followFile: true), OverlayHtmlError.tailWithoutText),
        (ControlArgs(markdownFile: "/tmp/r.md", tail: 10), OverlayHtmlError.tailWithoutText),
        (ControlArgs(html: "/tmp/r.html", followFile: true), OverlayHtmlError.tailWithoutText),
        (ControlArgs(textFile: "/tmp/a.log", line: 3, tail: 10), OverlayHtmlError.tailWithLine),
        (ControlArgs(textFile: "/tmp/a.log", line: 3, followFile: true), OverlayHtmlError.tailWithLine),
        (ControlArgs(textFile: "/tmp/a.log", tail: 0), OverlayHtmlError.tailRange),
        (ControlArgs(textFile: "/tmp/a.log", tail: TextPage.maxTail + 1), OverlayHtmlError.tailRange),
    ])
    func textOpenRejectsInvalidInputsBeforeCallingActions(_ args: ControlArgs, _ error: String) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayOpen, target: "session", args: args))

        #expect(response == ControlResponse(ok: false, error: error))
        #expect(actions.calls.isEmpty)
    }

    @Test(arguments: [("/tmp/../tmp/Main.GO", 12), ("/tmp/notes.txt", nil), ("/tmp/src/Makefile", 1)] as [(String, Int?)])
    func textOpenRoutesTheStandardizedPathAndItsLine(_ path: String, _ line: Int?) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayOpen, target: "session",
                                                     args: ControlArgs(sizePercent: 95, textFile: path, line: line)))

        #expect(actions.calls == [
            .overlayOpen(target: "session", window: nil,
                         ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: 95,
                                                          backgroundColor: nil,
                                                          page: .text(path: URL(fileURLWithPath: path).standardizedFileURL.path,
                                                                      line: line)))
        ])
    }

    @Test func aTextOpenRequestRoundTripsItsFileAndLine() throws {
        let req = ControlRequest(cmd: .sessionOverlayOpen, target: "s", args: ControlArgs(textFile: "/tmp/a:12.go", line: 7))

        let data = try JSONEncoder().encode(req)

        #expect(try JSONDecoder().decode(ControlRequest.self, from: data) == req)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""textFile":"\/tmp\/a:12.go""#))
        #expect(json.contains(#""line":7"#))
        #expect(!String(decoding: try JSONEncoder().encode(ControlArgs(textFile: "/tmp/a.go")), as: UTF8.self).contains("line"))
    }

    @Test func pageCompanionRefusesATextFile() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sessionCompanionPage, target: "session",
                                                                args: ControlArgs(textFile: "/tmp/a.go", line: 3)))

        #expect(response == ControlResponse(ok: false, error: OverlayHtmlError.companionNeedsPage))
        #expect(actions.calls.isEmpty)
    }

    @Test func pageCompanionRefusesAnImage() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sessionCompanionPage, target: "session",
                                                                args: ControlArgs(image: "/tmp/a.png")))

        #expect(response == ControlResponse(ok: false, error: OverlayHtmlError.companionNeedsPage))
        #expect(actions.calls.isEmpty)
    }

    @Test(arguments: [Bool?.none, false, true])
    func urlOpenRoutesItsNavigationScope(_ browse: Bool?) async throws {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayOpen, target: "session", args: ControlArgs(url: "http://localhost:5173/", browse: browse)
        ))

        #expect(actions.calls == [
            .overlayOpen(target: "session", window: nil,
                         ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: nil,
                                                          backgroundColor: nil,
                                                          page: .url(try #require(URL(string: "http://localhost:5173/"))),
                                                          browse: browse == true))
        ])
    }

    @Test(arguments: [Bool?.none, false, true])
    func urlOpenRoutesItsStorageChoice(_ persistent: Bool?) async throws {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayOpen, target: "session", args: ControlArgs(url: "http://localhost:5173/", persistent: persistent)
        ))

        #expect(actions.calls == [
            .overlayOpen(target: "session", window: nil,
                         ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: nil,
                                                          backgroundColor: nil,
                                                          page: .url(try #require(URL(string: "http://localhost:5173/"))),
                                                          persistent: persistent == true))
        ])
    }

    @Test(arguments: [Bool?.none, true])
    func urlOpenRoutesTheWebPageWithItsToolbar(_ javascript: Bool?) async throws {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayOpen, target: "session",
            args: ControlArgs(sizePercent: 60, navigation: true, url: "http://localhost:5173/app", javascript: javascript)
        ))

        #expect(actions.calls == [
            .overlayOpen(target: "session", window: nil,
                         ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: 60,
                                                          backgroundColor: nil,
                                                          page: .url(try #require(URL(string: "http://localhost:5173/app"))),
                                                          navigation: true, javascript: javascript == true))
        ])
    }

    @Test(arguments: [Bool?.none, true])
    func htmlOpenRoutesChromeless(_ chromeless: Bool?) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayOpen, target: "session",
            args: ControlArgs(html: "/tmp/r.html", javascript: true, chromeless: chromeless)
        ))

        #expect(actions.calls == [
            .overlayOpen(target: "session", window: nil,
                         ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: nil,
                                                          backgroundColor: nil, page: .file(path: "/tmp/r.html", grantRoot: nil),
                                                          javascript: true, chromeless: chromeless == true))
        ])
    }

    @Test(arguments: ["http://127.0.0.1:8792/", "http://[::1]:8792/", "http://localhost:5173/app"])
    func urlOpenRoutesAChromelessLoopbackPage(_ url: String) async throws {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayOpen, target: "session",
            args: ControlArgs(url: url, javascript: true, chromeless: true, persistent: true)
        ))

        #expect(response?.ok == true)
        #expect(actions.calls == [
            .overlayOpen(target: "session", window: nil,
                         ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: nil,
                                                          backgroundColor: nil, page: .url(try #require(URL(string: url))),
                                                          javascript: true, chromeless: true, persistent: true))
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

    @Test(arguments: [("back", HtmlNavigation.back), ("forward", .forward), ("browser", .browser), ("finder", .finder)])
    func navigateRoutesTheStepAndPane(_ name: String, _ navigation: HtmlNavigation) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayNavigate, target: "session",
                                                     args: ControlArgs(pane: "left", to: name)))

        #expect(actions.calls == [.overlayNavigate(target: "session", window: nil, pane: .left, navigation)])
    }

    @Test(arguments: [(String?.none, OverlayHtmlError.navigation), ("up", OverlayHtmlError.navigation), ("copy", OverlayHtmlError.navigation)])
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

    @Test(arguments: [(Command.sessionOverlayHide, OverlayVisibilityMode.hide),
                      (.sessionOverlayShow, .show), (.sessionOverlayToggle, .toggle)])
    func visibilityCommandsRouteModePaneTargetAndWindow(_ cmd: Command, _ mode: OverlayVisibilityMode) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let whole = await dispatcher.dispatch(ControlRequest(cmd: cmd, target: "s", args: ControlArgs(window: "w")))
        _ = await dispatcher.dispatch(ControlRequest(cmd: cmd, target: "s", args: ControlArgs(pane: "split")))

        #expect(whole?.ok == true)
        #expect(actions.calls == [
            .overlayVisibility(target: "s", window: "w", pane: nil, mode: mode),
            .overlayVisibility(target: "s", window: nil, pane: .right, mode: mode),
        ])
    }

    @Test(arguments: [Command.sessionOverlayHide, .sessionOverlayShow, .sessionOverlayToggle])
    func visibilityCommandsRejectAnInvalidPaneBeforeTheHost(_ cmd: Command) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(cmd: cmd, target: "s", args: ControlArgs(pane: "scratch")))

        #expect(response == ControlResponse(ok: false, error: PaneOverlayError.invalidPane))
        #expect(actions.calls.isEmpty)
    }

    @Test(arguments: [
        (OverlayVisibilityFailure.unknownSession, "no such session"),
        (.noOverlay, OverlayVisibilityError.noOverlay),
        (.remote, OverlayResultError.shownElsewhere),
    ])
    func visibilityFailuresMapToTheirMessages(_ failure: OverlayVisibilityFailure, _ message: String) {
        #expect(failure.message == message)
    }

    @Test(arguments: [
        (ControlArgs(textFile: "/tmp/app.log", tail: 50), TextLog(tail: 50, follow: false)),
        (ControlArgs(textFile: "/tmp/app.log", followFile: true), TextLog(tail: TextPage.defaultTail, follow: true)),
        (ControlArgs(textFile: "/tmp/app.log", tail: TextPage.maxTail, followFile: true), TextLog(tail: TextPage.maxTail, follow: true)),
        (ControlArgs(textFile: "/tmp/app.log", followFile: false), nil),
    ] as [(ControlArgs, TextLog?)])
    func textOpenCarriesTheLogRequest(_ args: ControlArgs, _ log: TextLog?) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayOpen, target: "session", args: args))

        #expect(actions.calls == [
            .overlayOpen(target: "session", window: nil,
                         ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: nil,
                                                          backgroundColor: nil, page: .text(path: "/tmp/app.log", line: nil),
                                                          textLog: log))
        ])
    }

    @Test(arguments: [("on", ControlToggleMode.on), ("off", .off), ("toggle", .toggle)])
    func overlayFollowRoutesItsModeAndPane(_ raw: String, _ mode: ControlToggleMode) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayFollow, target: "session",
                                                                args: ControlArgs(mode: raw, pane: "right")))

        #expect(response?.ok == true)
        #expect(actions.calls == [.overlayFollow(target: "session", window: nil, pane: .right, mode: mode)])
    }

    @Test func overlayFollowDefaultsToToggle() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayFollow, target: "session"))

        #expect(actions.calls == [.overlayFollow(target: "session", window: nil, pane: nil, mode: .toggle)])
    }

    @Test(arguments: [
        (ControlArgs(mode: "maybe"), "invalid overlay follow mode: maybe"),
        (ControlArgs(mode: "on", pane: "middle"), PaneOverlayError.invalidPane),
    ])
    func overlayFollowRejectsBadInputBeforeCallingActions(_ args: ControlArgs, _ error: String) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayFollow, target: "session", args: args))

        #expect(response == ControlResponse(ok: false, error: error))
        #expect(actions.calls.isEmpty)
    }

    @Test(arguments: [
        (ControlArgs(text: "main()"), TextSearchRequest.query("main()")),
        (ControlArgs(to: "next"), .next),
        (ControlArgs(to: "prev"), .previous),
        (ControlArgs(to: "close"), .close),
    ])
    func overlaySearchRoutesItsRequestAndPane(_ args: ControlArgs, _ search: TextSearchRequest) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        var withPane = args
        withPane.pane = "right"

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlaySearch, target: "session", args: withPane))

        #expect(response?.result?.text == "1 of 2")
        #expect(actions.calls == [.overlaySearch(target: "session", window: nil, pane: .right, request: search)])
    }

    @Test(arguments: [
        (ControlArgs(), OverlayHtmlError.searchRequest),
        (ControlArgs(text: "a", to: "next"), OverlayHtmlError.searchTextWithStep),
        (ControlArgs(text: ""), "session.overlay.search: text must not be empty"),
        (ControlArgs(to: "up"), "invalid overlay search direction: up"),
        (ControlArgs(text: "a", pane: "middle"), PaneOverlayError.invalidPane),
    ])
    func overlaySearchRejectsBadInputBeforeCallingActions(_ args: ControlArgs, _ error: String) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlaySearch, target: "session", args: args))

        #expect(response == ControlResponse(ok: false, error: error))
        #expect(actions.calls.isEmpty)
    }

    @Test(arguments: [("next", true), ("prev", false)])
    func overlayChangesRoutesItsDirectionAndPane(_ to: String, _ forward: Bool) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayChanges, target: "session",
                                                                args: ControlArgs(pane: "right", to: to)))

        #expect(response?.result?.text == "3 of 7")
        #expect(actions.calls == [.overlayChanges(target: "session", window: nil, pane: .right, forward: forward)])
    }

    @Test(arguments: [
        (ControlArgs(), "session.overlay.changes requires to next or prev"),
        (ControlArgs(to: "close"), "invalid overlay changes direction: close"),
        (ControlArgs(pane: "middle", to: "next"), PaneOverlayError.invalidPane),
    ])
    func overlayChangesRejectsBadInputBeforeCallingActions(_ args: ControlArgs, _ error: String) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayChanges, target: "session", args: args))

        #expect(response == ControlResponse(ok: false, error: error))
        #expect(actions.calls.isEmpty)
    }
}
