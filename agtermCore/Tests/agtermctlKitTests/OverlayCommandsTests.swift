import ArgumentParser
import Foundation
import Testing
import agtermCore
@testable import agtermctlKit

struct OverlayCommandsTests {
    private func request(_ argv: [String]) throws -> ControlRequest {
        let parsed = try Agtermctl.parseAsRoot(argv)
        guard let command = parsed as? any RequestCommand else {
            throw SocketClientError("parsed \(argv) is not a RequestCommand")
        }
        return try command.makeRequest()
    }

    private func rejects(_ argv: [String]) -> Bool {
        (try? Agtermctl.parseAsRoot(argv)) == nil
    }

    @Test func htmlOpenSendsTheNormalizedPageAndGrant() throws {
        let req = try request(["session", "overlay", "open", "--html", "/tmp/a/../a/./r.html", "--cwd", "/tmp/a/",
                               "--pane", "right", "--background-color", "#102030", "--target", "s"])
        #expect(req.cmd == .sessionOverlayOpen)
        #expect(req.args?.html == "/tmp/a/r.html")
        #expect(req.args?.cwd == "/tmp/a")
        #expect(req.args?.command == nil)
        #expect(req.args?.pane == "right")
        #expect(req.args?.color == "#102030")
        #expect(req.args?.navigation == nil)
        #expect(req.args?.javascript == nil)
        #expect(req.args?.chromeless == nil)
        let chromeless = try request(["session", "overlay", "open", "--html", "/tmp/r.html", "--chromeless", "--js"])
        #expect(chromeless.args?.chromeless == true)
        let withToolbar = try request(["session", "overlay", "open", "--html", "/tmp/r.html", "--navigation", "--js"])
        #expect(withToolbar.args?.navigation == true)
        #expect(withToolbar.args?.javascript == true)
    }

    @Test func openAndResizeSendPointSizes() throws {
        let open = try request(["session", "overlay", "open", "--html", "/tmp/r.html", "--size-percent", "60",
                                "--width", "700", "--height", "240"])
        #expect(open.args?.sizePercent == 60)
        #expect(open.args?.width == 700)
        #expect(open.args?.height == 240)
        let resize = try request(["session", "overlay", "resize", "--height", "300", "--target", "s"])
        #expect(resize.cmd == .sessionOverlayResize)
        #expect(resize.target == "s")
        #expect(resize.args?.height == 300)
        #expect(resize.args?.width == nil)
        #expect(resize.args?.sizePercent == nil)
    }

    @Test(arguments: [
        ["session", "overlay", "open", "--html", "/tmp/r.html", "--height", "240"],
        ["session", "overlay", "open", "cat", "--size-percent", "60", "--width", "0"],
        ["session", "overlay", "open", "cat", "--pane", "right", "--height", "240"],
        ["session", "overlay", "resize", "--full", "--height", "240"],
        ["session", "overlay", "resize", "--width", "-1"],
    ])
    func pointSizesAreRefusedBeforeAnyConnection(argv: [String]) {
        #expect(rejects(argv))
    }

    @Test func aRelativePageResolvesAgainstTheCallersDirectory() throws {
        let req = try request(["session", "overlay", "open", "--html", "out/r.html", "--cwd", "out"])
        let cwd = FileManager.default.currentDirectoryPath
        #expect(req.args?.html == URL(fileURLWithPath: cwd).appendingPathComponent("out/r.html").standardizedFileURL.path)
        #expect(req.args?.cwd == URL(fileURLWithPath: cwd).appendingPathComponent("out").standardizedFileURL.path)
    }

    @Test func urlOpenSendsTheAddressUntouched() throws {
        let req = try request(["session", "overlay", "open", "--url", "http://localhost:5173/a/../b", "--navigation", "--js"])
        #expect(req.args?.url == "http://localhost:5173/a/../b")
        #expect(req.args?.html == nil)
        #expect(req.args?.cwd == nil)
        #expect(req.args?.navigation == true)
        #expect(req.args?.javascript == true)
        #expect(req.args?.persistent == nil)
    }

