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

    @Test func flagKeepsItsExistingModesAndTheToggleDefault() throws {
        #expect(try request(["session", "flag"])
            == ControlRequest(cmd: .sessionFlag, target: "active", args: ControlArgs(mode: "toggle")))
        #expect(try request(["session", "flag", "off", "--target", "aa"])
            == ControlRequest(cmd: .sessionFlag, target: "aa", args: ControlArgs(mode: "off")))
    }
}
