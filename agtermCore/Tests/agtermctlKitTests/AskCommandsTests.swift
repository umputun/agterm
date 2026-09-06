import ArgumentParser
import Foundation
import Testing
import agtermCore
@testable import agtermctlKit

struct AskCommandsTests {
    @Test(arguments: [10, 50, 100])
    func rootMapsFixedWidth(width: Int) throws {
        let command = try open(["Choose", "--button", "ok", "--width", String(width)])
        #expect(try command.makeRequest().args?.width == width)
    }

    @Test(arguments: ["-1", "0", "9", "101", "50.5", "wide", "", "999999999999999999999"])
    func rootRejectsInvalidWidth(width: String) {
        do {
            _ = try open(["Choose", "--button", "ok", "--width", width])
            Issue.record("expected invalid width")
        } catch {
            #expect(Agtermctl.message(for: error) == "width must be 10 to 100")
        }
    }

    @Test func rootDefaultsToBlockingOpenWithoutATarget() throws {
        let command = try open(["Continue?", "--button", "yes=Yes"])
        let request = try command.makeRequest()
        #expect(request == ControlRequest(cmd: .askOpen, args: ControlArgs(
            buttons: [ControlAskButton(id: "yes", label: "Yes")], style: "terminal", align: "right", title: "Continue?"
        )))
        #expect(!command.noBlock)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(json["target"] == nil)
    }

    @Test func rootMapsEveryOpenOption() throws {
        let command = try open([
            "Keep changes?", "--message", "Choose an action.", "--button", "save=Save=keep",
            "--button", "no", "--button", "discard=Discard", "--hotkey", "save=S", "--hotkey", "no=n",
            "--default", "save", "--destructive", "discard", "--style", "gui", "--align", "left",
            "--target", "session-id", "--pane", "right", "--pane-id", "pane-token", "--window", "window-id",
            "--follow", "--no-block", "--socket", "/tmp/ask-cli.sock", "--json",
        ])
        #expect(try command.makeRequest() == ControlRequest(cmd: .askOpen, target: "session-id", args: ControlArgs(
            follow: true, message: "Choose an action.",
            buttons: [ControlAskButton(id: "save", label: "Save=keep", hotkey: "S"),
                      ControlAskButton(id: "no", label: "no", hotkey: "n"),
                      ControlAskButton(id: "discard", label: "Discard")],
            defaultButton: "save", destructiveButton: "discard", style: "gui", align: "left",
            window: "window-id", pane: "right", paneID: "pane-token", title: "Keep changes?"
        )))
        #expect(command.noBlock)
        #expect(command.options.json)
        #expect(command.options.socketPath() == "/tmp/ask-cli.sock")
    }

    @Test(arguments: ["open", "result", "cancel"])
    func explicitOpenAcceptsReservedWordsAsTitles(title: String) throws {
        let command = try open(["open", title, "--button", "ok"])
        #expect(try command.makeRequest().args?.title == title)
    }

    @Test(arguments: [
        (["Question", "--button", "ok", "--style", "other"], "unknown style"),
        (["Question", "--button", "ok", "--align", "other"], "unknown align"),
        (["Question"], "ask requires at least one --button"),
        ([" ", "--button", "ok"], "ask.open requires a title"),
        (["Question", "--button", "ok", "--hotkey", "o"], "--hotkey requires ID=LETTER"),
        (["Question", "--button", "ok", "--hotkey", "missing=x"], "unknown hotkey button: missing"),
        (["Question", "--button", "ok", "--hotkey", "ok=o", "--hotkey", "ok=k"], "hotkey already assigned to button: ok"),
        (["Question", "--button", "ok", "--pane", "right"], "--pane requires a session"),
        (["Question", "--button", "ok", "--pane-id", "token"], "--pane requires a session"),
        (["Question", "--button", "ok", "--target", "active", "--pane", "scratch"], "--pane must be left or right"),
    ])
    func rootRejectsInvalidSyntax(argv: [String], expected: String) {
        do {
            _ = try Agtermctl.parseAsRoot(["ask"] + argv)
            Issue.record("expected validation failure")
        } catch {
            #expect(Agtermctl.message(for: error) == expected)
        }
    }

    @Test func resultAndCancelRouteIDsAndWindowOptions() throws {
        let result = try #require(try Agtermctl.parseAsRoot(["ask", "result", "ask-id", "--window", "w"]) as? Ask.Result)
        let cancel = try #require(try Agtermctl.parseAsRoot(["ask", "cancel", "ask-id", "--window", "w"]) as? Ask.Cancel)
        #expect(try result.makeRequest() == ControlRequest(cmd: .askResult, target: "ask-id", args: ControlArgs(window: "w")))
        #expect(try cancel.makeRequest() == ControlRequest(cmd: .askCancel, target: "ask-id", args: ControlArgs(window: "w")))
    }

    @Test func noBlockPrintsOnlyIDWithoutPolling() throws {
        let command = try open(["Continue?", "--button", "yes=Yes", "--no-block", "--json"])
        var requests: [ControlRequest] = []
        var lines: [String] = []
        try command.execute(send: {
            requests.append($0)
            return ControlResponse(ok: true, result: ControlResult(id: "ask-id", pane: "right"))
        }, sleep: { _ in Issue.record("no-block must not sleep") }, output: { lines.append($0) })

        #expect(requests.count == 1)
        #expect(requests.first?.cmd == .askOpen)
        #expect(lines.count == 1)
        let line = try #require(lines.first)
        let fields = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String])
        #expect(fields == ["id": "ask-id"])
    }

    @Test func blockingPollUsesGlobalIDBackoffAndPrintsOneAnswer() throws {
        let command = try open(["Continue?", "--button", "yes=Yes", "--window", "w"])
        var requests: [ControlRequest] = []
        var delays: [TimeInterval] = []
        var lines: [String] = []
        var polls = 0
        let answer = ControlAskResult(result: .answered, id: "yes", label: "Yes", index: 0)
        try command.execute(send: { request in
            requests.append(request)
            if request.cmd == .askOpen { return ControlResponse(ok: true, result: ControlResult(id: "ask-id")) }
            polls += 1
            return ControlResponse(ok: true, result: ControlResult(
                ask: polls <= 11 ? ControlAskResult(result: .pending) : answer
            ))
        }, sleep: { delays.append($0) }, output: { lines.append($0) })

        #expect(requests.first?.args?.window == "w")
        #expect(requests.dropFirst().allSatisfy { $0 == ControlRequest(cmd: .askResult, target: "ask-id") })
        #expect(delays == Array(repeating: 0.1, count: 10) + [0.5])
        #expect(lines.count == 1)
        #expect(try JSONDecoder().decode(ControlAskResult.self, from: Data(#require(lines.first).utf8)) == answer)
    }

    @Test(arguments: [(ControlAskOutcome.cancelled, Int32(2)), (.escaped, Int32(3))])
    func dismissalPrintsBeforeExit(outcome: ControlAskOutcome, code: Int32) throws {
        let command = try open(["Continue?", "--button", "yes=Yes"])
        var lines: [String] = []
        #expect(throws: ExitCode(rawValue: code)) {
            try command.execute(send: {
                $0.cmd == .askOpen
                    ? ControlResponse(ok: true, result: ControlResult(id: "ask-id"))
                    : ControlResponse(ok: true, result: ControlResult(ask: ControlAskResult(result: outcome)))
            }, sleep: { _ in }, output: { lines.append($0) })
        }
        #expect(lines == ["{\"result\":\"\(outcome.rawValue)\"}"])
    }

    @Test(arguments: [false, true])
    func serverErrorsFollowTheJSONFlag(json: Bool) throws {
        let command = try open(["Continue?", "--button", "yes=Yes"] + (json ? ["--json"] : []))
        var lines: [String] = []
        var errors: [String] = []
        let response = ControlResponse(ok: false, error: "ask already pending")
        #expect(throws: ExitCode.failure) {
            try command.execute(send: { _ in response }, sleep: { _ in }, output: { lines.append($0) },
                                errorOutput: { errors.append($0) })
        }
        #expect(lines.count == (json ? 1 : 0))
        #expect(errors == (json ? [] : ["error: ask already pending"]))
        if json {
            #expect(try JSONDecoder().decode(ControlResponse.self, from: Data(#require(lines.first).utf8)) == response)
        }
    }

    @Test func missingOpenIDFailsBeforePolling() throws {
        let command = try open(["Continue?", "--button", "yes=Yes"])
        var requests: [ControlRequest] = []
        var errors: [String] = []
        #expect(throws: ExitCode.failure) {
            try command.execute(send: {
                requests.append($0)
                return ControlResponse(ok: true)
            }, sleep: { _ in }, output: { _ in Issue.record("malformed open must not print an answer") },
            errorOutput: { errors.append($0) })
        }
        #expect(requests.map(\.cmd) == [.askOpen])
        #expect(errors == ["error: ask.open result missing id"])
    }

    @Test func malformedPollCancelsTheExactAsk() throws {
        let command = try open(["Continue?", "--button", "yes=Yes", "--window", "w"])
        var requests: [ControlRequest] = []
        var errors: [String] = []
        #expect(throws: ExitCode.failure) {
            try command.execute(send: {
                requests.append($0)
                return $0.cmd == .askOpen ? ControlResponse(ok: true, result: ControlResult(id: "ask-id")) : ControlResponse(ok: true)
            }, sleep: { _ in }, output: { _ in Issue.record("malformed poll must not print an answer") },
            errorOutput: { errors.append($0) })
        }
        #expect(requests.map(\.cmd) == [.askOpen, .askResult, .askCancel])
        #expect(requests.last == ControlRequest(cmd: .askCancel, target: "ask-id"))
        #expect(errors == ["error: ask.result missing result"])
    }

    @Test func failedCancellationPreservesTheTransportFailure() throws {
        let command = try open(["Continue?", "--button", "yes=Yes"])
        var requests: [ControlRequest] = []
        do {
            try command.execute(send: {
                requests.append($0)
                switch $0.cmd {
                case .askOpen: return ControlResponse(ok: true, result: ControlResult(id: "ask-id"))
                case .askResult: throw SocketClientError("poll failed")
                default: throw SocketClientError("cancel failed")
                }
            }, sleep: { _ in }, output: { _ in })
            Issue.record("expected transport failure")
        } catch let error as SocketClientError {
            #expect(error.description == "poll failed")
        }
        #expect(requests.map(\.cmd) == [.askOpen, .askResult, .askCancel])
        #expect(requests.last?.target == "ask-id")
    }

    @Test func unknownAskResponseDoesNotAttemptCancellation() throws {
        let command = try open(["Continue?", "--button", "yes=Yes"])
        var requests: [ControlRequest] = []
        #expect(throws: ExitCode.failure) {
            try command.execute(send: {
                requests.append($0)
                return $0.cmd == .askOpen
                    ? ControlResponse(ok: true, result: ControlResult(id: "ask-id"))
                    : ControlResponse(ok: false, error: "unknown ask: ask-id")
            }, sleep: { _ in }, output: { _ in }, errorOutput: { _ in })
        }
        #expect(requests.map(\.cmd) == [.askOpen, .askResult])
    }

    @Test(arguments: [
        (ControlAskResult(result: .pending), Int32(1)),
        (ControlAskResult(result: .answered, id: "yes", label: "Yes", index: 0), Int32(0)),
        (ControlAskResult(result: .cancelled), Int32(2)),
        (ControlAskResult(result: .escaped), Int32(3)),
    ])
    func oneShotResultPrintsEveryOutcomeAndMapsExit(result: ControlAskResult, expectedExit: Int32) throws {
        let command = try #require(try Agtermctl.parseAsRoot(["ask", "result", "ask-id", "--window", "w"]) as? Ask.Result)
        var requests: [ControlRequest] = []
        var lines: [String] = []
        var exit: Int32 = 0
        do {
            try command.execute(send: {
                requests.append($0)
                return ControlResponse(ok: true, result: ControlResult(ask: result))
            }, output: { lines.append($0) })
        } catch let code as ExitCode {
            exit = code.rawValue
        }
        #expect(exit == expectedExit)
        #expect(requests == [ControlRequest(cmd: .askResult, target: "ask-id", args: ControlArgs(window: "w"))])
        #expect(lines.count == 1)
        #expect(try JSONDecoder().decode(ControlAskResult.self, from: Data(#require(lines.first).utf8)) == result)
    }

    @Test func oneShotMalformedResultDoesNotCancelSomeoneElsesDialog() throws {
        let command = try #require(try Agtermctl.parseAsRoot(["ask", "result", "ask-id"]) as? Ask.Result)
        var requests: [ControlRequest] = []
        var errors: [String] = []
        #expect(throws: ExitCode.failure) {
            try command.execute(send: {
                requests.append($0)
                return ControlResponse(ok: true)
            }, output: { _ in }, errorOutput: { errors.append($0) })
        }
        #expect(requests.map(\.cmd) == [.askResult])
        #expect(errors == ["error: ask.result missing result"])
    }

    private func open(_ argv: [String]) throws -> Ask.Open {
        try #require(try Agtermctl.parseAsRoot(["ask"] + argv) as? Ask.Open)
    }
}