    @Test func browserClearTakesNoWindow() throws {
        #expect(try request(["browser", "clear"]) == ControlRequest(cmd: .browserClear))
        #expect(rejects(["browser", "clear", "--window", "w1"]))
    }

    @Test func urlOpenSendsBrowseOnlyWhenAsked() throws {
        #expect(try request(["session", "overlay", "open", "--url", "http://localhost:5173/"]).args?.browse == nil)
        let req = try request(["session", "overlay", "open", "--url", "http://localhost:5173/", "--browse", "--js",
                               "--navigation", "--persistent"])
        #expect(req.args?.browse == true)
        #expect(req.args?.javascript == true)
        #expect(req.args?.navigation == true)
        #expect(req.args?.persistent == true)
    }

    @Test func urlOpenSendsPersistent() throws {
        let req = try request(["session", "overlay", "open", "--url", "http://localhost:5173/", "--persistent"])
        #expect(req.args?.persistent == true)
    }

    @Test(arguments: ["http://127.0.0.1:8792/", "http://[::1]:8792/", "http://localhost:5173/"])
    func urlOpenSendsChromelessForALoopbackHost(_ url: String) throws {
        let req = try request(["session", "overlay", "open", "--url", url, "--chromeless", "--js", "--persistent"])
        #expect(req.args?.url == url)
        #expect(req.args?.chromeless == true)
    }

    @Test func aMalformedChromelessUrlIsLeftForTheServerToName() throws {
        let req = try request(["session", "overlay", "open", "--url", "localhost:5173", "--chromeless"])
        #expect(req.args?.url == "localhost:5173")
    }

    @Test func aProgramOpenLeavesItsCwdAsTyped() throws {
        let req = try request(["session", "overlay", "open", "revdiff", "--cwd", "repo"])
        #expect(req.args?.command == "revdiff")
        #expect(req.args?.cwd == "repo")
        #expect(req.args?.html == nil)
    }

