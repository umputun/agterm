import ArgumentParser
import Testing
import agtermCore
@testable import agtermctlKit

struct SessionMetadataCommandsTests {
    private func request(_ argv: [String]) throws -> ControlRequest {
        let parsed = try Agtermctl.parseAsRoot(argv)
        guard let command = parsed as? any RequestCommand else {
            throw SocketClientError("parsed \(argv) is not a RequestCommand")
        }
        return try command.makeRequest()
    }

    @Test func flagMoveCarriesTheTargetAndBeforeAnchor() throws {
        var args = ControlArgs(mode: "move", window: "w1")
        args.before = "bb"
        #expect(try request(["session", "flag", "move", "--target", "aa", "--before", "bb", "--window", "w1"])
            == ControlRequest(cmd: .sessionFlag, target: "aa", args: args))
    }

    @Test func flagMoveCarriesTheAfterAnchor() throws {
        var args = ControlArgs(mode: "move")
        args.after = "cc"
        #expect(try request(["session", "flag", "move", "--after", "cc"])
            == ControlRequest(cmd: .sessionFlag, target: "active", args: args))
    }

    @Test(arguments: [["session", "flag", "move"], ["session", "flag", "move", "--before", "b", "--after", "c"]])
    func flagMoveNeedsExactlyOneAnchor(_ argv: [String]) {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(argv) }
    }

    @Test(arguments: ["on", "toggle", "clear"])
    func flagRefusesAnAnchorOutsideMove(_ mode: String) {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["session", "flag", mode, "--after", "c"]) }
    }

    @Test func infoSetsMarkdownAndHideAfterVerbatim() throws {
        var args = ControlArgs(text: "**3** ^[ok](color: \"green\")", mode: "set", hideAfter: 30, markdown: true)
        args.window = "w1"
        #expect(try request(["session", "info", "**3** ^[ok](color: \"green\")", "--markdown", "--hide-after", "30",
                             "--target", "s1", "--window", "w1"])
            == ControlRequest(cmd: .sessionInfo, target: "s1", args: args))
    }

    @Test func infoDefaultsToPlainUntimedOnTheActiveSession() throws {
        let req = try request(["session", "info", "**not bold**"])
        #expect(req == ControlRequest(cmd: .sessionInfo, target: "active", args: ControlArgs(text: "**not bold**", mode: "set")))
        #expect(req.args?.markdown == nil)
        #expect(req.args?.hideAfter == nil)
    }

    @Test func infoClears() throws {
        #expect(try request(["session", "info", "--clear"])
            == ControlRequest(cmd: .sessionInfo, target: "active", args: ControlArgs(mode: "clear")))
    }

    @Test(arguments: [
        (["session", "info"], "provide exactly one of a TEXT or --clear"),
        (["session", "info", "x", "--clear"], "provide exactly one of a TEXT or --clear"),
        (["session", "info", "--clear", "--markdown"], "--clear takes no --markdown or --hide-after"),
        (["session", "info", "--clear", "--hide-after", "5"], "--clear takes no --markdown or --hide-after"),
        (["session", "info", "x", "--hide-after=-1"], "hide-after must be 0...86400 seconds"),
        (["session", "info", "x", "--hide-after", "86401"], "hide-after must be 0...86400 seconds"),
    ])
    func infoRejectsBadFormsAtParseTime(argv: [String], message: String) {
        #expect(validationMessage(argv) == message)
    }

    private func validationMessage(_ argv: [String]) -> String? {
        do {
            _ = try Agtermctl.parseAsRoot(argv)
            return nil
        } catch {
            return Agtermctl.message(for: error)
        }
    }

    @Test func flagKeepsItsExistingModesAndTheToggleDefault() throws {
        #expect(try request(["session", "flag"])
            == ControlRequest(cmd: .sessionFlag, target: "active", args: ControlArgs(mode: "toggle")))
        #expect(try request(["session", "flag", "off", "--target", "aa"])
            == ControlRequest(cmd: .sessionFlag, target: "aa", args: ControlArgs(mode: "off")))
    }
}
