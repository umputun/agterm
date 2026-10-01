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

    @Test func urlOpenSendsPersistent() throws {
        let req = try request(["session", "overlay", "open", "--url", "http://localhost:5173/", "--persistent"])
        #expect(req.args?.persistent == true)
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
        ["session", "overlay", "open", "--url", "http://localhost:5173/", "--chromeless"],
        ["session", "overlay", "open", "--html", "/tmp/r.html", "--chromeless", "--navigation"],
        ["session", "overlay", "open", "revdiff", "--persistent"],
        ["session", "overlay", "open", "--html", "/tmp/r.html", "--persistent"],
        ["session", "overlay", "open", "revdiff", "--url", "http://localhost:5173/"],
        ["session", "overlay", "open", "--html", "/tmp/r.html", "--url", "http://localhost:5173/"],
        ["session", "overlay", "open", "--url", "http://localhost:5173/", "--wait"],
        ["session", "overlay", "open", "--url", "http://localhost:5173/", "--block"],
        ["session", "overlay", "open", "--url", "http://localhost:5173/", "--cwd", "/tmp"],
    ])
    func openRejectsAMissingOrConflictingContent(_ argv: [String]) {
        #expect(rejects(argv))
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
}