    @Test(arguments: [
        ["session", "overlay", "open"],
        ["session", "overlay", "open", "revdiff", "--html", "/tmp/r.html"],
        ["session", "overlay", "open", "--html", "/tmp/r.html", "--wait"],
        ["session", "overlay", "open", "--html", "/tmp/r.html", "--block", "--wait"],
        ["session", "overlay", "open", "revdiff", "--navigation"],
        ["session", "overlay", "open", "revdiff", "--js"],
        ["session", "overlay", "open", "revdiff", "--chromeless"],
        ["session", "overlay", "open", "--url", "http://example.com/", "--chromeless"],
        ["session", "overlay", "open", "--url", "http://127.0.0.2:8792/", "--chromeless"],
        ["session", "overlay", "open", "--url", "http://localhost:5173/", "--chromeless", "--browse"],
        ["session", "overlay", "open", "--url", "http://localhost:5173/", "--chromeless", "--navigation"],
        ["session", "overlay", "open", "--html", "/tmp/r.html", "--chromeless", "--navigation"],
        ["session", "overlay", "open", "revdiff", "--persistent"],
        ["session", "overlay", "open", "--html", "/tmp/r.html", "--persistent"],
        ["session", "overlay", "open", "revdiff", "--browse"],
        ["session", "overlay", "open", "--html", "/tmp/r.html", "--browse"],
        ["session", "overlay", "open", "revdiff", "--url", "http://localhost:5173/"],
        ["session", "overlay", "open", "--html", "/tmp/r.html", "--url", "http://localhost:5173/"],
        ["session", "overlay", "open", "--url", "http://localhost:5173/", "--wait"],
        ["session", "overlay", "open", "--url", "http://localhost:5173/", "--block"],
        ["session", "overlay", "open", "--url", "http://localhost:5173/", "--cwd", "/tmp"],
        ["session", "overlay", "open", "revdiff", "--image", "/tmp/a.png"],
        ["session", "overlay", "open", "--html", "/tmp/r.html", "--image", "/tmp/a.png"],
        ["session", "overlay", "open", "--url", "http://localhost:5173/", "--image", "/tmp/a.png"],
        ["session", "overlay", "open", "--image", "/tmp/a.png", "--companion"],
        ["session", "overlay", "open", "--image", "/tmp/a.png", "--block"],
        ["session", "overlay", "open", "--image", "/tmp/a.png", "--wait"],
        ["session", "overlay", "open", "--image", "/tmp/a.png", "--navigation"],
        ["session", "overlay", "open", "--image", "/tmp/a.png", "--js"],
        ["session", "overlay", "open", "--image", "/tmp/a.png", "--chromeless"],
        ["session", "overlay", "open", "--image", "/tmp/a.png", "--persistent"],
        ["session", "overlay", "open", "--image", "/tmp/a.png", "--browse"],
        ["session", "overlay", "open", "--image", "/tmp/a.png", "--cwd", "/tmp"],
        ["session", "overlay", "open", "--image", "/tmp/a.png", "--width", "400"],
        ["session", "overlay", "open", "revdiff", "--markdown", "/tmp/r.md"],
        ["session", "overlay", "open", "--html", "/tmp/r.html", "--markdown", "/tmp/r.md"],
        ["session", "overlay", "open", "--url", "http://localhost:5173/", "--markdown", "/tmp/r.md"],
        ["session", "overlay", "open", "--image", "/tmp/a.png", "--markdown", "/tmp/r.md"],
        ["session", "overlay", "open", "--markdown", "/tmp/r.md", "--companion"],
        ["session", "overlay", "open", "--markdown", "/tmp/r.md", "--block"],
        ["session", "overlay", "open", "--markdown", "/tmp/r.md", "--wait"],
        ["session", "overlay", "open", "--markdown", "/tmp/r.md", "--js"],
        ["session", "overlay", "open", "--markdown", "/tmp/r.md", "--chromeless"],
        ["session", "overlay", "open", "--markdown", "/tmp/r.md", "--persistent"],
        ["session", "overlay", "open", "--markdown", "/tmp/r.md", "--browse"],
        ["session", "overlay", "open", "--markdown", "/tmp/r.md", "--cwd", "/tmp"],
        ["session", "overlay", "open", "revdiff", "--text", "/tmp/a.go"],
        ["session", "overlay", "open", "--html", "/tmp/r.html", "--text", "/tmp/a.go"],
        ["session", "overlay", "open", "--markdown", "/tmp/r.md", "--text", "/tmp/a.go"],
        ["session", "overlay", "open", "--text", "/tmp/a.go", "--companion"],
        ["session", "overlay", "open", "--text", "/tmp/a.go", "--block"],
        ["session", "overlay", "open", "--text", "/tmp/a.go", "--wait"],
        ["session", "overlay", "open", "--text", "/tmp/a.go", "--navigation"],
        ["session", "overlay", "open", "--text", "/tmp/a.go", "--js"],
        ["session", "overlay", "open", "--text", "/tmp/a.go", "--chromeless"],
        ["session", "overlay", "open", "--text", "/tmp/a.go", "--persistent"],
        ["session", "overlay", "open", "--text", "/tmp/a.go", "--browse"],
        ["session", "overlay", "open", "--text", "/tmp/a.go", "--cwd", "/tmp"],
        ["session", "overlay", "open", "--text", "/tmp/a.go", "--line", "0"],
        ["session", "overlay", "open", "--line", "3", "--markdown", "/tmp/r.md"],
        ["session", "overlay", "open", "revdiff", "--line", "3"],
        ["session", "overlay", "open", "--tail", "10"],
        ["session", "overlay", "open", "revdiff", "--follow-file"],
        ["session", "overlay", "open", "--markdown", "/tmp/r.md", "--tail", "10"],
        ["session", "overlay", "open", "--text", "/tmp/a.log", "--line", "3", "--tail", "10"],
        ["session", "overlay", "open", "--text", "/tmp/a.log", "--line", "3", "--follow-file"],
        ["session", "overlay", "open", "--text", "/tmp/a.log", "--tail", "0"],
        ["session", "overlay", "open", "--text", "/tmp/a.log", "--tail", "100001"],
    ])
    func openRejectsAMissingOrConflictingContent(_ argv: [String]) {
        #expect(rejects(argv))
    }

    @Test func imageOpenSendsTheResolvedPathAndNoPageFlags() throws {
        let req = try request(["session", "overlay", "open", "--image", "shots/../shots/a.png", "--follow"])
        let cwd = FileManager.default.currentDirectoryPath
        #expect(req.cmd == .sessionOverlayOpen)
        #expect(req.args?.image == URL(fileURLWithPath: cwd).appendingPathComponent("shots/a.png").standardizedFileURL.path)
        #expect(req.args?.html == nil)
        #expect(req.args?.cwd == nil)
        #expect(req.args?.sizePercent == nil)
        #expect(req.args?.follow == true)
    }

    @Test func markdownOpenTakesNavigation() throws {
        let req = try request(["session", "overlay", "open", "--markdown", "/tmp/r.md", "--navigation"])
        #expect(req.args?.markdownFile == "/tmp/r.md")
        #expect(req.args?.navigation == true)
        #expect(rejects(["session", "overlay", "open", "--markdown", "/tmp/r.md", "--navigation", "--companion"]))
        #expect(rejects(["session", "overlay", "open", "--markdown", "/tmp/r.md", "--navigation", "--chromeless"]))
    }

    @Test func markdownOpenSendsTheResolvedPathInItsOwnField() throws {
        let req = try request(["session", "overlay", "open", "--markdown", "docs/../docs/r.md", "--size-percent", "95"])
        let cwd = FileManager.default.currentDirectoryPath
        #expect(req.cmd == .sessionOverlayOpen)
        #expect(req.args?.markdownFile == URL(fileURLWithPath: cwd).appendingPathComponent("docs/r.md").standardizedFileURL.path)
        #expect(req.args?.markdown == nil)
        #expect(req.args?.image == nil)
        #expect(req.args?.sizePercent == 95)
        let data = try JSONEncoder().encode(req)
        #expect(try JSONDecoder().decode(ControlRequest.self, from: data) == req)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""markdownFile":"#))
        #expect(!json.contains(#""markdown":"#))
    }

    @Test func textOpenSendsTheResolvedPathLiterallyAndItsLine() throws {
        let req = try request(["session", "overlay", "open", "--text", "src/../src/a.go:12", "--line", "40"])
        let cwd = FileManager.default.currentDirectoryPath
        #expect(req.cmd == .sessionOverlayOpen)
        #expect(req.args?.textFile == URL(fileURLWithPath: cwd).appendingPathComponent("src/a.go:12").standardizedFileURL.path)
        #expect(req.args?.line == 40)
        #expect(req.args?.markdownFile == nil)
        #expect(req.args?.cwd == nil)
        let bare = try request(["session", "overlay", "open", "--text", "/tmp/notes.txt"])
        #expect(bare.args?.textFile == "/tmp/notes.txt")
        #expect(bare.args?.line == nil)
    }

    @Test func textOpenSendsTheTailAndFollowFile() throws {
        let req = try request(["session", "overlay", "open", "--text", "/tmp/app.log", "--tail", "200", "--follow-file"])
        #expect(req.args?.tail == 200)
        #expect(req.args?.followFile == true)
        #expect(req.args?.follow == nil)
        let bare = try request(["session", "overlay", "open", "--text", "/tmp/app.log"])
        #expect(bare.args?.tail == nil)
        #expect(bare.args?.followFile == nil)
    }

    @Test(arguments: ["on", "off", "toggle"])
    func followSendsItsModePaneAndTarget(_ mode: String) throws {
        let req = try request(["session", "overlay", "follow", mode, "--pane", "right", "--target", "s"])
        #expect(req.cmd == .sessionOverlayFollow)
        #expect(req.target == "s")
        #expect(req.args?.mode == mode)
        #expect(req.args?.pane == "right")
    }

    @Test func followRefusesABadModeOrPane() {
        #expect(rejects(["session", "overlay", "follow", "maybe"]))
        #expect(rejects(["session", "overlay", "follow"]))
        #expect(rejects(["session", "overlay", "follow", "on", "--pane", "scratch"]))
    }

    @Test(arguments: [
        (["main()"], "main()" as String?, nil as String?),
        (["--next"], nil as String?, "next" as String?),
        (["--prev"], nil as String?, "prev" as String?),
        (["--close"], nil as String?, "close" as String?),
    ])
    func searchSendsItsQueryOrStepPaneAndTarget(_ extra: [String], _ text: String?, _ to: String?) throws {
        let req = try request(["session", "overlay", "search"] + extra + ["--pane", "right", "--target", "s"])
        #expect(req.cmd == .sessionOverlaySearch)
        #expect(req.target == "s")
        #expect(req.args?.text == text)
        #expect(req.args?.to == to)
        #expect(req.args?.pane == "right")
    }

    @Test func searchRefusesAMissingOrMixedRequest() {
        #expect(rejects(["session", "overlay", "search"]))
        #expect(rejects(["session", "overlay", "search", ""]))
        #expect(rejects(["session", "overlay", "search", "a", "--next"]))
        #expect(rejects(["session", "overlay", "search", "--next", "--prev"]))
        #expect(rejects(["session", "overlay", "search", "a", "--pane", "scratch"]))
    }

    @Test(arguments: [("--next", "next"), ("--prev", "prev")])
    func changesSendsItsStepPaneAndTarget(_ flag: String, _ to: String) throws {
        let req = try request(["session", "overlay", "changes", flag, "--pane", "right", "--target", "s"])
        #expect(req.cmd == .sessionOverlayChanges)
        #expect(req.target == "s")
        #expect(req.args?.to == to)
        #expect(req.args?.pane == "right")
    }

    @Test func changesRefusesAMissingOrDoubleStep() {
        #expect(rejects(["session", "overlay", "changes"]))
        #expect(rejects(["session", "overlay", "changes", "--next", "--prev"]))
        #expect(rejects(["session", "overlay", "changes", "--next", "--pane", "scratch"]))
    }

    @Test func openHelpTellsFollowFileFromFollow() {
        let open = Session.Overlay.Open.helpMessage(columns: 400)
        #expect(open.contains("--follow-file"))
        #expect(open.contains("Not --follow, which selects the session."))
    }

    @Test func submitSendsTheValuePaneAndTarget() throws {
        let req = try request(["session", "overlay", "submit", "--value", "", "--pane", "right", "--target", "s"])
        #expect(req.cmd == .sessionOverlaySubmit)
        #expect(req.target == "s")
        #expect(req.args?.value == "")
        #expect(req.args?.pane == "right")
        #expect(rejects(["session", "overlay", "submit"]))
        #expect(rejects(["session", "overlay", "submit", "--value", "x", "--pane", "middle"]))
    }

    @Test func resultWithAPageReadsThePageAndNoSession() throws {
        let req = try request(["session", "overlay", "result", "--page", "P1"])
        #expect(req.cmd == .sessionOverlayResult)
        #expect(req.target == nil)
        #expect(req.args?.page == "P1")
        #expect(rejects(["session", "overlay", "result", "--page", "P1", "--pane", "left"]))
    }

    @Test func pageSendsThePageSessionCommandWithItsSourceAndFollow() throws {
        let file = try request(["session", "overlay", "open", "--html", "/tmp/a/./r.html", "--cwd", "/tmp/a/", "--page", "--follow",
                                "--js", "--background-color", "#102030", "--target", "p1", "--window", "win"])
        #expect(file == ControlRequest(cmd: .sessionPage, target: "p1", args: ControlArgs(
            cwd: "/tmp/a", follow: true, window: "win", color: "#102030", html: "/tmp/a/r.html", javascript: true)))
        let url = try request(["session", "overlay", "open", "--url", "https://example.com/", "--page", "--persistent"])
        #expect(url.cmd == .sessionPage)
        #expect(url.target == "active")
        #expect(url.args?.url == "https://example.com/")
        #expect(url.args?.persistent == true)
        #expect(url.args?.follow == nil)
        #expect(try request(["session", "overlay", "open", "--html", "/tmp/r.html", "--page", "--block"]).cmd == .sessionPage)
    }

    @Test(arguments: [
        ["--html", "/tmp/r.html", "--page", "--companion"],
        ["revdiff", "--page"],
        ["--image", "/tmp/a.png", "--page"],
        ["--markdown", "/tmp/r.md", "--page"],
        ["--text", "/tmp/a.go", "--page"],
        ["--html", "/tmp/r.html", "--page", "--pane", "right"],
        ["--html", "/tmp/r.html", "--page", "--size-percent", "50"],
        ["--html", "/tmp/r.html", "--page", "--size-percent", "50", "--width", "300"],
        ["--url", "http://localhost:5173/", "--page", "--block"],
    ])
    func pageRefusesAnythingButAFullSizeFileOrURLPageAndCompanion(_ extra: [String]) {
        #expect(rejects(["session", "overlay", "open"] + extra))
    }

    @Test func openHelpNamesTheNewRowForFollowAndThePageFlag() {
        let open = Session.Overlay.Open.helpMessage(columns: 400)
        #expect(open.contains("--page"))
        #expect(open.contains("with --companion or --page, the new row"))
    }

    @Test func aPageMayBlockButAUrlMayNot() throws {
        let opened = try request(["session", "overlay", "open", "--html", "/tmp/r.html", "--block"])
        #expect(opened.args?.html == "/tmp/r.html")
        #expect(rejects(["session", "overlay", "open", "--url", "http://localhost:5173/", "--block"]))
    }

    private final class Wire {
        var replies: [ControlResponse]
        var sent: [ControlRequest] = []
        var slept = 0
        var out: [String] = []
        var err: [String] = []
        var lastLine = ""

        init(_ replies: [ControlResponse]) { self.replies = replies }

        func runner(json: Bool = false) -> HtmlPageRunner {
            HtmlPageRunner(json: json, send: { request in
                self.sent.append(request)
                let response = self.replies.removeFirst()
                let raw = try JSONEncoder().encode(response)
                self.lastLine = String(decoding: raw, as: UTF8.self)
                return SocketReply(response: response, raw: raw)
            }, sleep: { _ in self.slept += 1 }, output: { self.out.append($0) }, errorOutput: { self.err.append($0) })
        }
    }

    private static func outcome(_ state: ControlHtmlPageOutcomeState, _ value: String? = nil) -> ControlResponse {
        ControlResponse(ok: true, result: ControlResult(pageOutcome: ControlHtmlPageOutcome(pageID: "P1", outcome: state, value: value)))
    }

    private static let opened = ControlResponse(ok: true, result: ControlResult(id: "S1", pageID: "P1"))
    private static let open = ControlRequest(cmd: .sessionOverlayOpen, args: ControlArgs(html: "/tmp/r.html"))

    @Test func aBlockedSelectorPrintsTheSubmittedValueAndExitsZero() throws {
        let wire = Wire([Self.opened, Self.outcome(.pending), Self.outcome(.submitted, "a\nb")])
        try wire.runner().block(Self.open)
        #expect(wire.slept == 1)
        #expect(wire.sent.dropFirst().allSatisfy { $0.cmd == .sessionOverlayResult && $0.args?.page == "P1" && $0.target == nil })
        let printed = try JSONDecoder().decode(ControlHtmlPageOutcome.self, from: Data(try #require(wire.out.last).utf8))
        #expect(printed == ControlHtmlPageOutcome(pageID: "P1", outcome: .submitted, value: "a\nb"))
    }

    @Test func anEmptySubmittedValueIsPrintedIntact() throws {
        let wire = Wire([Self.opened, Self.outcome(.submitted, "")])
        try wire.runner().block(Self.open)
        #expect(try #require(wire.out.last).contains(#""value":"""#))
    }

    @Test func aDismissedSelectorExitsTwo() throws {
        let wire = Wire([Self.opened, Self.outcome(.dismissed)])
        #expect(throws: ExitCode(rawValue: 2)) { try wire.runner().block(Self.open) }
        #expect(try #require(wire.out.last).contains(#""outcome":"dismissed""#))
    }

    @Test func anOpenReplyWithoutAPageIDFails() throws {
        let wire = Wire([ControlResponse(ok: true, result: ControlResult(id: "S1"))])
        #expect(throws: ExitCode.failure) { try wire.runner().block(Self.open) }
        #expect(wire.err.last?.contains("pageID") == true)
    }

    @Test func aFailedOpenOrPollExitsOne() throws {
        let refused = Wire([ControlResponse(ok: false, error: "overlay already open")])
        #expect(throws: ExitCode.failure) { try refused.runner().block(Self.open) }
        #expect(refused.err.last?.contains("overlay already open") == true)
        let lost = Wire([Self.opened, ControlResponse(ok: false, error: OverlayHtmlError.unknownPage)])
        #expect(throws: ExitCode.failure) { try lost.runner().block(Self.open) }
    }

    @Test func jsonPrintsTheRawReply() throws {
        let wire = Wire([Self.opened, Self.outcome(.submitted, "x")])
        try wire.runner(json: true).block(Self.open)
        #expect(wire.out.last == wire.lastLine)
        #expect(wire.lastLine.contains(#""pageOutcome""#))
    }

    @Test func aOneShotReadOfAPendingPageExitsOne() throws {
        let wire = Wire([Self.outcome(.pending)])
        #expect(throws: ExitCode.failure) { try wire.runner().read("P1") }
        #expect(try #require(wire.out.last).contains(#""outcome":"pending""#))
    }

    @Test func reloadDefaultsToTheOriginalFile() throws {
        let original = try request(["session", "overlay", "reload", "--pane", "left", "--target", "s"])
        let current = try request(["session", "overlay", "reload", "--current"])
        #expect(original.cmd == .sessionOverlayReload)
        #expect(original.args?.pane == "left")
        #expect(original.args?.current == nil)
        #expect(current.args?.current == true)
        #expect(rejects(["session", "overlay", "reload", "--pane", "middle"]))
    }

    @Test(arguments: ["back", "forward", "browser", "finder"])
    func navigateSendsTheStep(_ step: String) throws {
        let req = try request(["session", "overlay", "navigate", step, "--pane", "right"])
        #expect(req.cmd == .sessionOverlayNavigate)
        #expect(req.args?.to == step)
        #expect(req.args?.pane == "right")
    }

    @Test func navigateRejectsAnUnknownStep() {
        #expect(rejects(["session", "overlay", "navigate", "up"]))
        #expect(rejects(["session", "overlay", "navigate", "copy"]))
        #expect(rejects(["session", "overlay", "navigate"]))
    }

    @Test func navigationHelpDescribesFinderAndTheSourceButtons() {
        let navigate = Session.Overlay.Navigate.helpMessage(columns: 200)
        #expect(navigate.contains("current file in Finder"))
        #expect(navigate.contains("finder (file pages only)"))
        let open = Session.Overlay.Open.helpMessage(columns: 200)
        #expect(open.contains("Show in Finder or Copy Link"))
    }

    @Test(arguments: [("hide", Command.sessionOverlayHide), ("show", .sessionOverlayShow), ("toggle", .sessionOverlayToggle)])
    func visibilityCommandsSendTheirCommandPaneAndTarget(_ verb: String, _ cmd: Command) throws {
        let whole = try request(["session", "overlay", verb, "--target", "s"])
        #expect(whole.cmd == cmd)
        #expect(whole.target == "s")
        #expect(whole.args?.pane == nil)

        let pane = try request(["session", "overlay", verb, "--pane", "right", "--window", "w"])
        #expect(pane.args?.pane == "right")
        #expect(pane.args?.window == "w")
        #expect(rejects(["session", "overlay", verb, "--pane", "scratch"]))
    }

    @Test func visibilityHelpStatesTheSessionScopeAndTheToggleRule() {
        let helps = [Session.Overlay.Hide.helpMessage(columns: 400), Session.Overlay.Show.helpMessage(columns: 400),
                     Session.Overlay.Toggle.helpMessage(columns: 400)]
        for help in helps {
            #expect(help.contains("every overlay of the session"))
            #expect(help.contains("--pane"))
        }
        #expect(helps[2].contains("if any is shown, otherwise show them all"))
    }
}
